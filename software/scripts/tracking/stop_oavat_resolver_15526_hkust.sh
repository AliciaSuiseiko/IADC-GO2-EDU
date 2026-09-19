#!/usr/bin/env bash
set -euo pipefail

JOB_ID=15526
TARGET_PID=1230295
EXPECTED='runs/oavat_20260831/requirements.runtime.txt'

srun --jobid="$JOB_ID" --overlap -N1 -n1 bash -s <<'REMOTE'
set -euo pipefail
pid=1230295
expected='runs/oavat_20260831/requirements.runtime.txt'
if [[ ! -r "/proc/$pid/cmdline" ]]; then
  printf 'OA_RESOLVER_ALREADY_GONE\n'
  exit 0
fi
cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
printf 'cmd=%s\n' "$cmd"
if [[ "$cmd" != *"$expected"* ]]; then
  printf 'PID_MISMATCH_REFUSED\n' >&2
  exit 2
fi
kill -TERM "$pid"
for _ in {1..15}; do
  kill -0 "$pid" 2>/dev/null || {
    printf 'OA_RESOLVER_STOPPED\n'
    exit 0
  }
  sleep 1
done
kill -KILL "$pid"
printf 'OA_RESOLVER_KILLED_AFTER_TIMEOUT\n'
REMOTE
