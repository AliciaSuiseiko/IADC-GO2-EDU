#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
LOG="$ROOT/logs/sequencer_20260831.log"
STATE="$ROOT/status/sequencer.status"
mkdir -p "$ROOT/logs" "$ROOT/status"

exec >> "$LOG" 2>&1
printf 'RUNNING pid=%s time=%s\n' "$$" "$(date -Is)" | tee "$STATE"

wait_for_empty_queue() {
  while [[ -n "$(squeue -h -u aiwei -o '%i')" ]]; do
    sleep 30
  done
}

run_one() {
  local script="$1"
  local name="$2"
  wait_for_empty_queue
  local job_id
  job_id="$(sbatch --parsable "$ROOT/scripts/$script")"
  printf 'SUBMITTED name=%s job=%s time=%s\n' "$name" "$job_id" "$(date -Is)"
  while squeue -h -j "$job_id" | grep -q .; do
    sleep 30
  done
  sacct -j "$job_id" --format=JobID,JobName,State,Elapsed,ExitCode -n -P || true
}

wait_for_empty_queue
run_one setup_and_smoke_oavat.sbatch oavat
run_one setup_and_smoke_omnitrack.sbatch omnitrack
run_one setup_and_smoke_lhvln.sbatch lhvln
run_one setup_and_smoke_sam3.sbatch sam3

printf 'COMPLETE pid=%s time=%s\n' "$$" "$(date -Is)" | tee "$STATE"
