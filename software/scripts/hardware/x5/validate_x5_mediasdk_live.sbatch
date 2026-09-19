#!/usr/bin/env bash
#SBATCH --job-name=x5-media-live
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --cpus-per-task=2
#SBATCH --gres=gpu:4090:1
#SBATCH --time=00:10:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/logs/x5-media-live-%j.out

set -euo pipefail

ROOT="$HOME/lianaiwei"
STORE="/mnt/slurmfs-4090node3/user_data/$USER/lianaiwei"
ENV="$STORE/envs/sysnav-jazzy"
WS="$STORE/src/camera_x5_ws"
MEDIA_ROOT="$ROOT/vendor/insta360/mediasdk-3.1.1/root/usr"
SAVER="$ROOT/scripts/hardware/x5/save_ros_image_once.py"
LOG_DIR="$STORE/logs/x5-media-live-$SLURM_JOB_ID"
STATUS="$STORE/logs/x5-media-live.status"

mkdir -p "$LOG_DIR"
printf 'STARTING job=%s host=%s\n' "$SLURM_JOB_ID" "$(hostname)" >"$STATUS"
set +u
source "$ROOT/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
source "$WS/install/setup.bash"
set -u
export INSTA360_MEDIA_SDK_ROOT="$MEDIA_ROOT"
export LD_LIBRARY_PATH="$MEDIA_ROOT/lib:${LD_LIBRARY_PATH:-}"
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_DOMAIN_ID=92
unset ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT FASTDDS_BUILTIN_TRANSPORTS

stitcher_pid=""
saver_pid=""
cleanup() {
  local rc=$?
  [[ -n "$saver_pid" ]] && kill -TERM "$saver_pid" 2>/dev/null || true
  [[ -n "$stitcher_pid" ]] && kill -TERM "$stitcher_pid" 2>/dev/null || true
  [[ -n "$saver_pid" ]] && wait "$saver_pid" 2>/dev/null || true
  [[ -n "$stitcher_pid" ]] && wait "$stitcher_pid" 2>/dev/null || true
  if ! grep -q '^COMPLETE ' "$STATUS" 2>/dev/null; then
    printf 'STOPPED job=%s rc=%s\n' "$SLURM_JOB_ID" "$rc" >"$STATUS"
  fi
}
trap cleanup EXIT INT TERM

ros2 run insta360_x5_media_ros2 x5_media_stitcher_node --ros-args \
  -p port:=42101 \
  -p output_width:=1920 \
  -p output_height:=960 \
  -p crop_top:=160 \
  -p crop_bottom:=160 \
  -p publish_fps:=5.0 \
  >"$LOG_DIR/stitcher.log" 2>&1 &
stitcher_pid=$!

for _ in $(seq 1 100); do
  grep -q 'Listening for official X5 CameraSDK stream' "$LOG_DIR/stitcher.log" && break
  kill -0 "$stitcher_pid" 2>/dev/null || exit 3
  sleep 0.1
done
grep -q 'Listening for official X5 CameraSDK stream' "$LOG_DIR/stitcher.log"
printf 'READY job=%s host=%s\n' "$SLURM_JOB_ID" "$(hostname)" >"$STATUS"

python3 "$SAVER" --topic /camera/image --output "$LOG_DIR/panorama.jpg" --timeout 120 \
  >"$LOG_DIR/saver.log" 2>&1 &
saver_pid=$!
wait "$saver_pid"
saver_pid=""
test -s "$LOG_DIR/panorama.jpg"
grep -q 'Publishing official stitched X5 panorama' "$LOG_DIR/stitcher.log"
printf 'COMPLETE job=%s image=%s\n' "$SLURM_JOB_ID" "$LOG_DIR/panorama.jpg" >"$STATUS"
