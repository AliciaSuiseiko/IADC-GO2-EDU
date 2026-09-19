#!/usr/bin/env bash
#SBATCH --job-name=sysnav-pytorch3d
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node2
#SBATCH --cpus-per-task=8
#SBATCH --time=02:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/logs/setup-sysnav-pytorch3d-%j.out

set -euo pipefail

ROOT="$HOME/lianaiwei"
STORE="/mnt/slurmfs-4090node3/user_data/$USER/lianaiwei"
ENV="$STORE/envs/sysnav-jazzy"
STATUS="$STORE/logs/setup-sysnav-pytorch3d.status"
mkdir -p "$STORE/logs" "$STORE/cache/pip"

printf 'RUNNING job=%s host=%s %s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" >"$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s %s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" >"$STATUS"; exit "$rc"' ERR

set +u
source "$ROOT/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
set -u
export PYTHONNOUSERSITE=1
export PIP_CACHE_DIR="$STORE/cache/pip"
export MAX_JOBS="${SLURM_CPUS_PER_TASK:-8}"

if ! python -c 'from pytorch3d.ops import box3d_overlap'; then
  # SysNav officially installs PyTorch3D from Git. Build its CPU extension by
  # hiding the GPU during compilation; SAM2 and YOLOE retain CUDA at runtime.
  CUDA_VISIBLE_DEVICES='' python -m pip install --no-build-isolation \
    'git+https://github.com/facebookresearch/pytorch3d.git'
fi

python - <<'PY'
import torch
from pytorch3d.ops import box3d_overlap

assert callable(box3d_overlap)
print("pytorch3d_import_ok", torch.__version__)
PY

printf 'COMPLETE job=%s %s\n' "$SLURM_JOB_ID" "$(date -Is)" >"$STATUS"
