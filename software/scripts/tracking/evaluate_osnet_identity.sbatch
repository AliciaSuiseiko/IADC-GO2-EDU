#!/usr/bin/env bash
#SBATCH --job-name=pano-reid
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=00:30:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/pano-reid-%j.out

set -euo pipefail
ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
ENV="$HOME/lianaiwei/tracking_envs/omnitrack"
PYDEPS="$HOME/lianaiwei/tracking_envs/panorama_sot_pydeps"
MODEL=osnet_ain_x1_0_msmt17_256x128_amsgrad_ep50_lr0.0015_coslr_b64_fb10_softmax_labsmth_flip_jitter.pth
RUN="$ROOT/runs/panorama_reid_${SLURM_JOB_ID}"
mkdir -p "$RUN" "$ROOT/logs"

set +u
source "$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
set -u
export PYTHONNOUSERSITE=1
export PYTHONPATH="$PYDEPS:$ROOT/scripts"

python "$ROOT/scripts/evaluate_osnet_identity.py" \
  --torchreid-repo "$ROOT/src/deep-person-reid" \
  --checkpoint "$ROOT/models/osnet/$MODEL" \
  --frames "$ROOT/datasets/QuadTrack/train/0017/img1" \
  --ground-truth "$ROOT/datasets/QuadTrack/train/0017/gt/gt.txt" \
  --target-id 4 \
  --stride 5 \
  --output "$RUN/metrics.json"
