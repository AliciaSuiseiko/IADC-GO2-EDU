#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
GO2_IFACE="${GO2_IFACE:-eth0}"
GO2_IP="${GO2_IP:-192.168.123.161}"
MID360_IP="${MID360_IP:-192.168.1.148}"
STARTUP_TIMEOUT="${SYSNAV_STARTUP_TIMEOUT:-90}"
GO2_BRIDGE_ATTEMPTS="${SYSNAV_GO2_BRIDGE_ATTEMPTS:-3}"
GO2_BRIDGE_RETRY_SEC="${SYSNAV_GO2_BRIDGE_RETRY_SEC:-5}"
MODE="--validate"
LIO_BACKEND="${SYSNAV_LIO_BACKEND:-arise}"
HEADLESS=0
RECORD_LIO=0
RECORD_DEMO=0
RECORD_DELAY_SEC="${SYSNAV_RECORD_DELAY_SEC:-60}"

while (($#)); do
  case "$1" in
    --arm-motion|--validate|--manual-map)
      MODE="$1"
      shift
      ;;
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
    --record-lio)
      RECORD_LIO=1
      shift
      ;;
    --record-demo)
      RECORD_DEMO=1
      shift
      ;;
    *)
      echo "Usage: $0 [--validate|--manual-map|--arm-motion] [--lio arise|fastlio2|elevator] [--headless] [--record-lio] [--record-demo]" >&2
      exit 2
      ;;
  esac
done

if [[ "$LIO_BACKEND" != "arise" && "$LIO_BACKEND" != "fastlio2" && "$LIO_BACKEND" != "elevator" ]]; then
  echo "Unsupported LIO backend: $LIO_BACKEND" >&2
  exit 2
fi

if [[ ! "$RECORD_DELAY_SEC" =~ ^[0-9]+$ ]]; then
  echo "SYSNAV_RECORD_DELAY_SEC must be a non-negative integer" >&2
  exit 2
fi

if [[ "$MODE" == "--arm-motion" ]]; then
  ENABLE_LOCAL_PLANNER=true
  ENABLE_PATH_FOLLOWER=true
  PLANNER_STATUS=TARE_localPlanner_pathFollower
  GO2_CONTROL_ALLOWED=1
elif [[ "$MODE" == "--manual-map" ]]; then
  ENABLE_LOCAL_PLANNER=true
  ENABLE_PATH_FOLLOWER=false
  PLANNER_STATUS=TARE_localPlanner_manual_mapping
  GO2_CONTROL_ALLOWED=0
else
  ENABLE_LOCAL_PLANNER=true
  ENABLE_PATH_FOLLOWER=true
  PLANNER_STATUS=TARE_localPlanner_pathFollower_dry_run
  GO2_CONTROL_ALLOWED=0
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$ROOT/logs/sysnav-foreground-$RUN_ID"
STATUS_FILE="$LOG_DIR/status.txt"
SUPERVISOR_LOG="$LOG_DIR/supervisor.log"
mkdir -p "$LOG_DIR"

BRIDGE="$ROOT/scripts/hardware/go2/manage_sysnav_go2_bridge.sh"
DEMO_RECORDER="$ROOT/scripts/sysnav/record_sysnav_demo.sh"

declare -a CHILD_NAMES=()
declare -a CHILD_PIDS=()
CONTROL_STARTED=0
CLEANED_UP=0
SEMANTIC_JOB_ID=""
SEMANTIC_STATUS_POLL=0
SEMANTIC_SETUP_PID=""
CORE_STARTED_AT=0
START_CHILD_SETTLE_SEC="${SYSNAV_CHILD_SETTLE_SEC:-0.25}"

log() {
  local message
  message="$(date '+%F %T') $*"
  printf '%s\n' "$message"
  printf '%s\n' "$message" >>"$SUPERVISOR_LOG"
}

fail() {
  log "FAILED: $*"
  printf 'FAILED: %s\n' "$*" >"$STATUS_FILE"
  return 1
}

require_file() {
  [[ -r "$1" ]] || fail "required file is missing: $1"
}

ros_setup() {
  set +u
  source /opt/ros/humble/setup.bash
  source "$ROOT/src/elevator_lio_ws/install/setup.bash"
  source "$ROOT/src/fastlio2_ws/install/setup.bash"
  source "$ROOT/src/camera_x5_ws/install/setup.bash"
  source "$ROOT/src/sysnav_ws/install/setup.bash"
  source "$ROOT/src/sysnav_ws/install-standalone-preview/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
}

