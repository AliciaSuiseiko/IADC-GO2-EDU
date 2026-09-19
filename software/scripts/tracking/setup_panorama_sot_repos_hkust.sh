#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src"
LOG="$ROOT/logs/panorama_sot_repo_setup_20260909"
MANIFEST="$ROOT/panorama_sot_source_manifest.tsv"

mkdir -p "$SRC" "$LOG"

clone_once() {
  local name="$1"
  local url="$2"
  local target="$SRC/$name"

  if [[ -d "$target/.git" ]]; then
    git -C "$target" remote get-url origin
    git -C "$target" rev-parse HEAD
    return
  fi
  if [[ -e "$target" ]]; then
    printf 'Refusing non-git path: %s\n' "$target" >&2
    return 1
  fi
  git clone --filter=blob:none "$url" "$target"
  git -C "$target" rev-parse HEAD
}

clone_once 360VOT https://github.com/HuajianUP/360VOT.git \
  > "$LOG/360vot.log" 2>&1
clone_once 360Tracking https://github.com/HuajianUP/360Tracking.git \
  > "$LOG/360tracking.log" 2>&1
clone_once ODTrack https://github.com/GXNU-ZhongLab/ODTrack.git \
  > "$LOG/odtrack.log" 2>&1

for repo in 360VOT 360Tracking ODTrack; do
  printf '%s\t%s\t%s\n' \
    "$repo" \
    "$(git -C "$SRC/$repo" rev-parse HEAD)" \
    "$(git -C "$SRC/$repo" remote get-url origin)"
done > "$MANIFEST"

printf 'READY %s\n' "$MANIFEST"
