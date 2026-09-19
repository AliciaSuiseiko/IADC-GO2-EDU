#!/usr/bin/env bash
#SBATCH --job-name=pano-ltsot
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=01:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/pano-ltsot-%j.out

set -euo pipefail
ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
ENV="$HOME/lianaiwei/tracking_envs/omnitrack"
PYDEPS="$HOME/lianaiwei/tracking_envs/panorama_sot_pydeps"
OSNET=osnet_ain_x1_0_msmt17_256x128_amsgrad_ep50_lr0.0015_coslr_b64_fb10_softmax_labsmth_flip_jitter.pth
RUN="$ROOT/runs/panorama_ltsot_${SLURM_JOB_ID}"
MAX_FRAMES="${MAX_FRAMES:-300}"
DETECTOR_INTERVAL="${DETECTOR_INTERVAL:-5}"
mkdir -p "$ROOT/logs"

set +u
source "$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
set -u
export PYTHONNOUSERSITE=1
export PYTHONPATH="$PYDEPS:$ROOT/src/ODTrack:$ROOT/scripts"

python "$ROOT/scripts/run_panorama_odtrack_reid.py" \
  --odtrack-repo "$ROOT/src/ODTrack" \
  --checkpoint "$ROOT/models/odtrack/Base-Fulldata-300ep/ODTrack_ep0300.pth.tar" \
  --torchreid-repo "$ROOT/src/deep-person-reid" \
  --reid-checkpoint "$ROOT/models/osnet/$OSNET" \
  --detector "$ROOT/models/tbd/yolo11n.pt" \
  --frames "$ROOT/datasets/QuadTrack/train/0017/img1" \
  --init-bbox 1555.0809547325102,87.2736,88.6371028806583,391.4688 \
  --output "$RUN" \
  --detector-confidence 0.08 \
  --detector-interval "$DETECTOR_INTERVAL" \
  --max-frames "$MAX_FRAMES"

python "$ROOT/scripts/evaluate_panorama_sot.py" \
  --predictions "$RUN/predictions.json" \
  --ground-truth "$ROOT/datasets/QuadTrack/train/0017/gt/gt.txt" \
  --target-id 4 \
  --erp-width 2048 \
  --erp-height 480
