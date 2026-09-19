#!/usr/bin/env bash
#SBATCH --job-name=tracking-parallel
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:4090:4
#SBATCH --cpus-per-task=32
#SBATCH --time=10:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/tracking-parallel-%j.out

set -uo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SCRIPTS="$ROOT/scripts"
RUN="$ROOT/runs/tracking_parallel_${SLURM_JOB_ID}"
STATUS="$ROOT/status/tracking_parallel.status"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 2 ;;
esac

mkdir -p "$RUN" "$ROOT/logs" "$ROOT/status"
printf 'RUNNING job=%s host=%s time=%s\n' \
  "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
nvidia-smi --query-gpu=index,name,uuid,memory.total \
  --format=csv,noheader > "$RUN/gpus.start.csv"

worker_oavat() {
  bash "$SCRIPTS/setup_and_smoke_oavat.sbatch"
  bash "$SCRIPTS/run_oavat_unrealcv_pipeline.sbatch"
}

worker_omnitrack() {
  bash "$SCRIPTS/setup_and_smoke_omnitrack.sbatch"
  bash "$SCRIPTS/run_omnitrack_model_pipeline.sbatch"
}

worker_lhvln() {
  bash "$SCRIPTS/setup_and_smoke_lhvln.sbatch"
  bash "$SCRIPTS/run_lhvln_habitat_pipeline.sbatch"
}

worker_sam3() {
  bash "$SCRIPTS/setup_and_smoke_sam3.sbatch"
  bash "$SCRIPTS/setup_and_smoke_farm.sbatch"
}

names=(oavat omnitrack lhvln sam3)
functions=(worker_oavat worker_omnitrack worker_lhvln worker_sam3)
pids=()

for gpu in 0 1 2 3; do
  name="${names[$gpu]}"
  function_name="${functions[$gpu]}"
  (
    set -e
    export CUDA_DEVICE_ORDER=PCI_BUS_ID
    export CUDA_VISIBLE_DEVICES="$gpu"
    export PYTHONNOUSERSITE=1
    export SLURM_CPUS_PER_TASK=8
    export HF_HOME="$ROOT/cache/huggingface"
    export TORCH_HOME="$ROOT/cache/torch"
    printf 'START project=%s physical_gpu=%s time=%s\n' \
      "$name" "$gpu" "$(date -Is)"
    "$function_name"
    printf 'COMPLETE project=%s physical_gpu=%s time=%s\n' \
      "$name" "$gpu" "$(date -Is)"
  ) > "$RUN/$name.log" 2>&1 &
  pid=$!
  pids+=("$pid")
  printf '%s\tgpu=%s\tpid=%s\tlog=%s\n' \
    "$name" "$gpu" "$pid" "$RUN/$name.log" >> "$RUN/workers.tsv"
done

failed=0
for index in 0 1 2 3; do
  name="${names[$index]}"
  if wait "${pids[$index]}"; then
    printf '%s\tCOMPLETE\tlog=%s\n' \
      "$name" "$RUN/$name.log" | tee -a "$RUN/results.tsv"
  else
    rc=$?
    printf '%s\tFAILED\trc=%s\tlog=%s\n' \
      "$name" "$rc" "$RUN/$name.log" | tee -a "$RUN/results.tsv"
    failed=1
  fi
done

nvidia-smi --query-gpu=index,name,memory.used,utilization.gpu \
  --format=csv,noheader > "$RUN/gpus.end.csv"

if (( failed == 0 )); then
  printf 'COMPLETE job=%s run=%s time=%s\n' \
    "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
else
  printf 'PARTIAL job=%s run=%s time=%s\n' \
    "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
fi

exit "$failed"
