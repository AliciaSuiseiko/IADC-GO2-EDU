#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
JOB_ID=15526
SCRIPTS="$ROOT/scripts/retry_15526"
LOG="$ROOT/runs/oavat_retry_15526.log"
PID_FILE="$ROOT/status/oavat_retry_15526.launcher.pid"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 2 ;;
esac

squeue -h -j "$JOB_ID" -o '%T' | grep -qx RUNNING
if [[ -s "$PID_FILE" ]]; then
  old_pid=$(cat "$PID_FILE")
  if kill -0 "$old_pid" 2>/dev/null; then
    printf 'OA retry already active: pid=%s log=%s\n' "$old_pid" "$LOG"
    exit 0
  fi
fi

nohup srun --jobid="$JOB_ID" --overlap -N1 -n1 --cpus-per-task=8 \
  bash -lc "export CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=0 PYTHONNOUSERSITE=1 PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple; bash '$SCRIPTS/setup_and_smoke_oavat.sbatch' && bash '$ROOT/scripts/run_oavat_unrealcv_pipeline.sbatch'" \
  >"$LOG" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$PID_FILE"
sleep 2
kill -0 "$pid"
printf 'OA retry started: pid=%s log=%s\n' "$pid" "$LOG"
