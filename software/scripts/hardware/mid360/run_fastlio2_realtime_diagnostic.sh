#!/usr/bin/env bash
set -eo pipefail

ROOT="$HOME/lianaiwei"
WS="$ROOT/src/fastlio2_ws"
CONFIG="$WS/src/FAST_LIO_ROS2/config/mid360_real.yaml"
D="$ROOT/logs/hardware/fastlio2-live-diagnostic-$(date +%Y%m%d-%H%M%S)"
DURATION="${DIAGNOSTIC_SECONDS:-180}"
mkdir -p "$D"

source /opt/ros/humble/setup.bash
source "$WS/install/setup.bash"
set -u

if ! ip link show eth0 | grep -q 'LOWER_UP'; then
  echo "BLOCKED: eth0 has no carrier" | tee "$D/status.txt"
  exit 2
fi
if ! ping -c 1 -W 1 192.168.1.148 >/dev/null 2>&1; then
  echo "BLOCKED: Mid-360 192.168.1.148 is unreachable" | tee "$D/status.txt"
  exit 2
fi

cleanup() {
  kill -- -"${ADAPTER_PGID:-0}" 2>/dev/null || true
  kill -- -"${FASTLIO_PGID:-0}" 2>/dev/null || true
  kill -- -"${DRIVER_PGID:-0}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

setsid ros2 launch livox_ros_driver2 msg_MID360_launch.py >"$D/livox.log" 2>&1 &
DRIVER_PGID=$!
sleep 5
setsid ros2 launch fast_lio mapping.launch.py \
  config_path:="$(dirname "$CONFIG")" \
  config_file:=mid360_real.yaml \
  rviz:=false >"$D/fastlio.log" 2>&1 &
FASTLIO_PGID=$!
setsid ros2 launch fastlio2_go2_adapter mid360_go2_adapter.launch.py \
  >"$D/go2-adapter.log" 2>&1 &
ADAPTER_PGID=$!

python3 "$ROOT/scripts/fastlio_odom_monitor.py" \
  --duration "$DURATION" \
  --output "$D/odom.json" >"$D/monitor.log" 2>&1 &
MONITOR_PID=$!

for _ in $(seq 1 $((DURATION / 5))); do
  date -Is
  ps -eo pid,etime,pcpu,rss,stat,cmd | grep -E 'livox_ros_driver2|fastlio_mapping' | grep -v grep || true
  sleep 5
done >"$D/processes.log"

wait "$MONITOR_PID" || true
grep -E 'No Effective|Too few|No point|not Synced|loop back|process has died' "$D/fastlio.log" >"$D/warnings.log" || true
echo "COMPLETE: diagnostic logs in $D" | tee "$D/status.txt"
