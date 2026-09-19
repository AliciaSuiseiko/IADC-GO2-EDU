#!/usr/bin/env bash
#SBATCH --job-name=sam3-smoke
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=03:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/sam3-smoke-%j.out

set -euo pipefail
ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src/sam3"
ENV="$HOME/lianaiwei/tracking_envs/sam3"
RUN="$ROOT/runs/sam3_20260831"
STATUS="$ROOT/status/sam3.status"
CONDA_ROOT="$HOME/lianaiwei/miniforge3"
mkdir -p "$HOME/lianaiwei/tracking_envs" "$ROOT/cache/conda" "$ROOT/cache/pip" "$ROOT/logs" "$ROOT/status" "$RUN"
printf 'RUNNING job=%s host=%s time=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR
set +u
source "$CONDA_ROOT/etc/profile.d/conda.sh"
export CONDA_PKGS_DIRS="$CONDA_ROOT/pkgs"
export PIP_CACHE_DIR="$ROOT/cache/pip"
export PYTHONNOUSERSITE=1
exec 9> "$ROOT/status/conda.lock"
flock 9
if [[ ! -x "$ENV/bin/python" ]]; then
  conda create --prefix "$ENV" python=3.12 pip -y
fi
flock -u 9
conda activate "$ENV"
set -u
python -m pip install "setuptools==69.5.1" einops pycocotools psutil
if [[ ! -f "$ENV/.requirements_complete" ]]; then
  python -m pip install torch==2.7.1 torchvision==0.22.1 \
    --index-url https://download.pytorch.org/whl/cu118
  python -m pip install -e "$SRC"
  touch "$ENV/.requirements_complete"
fi
cd "$SRC"
python - <<'PY'
import json
import platform
import subprocess
import torch
import sam3
from sam3.model_builder import build_sam3_image_model

root = "/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment"
manifest = {
    "python": platform.python_version(),
    "torch": torch.__version__,
    "cuda_runtime": torch.version.cuda,
    "cuda_available": torch.cuda.is_available(),
    "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
    "sam3_import": sam3.__name__,
    "builder_import": build_sam3_image_model.__name__,
    "checkpoint_available": False,
    "checkpoint_blocker": "Official Hugging Face checkpoint requires approved authentication",
    "commit": subprocess.check_output(
        ["git", "-C", f"{root}/src/sam3", "rev-parse", "HEAD"], text=True
    ).strip(),
}
with open(f"{root}/runs/sam3_20260831/manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
print(json.dumps(manifest, indent=2))
PY
printf 'COMPLETE job=%s time=%s\n' "$SLURM_JOB_ID" "$(date -Is)" > "$STATUS"
