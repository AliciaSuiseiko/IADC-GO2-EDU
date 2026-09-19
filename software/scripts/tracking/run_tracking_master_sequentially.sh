#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
LOG="$ROOT/logs/master_sequencer_20260831.log"
STATE="$ROOT/status/master_sequencer.status"
mkdir -p "$ROOT/logs" "$ROOT/status"
exec >> "$LOG" 2>&1
printf 'RUNNING pid=%s time=%s\n' "$$" "$(date -Is)" | tee "$STATE"

wait_for_empty_queue() {
  while [[ -n "$(squeue -h -u aiwei -o '%i')" ]]; do
    sleep 30
  done
}

is_complete() {
  local status_file="$1"
  grep -q '^COMPLETE' "$status_file" 2>/dev/null
}

run_one() {
  local name="$1"
  local script="$2"
  local status_file="$3"

  wait_for_empty_queue
  if is_complete "$status_file"; then
    printf 'SKIPPED name=%s reason=complete time=%s\n' "$name" "$(date -Is)"
    return 0
  fi

  local job_id
  job_id="$(sbatch --parsable "$ROOT/scripts/$script")"
  printf 'SUBMITTED name=%s job=%s time=%s\n' "$name" "$job_id" "$(date -Is)"
  while squeue -h -j "$job_id" | grep -q .; do
    sleep 30
  done
  sacct -j "$job_id" --format=JobID,JobName,State,Elapsed,MaxRSS,ExitCode -n -P || true
}

# An already-running project is allowed to finish before this sequence starts.
wait_for_empty_queue
run_one dap setup_and_smoke_dap.sbatch "$ROOT/status/dap.status"
run_one omnitrack setup_and_smoke_omnitrack.sbatch "$ROOT/status/omnitrack.status"
run_one oavat setup_and_smoke_oavat.sbatch "$ROOT/status/oavat.status"
run_one lhvln setup_and_smoke_lhvln.sbatch "$ROOT/status/lhvln.status"
run_one sam3 setup_and_smoke_sam3.sbatch "$ROOT/status/sam3.status"
run_one omnitrack_model run_omnitrack_model_pipeline.sbatch "$ROOT/status/omnitrack_model.status"
run_one oavat_unreal run_oavat_unrealcv_pipeline.sbatch "$ROOT/status/oavat_unreal.status"
run_one lhvln_habitat run_lhvln_habitat_pipeline.sbatch "$ROOT/status/lhvln_habitat.status"

printf 'COMPLETE pid=%s time=%s\n' "$$" "$(date -Is)" | tee "$STATE"
