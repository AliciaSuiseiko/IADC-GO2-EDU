#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "usage: $0 arise-only|full-headless [duration-seconds]" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
MODE="$1"
DURATION="${2:-300}"
[[ "$MODE" == "arise-only" || "$MODE" == "full-headless" ]] || usage
[[ "$DURATION" =~ ^[0-9]+$ ]] && ((DURATION >= 30)) || usage

ROOT="$HOME/lianaiwei"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/logs/sysnav-baseline-ab/${STAMP}-${MODE}"
DOMAIN_ID="${SYSNAV_BASELINE_DOMAIN_ID:-54}"
DRIVER_PID=""
CORE_PID=""
MONITOR_PID=""
TEGRA_PID=""
mkdir -p "$OUT"

cleanup() {
  set +e
  for pid in "$MONITOR_PID" "$TEGRA_PID" "$CORE_PID" "$DRIVER_PID"; do
    [[ -n "$pid" ]] && kill -INT -- "-$pid" 2>/dev/null
  done
  sleep 4
  for pid in "$MONITOR_PID" "$TEGRA_PID" "$CORE_PID" "$DRIVER_PID"; do
    [[ -n "$pid" ]] && kill -TERM -- "-$pid" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

fail() {
  echo "FAILED: $*" | tee "$OUT/status"
  exit 1
}

pgrep -af 'unitree_webrtc_ros/.*/[u]nitree_control|[g]o2_cmd_vel_bridge' >"$OUT/motion-bridge.preflight" && \
  fail "a Unitree motion bridge is running"
if pgrep -af '[f]eature_extraction_node|[l]aser_mapping_node|[i]mu_preintegration_node|[t]are_planner_node|[r]oom_segmentation' \
  >"$OUT/sysnav-process.preflight"; then
  fail "another SysNav process is running"
fi

ip link show eth0 | grep -q LOWER_UP || fail "eth0 has no carrier"
ping -c 1 -W 2 192.168.1.148 >/dev/null || fail "Mid-360 is unreachable"

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/elevator_lio_ws/install/setup.bash"
source "$ROOT/src/sysnav_ws/install/setup.bash"
source "$ROOT/src/sysnav_ws/install-standalone-preview/setup.bash"
set -u
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID="$DOMAIN_ID" ROS_LOCALHOST_ONLY=1

setsid ros2 launch "$ROOT/scripts/elevator_lio/mid360_driver_launch.py" \
  >"$OUT/mid360.log" 2>&1 &
DRIVER_PID=$!

for topic in /livox/lidar /livox/imu; do
  ready=0
  for _ in $(seq 1 30); do
    if timeout 3 ros2 topic echo --once "$topic" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  ((ready == 1)) || fail "$topic did not publish"
done

if [[ "$MODE" == "arise-only" ]]; then
  STATE_TOPIC=/sysnav_standalone_preview/state_estimation
  setsid ros2 launch "$ROOT/scripts/sysnav/sysnav_standalone_preview.launch.py" \
    start_planner:=false map_file:="$OUT/pointcloud_local.txt" \
    >"$OUT/core.log" 2>&1 &
else
  STATE_TOPIC=/state_estimation
  setsid ros2 launch "$ROOT/scripts/sysnav/sysnav_exploration_planner_only.launch.py" \
    >"$OUT/core.log" 2>&1 &
fi
CORE_PID=$!

setsid bash -c '
  topic="$1"; duration="$2"; output="$3"
  deadline=$((SECONDS + duration))
  pass=0; miss=0
  while ((SECONDS < deadline)); do
    if timeout 3 ros2 topic echo --once "$topic" >/dev/null 2>&1; then
      pass=$((pass + 1))
    else
      miss=$((miss + 1))
    fi
    sleep 2
  done
  printf "state_samples_pass=%s\nstate_samples_miss=%s\n" "$pass" "$miss" >"$output"
' _ "$STATE_TOPIC" "$DURATION" "$OUT/liveness.txt" &
MONITOR_PID=$!

if command -v tegrastats >/dev/null 2>&1; then
  setsid tegrastats --interval 2000 >"$OUT/tegrastats.log" 2>&1 &
  TEGRA_PID=$!
fi

sleep "$DURATION"
wait "$MONITOR_PID" || true
MONITOR_PID=""

{
  echo "mode=$MODE"
  echo "duration_seconds=$DURATION"
  echo "ros_domain_id=$DOMAIN_ID"
  cat "$OUT/liveness.txt"
  printf 'large_lidar_buffer='; grep -c 'Large lidar buffer' "$OUT/core.log" || true
  printf 'out_of_sync='; grep -c 'out of sync' "$OUT/core.log" || true
  printf 'underconstrained='; grep -c 'underconstrained' "$OUT/core.log" || true
  printf 'failure_detected='; grep -c 'failureDetected' "$OUT/core.log" || true
  printf 'no_candidate_viewpoints='; grep -c 'Cannot get candidate viewpoints' "$OUT/core.log" || true
  printf 'wrong_room='; grep -c 'wrong room' "$OUT/core.log" || true
  printf 'room_id_out_of_bounds='; grep -Ec 'Room ID .* out of bounds' "$OUT/core.log" || true
} | tee "$OUT/result.txt"

printf 'COMPLETE %s\n' "$(date --iso-8601=seconds)" >"$OUT/status"
printf '%s\n' "$OUT"
