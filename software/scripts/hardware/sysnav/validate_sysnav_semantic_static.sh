#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
DURATION="${SYSNAV_SEMANTIC_STATIC_DURATION:-90}"
RUN_DIR="$ROOT/logs/hardware/sysnav-semantic-static-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"

declare -a CHILD_PIDS=()
SEMANTIC_JOB_ID=""
TUNNEL_PID=""

ros_setup() {
  set +u
  source /opt/ros/humble/setup.bash
  source "$ROOT/src/elevator_lio_ws/install/setup.bash"
  source "$ROOT/src/fastlio2_ws/install/setup.bash"
  source "$ROOT/src/camera_x5_ws/install/setup.bash"
  source "$ROOT/src/sysnav_ws/install/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
}

stop_group() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  for pid in "${CHILD_PIDS[@]}"; do
    stop_group "$pid"
  done
  stop_group "$TUNNEL_PID"
  if [[ -n "$SEMANTIC_JOB_ID" ]]; then
    ssh -i "$HOME/.ssh/id_ed25519" -o BatchMode=yes -o ConnectTimeout=8 \
      robot@login.example "scancel '$SEMANTIC_JOB_ID'" 2>/dev/null || true
  fi
  sleep 2
  for pid in "${CHILD_PIDS[@]}"; do
    kill -KILL -- "-$pid" 2>/dev/null || true
  done
  [[ -n "$TUNNEL_PID" ]] && kill -KILL -- "-$TUNNEL_PID" 2>/dev/null || true
  printf 'exit_code=%s\n' "$rc" >"$RUN_DIR/status.txt"
  exit "$rc"
}
trap cleanup EXIT INT TERM HUP

start_child() {
  local name="$1"
  shift
  setsid "$@" >"$RUN_DIR/$name.log" 2>&1 < /dev/null &
  CHILD_PIDS+=("$!")
}

wait_topic() {
  local topic="$1" timeout_seconds="${2:-60}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if timeout 3 ros2 topic echo "$topic" --once >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "topic did not publish: $topic" >&2
  return 1
}

ros_setup
if pgrep -af 'localPlanner|pathFollower|tare_planner_node|unitree.*sport|x5_sdk_node|fastlio_mapping' \
  >"$RUN_DIR/process-collisions.txt"; then
  echo "existing robotics process detected" >&2
  exit 2
fi
if ros2 topic info /cmd_vel 2>/dev/null | grep -Eq 'Publisher count: [1-9]'; then
  echo "/cmd_vel already has a publisher" >&2
  exit 3
fi

start_child mid360 ros2 launch "$ROOT/scripts/elevator_lio/mid360_driver_launch.py"
wait_topic /livox/lidar 45
wait_topic /livox/imu 45

start_child fastlio ros2 run fast_lio fastlio_mapping --ros-args \
  --params-file "$ROOT/scripts/hardware/mid360/fastlio2_mid360_real.yaml" \
  -p common.lid_topic:=/livox/lidar \
  -p common.imu_topic:=/livox/imu
start_child fastlio_adapter ros2 run fastlio2_go2_adapter fastlio2_sysnav_adapter \
  --ros-args --params-file \
  "$ROOT/src/fastlio2_ws/src/fastlio2_go2_adapter/config/mid360_sysnav.yaml"
wait_topic /state_estimation 60
wait_topic /registered_scan 60

SYSNAV_RUN_DIR="$RUN_DIR" "$ROOT/scripts/sysnav/start_hkust_semantic_link.sh" \
  >"$RUN_DIR/semantic-link.log" 2>&1
SEMANTIC_JOB_ID="$(awk -F= '$1 == "job_id" {print $2}' "$RUN_DIR/semantic-job.txt")"
TUNNEL_PID="$(cat "$RUN_DIR/hkust-tunnel.pid")"

start_child x5 ros2 run insta360_x5_sdk_ros2 x5_sdk_node --ros-args \
  --params-file "$ROOT/src/camera_x5_ws/install/insta360_x5_sdk_ros2/share/insta360_x5_sdk_ros2/config/x5_sdk.yaml" \
  --params-file "$ROOT/scripts/sysnav/x5_sysnav.yaml"
start_child panorama python3 "$ROOT/scripts/x5_panorama_tcp_receiver.py"
start_child annotated python3 "$ROOT/scripts/x5_annotated_tcp_receiver.py"
start_child semantic_uplink python3 "$ROOT/scripts/sysnav_semantic_bridge.py" \
  jetson-uplink --host 127.0.0.1
start_child semantic_downlink python3 "$ROOT/scripts/sysnav_semantic_bridge.py" \
  jetson-downlink --host 127.0.0.1

wait_topic /camera/image 120
wait_topic /camera/image/compressed 45

status_remote=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/logs/sysnav-semantic-live.status
for _ in $(seq 1 180); do
  status="$(ssh -i "$HOME/.ssh/id_ed25519" -o BatchMode=yes \
    -o ConnectTimeout=8 robot@login.example "cat '$status_remote' 2>/dev/null" || true)"
  [[ "$status" == READY\ * ]] && break
  [[ "$status" == FAILED\ * || "$status" == STOPPED\ * ]] && {
    echo "$status" >&2
    exit 4
  }
  sleep 1
done
[[ "$status" == READY\ * ]]

python3 "$ROOT/scripts/sysnav/monitor_sysnav_semantic_static.py" \
  --duration "$DURATION" --output "$RUN_DIR/summary.json"

ssh -i "$HOME/.ssh/id_ed25519" -o BatchMode=yes -o ConnectTimeout=8 \
  robot@login.example \
  "tar -C /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/logs -czf - \
    sysnav-semantic-live-$SEMANTIC_JOB_ID" \
  >"$RUN_DIR/server-logs.tar.gz"
cat "$RUN_DIR/summary.json"
printf 'COMPLETE\n' >"$RUN_DIR/status.txt"
echo "RUN_DIR=$RUN_DIR"
