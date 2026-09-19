#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
LIO_BACKEND="${SYSNAV_LIO_BACKEND:-elevator}"
HEADLESS=0
STARTUP_TIMEOUT="${SYSNAV_STARTUP_TIMEOUT:-90}"

while (($#)); do
  case "$1" in
    --lio)
      [[ $# -ge 2 ]] || { echo "--lio requires arise, fastlio2, or elevator" >&2; exit 2; }
      LIO_BACKEND="$2"
      shift 2
      ;;
    --lio=*)
      LIO_BACKEND="${1#--lio=}"
      shift
      ;;
    --headless)
      HEADLESS=1
      shift
      ;;
    *)
      echo "Usage: $0 [--lio arise|fastlio2|elevator] [--headless]" >&2
      exit 2
      ;;
  esac
done

case "$LIO_BACKEND" in
  arise|fastlio2|elevator) ;;
  *) echo "Unsupported LIO backend: $LIO_BACKEND" >&2; exit 2 ;;
esac

RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$ROOT/logs/sysnav-manual-mapping-$RUN_ID"
mkdir -p "$LOG_DIR"
ln -sfn "$LOG_DIR" "$ROOT/logs/sysnav-manual-mapping-current"

declare -a CHILD_PIDS=()

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_DIR/supervisor.log"
}

ros_setup() {
  set +u
  source /opt/ros/humble/setup.bash
  source "$ROOT/src/elevator_lio_ws/install/setup.bash"
  source "$ROOT/src/fastlio2_ws/install/setup.bash"
  source "$ROOT/src/sysnav_ws/install/setup.bash"
  source "$ROOT/src/sysnav_ws/install-standalone-preview/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
}

cleanup() {
  trap - EXIT INT TERM HUP
  log "stopping manual mapping processes"
  local pid
  for pid in "${CHILD_PIDS[@]}"; do
    kill -TERM -- "-$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in "${CHILD_PIDS[@]}"; do
    kill -KILL -- "-$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM HUP

start_child() {
  local name="$1" command="$2"
  setsid bash -lc "$command" >"$LOG_DIR/$name.log" 2>&1 &
  CHILD_PIDS+=("$!")
  log "started $name (pid $!)"
}

wait_topic() {
  local topic="$1" timeout_seconds="${2:-$STARTUP_TIMEOUT}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if timeout 3 ros2 topic echo "$topic" --once >/dev/null 2>&1; then
      log "topic ready: $topic"
      return 0
    fi
    sleep 1
  done
  log "WARNING: topic not ready within ${timeout_seconds}s: $topic"
  return 1
}

publisher_count() {
  ros2 topic info "$1" 2>/dev/null | awk -F': ' '/Publisher count/ {print $2}' || true
}

subscriber_count() {
  ros2 topic info "$1" 2>/dev/null | awk -F': ' '/Subscription count/ {print $2}' || true
}

ros_setup

required_files=(
  "$ROOT/scripts/elevator_lio/mid360_driver_launch.py"
  "$ROOT/scripts/sysnav/sysnav_exploration_planner_only.launch.py"
  "$ROOT/scripts/sysnav/tare_planner_ground_jetson_operational.rviz"
)
for path in "${required_files[@]}"; do
  [[ -r "$path" ]] || { log "missing required file: $path"; exit 3; }
done

collision_pattern='livox_ros_driver2_node|feature_extraction_node|laser_mapping_node|imu_preintegration_node|fastlio_mapping|fastlio2_sysnav_adapter|/lio/lib/lio/lio|terrainAnalysis|terrainAnalysisExt|localPlanner|pathFollower|tare_planner_node|room_segmentation|unitree_webrtc_ros/.*/unitree_control'
if pgrep -af "$collision_pattern" >"$LOG_DIR/preflight-processes.txt"; then
  log "existing mapping or motion process found; refusing duplicate startup"
  cat "$LOG_DIR/preflight-processes.txt"
  exit 4
fi

for topic in /cmd_vel; do
  count="$(publisher_count "$topic")"
  if [[ -n "$count" && "$count" != "0" ]]; then
    log "motion publisher already exists on $topic; refusing startup"
    exit 5
  fi
done

start_child mid360_driver "
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  source '$ROOT/src/elevator_lio_ws/install/setup.bash'
  set -u
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
  exec ros2 launch '$ROOT/scripts/elevator_lio/mid360_driver_launch.py'
"
wait_topic /livox/lidar 45 || exit 6
wait_topic /livox/imu 45 || exit 6

start_child sysnav_mapping "
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  source '$ROOT/src/fastlio2_ws/install/setup.bash'
  source '$ROOT/src/elevator_lio_ws/install/setup.bash'
  source '$ROOT/src/sysnav_ws/install/setup.bash'
  source '$ROOT/src/sysnav_ws/install-standalone-preview/setup.bash'
  set -u
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
  exec ros2 launch '$ROOT/scripts/sysnav/sysnav_exploration_planner_only.launch.py' \
    lio_backend:='$LIO_BACKEND' \
    enable_motion_pipeline:=false
"

wait_topic /state_estimation 90 || exit 7
wait_topic /registered_scan 90 || exit 7
wait_topic /occupied_cloud 45 || true
wait_topic /freespace_cloud 60 || true

if pgrep -af 'localPlanner|pathFollower|unitree_webrtc_ros/.*/unitree_control' >"$LOG_DIR/unexpected-motion-processes.txt"; then
  log "unexpected motion-capable process detected; stopping"
  cat "$LOG_DIR/unexpected-motion-processes.txt"
  exit 8
fi

for topic in /cmd_vel; do
  count="$(publisher_count "$topic")"
  if [[ -n "$count" && "$count" != "0" ]]; then
    log "unexpected motion publisher on $topic; stopping"
    exit 9
  fi
done

waypoint_subscribers="$(subscriber_count /way_point)"
if [[ -n "$waypoint_subscribers" && "$waypoint_subscribers" != "0" ]]; then
  log "/way_point has $waypoint_subscribers subscriber(s); stopping because manual mapping requires zero"
  exit 10
fi

if ((HEADLESS == 0)); then
  start_child rviz "
    set -euo pipefail
    set +u
    source /opt/ros/humble/setup.bash
    source '$ROOT/src/sysnav_ws/install/setup.bash'
    source '$ROOT/scripts/hardware/nomachine/nomachine-session-env.sh'
    set -u
    export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
    exec nice -n 15 rviz2 -d '$ROOT/scripts/sysnav/tare_planner_ground_jetson_operational.rviz'
  "
fi

log "MANUAL MAPPING READY"
log "LIO backend: $LIO_BACKEND"
log "No ROS motion pipeline is running. Drive Go2 only with the handheld controller."
log "Room outputs: /room_mask /room_nodes_list /door_cloud"
log "Logs: $LOG_DIR"
log "Press Ctrl+C here to stop mapping."

while true; do
  sleep 5
  for pid in "${CHILD_PIDS[@]:0:2}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      log "a required child process exited; inspect logs"
      exit 11
    fi
  done
done
