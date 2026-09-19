#!/usr/bin/env bash
#SBATCH --job-name=farm-native
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=04:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/farm-native-%j.out

set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src/FARM-Project"
BASE="$HOME/lianaiwei/tracking_envs/sam3"
ENV="$HOME/lianaiwei/tracking_envs/farm"
RUN="$ROOT/runs/farm_native_${SLURM_JOB_ID}"
STATUS="$ROOT/status/farm_native.status"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 2 ;;
esac

mkdir -p "$HOME/lianaiwei/tracking_envs" "$ROOT/status" "$ROOT/logs" \
  "$ROOT/cache/pip" "$RUN/data/sample_npz"
printf 'RUNNING job=%s host=%s time=%s\n' \
  "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

if [[ ! -x "$ENV/bin/python" ]]; then
  "$BASE/bin/python" -m venv --system-site-packages "$ENV"
fi
source "$ENV/bin/activate"
export PYTHONNOUSERSITE=1
export PIP_CACHE_DIR="$ROOT/cache/pip"
export SCENE_GRAPH_MODEL_DIR="$SRC/models"

if [[ ! -f "$ENV/.requirements_complete" ]]; then
  python -m pip install \
    'setuptools>=70' 'transformers>=4.57,<5' 'timm==0.9.5' \
    opencv-python-headless h5py loguru 'networkx>=2.8' 'supervision>=0.25.1' \
    scipy transforms3d scikit-learn pandas seaborn py-cpuinfo \
    ultralytics-thop open-clip-torch matplotlib 'imageio[ffmpeg]' pydantic viser
  python -m pip install --no-deps -e "$SRC/third_party/yoloe"
  python -m pip install --no-deps -e "$SRC/third_party/yoloe/third_party/ml-mobileclip"
  python -m pip install --no-deps -e "$SRC"
  touch "$ENV/.requirements_complete"
fi

python - "$RUN" <<'PY'
import json
import os
import sys

import numpy as np
import torch

run = sys.argv[1]
sample_dir = os.path.join(run, "data", "sample_npz")
n, height, width = 4, 240, 320
rng = np.random.default_rng(0)
images = rng.integers(0, 255, (n, height, width, 3), dtype=np.uint8)
depths = np.full((n, height, width), 2.0, np.float32)
intrinsics = np.array(
    [[160, 0, width / 2], [0, 160, height / 2], [0, 0, 1]],
    np.float32,
)
poses = np.stack([np.eye(4, dtype=np.float32) for _ in range(n)])
poses[:, 0, 3] = np.linspace(0, 0.1, n)
np.savez(
    os.path.join(sample_dir, "frames_000.npz"),
    images=images,
    depths=depths,
    camtoworlds=poses,
    K=intrinsics,
    pose_convention="opencv",
)

from scene_graph.offline.frame_sources.npz import NPZFrameSource
from scene_graph.segmentation.yoloe import YOLOESegmenter

source = NPZFrameSource(sample_dir, camera="sample", end=1)
frame = next(iter(source))
segmenter = YOLOESegmenter(
    model_id="yoloe-v8l",
    imgsz=320,
    conf_thres=0.99,
    device="cuda",
    use_dino_features=False,
    max_det=10,
)
color = torch.from_numpy(frame["rgb"]).to("cuda")
depth = torch.from_numpy(frame["depth_f32"]).to("cuda")
K = torch.tensor(intrinsics, device="cuda")
output = segmenter(color, depth, K, camera_names=["sample"], offline_debug=True)

payload = {
    "source_frames": len(source),
    "rgb_shape": list(frame["rgb"].shape),
    "depth_shape": list(frame["depth_f32"].shape),
    "output_type": type(output).__name__,
    "torch": torch.__version__,
    "gpu": torch.cuda.get_device_name(0),
    "cuda_peak_bytes": torch.cuda.max_memory_allocated(),
    "smoke_scope": "NPZFrameSource plus FARM YOLOESegmenter RGB-D CUDA forward",
}
with open(os.path.join(run, "manifest.json"), "w") as f:
    json.dump(payload, f, indent=2)
print(json.dumps(payload, indent=2))
PY

test -s "$RUN/manifest.json"
trap - ERR
printf 'COMPLETE job=%s run=%s time=%s\n' \
  "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
