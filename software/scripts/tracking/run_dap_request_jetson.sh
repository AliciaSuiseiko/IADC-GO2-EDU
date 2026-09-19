#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
COMPUTE_HOST="${1:?compute host is required}"
IMAGE="${2:?image path is required}"
OUTPUT="${3:?output directory is required}"
LOCAL_PORT="${4:-18762}"
SSH_KEY=/home/orin/.ssh/id_ed25519
LOG="${OUTPUT%/*}/dap-tunnel.log"

case "$IMAGE" in
    "$ROOT"/*) ;;
    *) echo "image must be below $ROOT" >&2; exit 2 ;;
esac
case "$OUTPUT" in
    "$ROOT"/*) ;;
    *) echo "output must be below $ROOT" >&2; exit 2 ;;
esac
[[ "$COMPUTE_HOST" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$LOCAL_PORT" =~ ^[0-9]+$ ]]
[[ -s "$IMAGE" ]]
[[ ! -e "$OUTPUT" ]]
mkdir -p "$OUTPUT"

tunnel_pid=
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "$tunnel_pid" ]]; then
        kill "$tunnel_pid" 2>/dev/null || true
        wait "$tunnel_pid" 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

setsid ssh -N -i "$SSH_KEY" \
    -o BatchMode=yes -o ConnectTimeout=8 -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -L "127.0.0.1:$LOCAL_PORT:$COMPUTE_HOST:18761" \
    robot@login.example > "$LOG" 2>&1 < /dev/null &
tunnel_pid=$!

for _ in $(seq 1 20); do
    kill -0 "$tunnel_pid" 2>/dev/null || break
    if ss -ltn | grep -q "127.0.0.1:$LOCAL_PORT"; then
        break
    fi
    sleep 1
done
kill -0 "$tunnel_pid"
ss -ltn | grep -q "127.0.0.1:$LOCAL_PORT"

python3 "$ROOT/scripts/dap_remote_jetson_client.py" \
    --host 127.0.0.1 \
    --port "$LOCAL_PORT" \
    --image "$IMAGE" \
    --output "$OUTPUT"
