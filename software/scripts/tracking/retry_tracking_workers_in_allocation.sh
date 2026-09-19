#!/usr/bin/env bash
set -uo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
RETRY_SCRIPTS="$ROOT/scripts/retry_15525"
SCRIPTS="$ROOT/scripts"
RUN="$ROOT/runs/tracking_retry_${SLURM_JOB_ID}_$(date +%Y%m%d-%H%M%S)"
STATUS="$ROOT/status/tracking_retry.status"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 2 ;;
esac

mkdir -p "$RUN" "$ROOT/status"
printf 'RUNNING job=%s host=%s run=%s time=%s\n' \
  "$SLURM_JOB_ID" "$(hostname)" "$RUN" "$(date -Is)" > "$STATUS"

worker_omnitrack() {
  bash "$RETRY_SCRIPTS/setup_and_smoke_omnitrack.sbatch"
  bash "$SCRIPTS/run_omnitrack_model_pipeline.sbatch"
}

worker_lhvln() {
  bash "$RETRY_SCRIPTS/setup_and_smoke_lhvln.sbatch"
  bash "$SCRIPTS/run_lhvln_habitat_pipeline.sbatch"
}

worker_sam3_farm() {
  bash "$RETRY_SCRIPTS/setup_and_smoke_sam3.sbatch"
  bash "$SCRIPTS/setup_and_smoke_farm.sbatch"
}

names=(omnitrack lhvln sam3_farm)
functions=(worker_omnitrack worker_lhvln worker_sam3_farm)
gpus=(1 2 3)
pids=()

for index in 0 1 2; do
  name="${names[$index]}"
  function_name="${functions[$index]}"
  gpu="${gpus[$index]}"
  (
    set -e
    export CUDA_DEVICE_ORDER=PCI_BUS_ID
    export CUDA_VISIBLE_DEVICES="$gpu"
    export PYTHONNOUSERSITE=1
    export SLURM_CPUS_PER_TASK=8
    "$function_name"
  ) > "$RUN/$name.log" 2>&1 &
  pids+=("$!")
done

failed=0
for index in 0 1 2; do
  name="${names[$index]}"
  if wait "${pids[$index]}"; then
    printf '%s\tCOMPLETE\tlog=%s\n' "$name" "$RUN/$name.log" \
      | tee -a "$RUN/results.tsv"
  else
    rc=$?
    printf '%s\tFAILED\trc=%s\tlog=%s\n' \
      "$name" "$rc" "$RUN/$name.log" | tee -a "$RUN/results.tsv"
    failed=1
  fi
done

if (( failed == 0 )); then
  printf 'COMPLETE job=%s run=%s time=%s\n' \
    "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
else
  printf 'PARTIAL job=%s run=%s time=%s\n' \
    "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
fi

exit "$failed"
