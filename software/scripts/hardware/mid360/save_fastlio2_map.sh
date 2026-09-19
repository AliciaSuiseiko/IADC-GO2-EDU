#!/usr/bin/env bash
set -eo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
WS="$ROOT/src/fastlio2_ws"
CURRENT_FILE="$ROOT/logs/hardware/fastlio2-map-session.current"

source /opt/ros/humble/setup.bash
source "$WS/install/setup.bash"

if [[ ! -s "$CURRENT_FILE" ]]; then
  echo "FAILED: no active FAST-LIO2 mapping session" >&2
  exit 2
fi

SESSION="$(<"$CURRENT_FILE")"
MAP_FILE="$SESSION/map.pcd"
if [[ ! -d "$SESSION" ]]; then
  echo "FAILED: mapping session directory is missing: $SESSION" >&2
  exit 2
fi

RESPONSE="$(timeout 90 ros2 service call /map_save std_srvs/srv/Trigger '{}')"
printf '%s\n' "$RESPONSE"
if ! grep -Eq 'success=(True|true)' <<<"$RESPONSE"; then
  echo "FAILED: /map_save did not report success" >&2
  exit 1
fi
if [[ ! -s "$MAP_FILE" ]]; then
  echo "FAILED: map file was not created: $MAP_FILE" >&2
  exit 1
fi

{
  printf 'saved_at=%s\n' "$(date -Is)"
  stat -c 'bytes=%s' "$MAP_FILE"
  grep -a -m1 '^POINTS ' "$MAP_FILE" || true
  sha256sum "$MAP_FILE"
} | tee "$SESSION/last_save.txt"

echo "COMPLETE: $MAP_FILE"
