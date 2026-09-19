#!/usr/bin/env bash
#SBATCH --job-name=tracking-audit
#SBATCH --partition=GPU
#SBATCH --cpus-per-task=8
#SBATCH --gres=gpu:4090:1
#SBATCH --mem=64G
#SBATCH --time=12:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/slurm-%j.out

set -uo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src"
ENVS="$ROOT/envs"
MODELS="$ROOT/models"
RUNTIME="$ROOT/runtime"
CACHE="$ROOT/cache"
RUN="$ROOT/runs/setup_${SLURM_JOB_ID}"
STATUS="$ROOT/setup.status"
CONDA_SH="$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 1 ;;
esac

mkdir -p "$ENVS" "$MODELS" "$RUNTIME" "$CACHE/pip" "$CACHE/conda" "$RUN"
printf 'RUNNING\tjob=%s\thost=%s\t%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
printf 'job_id=%s\nhost=%s\nstart=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$RUN/manifest.txt"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader >> "$RUN/manifest.txt"

source "$CONDA_SH"
export CONDA_PKGS_DIRS="$CACHE/conda"
export PIP_CACHE_DIR="$CACHE/pip"
export PYTHONNOUSERSITE=1
export HF_HOME="$CACHE/huggingface"
export TORCH_HOME="$CACHE/torch"
export CUDA_HOME=/usr/local/cuda
export PATH="$CUDA_HOME/bin:$PATH"
export MAX_JOBS=8

ensure_env() {
  local prefix="$1"
  local python_version="$2"
  if [[ -d "$prefix" && ! -s "$prefix/conda-meta/history" ]]; then
    printf 'Incomplete environment requires manual inspection: %s\n' "$prefix" >&2
    return 1
  fi
  if [[ ! -x "$prefix/bin/python" ]]; then
    conda create -y -p "$prefix" --override-channels -c conda-forge \
      "python=$python_version" pip
  fi
}

activate_env() {
  set +u
  conda activate "$1"
  set -u
}

install_torch() {
  local version="$1"
  local vision="$2"
  local audio="$3"
  local index="$4"
  if ! python - "$version" "$vision" <<'PY'
import sys
import torch, torchvision
assert torch.__version__.split('+')[0] == sys.argv[1], torch.__version__
assert torchvision.__version__.split('+')[0] == sys.argv[2], torchvision.__version__
PY
  then
    if [[ -n "$audio" ]]; then
      python -m pip install "torch==$version" "torchvision==$vision" "torchaudio==$audio" --index-url "$index"
    else
      python -m pip install "torch==$version" "torchvision==$vision" --index-url "$index"
    fi
  fi
}

download_file() {
  local output="$1"
  local url="$2"
  mkdir -p "$(dirname "$output")"
  [[ -s "$output" ]] && return 0
  curl -fL --retry 5 --retry-delay 10 -C - -o "$output" "$url"
  test -s "$output"
}

setup_omnitrack() {
  local env="$ENVS/omnitrack"
  local filtered="$RUN/omnitrack-requirements.txt"
  ensure_env "$env" 3.10
  activate_env "$env"
  python -m pip install --upgrade pip==24.2 'setuptools<70' wheel
  install_torch 2.1.1 0.16.1 2.1.1 https://download.pytorch.org/whl/cu118
  sed -E '/^(torch|torchvision|torchaudio|# mmcv_full)(==|$)/d' "$SRC/OmniTrack/requirements.txt" > "$filtered"
  python -m pip install -r "$filtered"
  python -m pip install --no-build-isolation causal_conv1d==1.1.1 mamba-ssm==1.2.0
  MMCV_WITH_OPS=1 python -m pip install --no-build-isolation -e "$SRC/OmniTrack/mmcv-full-1.7.1"
  (cd "$SRC/OmniTrack/projects/mmdet3d_plugin/ops" && python setup.py develop)
  (cd "$SRC/OmniTrack/jrdb_toolkit/detection_eval" && python setup.py develop)
  download_file "$MODELS/OmniTrack/resnet50-19c8e357.pth" \
    https://download.pytorch.org/models/resnet50-19c8e357.pth
  PYTHONPATH="$SRC/OmniTrack" python - <<'PY'
import torch
import mmcv
import mmdet
from mmcv.ops import nms
x = torch.arange(4096, device="cuda", dtype=torch.float32)
assert float((x * x).sum().cpu()) > 0
print("omnitrack_import_cuda_ok", torch.__version__, mmcv.__version__, mmdet.__version__, torch.cuda.get_device_name(0))
print("gpu_peak_bytes", torch.cuda.max_memory_allocated())
PY
  printf 'smoke=import_cuda_mmcv_ops\nevaluation=blocked_no_official_task_checkpoint_or_dataset\n' > "$RUN/omnitrack.result"
}

