#!/usr/bin/env bash
#SBATCH --job-name=dap-smoke
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=03:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/dap-smoke-%j.out

set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src/DAP"
ENV="$HOME/lianaiwei/tracking_envs/dap"
RUN="$ROOT/runs/dap_20260831_smoke5"
STATUS="$ROOT/status/dap.status"
CONDA_ROOT="$HOME/lianaiwei/miniforge3"

mkdir -p "$HOME/lianaiwei/tracking_envs" "$ROOT/cache/conda" "$ROOT/cache/pip" \
  "$ROOT/models/dap" "$ROOT/logs" "$ROOT/status" "$RUN/output"

printf 'RUNNING job=%s host=%s time=%s\n' \
  "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

set +u
source "$CONDA_ROOT/etc/profile.d/conda.sh"
set -u

export CONDA_PKGS_DIRS="$ROOT/cache/conda"
export PIP_CACHE_DIR="$ROOT/cache/pip"
export PYTHONNOUSERSITE=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

if [[ ! -x "$ENV/bin/python" ]]; then
  conda create --prefix "$ENV" python=3.12 pip -y
fi
conda activate "$ENV"

if [[ ! -f "$ENV/.dap_requirements_complete" ]]; then
  python -m pip install --upgrade pip
  # The repository's full requirements include the Gradio UI, Open3D and
  # Jupyter. None are imported by test/infer.py, so keep this smoke environment
  # limited to the actual single-image inference path.
  python -m pip install \
    torch==2.7.1 \
    torchvision==0.22.1 \
    torchmetrics==1.8.2 \
    'numpy<2' \
    opencv-python-headless \
    matplotlib \
    huggingface_hub \
    einops \
    safetensors \
    tensorboardX \
    mmengine \
    timm
  touch "$ENV/.dap_requirements_complete"
fi

if [[ ! -s "$ROOT/models/dap/model.pth" ]]; then
python - <<'PY'
from huggingface_hub import hf_hub_download

hf_hub_download(
    repo_id="Insta360-Research/DAP-weights",
    filename="model.pth",
    local_dir="/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/models/dap",
)
PY
fi

cat > "$RUN/infer.yaml" <<EOF
model:
  name: dap
  args:
    midas_model_type: vitl
    fine_tune_type: hypersim
    min_depth: 0.01
    max_depth: 1.0
    train_decoder: True
median_align: False
load_weights_dir: $ROOT/models/dap
input:
  height: 512
  width: 1024
inference:
  batch_size: 1
  num_workers: 1
  save_colormap: True
  colormap_type: jet
EOF

# Upstream test/infer.py does not consume config.input.height/width and sends
# the 4302x3369 teaser directly to ViT-L. Resize outside the source tree so the
# documented 1024x512 inference resolution is actually exercised.
python - <<PY
import cv2

source = cv2.imread("$SRC/assets/teaser.jpg")
if source is None:
    raise RuntimeError("failed to load upstream teaser image")
resized = cv2.resize(source, (1024, 512), interpolation=cv2.INTER_AREA)
if not cv2.imwrite("$RUN/input_1024x512.jpg", resized):
    raise RuntimeError("failed to write resized smoke input")
PY
printf '%s\n' "$RUN/input_1024x512.jpg" > "$RUN/input.txt"

cd "$SRC"
/usr/bin/time -v python test/infer.py \
  --config "$RUN/infer.yaml" \
  --txt "$RUN/input.txt" \
  --output "$RUN/output" \
  --gpu 0 \
  > "$RUN/infer.log" 2>&1

test -s "$RUN/output/depth_npy/000001.npy"
test -s "$RUN/output/depth_vis_color_100m/000001.png"

python - <<'PY'
import json
import os
import platform
import subprocess
import torch

root = "/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment"
manifest = {
    "python": platform.python_version(),
    "torch": torch.__version__,
    "cuda_runtime": torch.version.cuda,
    "cuda_available": torch.cuda.is_available(),
    "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
    "commit": subprocess.check_output(
        ["git", "-C", f"{root}/src/DAP", "rev-parse", "HEAD"], text=True
    ).strip(),
    "output_npy_bytes": os.path.getsize(
        f"{root}/runs/dap_20260831_smoke5/output/depth_npy/000001.npy"
    ),
}
with open(f"{root}/runs/dap_20260831_smoke5/manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
print(json.dumps(manifest, indent=2))
PY

printf 'COMPLETE job=%s time=%s\n' "$SLURM_JOB_ID" "$(date -Is)" > "$STATUS"
