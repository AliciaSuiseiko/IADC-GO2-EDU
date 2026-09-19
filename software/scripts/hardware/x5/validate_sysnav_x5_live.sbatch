#!/usr/bin/env bash
#SBATCH --job-name=sysnav-x5-live
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node2
#SBATCH --cpus-per-task=4
#SBATCH --gres=gpu:4090:1
#SBATCH --time=00:30:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/logs/sysnav-x5-live-%j.out

set -euo pipefail

ROOT="$HOME/lianaiwei"
STORE="/mnt/slurmfs-4090node3/user_data/$USER/lianaiwei"
ENV="$STORE/envs/sysnav-jazzy"
WS="$ROOT/src/sysnav_ws"
MODEL="$WS/src/SysNav/src/semantic_mapping/semantic_mapping/external/yoloe-26x-seg.pt"
LOG_DIR="$STORE/logs/sysnav-x5-live-$SLURM_JOB_ID"
STATUS="$STORE/logs/sysnav-x5-live.status"

mkdir -p "$LOG_DIR" "$STORE/models/sysnav"
printf 'RUNNING job=%s host=%s %s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s %s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

set +u
source "$ROOT/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
source "$WS/install/setup.bash"
set -u
export PYTHONNOUSERSITE=1
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_DOMAIN_ID=1
unset ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT FASTDDS_BUILTIN_TRANSPORTS
export TORCH_HOME="$STORE/cache/torch"
export ULTRALYTICS_CONFIG_DIR="$STORE/cache/ultralytics"

cleanup() {
  kill -INT "${DETECT_PID:-}" "${REPUB_PID:-}" 2>/dev/null || true
  sleep 2
  kill -TERM "${DETECT_PID:-}" "${REPUB_PID:-}" 2>/dev/null || true
  wait "${DETECT_PID:-}" "${REPUB_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$STORE/models/sysnav"
python3 "$ROOT/scripts/x5_tcp_receiver.py" \
  >"$LOG_DIR/republish.log" 2>&1 &
REPUB_PID=$!

ros2 run semantic_mapping detection_node --ros-args \
  -p detector_backend:=yoloe \
  -p detector_model:="$MODEL" \
  -p device:=cuda \
  -p annotate_image:=true \
  >"$LOG_DIR/detection.log" 2>&1 &
DETECT_PID=$!

for _ in $(seq 1 60); do
  kill -0 "$REPUB_PID"
  kill -0 "$DETECT_PID"
  if grep -q 'Publishing X5 raw frames' "$LOG_DIR/republish.log" 2>/dev/null; then
    break
  fi
  sleep 2
done
grep -q 'Publishing X5 raw frames' "$LOG_DIR/republish.log"

timeout 300 ros2 topic echo /detection_result tare_planner/msg/DetectionResult \
  --once --field label \
  >"$LOG_DIR/labels.txt"
grep -q '^-' "$LOG_DIR/labels.txt"
printf 'COMPLETE job=%s labels=%s %s\n' \
  "$SLURM_JOB_ID" "$(tr '\n' ' ' < "$LOG_DIR/labels.txt")" "$(date -Is)" > "$STATUS"
