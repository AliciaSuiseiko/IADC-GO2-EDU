#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SBATCH="$ROOT/scripts/setup_and_run_tracking_parallel.sbatch"
STATUS="$ROOT/status/parallel_launcher.status"
PID_FILE="$ROOT/status/parallel_launcher.pid"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/status" "$ROOT/logs"
printf '%s\n' "$$" > "$PID_FILE"
printf 'WAITING pid=%s time=%s\n' "$$" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED pid=%s rc=%s time=%s\n" "$$" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

while squeue -u aiwei -h | grep -q .; do
  sleep 20
done

job_id="$(sbatch --parsable "$SBATCH")"
trap - ERR
printf 'SUBMITTED pid=%s job=%s time=%s\n' \
  "$$" "$job_id" "$(date -Is)" > "$STATUS"
printf '%s\n' "$job_id" > "$ROOT/status/tracking_parallel.job_id"
