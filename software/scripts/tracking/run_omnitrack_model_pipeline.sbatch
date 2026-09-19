#!/usr/bin/env bash
#SBATCH --job-name=omni-model
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/omni-model-%j.out

set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src/OmniTrack"
ENV="$HOME/lianaiwei/tracking_envs/omnitrack"
RUN="$ROOT/runs/omnitrack_model_${SLURM_JOB_ID}"
STATUS="$ROOT/status/omnitrack_model.status"
DATA="$ROOT/datasets/QuadTrack"

mkdir -p "$RUN" "$ROOT/status" "$ROOT/logs"
printf 'RUNNING job=%s host=%s time=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

set +u
source "$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
set -u
export PYTHONNOUSERSITE=1
export PYTHONPATH="$SRC"
export HF_HOME="$ROOT/cache/huggingface"

# The official task checkpoint is unavailable, so downloading the complete
# QuadTrack dataset cannot produce an evaluation result. Reuse it only when it
# already exists; the CUDA model-build smoke itself does not require the data.
quadtrack_available=false
if [[ -d "$DATA" ]] && find "$DATA" -type f -print -quit | grep -q .; then
  quadtrack_available=true
fi
export OMNITRACK_QUADTRACK_AVAILABLE="$quadtrack_available"

cd "$SRC"
python - "$RUN" <<'PY'
import json
import os
import sys
import numpy as np
import torch
from mmcv import Config
from mmdet.models import build_detector

run = sys.argv[1]
config_path = "projects/configs/JRDB_OmniTrack.py"
cfg = Config.fromfile(config_path)
if cfg.get("plugin", False):
    import projects.mmdet3d_plugin

# The repository generates this file from the complete JRDB training annotations,
# but does not publish either the anchor file or a task checkpoint. Use a runtime-
# only anchor with the documented 900x4 contract to exercise model construction.
anchor_path = os.path.join(run, "smoke_anchor_900x4.npy")
centers = np.linspace(0.01, 0.99, 30, dtype=np.float32)
grid_x, grid_y = np.meshgrid(centers, centers)
anchor = np.column_stack(
    [grid_x.reshape(-1), grid_y.reshape(-1),
     np.full(900, np.log(0.05), dtype=np.float32),
     np.full(900, np.log(0.10), dtype=np.float32)]
)
np.save(anchor_path, anchor)
cfg.model.head.instance_bank.anchor = anchor_path
model = build_detector(cfg.model, train_cfg=cfg.get("train_cfg"), test_cfg=cfg.get("test_cfg"))
model = model.cuda().eval()
params = sum(p.numel() for p in model.parameters())
assert params > 0
probe = torch.randn(2048, 2048, device="cuda")
probe = probe @ probe.T
assert torch.isfinite(probe).all()
with open(os.path.join(run, "manifest.json"), "w") as f:
    json.dump({"config": config_path, "model": type(model).__name__, "parameters": params,
               "quadtrack_available": os.environ["OMNITRACK_QUADTRACK_AVAILABLE"] == "true",
               "anchor": "runtime-only synthetic 900x4 model-construction anchor",
               "evaluation_blocker": "No trained OmniTrack task checkpoint or generated JRDB anchor is published"}, f, indent=2)
print("omnitrack_model_build_cuda_ok", type(model).__name__, params, torch.cuda.get_device_name(0))
print("gpu_peak_bytes", torch.cuda.max_memory_allocated())
PY

printf 'COMPLETE job=%s run=%s time=%s\n' "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
