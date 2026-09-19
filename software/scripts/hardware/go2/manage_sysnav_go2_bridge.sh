#!/usr/bin/env bash
set -euo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
SCRIPT_DIR="$ROOT/scripts/hardware/go2"
ENV_FILE="$SCRIPT_DIR/unitree_go2_env.sh"
VENV="$ROOT/venvs/sysnav"
SYSNAV_SETUP="$ROOT/src/sysnav_ws/install/setup.bash"
ARMED_EXECUTABLE="$ROOT/src/sysnav_ws/install/unitree_webrtc_ros/lib/unitree_webrtc_ros/unitree_control"
STATE_DIR="$ROOT/logs/hardware/go2/sysnav-sdk-bridge"
PID_FILE="$STATE_DIR/bridge.pid"
LOG_FILE="$STATE_DIR/bridge.log"
ACTION="${1:-status}"

mkdir -p "$STATE_DIR"

bridge_pid() {
  if [[ -s "$PID_FILE" ]]; then
    cat "$PID_FILE"
  fi
}

bridge_running() {
  local pid
  pid="$(bridge_pid || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null &&
    ps -p "$pid" -o command= | grep -Fq "$ARMED_EXECUTABLE"
}

bridge_verified() {
  bridge_running &&
    grep -Fq 'ExitObstacleAvoidance command sent successfully' "$LOG_FILE" &&
    grep -Fq 'Unitree control node started' "$LOG_FILE"
}

stop_owned_controller_processes() {
  local pid
  while read -r pid; do
    [[ -n "$pid" && "$pid" != "$$" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done < <(pgrep -f "$ARMED_EXECUTABLE" 2>/dev/null || true)

  for _ in $(seq 1 30); do
    if ! pgrep -f "$ARMED_EXECUTABLE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  while read -r pid; do
    [[ -n "$pid" && "$pid" != "$$" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done < <(pgrep -f "$ARMED_EXECUTABLE" 2>/dev/null || true)
}

publish_zero_cmd_vel() {
  (
    set +u
    source /opt/ros/humble/setup.bash
    source "$SYSNAV_SETUP"
    set -u
    unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
    export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
    timeout 5 ros2 topic pub --once --qos-reliability best_effort \
      /cmd_vel geometry_msgs/msg/TwistStamped \
      '{header: {frame_id: vehicle}, twist: {linear: {x: 0.0, y: 0.0, z: 0.0}, angular: {x: 0.0, y: 0.0, z: 0.0}}}'
  ) >/dev/null 2>&1 || true
}

stop_bridge() {
  local pid
  pid="$(bridge_pid || true)"
  if bridge_running; then
    publish_zero_cmd_vel
    sleep 0.2
    kill -TERM "$pid"
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid"
  fi
  stop_owned_controller_processes
  rm -f "$PID_FILE"
}

start_bridge() {
  if bridge_running; then
    echo "Unitree controller is already running: pid=$(bridge_pid)" >&2
    exit 1
  fi
  stop_owned_controller_processes
  if [[ ! -r "$ENV_FILE" || ! -r "$SYSNAV_SETUP" || ! -x "$ARMED_EXECUTABLE" ]]; then
    echo "Go2 environment or official Unitree controller is missing" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$ENV_FILE" >/dev/null 2>&1
  set +u
  # shellcheck disable=SC1090
  source "$VENV/bin/activate"
  # shellcheck disable=SC1090
  source "$SYSNAV_SETUP"
  set -u
  : >"$LOG_FILE"
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
  setsid "$VENV/bin/python3" "$ARMED_EXECUTABLE" --ros-args \
    -r __node:=sysnav_unitree_control \
    -p robot_ip:=192.168.123.161 \
    -p connection_method:=LocalSTA \
    -p control_mode:=wireless_controller \
    >"$LOG_FILE" 2>&1 < /dev/null &
  local pid=$!
  printf '%s\n' "$pid" >"$PID_FILE"
  for _ in $(seq 1 80); do
    bridge_verified && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  if ! bridge_verified; then
    tail -40 "$LOG_FILE" >&2
    rm -f "$PID_FILE"
    exit 1
  fi
  echo "Unitree controller started: pid=$pid mode=armed"
}

case "$ACTION" in
  arm)
    stop_bridge
    start_bridge
    ;;
  stop)
    stop_bridge
    echo "Bridge stopped"
    ;;
  status)
    if bridge_running; then
      echo "RUNNING pid=$(bridge_pid) mode=armed"
      tail -5 "$LOG_FILE" 2>/dev/null || true
    else
      echo "STOPPED"
    fi
    ;;
  *)
    echo "Usage: $0 {arm|stop|status}" >&2
    exit 2
    ;;
esac
