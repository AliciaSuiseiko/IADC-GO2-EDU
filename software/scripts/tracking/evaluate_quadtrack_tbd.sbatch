#!/usr/bin/env bash
#SBATCH --job-name=quad-tbd
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --time=06:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/quad-tbd-%j.out

set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
ENV="$HOME/lianaiwei/tracking_envs/oavat"
DATA="$ROOT/datasets/QuadTrack"
SCRIPTS="$ROOT/scripts"
MODEL="$ROOT/models/tbd/yolo11n.pt"
RUN="$ROOT/runs/quadtrack_tbd_${SLURM_JOB_ID}"
STATUS="$ROOT/status/quadtrack_tbd.status"

mkdir -p "$DATA" "$ROOT/models/tbd" "$RUN" "$ROOT/logs" "$ROOT/status"
printf 'RUNNING job=%s host=%s time=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

set +u
source "$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
set -u
export PYTHONNOUSERSITE=1
export PIP_CACHE_DIR="$ROOT/cache/pip"

if [[ ! -s "$DATA/train.zip" ]]; then
  curl -fL --retry 20 --retry-delay 15 --retry-all-errors -C - \
    -o "$DATA/train.zip" \
    https://hf-mirror.com/datasets/xifen527/QuadTrack/resolve/main/train.zip
fi
for sequence in 0015 0016 0017; do
  if [[ ! -s "$DATA/train/$sequence/gt/gt.txt" ]]; then
    unzip -q "$DATA/train.zip" "train/$sequence/*" -d "$DATA"
  fi
done
if [[ ! -s "$MODEL" ]]; then
  curl -fL --retry 8 --retry-delay 10 -C - \
    -o "$MODEL" \
    https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n.pt
fi
python -c 'import motmetrics' 2>/dev/null || python -m pip install 'motmetrics==1.4.0'

python "$SCRIPTS/evaluate_panorama_tbd.py" \
  --data-root "$DATA" --output-dir "$RUN/botsort" --model "$MODEL" \
  --tracker "$SCRIPTS/botsort_panorama.yaml" --device 0 --image-size 960 \
  --max-sequences 3 --video-frames 400

python "$SCRIPTS/evaluate_panorama_tbd.py" \
  --data-root "$DATA" --output-dir "$RUN/bytetrack" --model "$MODEL" \
  --tracker bytetrack.yaml --device 0 --image-size 960 \
  --max-sequences 3 --video-frames 400

python - "$RUN" <<'PY'
import json
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
comparison = {}
for tracker in ("botsort", "bytetrack"):
    comparison[tracker] = json.loads((run / tracker / "metrics.json").read_text())
(run / "comparison.json").write_text(json.dumps(comparison, indent=2))
print(json.dumps(comparison, indent=2))
PY

printf 'COMPLETE job=%s run=%s time=%s\n' "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