wait_ping() {
  local label="$1" address="$2" deadline=$((SECONDS + STARTUP_TIMEOUT))
  while ((SECONDS < deadline)); do
    if ping -I "$GO2_IFACE" -c 1 -W 1 "$address" >/dev/null 2>&1; then
      log "$label reachable at $address"
      return 0
    fi
    sleep 2
  done
  fail "$label did not become reachable at $address within ${STARTUP_TIMEOUT}s"
}

wait_topic() {
  local topic="$1" timeout_seconds="${2:-$STARTUP_TIMEOUT}"
  local deadline=$((SECONDS + timeout_seconds))
  log "waiting for topic: $topic (timeout ${timeout_seconds}s)"
  while ((SECONDS < deadline)); do
    if timeout 3 ros2 topic echo "$topic" --once >/dev/null 2>&1; then
      log "topic ready: $topic"
      return 0
    fi
    if [[ -n "$SEMANTIC_JOB_ID" ]] && semantic_job_stopped; then
      fail "HKUST semantic job $SEMANTIC_JOB_ID stopped while waiting for $topic"
      return 1
    fi
    sleep 1
  done
  fail "topic did not publish within ${timeout_seconds}s: $topic"
}

wait_mid360_stream_stable() {
  log "checking continuous Mid-360 LiDAR/IMU data before starting SysNav"
  if ! timeout 15 python3 - <<'PY'
import sys
import time

import rclpy
from livox_ros_driver2.msg import CustomMsg
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import Imu

rclpy.init()
node = rclpy.create_node("sysnav_mid360_startup_gate")
counts = {"lidar": 0, "imu": 0}
stamps = {"lidar": None, "imu": None}
started = time.monotonic()


def stamp_seconds(stamp):
    return float(stamp.sec) + float(stamp.nanosec) * 1e-9


def lidar_callback(message):
    counts["lidar"] += 1
    stamps["lidar"] = stamp_seconds(message.header.stamp)


def imu_callback(message):
    counts["imu"] += 1
    stamps["imu"] = stamp_seconds(message.header.stamp)


node.create_subscription(
    CustomMsg, "/livox/lidar", lidar_callback, qos_profile_sensor_data
)
node.create_subscription(Imu, "/livox/imu", imu_callback, qos_profile_sensor_data)

try:
    while time.monotonic() - started < 12.0:
        rclpy.spin_once(node, timeout_sec=0.1)
        elapsed = time.monotonic() - started
        # livox_ros_driver2 exposes the Mid-360 IMU in the same observed ROS
        # delivery cadence as CustomMsg on this Jetson build. Require sustained
        # delivery from both topics instead of assuming the raw 200 Hz IMU rate.
        if elapsed >= 3.0 and counts["lidar"] >= 20 and counts["imu"] >= 20:
            skew = abs(stamps["lidar"] - stamps["imu"])
            if skew <= 0.5:
                print(
                    f"lidar_frames={counts['lidar']} imu_frames={counts['imu']} "
                    f"latest_stamp_skew_s={skew:.3f}"
                )
                sys.exit(0)
    print(
        f"unstable Mid-360 stream: lidar_frames={counts['lidar']} "
        f"imu_frames={counts['imu']}",
        file=sys.stderr,
    )
    sys.exit(1)
finally:
    node.destroy_node()
    rclpy.shutdown()
PY
  then
    fail "Mid-360 LiDAR/IMU streams did not remain stable; SysNav was not started"
    return 1
  fi
  log "Mid-360 stream stable"
}

wait_core_topic() {
  local topic="$1" timeout_seconds="${2:-$STARTUP_TIMEOUT}"
  local deadline=$((SECONDS + timeout_seconds))
  log "waiting for SysNav core topic: $topic (timeout ${timeout_seconds}s)"
  while ((SECONDS < deadline)); do
    if timeout 3 ros2 topic echo "$topic" --once >/dev/null 2>&1; then
      log "topic ready: $topic"
      return 0
    fi
    if grep -Eq 'feature_extraction_node.*process has died|fastlio_mapping.*process has died|Assertion .*plannerPoints' \
        "$LOG_DIR/sysnav_core.log" 2>/dev/null; then
      log "WARNING: $LIO_BACKEND localization exited during startup"
      return 3
    fi
    sleep 1
  done
  log "WARNING: SysNav core topic did not publish within ${timeout_seconds}s: $topic"
  return 2
}

