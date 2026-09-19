#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
RUN="${1:?fresh run directory is required}"
BAG_NAME="${2:?bag name is required}"
REFINEMENT="$RUN/refinement"
PREPARE="$ROOT/scripts/prepare_x5_mid360_refinement.py"
WS="$ROOT/src/x5_mid360_bounded_refiner_ws"
STATUS="$REFINEMENT/status"

case "$RUN" in
    "$ROOT"/runs/fresh_x5_mid360_*) ;;
    *) echo "run must be a fresh capture below $ROOT/runs" >&2; exit 2 ;;
esac
[[ "$BAG_NAME" =~ ^pose-live-[0-9][0-9]$ ]]
[[ -s "$RUN/preprocessed/$BAG_NAME.png" ]]
[[ -s "$RUN/preprocessed/$BAG_NAME.ply" ]]
[[ -s "$REFINEMENT/dap/$BAG_NAME/depth.npy" ]]
[[ ! -e "$REFINEMENT/initial_filtered" ]]
[[ ! -e "$REFINEMENT/dap_gated" ]]

mkdir -p "$REFINEMENT"
printf 'RUNNING started=%s\n' "$(date -Is)" > "$STATUS"
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if (( rc != 0 )); then
        printf 'FAILED rc=%s finished=%s\n' "$rc" "$(date -Is)" > "$STATUS"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

cp -a "$RUN/preprocessed" "$REFINEMENT/initial_filtered"
cp -a "$RUN/preprocessed" "$REFINEMENT/dap_gated"
python3 "$PREPARE" --data "$REFINEMENT/initial_filtered" \
    > "$REFINEMENT/prepare-intensity.log" 2>&1
python3 "$PREPARE" --data "$REFINEMENT/dap_gated" \
    --depth-root "$REFINEMENT/dap" \
    > "$REFINEMENT/prepare-dap.log" 2>&1

set +u
source /opt/ros/humble/setup.bash
source /home/orin/lianaiwei/src/direct_visual_lidar_calibration_ws/install/setup.bash
source "$WS/install/setup.bash"
source /home/orin/lianaiwei/scripts/hardware/nomachine/nomachine-session-env.sh
set -u
export LD_LIBRARY_PATH="/home/orin/lianaiwei/deps/direct_visual_lidar_calibration/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[[ "$(ros2 pkg prefix direct_visual_lidar_calibration)" == "$WS/install/direct_visual_lidar_calibration" ]]

for variant in initial_filtered dap_gated; do
    DATA="$REFINEMENT/$variant"
    python3 - "$DATA/calib.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.setdefault("results", {}).pop("T_lidar_camera", None)
path.write_text(json.dumps(data, indent=2) + "\n")
PY
    timeout --signal=INT --kill-after=20 180 \
        ros2 run direct_visual_lidar_calibration calibrate "$DATA" --background --auto_quit \
        > "$REFINEMENT/bounded-$variant.log" 2>&1
    python3 - "$DATA/calib.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert len(data["results"]["T_lidar_camera"]) == 7
PY
done

python3 - "$REFINEMENT" "$RUN/fresh_refinement_summary.json" <<'PY'
import json
import sys
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation

root = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
results = {}
transforms = {}
for output_name, variant in (("intensity_only", "initial_filtered"), ("dap_gated", "dap_gated")):
    config = json.loads((root / variant / "calib.json").read_text())
    initial = np.asarray(config["results"]["init_T_lidar_camera"], dtype=float)
    final = np.asarray(config["results"]["T_lidar_camera"], dtype=float)
    delta_t = float(np.linalg.norm(final[:3] - initial[:3]))
    delta_r = float(np.rad2deg(Rotation.from_matrix(
        Rotation.from_quat(final[3:]).as_matrix() @ Rotation.from_quat(initial[3:]).as_matrix().T
    ).magnitude()))
    transforms[output_name] = final
    results[output_name] = {
        "initial": initial.tolist(),
        "final": final.tolist(),
        "translation_delta_m": delta_t,
        "rotation_delta_deg": delta_r,
        "near_bound": delta_t > 0.0475 or delta_r > 0.95,
    }

a = transforms["intensity_only"]
b = transforms["dap_gated"]
results["ab_difference"] = {
    "translation_m": float(np.linalg.norm(a[:3] - b[:3])),
    "rotation_deg": float(np.rad2deg(Rotation.from_matrix(
        Rotation.from_quat(a[3:]).as_matrix() @ Rotation.from_quat(b[3:]).as_matrix().T
    ).magnitude())),
}
results["accepted_for_sysnav"] = False
results["reason"] = "multi-pose consistency and held-out validation are required"
summary_path.write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
PY

printf 'COMPLETE summary=%s finished=%s\n' "$RUN/fresh_refinement_summary.json" "$(date -Is)" > "$STATUS"
trap - EXIT
