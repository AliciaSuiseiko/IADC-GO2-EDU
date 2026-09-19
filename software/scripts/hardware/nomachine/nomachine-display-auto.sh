#!/usr/bin/env bash

set -euo pipefail

nxserver=/usr/NX/bin/nxserver
server_config=/usr/NX/etc/server.cfg
wait_seconds="${NOMACHINE_DISPLAY_WAIT_SECONDS:-30}"
log_file=/home/orin/lianaiwei/logs/hardware/nomachine-display-auto.log

mkdir -p "$(dirname "$log_file")"

log() {
  local message
  message="$(date '+%F %T') $*"
  printf '%s\n' "$message" | tee -a "$log_file"
  logger -t nomachine-display-auto -- "$*"
}

query_outputs() {
  local authority
  for authority in \
    /run/user/1000/gdm/Xauthority \
    /run/user/128/gdm/Xauthority; do
    if [[ -r "$authority" ]]; then
      DISPLAY=:0 XAUTHORITY="$authority" xrandr --query 2>/dev/null && return 0
    fi
  done
  return 1
}

set_server_key() {
  local key="$1" value="$2"
  if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$server_config"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|" "$server_config"
  else
    printf '\n%s %s\n' "$key" "$value" >>"$server_config"
  fi
}

if [[ ! -x "$nxserver" ]]; then
  log "FAILED nxserver_missing"
  exit 1
fi

if [[ ! -w "$server_config" ]]; then
  log "FAILED nomachine_server_config_not_writable"
  exit 1
fi

# Make the free-edition embedded display deterministic instead of relying on
# a client-side prompt after every headless reboot. If a physical X server is
# available, NoMachine still attaches to that shared desktop.
set_server_key CreateDisplay 1
set_server_key DisplayOwner '"orin"'
set_server_key DisplayGeometry 1920x1080

outputs=""
for ((elapsed = 0; elapsed < wait_seconds; elapsed += 2)); do
  outputs="$(query_outputs || true)"
  if awk '$2 == "connected" { found = 1 } END { exit !found }' <<<"$outputs"; then
    connected="$(awk '$2 == "connected" { printf "%s%s", sep, $1; sep="," }' <<<"$outputs")"
    log "PHYSICAL_DISPLAY connected=$connected mode=shared"
    "$nxserver" --restart
    exit 0
  fi
  sleep 2
done

log "NO_PHYSICAL_DISPLAY mode=headless"
systemctl stop display-manager
"$nxserver" --restart
log "HEADLESS_READY"
