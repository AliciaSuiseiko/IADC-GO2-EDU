#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SCRIPT="$ROOT/scripts/run_tracking_full_pipelines_sequentially.sh"
ACTIVE="$ROOT/status/full_pipeline_sequencer.pid"
RUN="$ROOT/runs/full_pipeline_sequencer_$(date +%Y%m%d-%H%M%S)"

mkdir -p "$RUN" "$ROOT/status"
if [[ -f "$ACTIVE" ]] && kill -0 "$(cat "$ACTIVE")" 2>/dev/null; then
  printf 'Full pipeline sequencer already active: pid=%s\n' "$(cat "$ACTIVE")" >&2
  exit 1
fi

nohup "$SCRIPT" > "$RUN/launcher.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$ACTIVE"
printf '%s\n' "$pid" > "$RUN/pid"
kill -0 "$pid"
ps -p "$pid" -o pid,etime,stat,cmd
printf 'RUN_DIR=%s\n' "$RUN"
