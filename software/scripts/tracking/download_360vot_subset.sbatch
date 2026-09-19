#!/usr/bin/env bash
#SBATCH --job-name=dl-360vot
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:20:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/download-360vot-%j.out

set -euo pipefail
ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
DEST="$ROOT/datasets/360VOT-subset"
mkdir -p "$DEST" "$ROOT/logs"

for sequence in 010 064; do
  archive="$DEST/${sequence}.zip"
  curl --fail --location --retry 5 --continue-at - \
    "https://hf-mirror.com/datasets/xuyzshaun/360VOTS/resolve/main/360VOT-test/${sequence}.zip?download=true" \
    --output "$archive"
  unzip -oq "$archive" -d "$DEST/$sequence"
  sha256sum "$archive" > "$archive.sha256"
done

find "$DEST" -maxdepth 3 -type f | sort
