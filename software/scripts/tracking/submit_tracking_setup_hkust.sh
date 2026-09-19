#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SBATCH_FILE="$HOME/lianaiwei/scripts/tracking/setup_tracking_envs.sbatch"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 1 ;;
esac

queue="$(squeue -u aiwei -h -o '%i\t%j\t%t\t%R')"
if [[ -n "$queue" ]]; then
  printf 'Refusing submission: aiwei already has an active Slurm job.\n%s\n' "$queue" >&2
  exit 3
fi

[[ -f "$SBATCH_FILE" ]] || { printf 'Missing sbatch file: %s\n' "$SBATCH_FILE" >&2; exit 2; }
bash -n "$SBATCH_FILE"
mkdir -p "$ROOT/logs"
job_id="$(sbatch --parsable "$SBATCH_FILE")"
printf '%s\n' "$job_id" > "$ROOT/current_job_id"
printf 'SUBMITTED\tjob=%s\t%s\n' "$job_id" "$(date -Is)"
squeue -j "$job_id" -h -o '%i\t%j\t%t\t%R'
