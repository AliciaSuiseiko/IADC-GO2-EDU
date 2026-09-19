#!/usr/bin/env bash
#SBATCH --job-name=oavat-smoke
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=03:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/oavat-smoke-%j.out

set -euo pipefail
ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src/OA-VAT"
ENV="$HOME/lianaiwei/tracking_envs/oavat"
RUN="$ROOT/runs/oavat_20260831"
STATUS="$ROOT/status/oavat.status"
CONDA_ROOT="$HOME/lianaiwei/miniforge3"
mkdir -p "$HOME/lianaiwei/tracking_envs" "$ROOT/cache/conda" "$ROOT/cache/pip" "$ROOT/logs" "$ROOT/status" "$RUN"
printf 'RUNNING job=%s host=%s time=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR
set +u
source "$CONDA_ROOT/etc/profile.d/conda.sh"
export CONDA_PKGS_DIRS="$ROOT/cache/conda"
export PIP_CACHE_DIR="$ROOT/cache/pip"
export PYTHONNOUSERSITE=1

"$CONDA_ROOT/bin/python" - "$SRC/environment.yml" \
  "$RUN/environment.conda.yml" "$RUN/requirements.runtime.txt" <<'PY'
import sys
from ruamel.yaml import YAML

source, conda_output, pip_output = sys.argv[1:]
yaml = YAML(typ="safe")
with open(source) as f:
    config = yaml.load(f)

pip_requirements = []
conda_dependencies = []
for dependency in config["dependencies"]:
    if isinstance(dependency, dict) and "pip" in dependency:
        pip_requirements.extend(dependency["pip"])
    else:
        conda_dependencies.append(dependency)

config["dependencies"] = conda_dependencies
with open(conda_output, "w") as f:
    YAML().dump(config, f)

excluded = ("--extra-index-url", "torch==", "torchvision==", "torchaudio==")
compatible_versions = {
    "transformers": "transformers==4.36.2",
    "accelerate": "accelerate==0.25.0",
}
with open(pip_output, "w") as f:
    for requirement in pip_requirements:
        if not requirement.startswith(excluded):
            f.write(compatible_versions.get(requirement, requirement) + "\n")
PY

conda_lock_held=0
if [[ ! -f "$ENV/.conda_complete" || ! -f "$ENV/.torch_complete" ]]; then
  exec 9> "$ROOT/status/conda.lock"
  flock 9
  conda_lock_held=1
fi

if [[ ! -f "$ENV/.conda_complete" ]]; then
  if [[ -x "$ENV/bin/python" ]]; then
    conda env update --prefix "$ENV" -f "$RUN/environment.conda.yml"
  else
    conda env create --prefix "$ENV" -f "$RUN/environment.conda.yml"
  fi
  touch "$ENV/.conda_complete"
fi
conda activate "$ENV"
if [[ ! -f "$ENV/.torch_complete" ]] && python - <<'PY'
import torch
import torchvision
import torchaudio

assert torch.__version__.startswith("2.2.2")
assert torchvision.__version__.startswith("0.17.2")
assert torchaudio.__version__.startswith("2.2.2")
PY
then
  touch "$ENV/.torch_complete"
fi
if [[ ! -f "$ENV/.torch_complete" ]]; then
  conda install pytorch==2.2.2 torchvision==0.17.2 torchaudio==2.2.2 \
    pytorch-cuda=11.8 -c pytorch -c nvidia -y
  touch "$ENV/.torch_complete"
fi
if (( conda_lock_held )); then
  flock -u 9
fi
set -u
if [[ ! -f "$ENV/.pip_complete" ]]; then
  python -m pip install -r "$RUN/requirements.runtime.txt"
  touch "$ENV/.pip_complete"
fi
touch "$ENV/.environment_complete"
cd "$SRC"
python -m py_compile main.py kalman_filter.py dinov3_feature_extractor.py extract_target_feature_dinov3.py
PYTHONPATH="$SRC/ORTrack${PYTHONPATH:+:$PYTHONPATH}" python - <<'PY'
import json
import platform
import subprocess
import torch
import ultralytics
from diffusers import DDPMScheduler

root = "/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment"
manifest = {
    "python": platform.python_version(),
    "torch": torch.__version__,
    "cuda_runtime": torch.version.cuda,
    "cuda_available": torch.cuda.is_available(),
    "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
    "ultralytics": ultralytics.__version__,
    "diffusion_import": DDPMScheduler.__name__,
    "commit": subprocess.check_output(
        ["git", "-C", f"{root}/src/OA-VAT", "rev-parse", "HEAD"], text=True
    ).strip(),
}
with open(f"{root}/runs/oavat_20260831/manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
print(json.dumps(manifest, indent=2))
PY
printf 'COMPLETE job=%s time=%s\n' "$SLURM_JOB_ID" "$(date -Is)" > "$STATUS"
