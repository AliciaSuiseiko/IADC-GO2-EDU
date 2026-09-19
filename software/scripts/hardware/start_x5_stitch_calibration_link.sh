#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$HOME/lianaiwei"
LOGIN_HOST="robot@login.example"
SSH_KEY="$HOME/.ssh/id_ed25519"
SERVER_SCRIPT="lianaiwei/scripts/run_x5_stitch_calibration.sbatch"
RUN_DIR="${X5_CALIBRATION_RUN_DIR:?X5_CALIBRATION_RUN_DIR is required}"
STITCH_TYPE="${X5_STITCH_TYPE:-dynamic}"
JPEG_QUALITY="${X5_PANORAMA_JPEG_QUALITY:-80}"
RUN_TRACKER="${X5_RUN_TRACKER:-0}"

server_ssh() {
  ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=8 "$LOGIN_HOST" "$@"
}

server_uid="$(server_ssh 'id -u')"
port_base=$((30000 + (server_uid % 1000) * 10))
queue="$(server_ssh "squeue -u aiwei -h -o '%i|%j|%t|%R'")"
job_line="$(awk -F'|' '$2 == "x5-stitch-calibration" {print; exit}' <<<"$queue")"

if [[ -z "$job_line" ]]; then
  if [[ -n "$queue" ]]; then
    echo "refusing submission because another aiwei Slurm job is active" >&2
    printf '%s\n' "$queue" >&2
    exit 2
  fi
  submission="$(server_ssh "sbatch --export=ALL,X5_CALIBRATION_PORT_BASE='$port_base',X5_STITCH_TYPE='$STITCH_TYPE',X5_PANORAMA_JPEG_QUALITY='$JPEG_QUALITY',X5_RUN_TRACKER='$RUN_TRACKER' '$SERVER_SCRIPT'")"
  job_id="${submission##* }"
else
  job_id="${job_line%%|*}"
fi
printf 'job_id=%s\n' "$job_id" >"$RUN_DIR/server-job.env"

compute_host=""
for _ in $(seq 1 60); do
  state_line="$(server_ssh "squeue -j '$job_id' -h -o '%t|%N'")"
  state="${state_line%%|*}"
  compute_host="${state_line#*|}"
  [[ "$state" == R && -n "$compute_host" && "$compute_host" != '(null)' ]] && break
  sleep 2
done
[[ -n "$compute_host" && "$compute_host" != '(null)' ]]

setsid ssh -N -i "$SSH_KEY" \
  -o BatchMode=yes -o ConnectTimeout=8 -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -L "127.0.0.1:42101:$compute_host:$((port_base + 1))" \
  -L "127.0.0.1:42105:$compute_host:$((port_base + 5))" \
  "$LOGIN_HOST" >"$RUN_DIR/hkust-tunnel.log" 2>&1 &
tunnel_pid=$!
printf '%s\n' "$tunnel_pid" >"$RUN_DIR/hkust-tunnel.pid"

for _ in $(seq 1 20); do
  if ! kill -0 "$tunnel_pid" 2>/dev/null; then
    wait "$tunnel_pid" || true
    echo "X5 calibration SSH tunnel exited before becoming ready" >&2
    cat "$RUN_DIR/hkust-tunnel.log" >&2
    exit 3
  fi
  if ss -ltn | grep -q '127.0.0.1:42101' && ss -ltn | grep -q '127.0.0.1:42105'; then
    printf 'job_id=%s\ncompute_host=%s\nport_base=%s\n' \
      "$job_id" "$compute_host" "$port_base" >"$RUN_DIR/server-job.env"
    echo "X5 calibration stitch link ready: job=$job_id host=$compute_host"
    exit 0
  fi
  sleep 1
done

echo "X5 calibration tunnel did not become ready" >&2
exit 3
