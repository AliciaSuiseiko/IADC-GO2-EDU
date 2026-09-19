#!/usr/bin/env bash
set -euo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
ENV_FILE="$ROOT/scripts/hardware/go2/unitree_go2_env.sh"
ACTION="${1:-}"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "Go2 environment not found: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE" >/dev/null 2>&1

publish_request() {
  local api_id="$1"
  local parameter="${2:-}"
  local message

  if [[ -n "$parameter" ]]; then
    message="{header: {identity: {api_id: $api_id}}, parameter: '$parameter'}"
  else
    message="{header: {identity: {api_id: $api_id}}}"
  fi

  timeout 15 ros2 topic pub --once \
    /api/sport/request unitree_api/msg/Request "$message" >/dev/null
}

stop_move() {
  publish_request 1003 || true
}

case "$ACTION" in
  stand-up)
    publish_request 1004
    echo "StandUp published"
    ;;
  stop)
    stop_move
    echo "StopMove published"
    ;;
  forward-small)
    trap stop_move EXIT HUP INT TERM
    # Match Unitree's official Move JSON fields: x=vx, y=vy, z=vyaw.
    publish_request 1008 '{"x":0.10,"y":0.0,"z":0.0}'
    sleep 1
    stop_move
    trap - EXIT HUP INT TERM
    echo "Move 0.10 m/s for 1.0 s completed; StopMove published"
    ;;
  *)
    echo "Usage: $0 {stand-up|forward-small|stop}" >&2
    exit 2
    ;;
esac