setup_oavat() {
  local env="$ENVS/oavat"
  ensure_env "$env" 3.10
  activate_env "$env"
  python -m pip install --upgrade 'pip<26' wheel
  install_torch 2.2.2 0.17.2 2.2.2 https://download.pytorch.org/whl/cu121
  python -m pip install \
    ultralytics==8.3.223 diffusers==0.25.0 transformers accelerate safetensors \
    opencv-python numpy==1.24.4 pandas==1.5.2 matplotlib==3.8.4 \
    scipy==1.15.3 scikit-learn==1.1.3 scikit-image==0.25.2 \
    pillow pyyaml tqdm einops huggingface-hub fastapi pygame \
    gym==0.10.9 tensorboard wandb easydict gdown lmdb shapely tensorboardX
  python -m pip install --no-deps -e "$SRC/OA-VAT/dinov3-main"
  PYTHONPATH="$SRC/OA-VAT:$SRC/OA-VAT/ORTrack" python - <<'PY'
import cv2
import torch
import config
import tracking.detection
from dinov3_feature_extractor import DINOv3FeatureExtractor
x = torch.eye(64, device="cuda")
assert float(x.sum().cpu()) == 64.0
print("oavat_import_cuda_ok", torch.__version__, torch.cuda.get_device_name(0))
print("gpu_peak_bytes", torch.cuda.max_memory_allocated())
PY
  PYTHONPATH="$SRC/OA-VAT:$SRC/OA-VAT/ORTrack" python "$SRC/OA-VAT/eval_on_real_image.py" --help > "$RUN/oavat-help.txt"
  printf 'smoke=imports_cuda_static_image_cli\ninference=blocked_official_dinov3_and_yoloe_weights_absent\nsimulation=not_run\n' > "$RUN/oavat.result"
}

setup_dap() {
  local env="$ENVS/dap"
  local model_dir="$MODELS/DAP"
  local dap_runtime="$RUNTIME/dap"
  ensure_env "$env" 3.12
  activate_env "$env"
  python -m pip install --upgrade 'pip<26' wheel
  install_torch 2.7.1 0.22.1 '' https://download.pytorch.org/whl/cu118
  python -m pip install torchmetrics==1.8.2 opencv-python matplotlib huggingface_hub \
    einops safetensors tensorboardX mmengine pyyaml tqdm timm pillow
  download_file "$model_dir/model.pth" \
    https://huggingface.co/Insta360-Research/DAP-weights/resolve/main/model.pth
  mkdir -p "$dap_runtime/input" "$dap_runtime/output"
  python - "$dap_runtime/input/synthetic_panorama.png" <<'PY'
from pathlib import Path
import sys
import numpy as np
from PIL import Image
h, w = 256, 512
x = np.linspace(0, 255, w, dtype=np.uint8)[None, :]
y = np.linspace(0, 255, h, dtype=np.uint8)[:, None]
rgb = np.stack((np.broadcast_to(x, (h, w)), np.broadcast_to(y, (h, w)), np.full((h, w), 127, np.uint8)), axis=-1)
Image.fromarray(rgb).save(sys.argv[1])
PY
  printf '%s\n' "$dap_runtime/input/synthetic_panorama.png" > "$dap_runtime/input.txt"
  cat > "$dap_runtime/infer.yaml" <<EOF
model:
  name: dap
  args:
    midas_model_type: vitl
    fine_tune_type: hypersim
    min_depth: 0.01
    max_depth: 1.0
    train_decoder: True
median_align: False
load_weights_dir: $model_dir
input:
  height: 512
  width: 1024
inference:
  batch_size: 1
  num_workers: 1
  save_colormap: True
  colormap_type: jet
EOF
  cd "$SRC/DAP"
  python test/infer.py --config "$dap_runtime/infer.yaml" --txt "$dap_runtime/input.txt" \
    --output "$dap_runtime/output" --gpu 0
  test -s "$dap_runtime/output/depth_npy/000001.npy"
  python - "$dap_runtime/output/depth_npy/000001.npy" <<'PY'
import sys
import numpy as np
import torch
a = np.load(sys.argv[1])
assert a.ndim == 2 and np.isfinite(a).all(), (a.shape, np.isfinite(a).mean())
print("dap_single_image_ok", a.shape, float(a.min()), float(a.max()))
print("gpu_peak_bytes", torch.cuda.max_memory_allocated())
PY
  printf 'smoke=official_weight_single_synthetic_panorama\noutput=%s\n' \
    "$dap_runtime/output/depth_npy/000001.npy" > "$RUN/dap.result"
}

