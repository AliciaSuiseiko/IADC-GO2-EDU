#!/usr/bin/env bash
#SBATCH --job-name=oavat-unreal
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=48G
#SBATCH --time=04:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/oavat-unreal-%j.out

set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src/OA-VAT"
ENV="$HOME/lianaiwei/tracking_envs/oavat"
SIM_ROOT="$ROOT/runtime/oavat_sim/gym-unrealcv"
RUN="$ROOT/runs/oavat_unreal_${SLURM_JOB_ID}_${SLURM_STEP_ID:-batch}"
STATUS="$ROOT/status/oavat_unreal.status"

mkdir -p "$ROOT/runtime/oavat_sim" "$RUN" "$ROOT/status" "$ROOT/logs"
printf 'RUNNING job=%s host=%s time=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
cleanup() {
  pkill -f "$SIM_ROOT/gym_unrealcv/envs/UnrealEnv" 2>/dev/null || true
}
trap cleanup EXIT
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"' ERR

set +u
source "$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
set -u
export PYTHONNOUSERSITE=1
export PIP_CACHE_DIR="$ROOT/cache/pip"
export MODELSCOPE_DOWNLOAD_PARALLEL_WORKERS=16
python -m pip install "setuptools==69.5.1"

if [[ ! -d "$SIM_ROOT/gym_unrealcv" ]]; then
  cp -a "$SRC/gym-unrealcv" "$SIM_ROOT"
fi
python -m pip install -e "$SIM_ROOT"
python -m pip install wget

cd "$SIM_ROOT"
DIRECT_ENV=gym_unrealcv/envs/UnrealEnv/urbancity
EXPECTED_ENV=gym_unrealcv/envs/UnrealEnv/UrbanCity_2P
TEXTURES=gym_unrealcv/envs/UnrealEnv/textures
TEXTURES_ZIP="$SIM_ROOT/Textures.zip"
TEXTURES_CACHE="$HOME/lianaiwei/tracking_runtime/oavat_textures"
DIRECT_BINARY="$DIRECT_ENV/Binaries/Linux/urbancity"
BINARY="$EXPECTED_ENV/urbancity/Binaries/Linux/urbancity"
if [[ ! -s "$DIRECT_BINARY" ]]; then
  python -m pip install modelscope
  python load_env.py -e UrbanCity -cloud modelscope
fi
if [[ ! -s "$TEXTURES_ZIP" ]] && [[ ! -s "$TEXTURES_CACHE/.complete" ]]; then
  python -m pip install modelscope
  modelscope download --dataset zfw1226/UnrealEnv --include Textures.zip --local_dir "$SIM_ROOT"
fi
if [[ ! -s "$TEXTURES_CACHE/.complete" ]]; then
  rm -rf "$TEXTURES_CACHE"
  mkdir -p "$TEXTURES_CACHE"
  unzip -q "$TEXTURES_ZIP" -d "$TEXTURES_CACHE"
  test -n "$(find "$TEXTURES_CACHE/Textures" -type f -print -quit)"
  printf 'complete time=%s\n' "$(date -Is)" > "$TEXTURES_CACHE/.complete"
fi
if [[ ! -L "$TEXTURES" ]] || [[ "$(readlink "$TEXTURES" 2>/dev/null || true)" != "$TEXTURES_CACHE/Textures" ]]; then
  rm -rf "$TEXTURES"
  ln -s "$TEXTURES_CACHE/Textures" "$TEXTURES"
fi
if [[ ! -e "$EXPECTED_ENV/urbancity" ]]; then
  mkdir -p "$EXPECTED_ENV"
  ln -s ../urbancity "$EXPECTED_ENV/urbancity"
fi
chmod +x "$BINARY"

# The runtime copy is intentionally adjusted for headless Slurm rendering.
sed -i 's/self\.unreal\.start(docker, resolution)/self.unreal.start(docker, resolution, offscreen=True)/' \
  gym_unrealcv/envs/unrealcv_tracking_1v1.py
if ! grep -q "cmd_exe.append('-vulkan')" gym_unrealcv/envs/utils/env_unreal.py; then
  sed -i "/cmd_exe.append('-RenderOffScreen')/a\\                cmd_exe.append('-vulkan')" \
    gym_unrealcv/envs/utils/env_unreal.py
fi
# UE4.19 crashes in ScalabilityCVarsSinkCallback on current NVIDIA drivers.
sed -i \
  -e "/^[[:space:]]*self.client.request('vrun sg.ShadowQuality 0', -1)/s/^[[:space:]]*/        # runtime-disabled: /" \
  -e "/^[[:space:]]*self.client.request('vrun sg.TextureQuality 0', -1)/s/^[[:space:]]*/        # runtime-disabled: /" \
  -e "/^[[:space:]]*self.client.request('vrun sg.EffectsQuality 0', -1)/s/^[[:space:]]*/        # runtime-disabled: /" \
  gym_unrealcv/envs/utils/unrealcv_basic.py

export AUDIODEV=null
timeout 240 xvfb-run -a -s "-screen 0 1024x768x24" python - "$RUN" <<'PY'
import json
import os
import sys
import time
import gym
import gym_unrealcv
import numpy as np
from PIL import Image

run = sys.argv[1]
env_id = "UnrealTrack-UrbanCityNav-ContinuousColor-v0"
env = gym.make(env_id)
try:
    obs = env.reset()
    if isinstance(obs, tuple):
        obs = obs[0]
    arr = np.asarray(obs)
    assert arr.size > 0, arr.shape
    reset_frame = arr[0] if arr.ndim == 4 else arr
    Image.fromarray(reset_frame.astype(np.uint8)).save(os.path.join(run, "reset.png"))
    actions = [np.zeros(space.shape, dtype=np.float32) for space in env.action_space]
    result = env.step(actions)
    obs2 = np.asarray(result[0])
    assert obs2.size > 0, obs2.shape
    step_frame = obs2[0] if obs2.ndim == 4 else obs2
    Image.fromarray(step_frame.astype(np.uint8)).save(os.path.join(run, "step.png"))
    with open(os.path.join(run, "manifest.json"), "w") as f:
        json.dump({"env_id": env_id, "reset_shape": list(arr.shape), "step_shape": list(obs2.shape)}, f, indent=2)
    print("oavat_unrealcv_gym_ok", env_id, arr.shape, obs2.shape)
finally:
    env.close()
PY

test -s "$RUN/reset.png"
test -s "$RUN/step.png"

mkdir -p "$ROOT/models/oavat"
cd "$ROOT/models/oavat"
python - "$RUN" <<'PY'
import json
import os
import sys
import numpy as np
from ultralytics import YOLO

run = sys.argv[1]
model = YOLO("yoloe-11l-seg.pt")
image = np.zeros((320, 640, 3), dtype=np.uint8)
result = model.predict(image, device=0, verbose=False)[0]
payload = {"model": "yoloe-11l-seg.pt", "boxes": len(result.boxes), "input_shape": list(image.shape)}
with open(os.path.join(run, "yoloe_manifest.json"), "w") as f:
    json.dump(payload, f, indent=2)
print("oavat_yoloe_static_image_ok", payload)
PY

pkill -f "$SIM_ROOT/gym_unrealcv/envs/UnrealEnv" 2>/dev/null || true
trap - ERR
printf 'COMPLETE job=%s run=%s time=%s\n' "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
