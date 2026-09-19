#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
TOOLS="$HOME/lianaiwei/tracking_envs/panorama_sot_tools_site"
MODEL_DIR="$ROOT/models/odtrack"
LOG_DIR="$ROOT/logs/odtrack_model_download_20260909"
MODEL_FOLDER_URL=https://drive.google.com/drive/folders/17LacrfRO01R75bxU4bgA87eo1b_rX5Gj

mkdir -p "$MODEL_DIR" "$LOG_DIR" "$TOOLS"
if [[ ! -d "$TOOLS/gdown" ]]; then
  python3 -m pip install \
    --disable-pip-version-check \
    --quiet \
    --target "$TOOLS" \
    gdown
fi

PYTHONPATH="$TOOLS${PYTHONPATH:+:$PYTHONPATH}" python3 -m gdown \
  --folder "$MODEL_FOLDER_URL" \
  --output "$MODEL_DIR" \
  2>&1 | tee "$LOG_DIR/download.log"

find "$MODEL_DIR" -type f -printf '%P\t%s\n' | sort > "$LOG_DIR/files.tsv"
printf 'READY %s\n' "$MODEL_DIR"
