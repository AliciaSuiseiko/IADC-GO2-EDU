#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src"
AUDIT="$ROOT/audits/20260831_171916"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 1 ;;
esac

mkdir -p "$AUDIT"
exec > >(tee "$AUDIT/probe.log") 2>&1

printf 'timestamp\t%s\n' "$(date --iso-8601=seconds)"
printf 'host\t%s\n' "$(hostname)"
printf 'arch\t%s\n' "$(uname -m)"
printf 'root\t%s\n' "$ROOT"
df -h "$ROOT"

printf '\n[queue]\n'
squeue -u aiwei -h -o '%i\t%j\t%t\t%R'

printf '\n[matching-processes]\n'
pgrep -af 'tracking_deployment|OmniTrack|OA-VAT|Insta360-Research-Team/DAP|LH-VLN|facebookresearch/sam3' || true

printf '\n[repositories]\n'
for repo in OmniTrack OA-VAT DAP LH-VLN sam3; do
  path="$SRC/$repo"
  printf '\n-- %s --\n' "$repo"
  if [[ ! -d "$path/.git" ]]; then
    printf 'state\tmissing-or-incomplete\n'
    continue
  fi
  printf 'state\tgit\n'
  printf 'commit\t%s\n' "$(git -C "$path" rev-parse HEAD)"
  printf 'origin\t%s\n' "$(git -C "$path" remote get-url origin)"
  printf 'branch\t%s\n' "$(git -C "$path" branch --show-current)"
  printf 'dirty\t%s\n' "$(git -C "$path" status --porcelain | wc -l)"
  find "$path" -maxdepth 2 -type f \
    \( -iname 'license*' -o -iname 'requirements*.txt' -o -iname 'environment*.yml' \
       -o -iname 'environment*.yaml' -o -iname 'pyproject.toml' -o -iname 'setup.py' \
       -o -iname 'readme*' \) \
    -printf '%P\n' | sort
done

printf '\n[environments]\n'
find "$ROOT" -maxdepth 3 -type d \
  \( -name 'bin' -o -name 'conda-meta' -o -name '.venv' -o -name 'venv' \) \
  -printf '%p\n' | sort

printf '\n[artifact-inventory]\n'
find "$ROOT" -maxdepth 3 -type f \
  \( -name '*.pt' -o -name '*.pth' -o -name '*.ckpt' -o -name '*.safetensors' \
     -o -name '*.onnx' -o -name '*.tar' -o -name '*.zip' \) \
  -printf '%p\t%s bytes\n' | sort

printf '\nAUDIT_READY\t%s\n' "$AUDIT"
