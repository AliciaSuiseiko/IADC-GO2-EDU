#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
RUN="$ROOT/runs/x5_erp_live_20260901"
JOB="$ROOT/scripts/capture_x5_erp_once_jetson.sh"

mkdir -p "$RUN/logs"
nohup "$JOB" > "$RUN/logs/job.log" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$RUN/pid"
sleep 1
kill -0 "$pid"
ps -p "$pid" -o pid,etime,stat,cmd
