#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
GO2_IFACE="${GO2_IFACE:-eth0}"
GO2_IP="${GO2_IP:-192.168.123.161}"
MID360_IP="${MID360_IP:-192.168.1.148}"
STARTUP_TIMEOUT="${SCANPLANNER_STARTUP_TIMEOUT:-60}"
MODE="${1:-preview}"

case "$MODE" in
  preview|run)
    MODE=preview
    ;;
  --validate)
    MODE=validate
    ;;
  --arm-motion)
    MODE=armed
    ;;
  --check) ;;
  *)
    echo "Usage: $0 [preview|--validate|--arm-motion|--check]" >&2
    exit 2
    ;;
esac

RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$ROOT/logs/hardware/scanplanner-full-$RUN_ID"
STATUS_FILE="$LOG_DIR/status.txt"
SUPERVISOR_LOG="$LOG_DIR/supervisor.log"
mkdir -p "$LOG_DIR"

declare -a CHILD_NAMES=()
declare -a CHILD_PIDS=()
CONTROL_STARTED=0
CLEANED_UP=0

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

wait_ping() {
  local label="$1"
  local address="$2"
  local deadline=$((SECONDS + STARTUP_TIMEOUT))

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
  local topic="$1"
  local deadline=$((SECONDS + STARTUP_TIMEOUT))

  while ((SECONDS < deadline)); do
    if timeout 3 ros2 topic echo "$topic" --once >/dev/null 2>&1; then
      log "topic ready: $topic"
      return 0
    fi
    sleep 1
  done
  fail "topic did not publish within ${STARTUP_TIMEOUT}s: $topic"
}

start_child() {
  local name="$1"
  local command="$2"
  local pid

  setsid bash -c "$command" >"$LOG_DIR/$name.log" 2>&1 &
  pid=$!
  CHILD_NAMES+=("$name")
  CHILD_PIDS+=("$pid")
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    tail -n 20 "$LOG_DIR/$name.log" >&2 || true
    fail "$name exited during startup"
    return 1
  fi
  log "started $name (pid=$pid)"
}

publish_l1_off() {
  log "publishing Unitree's official one-shot L1 OFF command"
  if ! timeout 20 bash -c '
    set -e
    source "$HOME/lianaiwei/scripts/hardware/go2/unitree_go2_env.sh" >/dev/null 2>&1
    exec ros2 topic pub --once \
      --qos-reliability best_effort \
      --qos-durability volatile \
      /utlidar/switch std_msgs/msg/String "{data: '\''OFF'\''}"
  ' >"$LOG_DIR/l1-off.log" 2>&1; then
    fail "official L1 OFF publication failed; see $LOG_DIR/l1-off.log"
    return 1
  fi
  log "L1 OFF published once"
}

publish_stop_move() {
  timeout 20 "$ROOT/scripts/hardware/go2/go2_sport_safe.sh" stop \
    >>"$SUPERVISOR_LOG" 2>&1 || log "WARNING: StopMove publication did not confirm"
}