wait_localization_healthy() {
  local timeout_seconds="${1:-$STARTUP_TIMEOUT}"
  local output deadline=$((SECONDS + timeout_seconds))
  log "waiting for healthy $LIO_BACKEND localization (timeout ${timeout_seconds}s)"
  while ((SECONDS < deadline)); do
    output="$(timeout 3 ros2 topic echo /state_estimation_health --once --field data 2>/dev/null || true)"
    if grep -Eiq '^true$' <<<"$output"; then
      log "$LIO_BACKEND localization health confirmed"
      return 0
    fi
    sleep 1
  done
  fail "$LIO_BACKEND localization did not report healthy within ${timeout_seconds}s"
}

wait_param() {
  local node="$1" parameter="$2" expected="$3"
  local output deadline=$((SECONDS + STARTUP_TIMEOUT))
  while ((SECONDS < deadline)); do
    output="$(timeout 4 ros2 param get "$node" "$parameter" 2>/dev/null || true)"
    if grep -Fq -- "$expected" <<<"$output"; then
      return 0
    fi
    sleep 1
  done
  fail "$node parameter $parameter is not $expected"
}

start_child() {
  local name="$1" command="$2" pid
  setsid bash -c "$command" >"$LOG_DIR/$name.log" 2>&1 &
  pid=$!
  CHILD_NAMES+=("$name")
  CHILD_PIDS+=("$pid")
  sleep "$START_CHILD_SETTLE_SEC"
  if ! kill -0 "$pid" 2>/dev/null; then
    tail -n 30 "$LOG_DIR/$name.log" >&2 || true
    fail "$name exited during startup"
    return 1
  fi
  log "started $name (pid=$pid)"
}

restart_child() {
  local name="$1" command="$2" index=-1 pid i
  for i in "${!CHILD_NAMES[@]}"; do
    if [[ "${CHILD_NAMES[$i]}" == "$name" ]]; then
      index="$i"
      break
    fi
  done
  ((index >= 0)) || fail "cannot restart untracked child: $name"
  pid="${CHILD_PIDS[$index]}"

  log "recycling $name process group after startup failure (pgid=$pid)"
  kill -INT -- "-$pid" 2>/dev/null || true
  sleep 3
  kill -TERM -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  mv "$LOG_DIR/$name.log" "$LOG_DIR/${name}-attempt1.log"
  setsid bash -c "$command" >"$LOG_DIR/$name.log" 2>&1 &
  pid=$!
  CHILD_PIDS[$index]="$pid"
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    tail -n 30 "$LOG_DIR/$name.log" >&2 || true
    fail "$name retry exited during startup"
    return 1
  fi
  log "restarted $name (pid=$pid)"
}

process_group_alive() {
  pgrep -g "$1" >/dev/null 2>&1
}

