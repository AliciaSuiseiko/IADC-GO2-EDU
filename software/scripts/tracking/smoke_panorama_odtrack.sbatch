#!/usr/bin/env bash
#SBATCH --job-name=pano-sot
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=01:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/pano-sot-%j.out

set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src/ODTrack"
ENV="$HOME/lianaiwei/tracking_envs/omnitrack"
PYDEPS="$HOME/lianaiwei/tracking_envs/panorama_sot_pydeps"
CHECKPOINT="${CHECKPOINT:-$ROOT/models/odtrack/Base-Fulldata-300ep/ODTrack_ep0300.pth.tar}"
SEQUENCE="${SEQUENCE:-0015}"
TARGET_ID="${TARGET_ID:-2}"
BBOX_X="${BBOX_X:-1610.9922}"
BBOX_Y="${BBOX_Y:-51.0912}"
BBOX_W="${BBOX_W:-110.5583}"
BBOX_H="${BBOX_H:-433.2768}"
INIT_BBOX="$BBOX_X,$BBOX_Y,$BBOX_W,$BBOX_H"
MAX_FRAMES="${MAX_FRAMES:-100}"
FRAMES="$ROOT/datasets/QuadTrack/train/$SEQUENCE/img1"
GROUND_TRUTH="$ROOT/datasets/QuadTrack/train/$SEQUENCE/gt/gt.txt"
RUN="$ROOT/runs/panorama_odtrack_${SEQUENCE}_${TARGET_ID}_${SLURM_JOB_ID}"
STATUS="$ROOT/status/panorama_odtrack.status"

mkdir -p "$ROOT/logs" "$ROOT/status"
printf 'RUNNING job=%s host=%s time=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

[[ -s "$CHECKPOINT" ]]
[[ -d "$FRAMES" ]]

set +u
source "$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
set -u
export PYTHONNOUSERSITE=1
export PYTHONPATH="$PYDEPS:$SRC:$ROOT/scripts"

python "$ROOT/scripts/test_panorama_sot_core.py"
python "$ROOT/scripts/run_panorama_odtrack.py" \
  --odtrack-repo "$SRC" \
  --checkpoint "$CHECKPOINT" \
  --config baseline \
  --frames "$FRAMES" \
  --init-bbox "$INIT_BBOX" \
  --output "$RUN" \
  --viewport-size 640 \
  --fov 100 \
  --fps 10 \
  --max-frames "$MAX_FRAMES"

python "$ROOT/scripts/evaluate_panorama_sot.py" \
  --predictions "$RUN/predictions.json" \
  --ground-truth "$GROUND_TRUTH" \
  --target-id "$TARGET_ID" \
  --erp-width 2048 \
  --erp-height 480

printf 'COMPLETE job=%s run=%s time=%s\n' "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
