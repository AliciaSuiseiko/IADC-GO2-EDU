#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
ENV="$HOME/lianaiwei/tracking_envs/oavat"
BIN="$ROOT/runtime/oavat_sim/gym-unrealcv/gym_unrealcv/envs/UnrealEnv/UrbanCity_2P/urbancity/Binaries/Linux/urbancity"
LOG="$ROOT/logs/oavat_camera_probe_15526_engine.log"

set +u
source "$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
set -u

setsid xvfb-run -a -s "-screen 0 1024x768x24" "$BIN" -RenderOffScreen -graphicsadapter=0 >"$LOG" 2>&1 &
server_pid=$!
cleanup() {
  kill -TERM -- "-$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

sleep 22
python - <<'PY'
from unrealcv import Client

commands = [
    "vget /camera/0/rotation",
    "vget /camera/1/rotation",
    "vget /camera/2/rotation",
    "vget /objects",
]
for command in commands:
    client = Client(("127.0.0.1", 9000))
    try:
        client.connect()
        response = client.request(command, timeout=8)
        print(f"RESULT {command}: {response!r}", flush=True)
    except Exception as exc:
        print(f"ERROR {command}: {type(exc).__name__}: {exc}", flush=True)
    finally:
        client.disconnect()
PY
