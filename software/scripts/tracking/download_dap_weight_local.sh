#!/usr/bin/env bash
set -euo pipefail

ROOT="${IADC_DAP_CACHE:-$HOME/.cache/tracking_deployment/dap}"
FILE="$ROOT/model.pth"
LOG="$ROOT/download.log"
URL='https://huggingface.co/Insta360-Research/DAP-weights/resolve/main/model.pth?download=true'
EXPECTED_SIZE=1460746347

mkdir -p "$ROOT"

curl --location --fail --retry 20 --retry-all-errors \
  --connect-timeout 30 --speed-time 120 --speed-limit 1024 \
  --continue-at - --output "$FILE" "$URL" \
  > "$LOG" 2>&1

actual_size="$(stat -f '%z' "$FILE")"
if [[ "$actual_size" != "$EXPECTED_SIZE" ]]; then
  printf 'Unexpected size: expected=%s actual=%s\n' \
    "$EXPECTED_SIZE" "$actual_size" >> "$LOG"
  exit 1
fi

shasum -a 256 "$FILE" > "$ROOT/model.pth.sha256"
printf 'COMPLETE size=%s time=%s\n' "$actual_size" "$(date -Is)" >> "$LOG"
