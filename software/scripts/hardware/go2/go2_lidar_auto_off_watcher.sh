#!/usr/bin/env bash
set -uo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
GO2_IP="${GO2_IP:-192.168.123.161}"
GO2_IFACE="${GO2_IFACE:-eth0}"
POLL_SECONDS="${GO2_POLL_SECONDS:-2}"
OFFLINE_POLLS="${GO2_OFFLINE_POLLS:-5}"
READY_TIMEOUT_SECONDS="${GO2_READY_TIMEOUT_SECONDS:-15}"
ONLINE_SETTLE_SECONDS="${GO2_ONLINE_SETTLE_SECONDS:-75}"
SKIP_INITIAL_ONLINE="${GO2_SKIP_INITIAL_ONLINE:-0}"
ENV_FILE="$ROOT/scripts/hardware/go2/unitree_go2_env.sh"
OBSTACLES_TOOL="$ROOT/src/unitree_go2_ws/install/go2_tools/bin/go2_obstacles_avoid"
LOCK_FILE="$ROOT/logs/hardware/go2-lidar-auto-off.lock"

mkdir -p "$ROOT/logs/hardware"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*"
}

go2_online() {
  ping -I "$GO2_IFACE" -c 1 -W 1 "$GO2_IP" >/dev/null 2>&1
}

monotonic_seconds() {
  cut -d. -f1 /proc/uptime
}

publish_off_once() {
  # Unitree's public interface is rt/utlidar/switch with String data OFF.
  # The ROS 2 Unitree message workspace maps it to /utlidar/switch.
  # shellcheck disable=SC1090
  source "$ENV_FILE" >/dev/null 2>&1
  timeout "$READY_TIMEOUT_SECONDS" ros2 topic pub --once \
    --qos-reliability best_effort \
    --qos-durability volatile \
    /utlidar/switch std_msgs/msg/String "{data: 'OFF'}" >/dev/null 2>&1
}

disable_obstacles_once() {
  local output
  # shellcheck disable=SC1090
  source "$ENV_FILE" >/dev/null 2>&1
  output="$(timeout 12 "$OBSTACLES_TOOL" "$GO2_IFACE" off 2>&1)" || {
    log "OBSTACLES_AVOID_RETRY $output"
    return 1
  }
  log "OBSTACLES_AVOID_OFF $output"
}

if [[ ! -r "$ENV_FILE" ]]; then
  log "FAILED prerequisites_missing"
  exit 1
fi

armed=1
online_since=0
if [[ "$SKIP_INITIAL_ONLINE" == "1" ]] && go2_online; then
  armed=0
  log "STARTED initial_online_skipped"
else
  log "STARTED armed"
fi

offline_count=0
obstacles_disabled=0
obstacles_retry_at=0
while true; do
  if go2_online; then
    offline_count=0
    if ((online_since == 0)); then
      online_since="$(monotonic_seconds)"
      log "GO2_ONLINE settling_for_${ONLINE_SETTLE_SECONDS}s"
    fi
    if ((armed)); then
      now="$(monotonic_seconds)"
      if ((now - online_since >= ONLINE_SETTLE_SECONDS)); then
        log "GO2_STABLE waiting_for_dds_subscriber"
        if publish_off_once; then
          log "OFF_PUBLISHED once_after_settle"
          armed=0
        else
          log "DDS_NOT_READY retrying_while_online"
        fi
      fi
    fi
    now="$(monotonic_seconds)"
    if ((!obstacles_disabled)) && ((now >= obstacles_retry_at)); then
      if disable_obstacles_once; then
        obstacles_disabled=1
      else
        obstacles_retry_at=$((now + 30))
      fi
    fi
  else
    online_since=0
    ((offline_count += 1))
    if ((offline_count >= OFFLINE_POLLS)) && ((!armed)); then
      armed=1
      obstacles_disabled=0
      obstacles_retry_at=0
      log "GO2_OFFLINE rearmed"
    fi
  fi
  sleep "$POLL_SECONDS"
done
