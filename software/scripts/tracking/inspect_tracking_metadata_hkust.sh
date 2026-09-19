#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src"
AUDIT="$ROOT/audits/20260831_171916"
OUT="$AUDIT/metadata.log"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 1 ;;
esac

mkdir -p "$AUDIT"
exec > >(tee "$OUT") 2>&1

emit_file() {
  local repo="$1"
  local relative="$2"
  local lines="${3:-260}"
  local path="$SRC/$repo/$relative"

  [[ -f "$path" ]] || return 0
  printf '\n===== %s/%s =====\n' "$repo" "$relative"
  sed -n "1,${lines}p" "$path"
}

printf '===== source_manifest.tsv =====\n'
cat "$ROOT/source_manifest.tsv"

for repo in OmniTrack OA-VAT DAP LH-VLN sam3; do
  printf '\n===== TREE %s =====\n' "$repo"
  find "$SRC/$repo" -maxdepth 2 -type f -printf '%P\n' | sort | sed -n '1,260p'
done

emit_file OmniTrack LICENSE 120
emit_file OmniTrack README.md 420
emit_file OmniTrack requirements.txt 260

emit_file OA-VAT README.md 500
emit_file OA-VAT environment.yml 300
emit_file OA-VAT requirements.txt 300
emit_file OA-VAT ORTrack/LICENSE 120
emit_file OA-VAT Pose2ID/LICENSE 120

emit_file DAP LICENSE 160
emit_file DAP README.md 500
emit_file DAP requirements.txt 300

emit_file LH-VLN README.md 520
emit_file LH-VLN requirements.txt 300

emit_file sam3 LICENSE 180
emit_file sam3 README.md 520
emit_file sam3 pyproject.toml 360

printf '\nMETADATA_READY\t%s\n' "$OUT"
