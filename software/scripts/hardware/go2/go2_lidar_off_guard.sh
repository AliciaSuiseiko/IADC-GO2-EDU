#!/usr/bin/env bash
# lianaiwei local guard, not an official Unitree tool.
#
# Why this exists:
# During Go2 + L1 bring-up, a single OFF command on /utlidar/switch can slow or
# stop the L1 motor, but the lidar may later try to spin up again. In practice,
# publishing the same OFF string at 10 Hz has been enough to suppress that
# restart tendency during static calibration and debugging.
#
# What it does:
# - Waits until the Go2 network peer is reachable.
# - Starts one ROS 2 publisher:
#     /utlidar/switch std_msgs/msg/String "{data: 'OFF'}"
# - Stops that publisher when the Go2 peer disappears.
#
# What it does not do:
# - It does not publish motion commands.
# - It does not replace the official Unitree SDK/service interfaces.
# - It is a workaround for our bench setup, not a persistent firmware setting.
set -uo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
ENV_FILE="${GO2_ENV_FILE:-$ROOT/scripts/hardware/go2/unitree_go2_env.sh}"
GO2_IFACE="${GO2_IFACE:-eth0}"
GO2_IP="${GO2_IP:-192.168.123.161}"
GO2_LOCAL_IP="${GO2_LOCAL_IP:-192.168.123.99}"
OFF_RATE_HZ="${GO2_LIDAR_OFF_RATE_HZ:-10}"
POLL_SECONDS="${GO2_LIDAR_OFF_POLL_SECONDS:-2}"
LOG_DIR="$ROOT/logs/hardware"
LOG_FILE="$LOG_DIR/go2-lidar-off-guard.log"
LOCK_FILE="$LOG_DIR/go2-lidar-off-guard.lock"

mkdir -p "$LOG_DIR"

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >/dev/null
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "ALREADY_RUNNING exiting"
  exit 0
fi

go2_online() {
  # Use the explicit Go2 subnet source address. On the Jetson, `ping -I eth0`
  # can still select the Tailscale address in some sessions, causing a false
  # offline decision even though the Go2 peer is reachable on 192.168.123.x.
  ping -I "$GO2_LOCAL_IP" -c 1 -W 1 "$GO2_IP" >/dev/null 2>&1
}

publisher_pid=""

stop_publisher() {
  if [[ -n "${publisher_pid:-}" ]] && kill -0 "$publisher_pid" >/dev/null 2>&1; then
    kill "$publisher_pid" >/dev/null 2>&1 || true
    wait "$publisher_pid" >/dev/null 2>&1 || true
  fi
  publisher_pid=""
}

start_publisher() {
  if [[ ! -r "$ENV_FILE" ]]; then
    log "ERROR missing_env_file path=$ENV_FILE"
    return 1
  fi

  # shellcheck disable=SC1090
  source "$ENV_FILE" >/dev/null 2>&1
  ros2 topic pub \
    --rate "$OFF_RATE_HZ" \
    --qos-reliability best_effort \
    --qos-durability volatile \
    /utlidar/switch std_msgs/msg/String "{data: 'OFF'}" \
    >/dev/null 2>&1 &
  publisher_pid="$!"
  log "OFF_PUBLISHER_STARTED pid=$publisher_pid rate_hz=$OFF_RATE_HZ topic=/utlidar/switch iface=$GO2_IFACE local_ip=$GO2_LOCAL_IP go2_ip=$GO2_IP"
}

cleanup() {
  stop_publisher
  log "STOPPED"
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

log "STARTED waiting_for_go2 iface=$GO2_IFACE local_ip=$GO2_LOCAL_IP go2_ip=$GO2_IP rate_hz=$OFF_RATE_HZ"

while true; do
  if go2_online; then
    if [[ -z "${publisher_pid:-}" ]] || ! kill -0 "$publisher_pid" >/dev/null 2>&1; then
      start_publisher || true
    fi
  else
    if [[ -n "${publisher_pid:-}" ]]; then
      log "GO2_OFFLINE stopping_publisher"
      stop_publisher
    fi
  fi
  sleep "$POLL_SECONDS"
done
