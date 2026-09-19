#!/usr/bin/env bash
#SBATCH --job-name=pano-recovery
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=00:30:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/pano-recovery-%j.out

set -euo pipefail
ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
ENV="$HOME/lianaiwei/tracking_envs/omnitrack"
PYDEPS="$HOME/lianaiwei/tracking_envs/panorama_sot_pydeps"
OSNET=osnet_ain_x1_0_msmt17_256x128_amsgrad_ep50_lr0.0015_coslr_b64_fb10_softmax_labsmth_flip_jitter.pth
RUN="$ROOT/runs/quadtrack_recovery_${SLURM_JOB_ID}"
STATUS="$ROOT/status/quadtrack_recovery.status"
mkdir -p "$RUN" "$ROOT/logs" "$ROOT/status"
printf 'RUNNING job=%s host=%s time=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

set +u
source "$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
set -u
export PYTHONNOUSERSITE=1
export PYTHONPATH="$PYDEPS:$ROOT/src/ODTrack:$ROOT/scripts"

for item in 0016:2 0017:9 0017:13; do
  sequence="${item%%:*}"
  target_id="${item##*:}"
  python "$ROOT/scripts/evaluate_panorama_recovery.py" \
    --frames "$ROOT/datasets/QuadTrack/train/$sequence/img1" \
    --ground-truth "$ROOT/datasets/QuadTrack/train/$sequence/gt/gt.txt" \
    --target-id "$target_id" \
    --torchreid-repo "$ROOT/src/deep-person-reid" \
    --reid-checkpoint "$ROOT/models/osnet/$OSNET" \
    --detector "$ROOT/models/tbd/yolo11x.pt" \
    --output "$RUN/${sequence}_${target_id}.json" \
    --minimum-gap 3 --recovery-window 20 \
    --viewport-width 960 --viewport-height 640 --fov 100 \
    --detector-confidence 0.03 --detector-imgsz 1280
done

python - "$RUN" <<'PY'
import json
import pathlib
import sys
run = pathlib.Path(sys.argv[1])
items = [json.loads(path.read_text()) for path in sorted(run.glob("[0-9]*.json"))]
events = sum(item["events"] for item in items)
successes = sum(item["successful_recoveries"] for item in items)
delays = [
    event["recovery_delay_frames"]
    for item in items for event in item["details"]
    if event["recovery_delay_frames"] is not None
]
summary = {
    "targets": len(items), "events": events, "successful_recoveries": successes,
    "recovery_rate": successes / events if events else None,
    "mean_recovery_delay_frames": sum(delays) / len(delays) if delays else None,
    "per_target": [{key: item[key] for key in ("sequence", "target_id", "events", "recovery_rate", "mean_recovery_delay_frames")} for item in items],
}
(run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
PY
printf 'COMPLETE job=%s run=%s time=%s\n' "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
