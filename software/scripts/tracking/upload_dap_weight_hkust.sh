#!/usr/bin/env bash
set -euo pipefail

SOURCE="${IADC_DAP_MODEL:-$HOME/.cache/tracking_deployment/dap/model.pth}"
HOST=robot@login.example
REMOTE_DIR=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/models/dap
REMOTE_FILE="$REMOTE_DIR/model.pth"
EXPECTED_SIZE=1460746347
SSH_OPTIONS=(-o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=120 -o TCPKeepAlive=yes -o ConnectTimeout=30)

[[ -f "$SOURCE" ]] || { printf 'missing source: %s\n' "$SOURCE" >&2; exit 2; }
[[ "$(stat -f '%z' "$SOURCE")" == "$EXPECTED_SIZE" ]] || {
  printf 'source size mismatch\n' >&2
  exit 2
}

ssh "${SSH_OPTIONS[@]}" "$HOST" "mkdir -p '$REMOTE_DIR'"

RSYNC_OPTIONS=(--archive --partial --append --progress --timeout=60)
if rsync --help 2>&1 | grep -q -- '--append-verify'; then
  RSYNC_OPTIONS=(--archive --partial --append-verify --progress --timeout=60)
fi

rsync "${RSYNC_OPTIONS[@]}" \
  -e "ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=120 -o TCPKeepAlive=yes -o ConnectTimeout=30" \
  "$SOURCE" "$HOST:$REMOTE_DIR/"

LOCAL_SIZE=$(stat -f '%z' "$SOURCE")
REMOTE_SIZE=$(ssh "${SSH_OPTIONS[@]}" "$HOST" "stat -c '%s' '$REMOTE_FILE'")
[[ "$LOCAL_SIZE" == "$REMOTE_SIZE" ]] || { printf 'remote size mismatch\n' >&2; exit 1; }

LOCAL_HASH=$(shasum -a 256 "$SOURCE" | awk '{print $1}')
REMOTE_HASH=$(ssh "${SSH_OPTIONS[@]}" "$HOST" "sha256sum '$REMOTE_FILE' | awk '{print \$1}'")
printf 'local_sha256=%s\nremote_sha256=%s\n' "$LOCAL_HASH" "$REMOTE_HASH"
[[ "$LOCAL_HASH" == "$REMOTE_HASH" ]] || { printf 'remote hash mismatch\n' >&2; exit 1; }
printf 'verification=OK bytes=%s\n' "$LOCAL_SIZE"
