#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src"
LOG="$ROOT/logs/repo_setup_20260831"

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

clone_once OmniTrack https://github.com/xifen523/OmniTrack.git \
  > "$LOG/omnitrack.log" 2>&1
clone_once OA-VAT https://github.com/SHWplus/OA-VAT.git \
  > "$LOG/oavat.log" 2>&1
clone_once DAP https://github.com/Insta360-Research-Team/DAP.git \
  > "$LOG/dap.log" 2>&1
clone_once LH-VLN https://github.com/HCPLab-SYSU/LH-VLN.git \
  > "$LOG/lhvln.log" 2>&1
clone_once sam3 https://github.com/facebookresearch/sam3.git \
  > "$LOG/sam3.log" 2>&1

for repo in OmniTrack OA-VAT DAP LH-VLN sam3; do
  printf '%s\t%s\t%s\n' \
    "$repo" \
    "$(git -C "$SRC/$repo" rev-parse HEAD)" \
    "$(git -C "$SRC/$repo" remote get-url origin)"
done > "$ROOT/source_manifest.tsv"

printf 'READY %s\n' "$ROOT"
