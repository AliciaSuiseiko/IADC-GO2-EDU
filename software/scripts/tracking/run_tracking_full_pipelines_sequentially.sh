#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
LOG="$ROOT/logs/full_pipeline_sequencer_20260831.log"
STATE="$ROOT/status/full_pipeline_sequencer.status"
mkdir -p "$ROOT/logs" "$ROOT/status"
exec >> "$LOG" 2>&1
printf 'RUNNING pid=%s time=%s\n' "$$" "$(date -Is)" | tee "$STATE"

while ! grep -q '^COMPLETE' "$ROOT/status/sequencer.status" 2>/dev/null; do
  sleep 30
done

wait_for_empty_queue() {
  while [[ -n "$(squeue -h -u aiwei -o '%i')" ]]; do
    sleep 30
  done
}

run_one() {
  local script="$1"
  local name="$2"
  wait_for_empty_queue
  job_id="$(sbatch --parsable "$ROOT/scripts/$script")"
  printf 'SUBMITTED name=%s job=%s time=%s\n' "$name" "$job_id" "$(date -Is)"
  while squeue -h -j "$job_id" | grep -q .; do
    sleep 30
  done
  sacct -j "$job_id" --format=JobID,JobName,State,Elapsed,MaxRSS,ExitCode -n -P || true
}

run_one run_omnitrack_model_pipeline.sbatch omnitrack_model
run_one run_oavat_unrealcv_pipeline.sbatch oavat_unrealcv
run_one run_lhvln_habitat_pipeline.sbatch lhvln_habitat

printf 'COMPLETE pid=%s time=%s\n' "$$" "$(date -Is)" | tee "$STATE"
