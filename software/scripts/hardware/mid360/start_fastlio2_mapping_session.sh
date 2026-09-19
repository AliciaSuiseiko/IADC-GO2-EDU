#!/usr/bin/env bash
set -eo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
WS="$ROOT/src/fastlio2_ws"
CONFIG="${FASTLIO2_CONFIG:-$WS/src/FAST_LIO_ROS2/config/mid360_real.yaml}"
MAP_ROOT="${FASTLIO2_MAP_ROOT:-$ROOT/data/maps/fastlio2}"
CURRENT_FILE="$ROOT/logs/hardware/fastlio2-map-session.current"

source /opt/ros/humble/setup.bash
source "$WS/install/setup.bash"

if pgrep -u "$USER" -x fastlio_mapping >/dev/null; then
  echo "BLOCKED: fastlio_mapping is already running" >&2
  exit 2
fi

SESSION="$MAP_ROOT/$(date +%Y%m%d-%H%M%S)"
MAP_FILE="$SESSION/map.pcd"
mkdir -p "$SESSION" "$(dirname "$CURRENT_FILE")"

{
  printf 'started_at=%s\n' "$(date -Is)"
  printf 'config=%s\n' "$CONFIG"
  printf 'map_file=%s\n' "$MAP_FILE"
  printf 'fastlio_commit=%s\n' "$(git -C "$WS/src/FAST_LIO_ROS2" rev-parse HEAD 2>/dev/null || echo unknown)"
} >"$SESSION/session.env"

setsid ros2 run fast_lio fastlio_mapping --ros-args \
  --params-file "$CONFIG" \
  -p map_file_path:="$MAP_FILE" \
  -p publish.map_en:=true \
  -p pcd_save.pcd_save_en:=true \
  -p pcd_save.interval:=-1 \
  >"$SESSION/fastlio.log" 2>&1 < /dev/null &
MAPPING_PID=$!
printf '%s\n' "$MAPPING_PID" >"$SESSION/fastlio.pid"

setsid ros2 launch fastlio2_go2_adapter mid360_go2_adapter.launch.py \
  >"$SESSION/go2-adapter.log" 2>&1 < /dev/null &
ADAPTER_PID=$!
printf '%s\n' "$ADAPTER_PID" >"$SESSION/go2-adapter.pid"
printf '%s\n' "$SESSION" >"$CURRENT_FILE"

sleep 5
if ! kill -0 "$MAPPING_PID" 2>/dev/null; then
  kill -INT -- "-$ADAPTER_PID" 2>/dev/null || true
  echo "FAILED: fastlio_mapping exited during startup" >&2
  tail -80 "$SESSION/fastlio.log" >&2
  exit 1
fi
if ! kill -0 "$ADAPTER_PID" 2>/dev/null; then
  kill -INT -- "-$MAPPING_PID" 2>/dev/null || true
  echo "FAILED: fastlio2_go2_adapter exited during startup" >&2
  tail -80 "$SESSION/go2-adapter.log" >&2
  exit 1
fi

echo "SESSION=$SESSION"
echo "MAP_FILE=$MAP_FILE"
echo "MAPPING_PID=$MAPPING_PID"
echo "ADAPTER_PID=$ADAPTER_PID"
