#!/usr/bin/env bash
#SBATCH --job-name=lhvln-smoke
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=04:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/lhvln-smoke-%j.out

set -euo pipefail
ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src/LH-VLN"
ENV="$HOME/lianaiwei/tracking_envs/lhvln"
RUN="$ROOT/runs/lhvln_20260831"
STATUS="$ROOT/status/lhvln.status"
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
  conda create --prefix "$ENV" python=3.9 pip -y
fi
conda activate "$ENV"
if [[ ! -f "$ENV/.habitat_complete" ]]; then
  conda install habitat-sim==0.3.1 headless -c conda-forge -c aihabitat -y
  touch "$ENV/.habitat_complete"
fi
flock -u 9
set -u
if [[ ! -f "$ENV/.requirements_complete" ]]; then
  python -m pip install torch==2.4.1 torchvision==0.19.1 \
    --index-url https://download.pytorch.org/whl/cu121
  grep -Ev '^(torch|torchvision|deepspeed|xformers|PyQt5)([<>=]|$)' \
    "$SRC/requirements.txt" > "$RUN/requirements.runtime.txt"
  python -m pip install -r "$RUN/requirements.runtime.txt"
  touch "$ENV/.requirements_complete"
fi
cd "$SRC"
python -m py_compile train.py sft.py
python - <<'PY'
import json
import platform
import subprocess
import habitat_sim
import torch
from NavModel.RandomNav import RandomAgent

agent = RandomAgent()
assert len(agent.actions) == 4

root = "/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment"
manifest = {
    "python": platform.python_version(),
    "torch": torch.__version__,
    "cuda_runtime": torch.version.cuda,
    "cuda_available": torch.cuda.is_available(),
    "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
    "habitat_import": habitat_sim.__name__,
    "commit": subprocess.check_output(
        ["git", "-C", f"{root}/src/LH-VLN", "rev-parse", "HEAD"], text=True
    ).strip(),
    "hm3d_downloaded": False,
    "benchmark_blocker": "HM3D requires Matterport access; no credentials were supplied",
}
with open(f"{root}/runs/lhvln_20260831/manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
print(json.dumps(manifest, indent=2))
PY
printf 'COMPLETE job=%s time=%s\n' "$SLURM_JOB_ID" "$(date -Is)" > "$STATUS"
