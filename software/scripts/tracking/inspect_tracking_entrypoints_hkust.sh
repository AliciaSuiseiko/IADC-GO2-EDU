#!/usr/bin/env bash
set -euo pipefail

SRC=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/src

case "$SRC" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds source root: %s\n' "$SRC" >&2; exit 1 ;;
esac

for relative in \
  DAP/requirements.txt DAP/test/infer.py DAP/depth_anything_utils.py \
  LH-VLN/requirements.txt LH-VLN/NavModel/RandomNav.py \
  OA-VAT/ORTrack/requirements.txt OA-VAT/dinov3_feature_extractor.py; do
  printf '\n===== %s =====\n' "$relative"
  sed -n '1,420p' "$SRC/$relative"
done