setup_lhvln() {
  local env="$ENVS/lhvln"
  ensure_env "$env" 3.9
  activate_env "$env"
  conda install -y -p "$env" --override-channels -c conda-forge -c aihabitat \
    habitat-sim==0.3.1 headless
  python -m pip install easydict==1.10 h5py jsonlines==2.0.0 lmdb==1.4.1 \
    more_itertools==10.1.0 msgpack_numpy==0.4.8 networkx==2.5.1 \
    numpy==1.23.5 opencv_python==4.7.0.72 Pillow==10.1.0 psutil==5.9.4 \
    PyYAML==6.0.1 requests==2.25.1 shapely==2.0.1 tqdm==4.64.1
  PYTHONPATH="$SRC/LH-VLN" python - <<'PY'
import habitat_sim
from NavModel.RandomNav import RandomAgent
agent = RandomAgent()
assert set(agent.actions) == {"move_forward", "turn_left", "turn_right", "stop"}
print("lhvln_import_ok", habitat_sim.__file__, len(agent.actions))
PY
  printf 'smoke=habitat_import_random_baseline_structure\nbenchmark=blocked_hm3d_requires_matterport_access_and_is_not_present\n' > "$RUN/lhvln.result"
}

setup_sam3() {
  local env="$ENVS/sam3"
  ensure_env "$env" 3.12
  activate_env "$env"
  python -m pip install --upgrade 'pip<26' wheel
  install_torch 2.7.1 0.22.1 '' https://download.pytorch.org/whl/cu118
  python -m pip install --no-build-isolation -e "$SRC/sam3"
  PYTHONPATH="$SRC/sam3" python - <<'PY'
import torch
import sam3
from sam3.model_builder import build_sam3_image_model
x = torch.ones(32, device="cuda")
assert float(x.sum().cpu()) == 32.0
print("sam3_import_cuda_ok", sam3.__version__, torch.__version__, torch.cuda.get_device_name(0))
print("gpu_peak_bytes", torch.cuda.max_memory_allocated())
PY
  printf 'smoke=official_package_import_cuda\ninference=blocked_official_huggingface_checkpoint_is_gated\n' > "$RUN/sam3.result"
}

run_stage() {
  local name="$1"
  local function_name="$2"
  local log="$RUN/$name.log"
  printf '%s\tRUNNING\t%s\n' "$name" "$(date -Is)" | tee -a "$STATUS"
  set +e
  (
    set -euo pipefail
    "$function_name"
  ) > "$log" 2>&1
  local rc=$?
  set -e
  if (( rc == 0 )); then
    printf '%s\tREADY\trc=0\tlog=%s\t%s\n' "$name" "$log" "$(date -Is)" | tee -a "$STATUS"
  else
    printf '%s\tFAILED\trc=%s\tlog=%s\t%s\n' "$name" "$rc" "$log" "$(date -Is)" | tee -a "$STATUS"
  fi
  du -sh "$ENVS/$name" 2>/dev/null | tee -a "$RUN/resources.tsv" || true
  nvidia-smi --query-gpu=timestamp,name,memory.used,memory.total,utilization.gpu \
    --format=csv,noheader | tee -a "$RUN/resources.tsv" || true
}

run_stage omnitrack setup_omnitrack
run_stage oavat setup_oavat
run_stage dap setup_dap
run_stage lhvln setup_lhvln
run_stage sam3 setup_sam3

printf 'FINISHED\tjob=%s\trun=%s\t%s\n' "$SLURM_JOB_ID" "$RUN" "$(date -Is)" | tee -a "$STATUS"
