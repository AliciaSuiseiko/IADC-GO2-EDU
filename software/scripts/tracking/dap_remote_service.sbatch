#!/usr/bin/env bash
#SBATCH --job-name=dap-remote
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --gres=gpu:1
#SBATCH --time=00:20:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/dap-remote-%j.out
#SBATCH --error=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/dap-remote-%j.err

set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
ENV_DIR="$HOME/lianaiwei/tracking_envs/dap"
SRC="$ROOT/src/DAP"
RUN="$ROOT/runs/dap_remote_${SLURM_JOB_ID}"
PORT=18761
MAX_REQUESTS="${DAP_MAX_REQUESTS:-3}"

mkdir -p "$RUN" "$ROOT/status" "$ROOT/logs"
rm -f "$ROOT/status/dap_remote.ready.json"

cat > "$RUN/infer.yaml" <<EOF
model:
  name: dap
  args:
    midas_model_type: vitl
    fine_tune_type: hypersim
    min_depth: 0.01
    max_depth: 1.0
    train_decoder: true
median_align: false
load_weights_dir: $ROOT/models/dap
EOF

cat > "$RUN/manifest.txt" <<EOF
job_id=$SLURM_JOB_ID
node=$(hostname)
port=$PORT
source=$SRC
commit=$(git -C "$SRC" rev-parse HEAD)
environment=$ENV_DIR
model=$ROOT/models/dap/model.pth
protocol=JPEG request; zlib float16 depth response
max_requests=$MAX_REQUESTS
EOF

if ss -ltn "sport = :$PORT" | tail -n +2 | grep -q .; then
    printf 'port %s is already in use\n' "$PORT" >&2
    exit 2
fi

cd "$SRC"
env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$SRC:$SRC/test" \
    "$ENV_DIR/bin/python" "$ROOT/scripts/dap_remote_server.py" \
    --config "$RUN/infer.yaml" \
    --port "$PORT" \
    --ready-file "$ROOT/status/dap_remote.ready.json" \
    --metrics "$RUN/metrics.jsonl" \
    --max-requests "$MAX_REQUESTS" \
    --idle-timeout 600

printf 'COMPLETE run=%s\n' "$RUN" > "$ROOT/status/dap_remote.status"
