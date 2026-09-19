#!/usr/bin/env bash
set -euo pipefail

ROOT="${HOME}/lianaiwei"
LOGIN_HOST="robot@login.example"
SSH_KEY="${HOME}/.ssh/id_ed25519"
SERVER_SCRIPT="lianaiwei/scripts/run_sysnav_semantic_live.sbatch"
STATUS_FILE="/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/logs/sysnav-semantic-live.status"
RUN_DIR="${SYSNAV_RUN_DIR:?SYSNAV_RUN_DIR is required}"
X5_IMAGE_LATENCY_MS="${X5_IMAGE_LATENCY_MS:-0.0}"
if [[ ! "$X5_IMAGE_LATENCY_MS" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
  echo "Invalid X5_IMAGE_LATENCY_MS: $X5_IMAGE_LATENCY_MS" >&2
  exit 2
fi
server_uid="$(ssh -i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=8 \
  "${LOGIN_HOST}" 'id -u')"
REMOTE_PORT_BASE=$((30000 + (server_uid % 1000) * 10))

server_ssh() {
  ssh -i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=8 "${LOGIN_HOST}" "$@"
}

queue="$(server_ssh "squeue -u aiwei -h -o '%i|%j|%t|%R'")"
semantic_line="$(printf '%s\n' "${queue}" | awk -F'|' '$2 == "sysnav-semantic-live" {print; exit}')"

if [[ -z "${semantic_line}" ]]; then
  if [[ -n "${queue}" ]]; then
    echo "Refusing semantic submission: another aiwei Slurm job is active." >&2
    printf '%s\n' "${queue}" >&2
    exit 2
  fi
  submit="$(server_ssh "sbatch --export=ALL,SYSNAV_PORT_BASE='${REMOTE_PORT_BASE}',X5_IMAGE_LATENCY_MS='${X5_IMAGE_LATENCY_MS}' '${SERVER_SCRIPT}'")"
  job_id="${submit##* }"
else
  job_id="${semantic_line%%|*}"
fi

# Persist ownership immediately so an interrupted parallel startup can still
# cancel the single allowed aiwei job during supervisor cleanup.
printf 'job_id=%s\n' "${job_id}" >"${RUN_DIR}/semantic-job.txt"

compute_host=""
for _ in $(seq 1 60); do
  job_line="$(server_ssh "squeue -j '${job_id}' -h -o '%t|%N'")"
  state="${job_line%%|*}"
  compute_host="${job_line#*|}"
  if [[ "${state}" == "R" && -n "${compute_host}" && "${compute_host}" != "(null)" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${compute_host}" || "${compute_host}" == "(null)" ]]; then
  echo "Slurm job ${job_id} did not reach RUNNING state." >&2
  exit 3
fi

expected_forward="127.0.0.1:42101:${compute_host}:$((REMOTE_PORT_BASE + 1))"
if ss -ltn | grep -q '127.0.0.1:42101' && \
   { ! pgrep -af 'ssh -N .*127\.0\.0\.1:42101:' | grep -Fq -- "${expected_forward}" || \
     ! ss -ltn | grep -q '127.0.0.1:42105'; }; then
  while read -r stale_pid; do
    kill "${stale_pid}" 2>/dev/null || true
  done < <(pgrep -f 'ssh -N .*127\.0\.0\.1:42101:' || true)
  sleep 2
fi

if ! ss -ltn | grep -q '127.0.0.1:42101'; then
  setsid ssh -N -i "${SSH_KEY}" \
    -o BatchMode=yes -o ConnectTimeout=8 -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -L "127.0.0.1:42101:${compute_host}:$((REMOTE_PORT_BASE + 1))" \
    -L "127.0.0.1:42102:${compute_host}:$((REMOTE_PORT_BASE + 2))" \
    -L "127.0.0.1:42103:${compute_host}:$((REMOTE_PORT_BASE + 3))" \
    -L "127.0.0.1:42104:${compute_host}:$((REMOTE_PORT_BASE + 4))" \
    -L "127.0.0.1:42105:${compute_host}:$((REMOTE_PORT_BASE + 5))" \
    "${LOGIN_HOST}" >"${RUN_DIR}/hkust-tunnel.log" 2>&1 &
  printf '%s\n' "$!" >"${RUN_DIR}/hkust-tunnel.pid"
fi

for _ in $(seq 1 15); do
  if ss -ltn | grep -q '127.0.0.1:42101' && \
     ss -ltn | grep -q '127.0.0.1:42102' && \
     ss -ltn | grep -q '127.0.0.1:42103' && \
     ss -ltn | grep -q '127.0.0.1:42104' && \
     ss -ltn | grep -q '127.0.0.1:42105'; then
    printf 'job_id=%s\ncompute_host=%s\nremote_port_base=%s\n' \
      "${job_id}" "${compute_host}" "${REMOTE_PORT_BASE}" \
      >"${RUN_DIR}/semantic-job.txt"
    echo "Semantic link ready: job=${job_id} host=${compute_host}"
    exit 0
  fi
  sleep 1
done

echo "SSH forwarding did not become ready." >&2
exit 4
