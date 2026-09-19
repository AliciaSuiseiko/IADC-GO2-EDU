#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
FULL_PID_FILE="$ROOT/status/full_pipeline_sequencer.pid"

if [[ -f "$FULL_PID_FILE" ]]; then
  pid="$(cat "$FULL_PID_FILE")"
  if kill -0 "$pid" 2>/dev/null; then
    command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    case "$command_line" in
      *"$ROOT/scripts/run_tracking_full_pipelines_sequentially.sh"*)
        kill "$pid"
        for _ in 1 2 3 4 5; do
          kill -0 "$pid" 2>/dev/null || break
          sleep 1
        done
        ;;
      *)
        printf 'Refusing unexpected PID %s: %s\n' "$pid" "$command_line" >&2
        exit 2
        ;;
    esac
  fi
fi

exec "$ROOT/scripts/launch_tracking_master_hkust.sh"
