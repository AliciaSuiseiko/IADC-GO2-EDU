#!/usr/bin/env bash
set -euo pipefail

RUN_ROOT="${IADC_PROXY_ROOT:-$HOME/.cache/iadc_tracking_proxy}"
PID_FILE="$RUN_ROOT/pid"
LOG="$RUN_ROOT/tunnel.log"

mkdir -p "$RUN_ROOT"
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE")"
  if kill -0 "$pid" 2>/dev/null; then
    command_line="$(ps -p "$pid" -o command=)"
    case "$command_line" in
      *"127.0.0.1:17890:127.0.0.1:7890"*)
        printf 'ALREADY_RUNNING pid=%s\n' "$pid"
        exit 0
        ;;
      *)
        printf 'Refusing unexpected live PID %s: %s\n' "$pid" "$command_line" >&2
        exit 3
        ;;
    esac
  fi
fi

nohup ssh -N \
  -o BatchMode=yes \
  -o ConnectTimeout=12 \
  -o ControlMaster=no \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=5 \
  -R 127.0.0.1:17890:127.0.0.1:7890 \
  robot@login.example > "$LOG" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$PID_FILE"
sleep 2
kill -0 "$pid"
printf 'RUNNING pid=%s remote_proxy=http://127.0.0.1:17890\n' "$pid"
