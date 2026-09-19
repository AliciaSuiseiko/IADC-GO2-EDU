#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
JOB_ID=15526
SCRIPTS="$ROOT/scripts/retry_15526"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 2 ;;
esac
squeue -h -j "$JOB_ID" -o '%T' | grep -qx RUNNING

launch() {
  local name=$1 gpu=$2 command=$3
  local log="$ROOT/runs/${name}_retry_15526.log"
  local pid_file="$ROOT/status/${name}_retry_15526.launcher.pid"
  if [[ -s "$pid_file" ]]; then
    local old_pid
    old_pid=$(cat "$pid_file")
    if kill -0 "$old_pid" 2>/dev/null; then
      printf '%s retry already active: pid=%s log=%s\n' "$name" "$old_pid" "$log"
      return 0
    fi
  fi
  nohup srun --jobid="$JOB_ID" --overlap -N1 -n1 --cpus-per-task=8 \
    bash -lc "export CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$gpu PYTHONNOUSERSITE=1 PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple; $command" \
    >"$log" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" > "$pid_file"
  sleep 2
  kill -0 "$pid"
  printf '%s retry started: gpu=%s pid=%s log=%s\n' "$name" "$gpu" "$pid" "$log"
}

launch omnitrack 1 "bash '$SCRIPTS/setup_and_smoke_omnitrack.sbatch' && bash '$ROOT/scripts/run_omnitrack_model_pipeline.sbatch'"
if grep -q '^COMPLETE ' "$ROOT/status/lhvln.status" 2>/dev/null && \
   grep -q '^COMPLETE ' "$ROOT/status/lhvln_habitat.status" 2>/dev/null; then
  printf 'lhvln retry skipped: environment and pipeline already complete\n'
else
  launch lhvln 2 "bash '$SCRIPTS/setup_and_smoke_lhvln.sbatch' && bash '$ROOT/scripts/run_lhvln_habitat_pipeline.sbatch'"
fi
launch sam3 3 "bash '$SCRIPTS/setup_and_smoke_sam3.sbatch' && bash '$ROOT/scripts/setup_and_smoke_farm.sbatch'"
