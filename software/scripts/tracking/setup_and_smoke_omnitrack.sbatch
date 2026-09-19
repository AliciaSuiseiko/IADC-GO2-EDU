#!/usr/bin/env bash
#SBATCH --job-name=omni-smoke
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=04:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/omnitrack-smoke-%j.out

set -euo pipefail
ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src/OmniTrack"
ENV="$HOME/lianaiwei/tracking_envs/omnitrack"
RUN="$ROOT/runs/omnitrack_20260831"
STATUS="$ROOT/status/omnitrack.status"
CONDA_ROOT="$HOME/lianaiwei/miniforge3"
mkdir -p "$HOME/lianaiwei/tracking_envs" "$ROOT/cache/conda" "$ROOT/cache/pip" "$ROOT/logs" "$ROOT/status" "$RUN"
printf 'RUNNING job=%s host=%s time=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR
set +u
source "$CONDA_ROOT/etc/profile.d/conda.sh"
export CONDA_PKGS_DIRS="$CONDA_ROOT/pkgs"
export PIP_CACHE_DIR="$ROOT/cache/pip"
export PYTHONNOUSERSITE=1
export MAX_JOBS="${SLURM_CPUS_PER_TASK:-8}"
exec 9> "$ROOT/status/conda.lock"
flock 9
if [[ ! -x "$ENV/bin/python" ]]; then
  conda create --prefix "$ENV" python=3.10.15 pip -y
fi
conda activate "$ENV"
if [[ ! -f "$ENV/.torch_complete" ]]; then
  conda install pytorch==2.1.1 torchvision==0.16.1 torchaudio==2.1.1 pytorch-cuda=11.8 -c pytorch -c nvidia -y
  touch "$ENV/.torch_complete"
fi
flock -u 9
set -u
if [[ ! -x "$ENV/bin/nvcc" || ! -f "$ENV/include/cuda_runtime.h" || ! -f "$ENV/include/thrust/complex.h" || ! -f "$ENV/include/cusparse.h" ]]; then
  exec 8> "$ROOT/status/conda.lock"
  flock 8
  set +u
  conda install --prefix "$ENV" cuda-nvcc=11.8 cuda-cudart-dev=11.8 cuda-cccl=11.8 cuda-libraries-dev=11.8 -c nvidia -y
  set -u
  flock -u 8
fi
export CUDA_HOME="$ENV"
export PATH="$CUDA_HOME/bin:$PATH"
if [[ ! -f "$ENV/.requirements_complete" ]]; then
  python -m pip install --upgrade 'pip==24.2'
  sed -E '/^(torch|torchvision|torchaudio|# mmcv_full)(==|$)/d' \
    "$SRC/requirements.txt" > "$RUN/requirements.filtered.txt"
  python -m pip install -r "$RUN/requirements.filtered.txt"
  python -m pip install 'setuptools==69.5.1'
  python -m pip install --no-build-isolation causal_conv1d==1.1.1 mamba-ssm==1.2.0
  touch "$ENV/.requirements_complete"
fi
if [[ ! -f "$ENV/.extensions_complete" ]]; then
  MMCV_WITH_OPS=1 python -m pip install -e "$SRC/mmcv-full-1.7.1"
  python -m pip install -e "$SRC/projects/mmdet3d_plugin/ops"
  python -m pip install -e "$SRC/jrdb_toolkit/detection_eval"
  touch "$ENV/.extensions_complete"
fi
mkdir -p "$ROOT/models/omnitrack"
if [[ ! -s "$ROOT/models/omnitrack/resnet50-19c8e357.pth" ]]; then
  curl -fL --retry 5 --retry-delay 10 -C - \
    -o "$ROOT/models/omnitrack/resnet50-19c8e357.pth" \
    https://download.pytorch.org/models/resnet50-19c8e357.pth
fi
cd "$SRC"
python - <<'PY'
import json
import platform
import subprocess
import torch
import mmcv
import mmdet
from mmcv.ops import nms

root = "/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment"
manifest = {
    "python": platform.python_version(),
    "torch": torch.__version__,
    "cuda_runtime": torch.version.cuda,
    "cuda_available": torch.cuda.is_available(),
    "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
    "mmcv": mmcv.__version__,
    "mmdet": mmdet.__version__,
    "backbone_available": True,
    "task_checkpoint_available": False,
    "commit": subprocess.check_output(
        ["git", "-C", f"{root}/src/OmniTrack", "rev-parse", "HEAD"], text=True
    ).strip(),
}
with open(f"{root}/runs/omnitrack_20260831/manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
print(json.dumps(manifest, indent=2))
PY
printf 'COMPLETE job=%s time=%s\n' "$SLURM_JOB_ID" "$(date -Is)" > "$STATUS"
