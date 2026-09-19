#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
LAUNCHER="$ROOT/scripts/launch_tracking_parallel_after_queue_hkust.sh"
PID_FILE="$ROOT/status/parallel_launcher.pid"
LOG="$ROOT/logs/parallel_launcher_20260831.log"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/status" "$ROOT/logs"
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE")"
  if kill -0 "$pid" 2>/dev/null; then
    command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    case "$command_line" in
      *"launch_tracking_parallel_after_queue_hkust.sh"*)
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

nohup bash "$LAUNCHER" >> "$LOG" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$PID_FILE"
sleep 1
if kill -0 "$pid" 2>/dev/null; then
  ps -p "$pid" -o pid,etime,stat,cmd
fi
cat "$ROOT/status/parallel_launcher.status"
