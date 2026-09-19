#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
RUN="$ROOT/runs/x5_mid360_refinement_20260901"
WS="$ROOT/src/x5_mid360_bounded_refiner_ws"
STATUS="$RUN/bounded.status"

printf 'RUNNING started=%s\n' "$(date -Is)" > "$STATUS"

set +u
source /opt/ros/humble/setup.bash
source /home/orin/lianaiwei/src/direct_visual_lidar_calibration_ws/install/setup.bash
source "$WS/install/setup.bash"
source /home/orin/lianaiwei/scripts/hardware/nomachine/nomachine-session-env.sh
set -u
export LD_LIBRARY_PATH="/home/orin/lianaiwei/deps/direct_visual_lidar_calibration/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

[[ "$(ros2 pkg prefix direct_visual_lidar_calibration)" == "$WS/install/direct_visual_lidar_calibration" ]]

for variant in initial_filtered dap_gated; do
    DATA="$RUN/$variant"
    python3 - "$DATA/calib.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.setdefault("results", {}).pop("T_lidar_camera", None)
path.write_text(json.dumps(data, indent=2) + "\n")
PY
    ros2 run direct_visual_lidar_calibration calibrate "$DATA" --background --auto_quit \
        > "$RUN/bounded-$variant.log" 2>&1
done

python3 - "$RUN" <<'PY'
import json
import sys
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation

run = Path(sys.argv[1])
results = {}
transforms = {}
for variant in ("initial_filtered", "dap_gated"):
    config = json.loads((run / variant / "calib.json").read_text())
    initial = np.asarray(config["results"]["init_T_lidar_camera"], dtype=float)
    final = np.asarray(config["results"]["T_lidar_camera"], dtype=float)
    initial_rotation = Rotation.from_quat(initial[3:]).as_matrix()
    final_rotation = Rotation.from_quat(final[3:]).as_matrix()
    translation_delta = float(np.linalg.norm(final[:3] - initial[:3]))
    rotation_delta = float(np.rad2deg(Rotation.from_matrix(final_rotation @ initial_rotation.T).magnitude()))
    transforms[variant] = final
    results[variant] = {
        "initial": initial.tolist(),
        "final": final.tolist(),
        "translation_delta_m": translation_delta,
        "rotation_delta_deg": rotation_delta,
        "inside_global_bound": translation_delta < 0.0501 and rotation_delta < 1.001,
        "near_bound": translation_delta > 0.0475 or rotation_delta > 0.95,
    }

a = transforms["initial_filtered"]
b = transforms["dap_gated"]
a_rotation = Rotation.from_quat(a[3:]).as_matrix()
b_rotation = Rotation.from_quat(b[3:]).as_matrix()
results["ab_difference"] = {
    "translation_m": float(np.linalg.norm(a[:3] - b[:3])),
    "rotation_deg": float(np.rad2deg(Rotation.from_matrix(a_rotation @ b_rotation.T).magnitude())),
}
results["accepted"] = (
    all(results[name]["inside_global_bound"] and not results[name]["near_bound"] for name in ("initial_filtered", "dap_gated"))
    and results["ab_difference"]["translation_m"] < 0.02
    and results["ab_difference"]["rotation_deg"] < 0.2
)
(run / "bounded_summary.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
PY

printf 'COMPLETE summary=%s\n' "$RUN/bounded_summary.json" > "$STATUS"
