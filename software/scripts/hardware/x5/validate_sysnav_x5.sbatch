#!/usr/bin/env bash
#SBATCH --job-name=sysnav-x5-smoke
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node2
#SBATCH --cpus-per-task=4
#SBATCH --gres=gpu:4090:1
#SBATCH --time=00:30:00
#SBATCH --output=/mnt/slurmfs-4090node1/homes/aiwei/lianaiwei/logs/sysnav-x5-smoke-%j.out

set -euo pipefail

ROOT="$HOME/lianaiwei"
STORE="/mnt/slurmfs-4090node3/user_data/$USER/lianaiwei"
ENV="$STORE/envs/sysnav-jazzy"
SRC="$ROOT/src/sysnav_ws/src/SysNav"
IMAGE="$ROOT/downloads/x5-ros-frame-20260810.jpg"
MODEL="$SRC/src/semantic_mapping/semantic_mapping/external/yoloe-26x-seg.pt"
OUTPUT="$ROOT/logs/sysnav-x5-smoke-$SLURM_JOB_ID"
STATUS="$ROOT/logs/sysnav-x5-smoke.status"

mkdir -p "$OUTPUT"
printf 'RUNNING job=%s host=%s %s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s %s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

export PYTHONNOUSERSITE=1
export TORCH_HOME="$STORE/cache/torch"
export ULTRALYTICS_CONFIG_DIR="$STORE/cache/ultralytics"
mkdir -p "$STORE/models/sysnav"
cd "$STORE/models/sysnav"
"$ENV/bin/python" "$ROOT/scripts/sysnav_x5_frame_smoke.py" \
  --image "$IMAGE" \
  --model "$MODEL" \
  --output-dir "$OUTPUT"

printf 'COMPLETE job=%s output=%s %s\n' "$SLURM_JOB_ID" "$OUTPUT" "$(date -Is)" > "$STATUS"
