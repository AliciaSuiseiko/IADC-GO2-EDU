#!/usr/bin/env bash
#SBATCH --job-name=x5-stitch-calibration
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --cpus-per-task=4
#SBATCH --gres=gpu:4090:1
#SBATCH --time=02:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/logs/x5-stitch-calibration-%j.out

set -Eeuo pipefail

ROOT="$HOME/lianaiwei"
STORE="/mnt/slurmfs-4090node3/user_data/$USER/lianaiwei"
ENV="$STORE/envs/sysnav-jazzy"
X5_WS="$STORE/src/camera_x5_ws"
MEDIA_ROOT="$ROOT/vendor/insta360/mediasdk-3.1.1/root/usr"
STITCHER="$X5_WS/install/insta360_x5_media_ros2/lib/insta360_x5_media_ros2/x5_media_stitcher_node"
PORT_BASE="${X5_CALIBRATION_PORT_BASE:?X5_CALIBRATION_PORT_BASE is required}"
STITCHER_PORT=$((PORT_BASE + 1))
PANORAMA_PORT=$((PORT_BASE + 5))
STITCH_TYPE="${X5_STITCH_TYPE:-dynamic}"
RUN_TRACKER="${X5_RUN_TRACKER:-0}"
TRACKER="$STORE/tracking_deployment/scripts/run_panorama_long_term_sot_server.sh"
LOG_DIR="$STORE/logs/x5-stitch-calibration-$SLURM_JOB_ID"
STATUS="$STORE/logs/x5-stitch-calibration.status"

mkdir -p "$LOG_DIR"
test -x "$STITCHER"

# The closed-source MediaSDK depends on the pristine Slurm library order.
STITCHER_BASE_PATH="$PATH"
STITCHER_BASE_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
STITCHER_BASE_PYTHONPATH="${PYTHONPATH:-}"

export CONDA_PREFIX="$ENV"
export CONDA_DEFAULT_ENV="$ENV"
export PATH="$ENV/bin:$PATH"
export PYTHONPATH="$ENV/lib/python3.12/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$MEDIA_ROOT/lib:$ENV/lib:$X5_WS/install/insta360_x5_media_ros2/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export INSTA360_MEDIA_SDK_ROOT="$MEDIA_ROOT"
export ROS_DISTRO=jazzy
export ROS_VERSION=2
export ROS_PYTHON_VERSION=3
export ROS_DOMAIN_ID=1
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
unset ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT FASTDDS_BUILTIN_TRANSPORTS

STITCHER_SOURCE="$X5_WS/src/insta360_x5_media_ros2/src/x5_media_stitcher_node.cpp"
STITCHER_BUILD="$X5_WS/build/insta360_x5_media_ros2"
if [[ "$STITCHER_SOURCE" -nt "$STITCHER" ]]; then
  "$ENV/bin/cmake" --build "$STITCHER_BUILD" -- -j4 -l4
  "$ENV/bin/cmake" --install "$STITCHER_BUILD"
fi

cleanup() {
  local rc=$?
  kill -INT "${TRACKER_PID:-}" "${PANORAMA_PID:-}" "${STITCHER_PID:-}" 2>/dev/null || true
  sleep 2
  kill -TERM "${TRACKER_PID:-}" "${PANORAMA_PID:-}" "${STITCHER_PID:-}" 2>/dev/null || true
  wait "${TRACKER_PID:-}" "${PANORAMA_PID:-}" "${STITCHER_PID:-}" 2>/dev/null || true
  printf 'STOPPED job=%s rc=%s %s\n' "$SLURM_JOB_ID" "$rc" "$(date -Is)" >"$STATUS"
}
trap cleanup EXIT INT TERM

printf 'STARTING job=%s host=%s %s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" >"$STATUS"

(
  export PATH="$STITCHER_BASE_PATH"
  export LD_LIBRARY_PATH="$STITCHER_BASE_LD_LIBRARY_PATH"
  export PYTHONPATH="$STITCHER_BASE_PYTHONPATH"
  unset AMENT_PREFIX_PATH CMAKE_PREFIX_PATH COLCON_PREFIX_PATH
  set +u
  source "$ROOT/miniforge3/etc/profile.d/conda.sh"
  conda activate "$ENV"
  source "$X5_WS/install/setup.bash"
  set -u
  export INSTA360_MEDIA_SDK_ROOT="$MEDIA_ROOT"
  export LD_LIBRARY_PATH="$MEDIA_ROOT/lib:${LD_LIBRARY_PATH:-}"
  export ROS_DOMAIN_ID=1
  export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
  exec ros2 run insta360_x5_media_ros2 x5_media_stitcher_node --ros-args \
    -p port:="$STITCHER_PORT" \
    -p output_width:=1920 \
    -p output_height:=960 \
    -p crop_top:=0 \
    -p crop_bottom:=0 \
    -p publish_fps:=5.0 \
    -p stitch_type:="$STITCH_TYPE" \
    -p image_latency_ms:=0.0
) >"$LOG_DIR/stitcher.log" 2>&1 &
STITCHER_PID=$!

for _ in $(seq 1 90); do
  kill -0 "$STITCHER_PID" 2>/dev/null || break
  grep -q 'Listening for official X5 CameraSDK stream' "$LOG_DIR/stitcher.log" 2>/dev/null && break
  sleep 2
done
grep -q 'Listening for official X5 CameraSDK stream' "$LOG_DIR/stitcher.log"

X5_PANORAMA_PORT="$PANORAMA_PORT" \
  "$ENV/bin/python" -u "$ROOT/scripts/x5_panorama_tcp_server.py" \
  >"$LOG_DIR/panorama-server.log" 2>&1 &
PANORAMA_PID=$!

for _ in $(seq 1 30); do
  kill -0 "$PANORAMA_PID" 2>/dev/null || break
  grep -q 'Listening for stitched-panorama clients' "$LOG_DIR/panorama-server.log" 2>/dev/null && break
  sleep 1
done
grep -q 'Listening for stitched-panorama clients' "$LOG_DIR/panorama-server.log"

if [[ "$RUN_TRACKER" == 1 ]]; then
  "$TRACKER" >"$LOG_DIR/tracker.log" 2>&1 &
  TRACKER_PID=$!
  for _ in $(seq 1 90); do
    kill -0 "$TRACKER_PID" 2>/dev/null || break
    grep -q 'Ready; initialize' "$LOG_DIR/tracker.log" 2>/dev/null && break
    sleep 2
  done
  grep -q 'Ready; initialize' "$LOG_DIR/tracker.log"
fi

printf 'LISTENING job=%s host=%s stitcher_port=%s panorama_port=%s %s\n' \
  "$SLURM_JOB_ID" "$(hostname)" "$STITCHER_PORT" "$PANORAMA_PORT" "$(date -Is)" >"$STATUS"

if [[ "$RUN_TRACKER" == 1 ]]; then
  wait -n "$STITCHER_PID" "$PANORAMA_PID" "$TRACKER_PID"
else
  wait -n "$STITCHER_PID" "$PANORAMA_PID"
fi
