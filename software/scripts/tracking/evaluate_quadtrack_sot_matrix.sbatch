#!/usr/bin/env bash
#SBATCH --job-name=pano-sot-matrix
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=01:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/pano-sot-matrix-%j.out

set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
ENV="$HOME/lianaiwei/tracking_envs/omnitrack"
PYDEPS="$HOME/lianaiwei/tracking_envs/panorama_sot_pydeps"
OSNET=osnet_ain_x1_0_msmt17_256x128_amsgrad_ep50_lr0.0015_coslr_b64_fb10_softmax_labsmth_flip_jitter.pth
RUN="$ROOT/runs/quadtrack_sot_matrix_${SLURM_JOB_ID}"
STATUS="$ROOT/status/quadtrack_sot_matrix.status"
mkdir -p "$RUN" "$ROOT/logs" "$ROOT/status"
printf 'RUNNING job=%s host=%s time=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

set +u
source "$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
set -u
export PYTHONNOUSERSITE=1
export PYTHONPATH="$PYDEPS:$ROOT/src/ODTrack:$ROOT/scripts"

targets=("0015:1" "0015:2" "0016:1" "0016:2" "0017:3" "0017:4" "0017:9")
detectors=("yolo11n.pt" "yolo26n.pt")

for detector in "${detectors[@]}"; do
  test -s "$ROOT/models/tbd/$detector"
  detector_name="${detector%.pt}"
  for item in "${targets[@]}"; do
    sequence="${item%%:*}"
    target_id="${item##*:}"
    gt="$ROOT/datasets/QuadTrack/train/$sequence/gt/gt.txt"
    bbox="$(awk -F, -v id="$target_id" '$1 == 0 && $2 == id {print $3 "," $4 "," $5 "," $6; exit}' "$gt")"
    test -n "$bbox"
    output="$RUN/${detector_name}_${sequence}_${target_id}"
    python "$ROOT/scripts/run_panorama_odtrack_reid.py" \
      --odtrack-repo "$ROOT/src/ODTrack" \
      --checkpoint "$ROOT/models/odtrack/Base-Fulldata-300ep/ODTrack_ep0300.pth.tar" \
      --torchreid-repo "$ROOT/src/deep-person-reid" \
      --reid-checkpoint "$ROOT/models/osnet/$OSNET" \
      --detector "$ROOT/models/tbd/$detector" \
      --frames "$ROOT/datasets/QuadTrack/train/$sequence/img1" \
      --init-bbox "$bbox" --output "$output" \
      --detector-confidence 0.08 --detector-interval 5 --max-frames 600
    python "$ROOT/scripts/evaluate_panorama_sot.py" \
      --predictions "$output/predictions.json" --ground-truth "$gt" \
      --target-id "$target_id" --erp-width 2048 --erp-height 480
  done
done

python - "$RUN" <<'PY'
import json
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
rows = []
for metrics_path in sorted(run.glob("*/metrics.json")):
    metrics = json.loads(metrics_path.read_text())
    prediction = json.loads((metrics_path.parent / "predictions.json").read_text())
    detector, sequence, target = metrics_path.parent.name.rsplit("_", 2)
    rows.append({
        "detector": detector,
        "sequence": sequence,
        "target_id": int(target),
        "frames": metrics["frames"],
        "mean_circular_iou": metrics["mean_circular_iou"],
        "success_at_iou_0_5": metrics["success_at_iou_0_5"],
        "mean_bearing_error_deg": metrics["mean_bearing_error_deg"],
        "mean_end_to_end_fps": prediction["mean_end_to_end_fps"],
        "corrections": prediction["corrections"],
        "identity_rejections": prediction["identity_rejections"],
    })
summary = {"runs": rows}
for detector in sorted({row["detector"] for row in rows}):
    selected = [row for row in rows if row["detector"] == detector]
    summary[detector] = {
        key: sum(row[key] for row in selected) / len(selected)
        for key in ("mean_circular_iou", "success_at_iou_0_5", "mean_bearing_error_deg", "mean_end_to_end_fps")
    }
(run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
PY

printf 'COMPLETE job=%s run=%s time=%s\n' "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