cleanup() {
  local i pid
  ((CLEANED_UP)) && return 0
  CLEANED_UP=1

  if ((CONTROL_STARTED)); then
    log "publishing StopMove before shutting down the stack"
    publish_stop_move
  fi

  for ((i=${#CHILD_PIDS[@]} - 1; i >= 0; i--)); do
    pid="${CHILD_PIDS[$i]}"
    if kill -0 "$pid" 2>/dev/null; then
      log "stopping ${CHILD_NAMES[$i]} (pid=$pid)"
      kill -INT -- "-$pid" 2>/dev/null || true
    fi
  done

  sleep 2
  for pid in "${CHILD_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM -- "-$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  done
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
  local collision
  local pattern
  local -a collision_patterns=(
    livox_ros_driver2_node
    '/install/lio/lib/lio/lio'
    scan_planner_node
    closed_loop_controller
    'go2_driver::Go2Driver'
    rviz2
  )

  require_file "$ROOT/scripts/elevator_lio/mid360_driver_launch.py"
  require_file "$ROOT/scripts/hardware/elevator_lio/run_elevator_lio_regular_safe.sh"
  require_file "$ROOT/scripts/hardware/scanplanner/run_scanplanner.sh"
  require_file "$ROOT/scripts/hardware/scanplanner/run_scanplanner_rviz_preview.sh"
  require_file "$ROOT/scripts/hardware/scanplanner/validate_elevator_rviz_preview.py"
  require_file "$ROOT/scripts/hardware/elevator_lio/monitor_body_extrinsic.py"
  require_file "$ROOT/scripts/hardware/go2/inspect_go2_connection.sh"
  require_file "$ROOT/scripts/hardware/go2/unitree_go2_env.sh"
  require_file "$ROOT/scripts/hardware/go2/go2_sport_safe.sh"
  require_file "$ROOT/scripts/hardware/nomachine/nomachine-session-env.sh"

  ip link show "$GO2_IFACE" | grep -q LOWER_UP || \
    fail "$GO2_IFACE has no carrier"
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

  if ! "$ROOT/scripts/hardware/go2/inspect_go2_connection.sh" \
      >"$LOG_DIR/go2-inspect.log" 2>&1; then
    fail "Go2 DDS inspection failed; see $LOG_DIR/go2-inspect.log"
  fi
  log "Go2 DDS read-only inspection passed"

  if ! source "$ROOT/scripts/hardware/nomachine/nomachine-session-env.sh"; then
    fail "no active GNOME desktop was found for RViz"
  fi
  if ! timeout 5 xset -q >/dev/null 2>&1; then
    fail "the active desktop cannot accept RViz windows"
  fi
  log "desktop ready on DISPLAY=$DISPLAY"
}

preflight
if [[ "$MODE" == "--check" ]]; then
  printf 'COMPLETE: preflight only; no OFF, controller, or ROS stack was started\n' \
    | tee "$STATUS_FILE"
  exit 0
fi

publish_l1_off

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/elevator_lio_ws/install/setup.bash"
source "$ROOT/src/scanplanner_ws/install/setup.bash"
set -u
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID=0
export ROS_LOCALHOST_ONLY=0

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

start_child elevator_lio '
  exec "$HOME/lianaiwei/scripts/hardware/elevator_lio/run_elevator_lio_regular_safe.sh"
'
wait_topic /LIO/odom_vehicle
wait_topic /LIO/odom_imu
wait_topic /LIO/clouds_lidar
log "holding the robot still for 10 seconds of LIO initialization"
sleep 10

if [[ "$MODE" == "armed" ]]; then
  start_child go2_cmd_vel_bridge '
    set -euo pipefail
    source "$HOME/lianaiwei/scripts/hardware/go2/unitree_go2_env.sh" >/dev/null 2>&1
    exec ros2 component standalone go2_driver go2_driver::Go2Driver --no-daemon
  '
  CONTROL_STARTED=1

  start_child scanplanner '
    exec "$HOME/lianaiwei/scripts/hardware/scanplanner/run_scanplanner.sh" real
  '
else
  start_child scanplanner_preview '
    exec "$HOME/lianaiwei/scripts/hardware/scanplanner/run_scanplanner_rviz_preview.sh"
  '
fi
wait_topic /grid_map/occupancy

start_child rviz '
  set -euo pipefail
  source "$HOME/lianaiwei/scripts/hardware/nomachine/nomachine-session-env.sh"
  set +u
  source /opt/ros/humble/setup.bash
  source "$HOME/lianaiwei/src/scanplanner_ws/install/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
  exec ros2 launch scan_planner rviz.launch.py
'

if [[ "$MODE" == "armed" ]]; then
  printf 'ARMED: controller and Go2 bridge ready; no stand-up or goal has been sent\n' \
    | tee "$STATUS_FILE"
  log "motion mode armed; open NoMachine, keep Fixed Frame=world, then use 2D Goal Pose"
  log "press Control-C here to publish StopMove and stop every child process"
else
  printf 'RUNNING_SAFE: planner preview ready; controller and Go2 bridge are absent\n' \
    | tee "$STATUS_FILE"
  log "safe preview ready; goals can generate trajectories but cannot reach Go2"
  log "press Control-C here to stop every child process"
fi

if [[ "$MODE" == "validate" ]]; then
  log "running live LIO health monitor"
  if ! timeout 45 python3 \
      "$ROOT/scripts/hardware/elevator_lio/monitor_body_extrinsic.py" \
      --seconds 20 >"$LOG_DIR/lio-health.json"; then
    fail "live LIO health validation failed; see $LOG_DIR/lio-health.json"
    exit 1
  fi

  log "publishing a planner-only validation goal"
  if ! timeout 90 python3 \
      "$ROOT/scripts/hardware/scanplanner/validate_elevator_rviz_preview.py" \
      >"$LOG_DIR/planner-validation.json" 2>"$LOG_DIR/planner-validation.err"; then
    fail "planner-only goal validation failed; see $LOG_DIR/planner-validation.err"
    exit 1
  fi

  if ros2 node list 2>/dev/null | grep -Eq \
      '^/(closed_loop_controller|open_loop_controller|go2_driver)$'; then
    fail "a controller or Go2 bridge appeared during safe validation"
    exit 1
  fi
  if ros2 topic info /cmd_vel 2>/dev/null | grep -Eq 'Publisher count: [1-9]'; then
    fail "/cmd_vel acquired a publisher during safe validation"
    exit 1
  fi

  if command -v gnome-screenshot >/dev/null 2>&1; then
    gnome-screenshot -f "$LOG_DIR/rviz-validation.png" >/dev/null 2>&1 || \
      log "WARNING: RViz validation screenshot could not be captured"
  fi

  printf 'COMPLETE: live LIO, occupancy and B-spline passed with no motion path\n' \
    | tee "$STATUS_FILE"
  log "safe live validation complete"
  exit 0
fi

while true; do
  for i in "${!CHILD_PIDS[@]}"; do
    if ! kill -0 "${CHILD_PIDS[$i]}" 2>/dev/null; then
      fail "${CHILD_NAMES[$i]} exited unexpectedly; see $LOG_DIR/${CHILD_NAMES[$i]}.log"
      exit 1
    fi
  done
  sleep 2
done