cleanup() {
  local i pid tunnel_pid
  ((CLEANED_UP)) && return 0
  CLEANED_UP=1

  # A second Control-C must not interrupt the process-group cleanup below.
  trap '' INT TERM HUP

  if ((RECORD_DEMO)); then
    log "stopping integrated demo recording"
    "$DEMO_RECORDER" stop >>"$SUPERVISOR_LOG" 2>&1 || true
  fi

  if ((GO2_CONTROL_ALLOWED)); then
    log "publishing zero velocity and disconnecting the official Go2 WebRTC node"
    "$BRIDGE" stop >>"$SUPERVISOR_LOG" 2>&1 || true
  else
    log "control-disabled mode: stopping managed processes without sending Go2 control requests"
  fi

  if [[ -n "$SEMANTIC_SETUP_PID" ]] && kill -0 "$SEMANTIC_SETUP_PID" 2>/dev/null; then
    log "stopping semantic-link setup (pid=$SEMANTIC_SETUP_PID)"
    kill -TERM "$SEMANTIC_SETUP_PID" 2>/dev/null || true
    wait "$SEMANTIC_SETUP_PID" 2>/dev/null || true
  fi
  if [[ -n "$SEMANTIC_SETUP_PID" && -r "$LOG_DIR/hkust-tunnel.pid" ]]; then
    tunnel_pid="$(cat "$LOG_DIR/hkust-tunnel.pid")"
    if process_group_alive "$tunnel_pid"; then
      kill -INT -- "-$tunnel_pid" 2>/dev/null || true
    fi
  fi

  for ((i=${#CHILD_PIDS[@]} - 1; i >= 0; i--)); do
    pid="${CHILD_PIDS[$i]}"
    if process_group_alive "$pid"; then
      log "stopping ${CHILD_NAMES[$i]} (pid=$pid)"
      kill -INT -- "-$pid" 2>/dev/null || true
    fi
  done
  sleep 3
  for pid in "${CHILD_PIDS[@]}"; do
    if process_group_alive "$pid"; then
      kill -TERM -- "-$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in "${CHILD_PIDS[@]}"; do
    if process_group_alive "$pid"; then
      log "forcing remaining managed process group to stop (pgid=$pid)"
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
  done

  if [[ -z "$SEMANTIC_JOB_ID" && -r "$LOG_DIR/semantic-job.txt" ]]; then
    SEMANTIC_JOB_ID="$(awk -F= '$1 == "job_id" {print $2}' "$LOG_DIR/semantic-job.txt")"
  fi
  if [[ -n "$SEMANTIC_JOB_ID" ]]; then
    log "cancelling HKUST semantic job $SEMANTIC_JOB_ID"
    ssh -i "$HOME/.ssh/id_ed25519" \
      -o BatchMode=yes -o ConnectTimeout=8 robot@login.example \
      "scancel '$SEMANTIC_JOB_ID'" >>"$SUPERVISOR_LOG" 2>&1 || \
      log "WARNING: failed to cancel semantic job $SEMANTIC_JOB_ID"
  fi
}

semantic_job_stopped() {
  local status
  [[ -n "$SEMANTIC_JOB_ID" ]] || return 1
  status="$(ssh -i "$HOME/.ssh/id_ed25519" \
    -o BatchMode=yes -o ConnectTimeout=5 robot@login.example \
    'cat /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/logs/sysnav-semantic-live.status 2>/dev/null' \
    2>/dev/null || true)"
  grep -Eq "^(STOPPED|FAILED) job=$SEMANTIC_JOB_ID " <<<"$status"
}

on_signal() {
  local signal="$1"
  log "received $signal"
  cleanup
  printf 'STOPPED: received %s\n' "$signal" >"$STATUS_FILE"
  exit 130
}

trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

preflight() {
  local collision pattern
  local -a collision_patterns=(
    livox_ros_driver2_node x5_sdk_node x5_panorama_tcp_receiver feature_extraction_node laser_mapping_node
    imu_preintegration_node fastlio_mapping fastlio2_sysnav_adapter
    elevator_lio elevator_sysnav_adapter /lio/lib/lio/lio
    terrainAnalysis terrainAnalysisExt localPlanner
    pathFollower tare_planner_node room_segmentation unitree_webrtc_ros/unitree_control
  )

  require_file "$ROOT/scripts/elevator_lio/mid360_driver_launch.py"
  require_file "$ROOT/scripts/sysnav/sysnav_exploration_planner_only.launch.py"
  require_file "$ROOT/scripts/hardware/mid360/fastlio2_mid360_real.yaml"
  require_file "$ROOT/scripts/sysnav/start_hkust_semantic_link.sh"
  require_file "$ROOT/scripts/sysnav/tare_planner_ground_jetson_operational.rviz"
  require_file "$ROOT/scripts/sysnav/x5_sysnav.yaml"
  require_file "$ROOT/scripts/sysnav/sysnav_image_viewer.py"
  require_file "$ROOT/scripts/sysnav/sysnav_object_viz.py"
  require_file "$ROOT/scripts/sysnav/sysnav_runtime_guard.py"
  require_file "$ROOT/scripts/sysnav/elevator_sysnav_adapter.py"
  require_file "$ROOT/scripts/x5_panorama_tcp_receiver.py"
  require_file "$ROOT/scripts/x5_annotated_tcp_receiver.py"
  require_file "$ROOT/scripts/sysnav_semantic_bridge.py"
  require_file "$ROOT/scripts/hardware/nomachine/nomachine-session-env.sh"
  require_file "$BRIDGE"
  if ((RECORD_DEMO)); then
    require_file "$DEMO_RECORDER"
  fi
  if [[ "$LIO_BACKEND" == "fastlio2" ]]; then
    require_file "$ROOT/src/fastlio2_ws/install/setup.bash"
    require_file "$ROOT/src/fastlio2_ws/install/fast_lio/lib/fast_lio/fastlio_mapping"
    require_file "$ROOT/src/fastlio2_ws/install/fastlio2_go2_adapter/lib/fastlio2_go2_adapter/fastlio2_sysnav_adapter"
  elif [[ "$LIO_BACKEND" == "elevator" ]]; then
    require_file "$ROOT/src/elevator_lio_ws/install/setup.bash"
    require_file "$ROOT/src/elevator_lio_ws/install/lio/lib/lio/lio"
    require_file "$ROOT/src/elevator_lio_ws/install/lio/share/lio/yaml/root_mid360_go2.yaml"
  fi

  if ((GO2_CONTROL_ALLOWED)); then
    "$BRIDGE" stop >/dev/null 2>&1 || true
    sleep 2
  fi

  ip link show "$GO2_IFACE" | grep -q LOWER_UP || fail "$GO2_IFACE has no carrier"
  ip -4 address show "$GO2_IFACE" | grep -q '192\.168\.1\.5/24' || \
    fail "$GO2_IFACE is missing 192.168.1.5/24 for Mid-360"
  ip -4 address show "$GO2_IFACE" | grep -q '192\.168\.123\.99/24' || \
    fail "$GO2_IFACE is missing 192.168.123.99/24 for Go2"

  for pattern in "${collision_patterns[@]}"; do
    if collision="$(pgrep -af "$pattern" 2>/dev/null)"; then
      printf '%s\n' "$collision" >>"$LOG_DIR/process-collisions.txt"
      fail "an existing process matches '$pattern'; stop the previous stack first"
    fi
  done

  wait_ping Mid-360 "$MID360_IP"
  wait_ping Go2 "$GO2_IP"

  if ((HEADLESS)); then
    log "headless mode: skipping the GNOME/RViz display check"
  else
    if ! source "$ROOT/scripts/hardware/nomachine/nomachine-session-env.sh"; then
      fail "no active GNOME desktop was found for RViz"
    fi
    timeout 5 xset -q >/dev/null 2>&1 || fail "desktop cannot accept RViz windows"
    log "desktop ready on DISPLAY=$DISPLAY"
  fi
}

preflight
if ((!GO2_CONTROL_ALLOWED)); then
  log "control-disabled mode: preserving handheld Go2 controls and built-in settings"
fi
ros_setup

log "preparing HKUST semantic link in parallel with Mid-360 startup"
SEMANTIC_SETUP_LOG="$LOG_DIR/semantic-link-setup.log"
SYSNAV_RUN_DIR="$LOG_DIR" "$ROOT/scripts/sysnav/start_hkust_semantic_link.sh" \
  >"$SEMANTIC_SETUP_LOG" 2>&1 &
SEMANTIC_SETUP_PID=$!

start_child mid360_driver '
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  source "$HOME/lianaiwei/src/elevator_lio_ws/install/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
  exec ros2 launch "$HOME/lianaiwei/scripts/elevator_lio/mid360_driver_launch.py"
'
wait_topic /livox/lidar
wait_topic /livox/imu
wait_mid360_stream_stable

if ((RECORD_LIO)); then
  start_child lio_recorder "
    set -euo pipefail
    set +u
    source /opt/ros/humble/setup.bash
    source \"$ROOT/src/fastlio2_ws/install/setup.bash\"
    source \"$ROOT/src/sysnav_ws/install/setup.bash\"
    set -u
    unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
    export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
    exec ros2 bag record -o \"$LOG_DIR/lio-diagnostic-bag\" \\
      /livox/lidar /livox/imu /Odometry /state_estimation \\
      /state_estimation_health /cmd_vel \\
      /room_nodes_list /LIO/odom_vehicle /LIO/clouds_lidar \\
      /way_point /path /free_paths /slow_down /global_path /local_path
  "
fi

SYSNAV_CORE_COMMAND='
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  source "$HOME/lianaiwei/src/fastlio2_ws/install/setup.bash"
  source "$HOME/lianaiwei/src/elevator_lio_ws/install/setup.bash"
  source "$HOME/lianaiwei/src/sysnav_ws/install/setup.bash"
  source "$HOME/lianaiwei/src/sysnav_ws/install-standalone-preview/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
  exec ros2 launch "$HOME/lianaiwei/scripts/sysnav/sysnav_exploration_planner_only.launch.py" \
    lio_backend:='"$LIO_BACKEND"' \
    enable_local_planner:='"$ENABLE_LOCAL_PLANNER"' \
    enable_path_follower:='"$ENABLE_PATH_FOLLOWER"'
'
start_child sysnav_core "$SYSNAV_CORE_COMMAND"
CORE_STARTED_AT=$SECONDS

if ! wait "$SEMANTIC_SETUP_PID"; then
  cat "$SEMANTIC_SETUP_LOG" | tee -a "$SUPERVISOR_LOG" >&2 || true
  fail "HKUST semantic link setup failed; see $SEMANTIC_SETUP_LOG"
  exit 1
fi
SEMANTIC_SETUP_PID=""
cat "$SEMANTIC_SETUP_LOG" | tee -a "$SUPERVISOR_LOG"
if [[ -r "$LOG_DIR/semantic-job.txt" ]]; then
  SEMANTIC_JOB_ID="$(awk -F= '$1 == "job_id" {print $2}' "$LOG_DIR/semantic-job.txt")"
fi
if [[ -r "$LOG_DIR/hkust-tunnel.pid" ]]; then
  CHILD_NAMES+=(hkust_tunnel)
  CHILD_PIDS+=("$(cat "$LOG_DIR/hkust-tunnel.pid")")
fi

# These components are independent once the semantic TCP forwards exist. Start
# them together, then use the readiness checks below as a single startup barrier.
start_child x5_camera '
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  source "$HOME/lianaiwei/src/camera_x5_ws/install/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
  exec ros2 run insta360_x5_sdk_ros2 x5_sdk_node --ros-args \
    --params-file "$HOME/lianaiwei/src/camera_x5_ws/install/insta360_x5_sdk_ros2/share/insta360_x5_sdk_ros2/config/x5_sdk.yaml" \
    --params-file "$HOME/lianaiwei/scripts/sysnav/x5_sysnav.yaml"
'
start_child panorama_receiver '
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  source "$HOME/lianaiwei/src/sysnav_ws/install/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0 X5_TCP_SERVER=127.0.0.1
  exec python3 "$HOME/lianaiwei/scripts/x5_panorama_tcp_receiver.py"
'
start_child annotated_receiver '
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  source "$HOME/lianaiwei/src/sysnav_ws/install/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0 X5_TCP_SERVER=127.0.0.1
  exec python3 "$HOME/lianaiwei/scripts/x5_annotated_tcp_receiver.py"
'
start_child semantic_uplink '
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  source "$HOME/lianaiwei/src/sysnav_ws/install/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
  exec python3 "$HOME/lianaiwei/scripts/sysnav_semantic_bridge.py" \
    jetson-uplink --host 127.0.0.1
'
start_child semantic_downlink '
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  source "$HOME/lianaiwei/src/sysnav_ws/install/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
  exec python3 "$HOME/lianaiwei/scripts/sysnav_semantic_bridge.py" \
    jetson-downlink --host 127.0.0.1
'

if ! wait_core_topic /state_estimation 30; then
  log "first $LIO_BACKEND startup did not produce localization; keeping sensor streams live"
  restart_child sysnav_core "$SYSNAV_CORE_COMMAND"
  CORE_STARTED_AT=$SECONDS
  wait_core_topic /state_estimation 60 || \
    fail "$LIO_BACKEND failed after one clean core restart; see $LOG_DIR/sysnav_core.log"
fi
wait_topic /registered_scan 60
wait_localization_healthy 30
wait_topic /terrain_map 60
wait_topic /terrain_map_ext 60
wait_topic /way_point 60
wait_topic /camera/x5_lens/image 30
wait_topic /camera/x5_lens/image/compressed 30
wait_topic /camera/image 90
wait_topic /camera/image/compressed 30
wait_topic /annotated_image/compressed 300
wait_param /terrainAnalysis vehicleHeight '0.9'
wait_param /terrainAnalysisExt vehicleHeight '0.9'
if [[ "$ENABLE_LOCAL_PLANNER" == true ]]; then
  wait_topic /path 60
  wait_topic /free_paths 60
  wait_param /localPlanner sensorOffsetX '0.32'
  wait_param /localPlanner vehicleLength '0.6'
  wait_param /localPlanner vehicleWidth '0.45'
  wait_param /localPlanner maxSpeed '0.5'
  wait_param /localPlanner checkRotObstacle 'False'
  wait_param /localPlanner twoWayDrive 'False'
fi
if [[ "$ENABLE_PATH_FOLLOWER" == true ]]; then
  wait_topic /cmd_vel 60
  wait_param /pathFollower maxSpeed '0.5'
  wait_param /pathFollower maxAccel '0.5'
  wait_param /pathFollower maxYawRate '28.64789'
  wait_param /pathFollower twoWayDrive 'False'
  log "Go2 geometry, obstacle envelope, official planning/following direction policy and speed limits confirmed"
elif [[ "$ENABLE_LOCAL_PLANNER" == true ]]; then
  log "localPlanner is active; pathFollower and all SysNav velocity output are disabled"
else
  log "validation mode: localPlanner and pathFollower are disabled"
fi

core_age=$((SECONDS - CORE_STARTED_AT))
if ((core_age < 10)); then
  remaining_hold=$((10 - core_age))
  log "holding Go2 still for the remaining ${remaining_hold}s of the 10s $LIO_BACKEND/TARE initialization window"
  sleep "$remaining_hold"
else
  log "$LIO_BACKEND/TARE has already been running for ${core_age}s; no additional fixed startup hold needed"
fi
wait_topic /state_estimation 10
wait_localization_healthy 10
if [[ "$MODE" == "--arm-motion" ]]; then
  wait_topic /cmd_vel 10
fi

start_child runtime_guard '
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  source "$HOME/lianaiwei/src/sysnav_ws/install/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
  exec python3 "$HOME/lianaiwei/scripts/sysnav/sysnav_runtime_guard.py"
'

start_child object_viz '
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  source "$HOME/lianaiwei/src/sysnav_ws/install/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
  exec python3 "$HOME/lianaiwei/scripts/sysnav/sysnav_object_viz.py"
'

if ((!HEADLESS)); then
  start_child rviz '
    set -euo pipefail
    source "$HOME/lianaiwei/scripts/hardware/nomachine/nomachine-session-env.sh"
    set +u
    source /opt/ros/humble/setup.bash
    source "$HOME/lianaiwei/src/sysnav_ws/install/setup.bash"
    set -u
    unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
    export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
    exec nice -n 15 rviz2 -d "$HOME/lianaiwei/scripts/sysnav/tare_planner_ground_jetson_operational.rviz"
  '
  start_child image_viewer '
    set -euo pipefail
    source "$HOME/lianaiwei/scripts/hardware/nomachine/nomachine-session-env.sh"
    set +u
    source /opt/ros/humble/setup.bash
    source "$HOME/lianaiwei/src/sysnav_ws/install/setup.bash"
    set -u
    unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
    export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
    exec nice -n 10 python3 "$HOME/lianaiwei/scripts/sysnav/sysnav_image_viewer.py"
  '
fi
for i in "${!CHILD_PIDS[@]}"; do
  if ! kill -0 "${CHILD_PIDS[$i]}" 2>/dev/null; then
    fail "${CHILD_NAMES[$i]} exited before the motion bridge was armed; see $LOG_DIR/${CHILD_NAMES[$i]}.log"
    exit 1
  fi
done
if [[ "$MODE" == "--arm-motion" ]]; then
  log "arming the verified Unitree WebRTC control bridge last"
  bridge_armed=0
  for attempt in $(seq 1 "$GO2_BRIDGE_ATTEMPTS"); do
    if "$BRIDGE" arm | tee -a "$SUPERVISOR_LOG"; then
      bridge_armed=1
      break
    fi
    log "Go2 WebRTC arm attempt ${attempt}/${GO2_BRIDGE_ATTEMPTS} failed"
    "$BRIDGE" stop >>"$SUPERVISOR_LOG" 2>&1 || true
    if ((attempt < GO2_BRIDGE_ATTEMPTS)); then
      log "retrying Go2 WebRTC arm in ${GO2_BRIDGE_RETRY_SEC}s"
      sleep "$GO2_BRIDGE_RETRY_SEC"
    fi
  done
  if ((bridge_armed == 0)); then
    fail "Go2 WebRTC control bridge failed after ${GO2_BRIDGE_ATTEMPTS} attempts"
    exit 1
  fi
  CONTROL_STARTED=1
  STATUS_MODE=ARMED
elif [[ "$MODE" == "--manual-map" ]]; then
  log "manual-map mode: Go2 control bridge remains stopped and no Go2 command was sent"
  STATUS_MODE=MANUAL_MAPPING
else
  log "validation mode: Go2 control bridge remains stopped"
  STATUS_MODE=VALIDATED
fi

if ((RECORD_DEMO)); then
  start_child demo_recorder "
    set -euo pipefail
    sleep $RECORD_DELAY_SEC
    \"$DEMO_RECORDER\" start
    while true; do
      status=\$(\"$DEMO_RECORDER\" status)
      grep -Fq 'screen=running' <<<\"\$status\"
      grep -Fq 'bag=running' <<<\"\$status\"
      sleep 2
    done
  "
  log "demo recording scheduled to start in ${RECORD_DELAY_SEC}s"
fi

cat >"$STATUS_FILE" <<EOF
$STATUS_MODE
mode=unknown_environment_active_exploration
localization=$LIO_BACKEND
planner=$PLANNER_STATUS
semantic_mapping=HKUST_4090_YOLOE_SAM2_3D
lio_recording=$([[ "$RECORD_LIO" == 1 ]] && printf enabled || printf disabled)
visualization=$([[ "$HEADLESS" == 1 ]] && printf headless || printf nomachine)
motion_output=$([[ "$ENABLE_PATH_FOLLOWER" == true ]] && printf enabled || printf disabled)
demo_recording=$([[ "$RECORD_DEMO" == 1 ]] && printf "scheduled_after_${RECORD_DELAY_SEC}s" || printf disabled)
EOF
cat "$STATUS_FILE"
if [[ "$MODE" == "--arm-motion" ]]; then
  log "full SysNav/TARE stack armed; autonomous exploration is active"
elif [[ "$MODE" == "--manual-map" ]]; then
  log "full semantic SysNav mapping is active; drive Go2 only with the handheld controller"
else
  log "full SysNav/TARE stack validated with robot motion disabled"
fi
if ((GO2_CONTROL_ALLOWED)); then
  log "press Control-C here to publish StopMove and stop every child process"
else
  log "press Control-C here to stop managed processes without sending a Go2 command"
fi

while true; do
  for i in "${!CHILD_PIDS[@]}"; do
    if ! kill -0 "${CHILD_PIDS[$i]}" 2>/dev/null; then
      fail "${CHILD_NAMES[$i]} exited unexpectedly; see $LOG_DIR/${CHILD_NAMES[$i]}.log"
      exit 1
    fi
  done
  for pattern in '[t]are_planner_node' '[r]oom_segmentation'; do
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
      fail "critical SysNav node exited: $pattern"
      exit 1
    fi
  done
  if [[ "$MODE" == "--arm-motion" ]]; then
    for pattern in '[l]ocalPlanner' '[p]athFollower'; do
      if ! pgrep -f "$pattern" >/dev/null 2>&1; then
        fail "critical SysNav motion node exited: $pattern"
        exit 1
      fi
    done
  fi
  if [[ "$LIO_BACKEND" == "fastlio2" ]]; then
    if ! pgrep -f '[f]astlio_mapping' >/dev/null 2>&1; then
      fail "FAST-LIO2 exited unexpectedly"
      exit 1
    fi
  elif [[ "$LIO_BACKEND" == "elevator" ]]; then
    if ! pgrep -f '/lio/lib/lio/lio' >/dev/null 2>&1; then
      fail "Elevator-LIO exited unexpectedly"
      exit 1
    fi
  elif ! pgrep -f '[l]aser_mapping_node' >/dev/null 2>&1; then
    fail "ARISE-SLAM laser mapping exited unexpectedly"
    exit 1
  fi
  if [[ "$MODE" == "--arm-motion" ]] && \
      ! "$BRIDGE" status | head -1 | grep -Fq 'mode=armed'; then
    fail "Go2 WebRTC control bridge stopped unexpectedly"
    exit 1
  fi
  ((SEMANTIC_STATUS_POLL += 1))
  if ((SEMANTIC_STATUS_POLL >= 5)); then
    SEMANTIC_STATUS_POLL=0
    if semantic_job_stopped; then
      fail "HKUST semantic job $SEMANTIC_JOB_ID stopped unexpectedly"
      exit 1
    fi
  fi
  sleep 2
done
