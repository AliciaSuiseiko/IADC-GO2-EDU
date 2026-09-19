#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
SRC="$ROOT/src/DAP"
MODEL_DIR="$ROOT/models/dap"
ENV_DIR=/home/orin/lianaiwei/tracking_envs/dap_jetson
ENV_SOURCE=/home/orin/lianaiwei/venvs/sysnav
RUN="$ROOT/runs/dap_jetson_20260901_retry3"
STATUS_DIR="$ROOT/status"
SOURCE_IMAGE=/home/orin/lianaiwei/logs/sysnav-preview-20260813-150927/x5-current.jpg
PREPARE="$ROOT/scripts/prepare_dap_input.py"
COMPAT_INFER="$ROOT/scripts/dap_torch24_compat_infer.py"

mkdir -p "$RUN/logs" "$RUN/input" "$RUN/output" "$STATUS_DIR" "$(dirname "$ENV_DIR")"
printf 'RUNNING\n' > "$STATUS_DIR/dap_jetson.status"

stats_pid=
on_exit() {
    rc=$?
    if [[ -n "$stats_pid" ]]; then
        kill "$stats_pid" 2>/dev/null || true
        wait "$stats_pid" 2>/dev/null || true
    fi
    if (( rc != 0 )); then
        printf 'FAILED rc=%s log=%s\n' "$rc" "$RUN/logs/job.log" > "$STATUS_DIR/dap_jetson.status"
    fi
}
trap on_exit EXIT

for path in "$SRC/.git" "$MODEL_DIR/model.pth" "$ENV_SOURCE/bin/python" "$SOURCE_IMAGE" "$PREPARE" "$COMPAT_INFER"; do
    if [[ ! -e "$path" ]]; then
        printf 'required path missing: %s\n' "$path" >&2
        exit 2
    fi
done

if [[ ! -x "$ENV_DIR/bin/python" ]]; then
    staging="$ENV_DIR.staging.$$"
    rm -rf "$staging"
    cp -a --reflink=auto "$ENV_SOURCE" "$staging"
    mv "$staging" "$ENV_DIR"
fi

if ! "$ENV_DIR/bin/python" -c 'import einops' >/dev/null 2>&1; then
    "$ENV_DIR/bin/python" -m pip install --no-cache-dir 'einops==0.8.1' > "$RUN/logs/pip.log" 2>&1
fi
if ! "$ENV_DIR/bin/python" -c 'import torchmetrics' >/dev/null 2>&1; then
    "$ENV_DIR/bin/python" -m pip install --no-cache-dir 'torchmetrics==1.8.2' >> "$RUN/logs/pip.log" 2>&1
fi

"$ENV_DIR/bin/python" - <<'PY' > "$RUN/environment.txt"
import platform
import cv2
import einops
import torch
import torchmetrics
import torchvision
print(f"python={platform.python_version()}")
print(f"torch={torch.__version__}")
print(f"torchvision={torchvision.__version__}")
print(f"torchmetrics={torchmetrics.__version__}")
print(f"cuda_runtime={torch.version.cuda}")
print(f"cuda_available={torch.cuda.is_available()}")
print(f"gpu={torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'none'}")
print(f"opencv={cv2.__version__}")
print(f"einops={einops.__version__}")
PY

/usr/bin/python3 "$PREPARE" \
    --image "$SOURCE_IMAGE" \
    --output "$RUN/input/x5-1024x512.jpg" \
    --metadata "$RUN/input/metadata.json"

cat > "$RUN/infer.yaml" <<EOF
model:
  name: dap
  args:
    midas_model_type: vitl
    fine_tune_type: hypersim
    min_depth: 0.01
    max_depth: 1.0
    train_decoder: true
median_align: false
load_weights_dir: $MODEL_DIR
input:
  height: 512
  width: 1024
inference:
  batch_size: 1
  num_workers: 1
  save_colormap: true
  colormap_type: jet
EOF
printf '%s\n' "$RUN/input/x5-1024x512.jpg" > "$RUN/input.txt"

cat > "$RUN/manifest.txt" <<EOF
host=$(hostname)
architecture=$(uname -m)
source=$SRC
commit=$(git -C "$SRC" rev-parse HEAD)
license=CC BY-NC 4.0
environment=$ENV_DIR
weights=$MODEL_DIR/model.pth
input=$RUN/input/x5-1024x512.jpg
output=$RUN/output
purpose=offline single-image ARM64 CUDA smoke; no ROS nodes or motion commands
EOF

tegrastats --interval 1000 > "$RUN/logs/tegrastats.log" 2>&1 &
stats_pid=$!
started=$(date +%s)
(
    cd "$SRC"
    env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$SRC" "$ENV_DIR/bin/python" "$COMPAT_INFER" "$SRC/test/infer.py" \
        --config "$RUN/infer.yaml" \
        --txt "$RUN/input.txt" \
        --output "$RUN/output" \
        --gpu 0 \
        --vis 100m
) > "$RUN/logs/inference.log" 2>&1
printf 'inference_wall_seconds=%s\n' "$(( $(date +%s) - started ))" > "$RUN/resources.txt"

kill "$stats_pid" 2>/dev/null || true
wait "$stats_pid" 2>/dev/null || true
stats_pid=

test -s "$RUN/output/depth_npy/000001.npy"
test -s "$RUN/output/depth_vis_gray_100m/000001.png"
test -s "$RUN/output/depth_vis_color_100m/000001.png"

"$ENV_DIR/bin/python" - <<PY > "$RUN/result.txt"
import numpy as np
from pathlib import Path
p = Path("$RUN/output/depth_npy/000001.npy")
x = np.load(p)
print(f"depth_shape={x.shape}")
print(f"depth_dtype={x.dtype}")
print(f"depth_min={float(x.min())}")
print(f"depth_max={float(x.max())}")
print(f"depth_mean={float(x.mean())}")
print(f"depth_npy_bytes={p.stat().st_size}")
PY

printf 'COMPLETE run=%s\n' "$RUN" > "$STATUS_DIR/dap_jetson.status"
trap - EXIT
