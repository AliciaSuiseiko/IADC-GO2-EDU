#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN="$ROOT/runs/sequencer_$STAMP"
ACTIVE="$ROOT/status/sequencer.pid"

mkdir -p "$RUN" "$ROOT/status"

if [[ -f "$ACTIVE" ]] && kill -0 "$(cat "$ACTIVE")" 2>/dev/null; then
  printf 'Sequencer already active: pid=%s\n' "$(cat "$ACTIVE")" >&2
  exit 1
fi

cat > "$RUN/manifest.txt" <<EOF
script=$ROOT/scripts/run_tracking_smokes_sequentially.sh
start_time=$(date -Is)
host=$(hostname)
EOF

nohup "$ROOT/scripts/run_tracking_smokes_sequentially.sh" \
  > "$RUN/launcher.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$RUN/pid"
printf '%s\n' "$pid" > "$ACTIVE"

kill -0 "$pid"
ps -p "$pid" -o pid,etime,stat,cmd
printf 'RUN_DIR=%s\n' "$RUN"
