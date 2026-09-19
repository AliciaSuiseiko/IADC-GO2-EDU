#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SBATCH="$ROOT/scripts/setup_and_run_tracking_parallel.sbatch"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 2 ;;
esac

if squeue -u aiwei -h | grep -q .; then
  printf 'Refusing submission: aiwei queue is not empty\n' >&2
  squeue -u aiwei -o '%.18i %.24j %.2t %.10M %R' >&2
  exit 3
fi

job_id="$(sbatch --parsable "$SBATCH")"
printf '%s\n' "$job_id" > "$ROOT/status/tracking_parallel.job_id"
printf 'SUBMITTED job=%s time=%s\n' "$job_id" "$(date -Is)"
