#!/usr/bin/env bash
set -euo pipefail

SRC=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/src/OA-VAT

for relative in \
  gym-unrealcv/load_env.py \
  gym-unrealcv/gym_unrealcv/envs/utils/env_unreal.py \
  gym-unrealcv/gym_unrealcv/envs/setting/tracking/1v1/UrbanCity.json \
  gym-unrealcv/gym_unrealcv/envs/setting/tracking/general/UrbanCity.json \
  gym-unrealcv/gym_unrealcv/__init__.py; do
  printf '\n===== %s =====\n' "$relative"
  if [[ -f "$SRC/$relative" ]]; then
    sed -n '1,420p' "$SRC/$relative"
  else
    printf 'missing\n'
  fi
done

printf '\n===== available settings =====\n'
find "$SRC/gym-unrealcv/gym_unrealcv/envs" -type f -name '*.json' -printf '%P\n' | sort | sed -n '1,240p'

printf '\n===== registrations =====\n'
grep -RnsE 'UrbanCity|Garden|UnrealTrack|register\(' "$SRC/gym-unrealcv/gym_unrealcv" \
  --include='*.py' | sed -n '1,320p'
