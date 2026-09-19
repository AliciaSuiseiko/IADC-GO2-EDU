#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment

printf '[queue]\n'
squeue -u aiwei -h -o '%i\t%j\t%t\t%M\t%R'

printf '\n[launcher]\n'
cat "$ROOT/status/parallel_launcher.status" 2>/dev/null || true
if [[ -f "$ROOT/status/parallel_launcher.pid" ]]; then
  pid="$(cat "$ROOT/status/parallel_launcher.pid")"
  ps -p "$pid" -o pid,etime,stat,cmd || true
fi

printf '\n[parallel-job]\n'
cat "$ROOT/status/tracking_parallel.status" 2>/dev/null || true
if [[ -f "$ROOT/status/tracking_parallel.job_id" ]]; then
  job_id="$(cat "$ROOT/status/tracking_parallel.job_id")"
  sacct -j "$job_id" --format=JobID,JobName,State,Elapsed,MaxRSS,AllocTRES%80 \
    -n -P 2>/dev/null || true
fi

latest_run="$(find "$ROOT/runs" -maxdepth 1 -type d \
  -name 'tracking_parallel_*' -printf '%T@\t%p\n' 2>/dev/null \
  | sort -nr | head -1 | cut -f2-)"
if [[ -n "$latest_run" ]]; then
  printf '\n[run]\n%s\n' "$latest_run"
  cat "$latest_run/results.tsv" 2>/dev/null || true
  for name in oavat omnitrack lhvln sam3; do
    printf -- '\n-- %s --\n' "$name"
    tail -20 "$latest_run/$name.log" 2>/dev/null || true
  done
fi
