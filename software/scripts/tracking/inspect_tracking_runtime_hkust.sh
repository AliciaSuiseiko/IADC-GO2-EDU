#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src"
AUDIT="$ROOT/audits/20260831_171916"
OUT="$AUDIT/runtime_metadata.log"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 1 ;;
esac

exec > >(tee "$OUT") 2>&1

emit() {
  local path="$1"
  local lines="${2:-420}"
  [[ -f "$path" ]] || return 0
  printf '\n===== %s =====\n' "${path#"$SRC/"}"
  sed -n "1,${lines}p" "$path"
}

emit "$SRC/OmniTrack/docs/quick_start.md" 500
emit "$SRC/OmniTrack/local_test.sh" 220
emit "$SRC/DAP/LICENSE" 180
emit "$SRC/DAP/README.md" 520
emit "$SRC/DAP/config/infer.yaml" 220
emit "$SRC/LH-VLN/README.md" 560
emit "$SRC/LH-VLN/configs/lh_vln.yaml" 220
emit "$SRC/OA-VAT/environment.yml" 360
emit "$SRC/OA-VAT/requirements.txt" 360
emit "$SRC/OA-VAT/eval_on_real_image.py" 260

printf '\n===== owned Python managers =====\n'
find /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei "$HOME/lianaiwei" \
  -maxdepth 5 -type f \( -name conda -o -name micromamba -o -name python \) \
  -path '*/bin/*' -printf '%p\n' 2>/dev/null | sort | sed -n '1,240p'

printf '\n===== Slurm partitions =====\n'
sinfo -h -o '%P\t%a\t%l\t%D\t%G' | sort -u

printf '\n===== login GPU/toolchain =====\n'
command -v gcc || true
command -v nvcc || true
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || true

printf '\nRUNTIME_METADATA_READY\t%s\n' "$OUT"
