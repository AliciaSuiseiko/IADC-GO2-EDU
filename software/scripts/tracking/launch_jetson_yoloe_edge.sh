#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
RUN="$ROOT/runs/yoloe_edge_20260901_retry1"
JOB="$ROOT/scripts/jetson_yoloe_edge_job.sh"

mkdir -p "$RUN/logs"
if [[ -f "$RUN/pid" ]] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null; then
    printf 'already running pid=%s\n' "$(cat "$RUN/pid")"
    exit 0
fi

nohup "$JOB" > "$RUN/logs/job.log" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$RUN/pid"
sleep 1
kill -0 "$pid"
ps -p "$pid" -o pid,etime,stat,cmd
df -h /home/orin/lianaiwei
