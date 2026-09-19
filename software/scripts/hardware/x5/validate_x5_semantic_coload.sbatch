#!/usr/bin/env bash
#SBATCH --job-name=x5-semantic-coload
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --cpus-per-task=8
#SBATCH --gres=gpu:4090:1
#SBATCH --time=00:15:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/logs/x5-semantic-coload-%j.out

set -Eeuo pipefail

ROOT="$HOME/lianaiwei"
STORE="/mnt/slurmfs-4090node3/user_data/$USER/lianaiwei"
ENV="$STORE/envs/sysnav-jazzy"
SYSNAV_WS="$ROOT/src/sysnav_ws"
X5_WS="$STORE/src/camera_x5_ws"
MEDIA_ROOT="$ROOT/vendor/insta360/mediasdk-3.1.1/root/usr"
STITCHER="$X5_WS/install/insta360_x5_media_ros2/lib/insta360_x5_media_ros2/x5_media_stitcher_node"
CAPTURE="$STORE/diagnostics/x5-captures/x5-capture-20260815-214237/transport.x5cap"
REPLAY="$ROOT/scripts/hardware/x5/replay_x5_stitch_stream.py"
SAVER="$ROOT/scripts/hardware/x5/save_ros_image_once.py"
MODEL="$SYSNAV_WS/src/SysNav/src/semantic_mapping/semantic_mapping/external/yoloe-26x-seg.pt"
OBJECTS="$SYSNAV_WS/src/SysNav/src/semantic_mapping/semantic_mapping/config/objects.yaml"
LOG_DIR="$STORE/logs/x5-semantic-coload-$SLURM_JOB_ID"
mkdir -p "$LOG_DIR"

STITCHER_BASE_PATH="$PATH"
STITCHER_BASE_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
STITCHER_BASE_PYTHONPATH="${PYTHONPATH:-}"

export CONDA_PREFIX="$ENV"
export CONDA_DEFAULT_ENV="$ENV"
export PATH="$ENV/bin:$PATH"
export PYTHONPATH="$ENV/lib/python/site-packages:$ENV/lib/python3.12/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$MEDIA_ROOT/lib:$ENV/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export INSTA360_MEDIA_SDK_ROOT="$MEDIA_ROOT"
export ROS_DISTRO=jazzy ROS_VERSION=2 ROS_PYTHON_VERSION=3
export ROS_ETC_DIR="$ENV/etc/ros" ROS_OS_OVERRIDE=conda:linux
export AMENT_PREFIX_PATH="$ENV"
export CMAKE_PREFIX_PATH="$ENV:$ENV/x86_64-conda-linux-gnu/sysroot/usr"
export COLCON_PYTHON_EXECUTABLE="$ENV/bin/python3.12"

SYSNAV_AMENT=""
SYSNAV_PYTHON=""
SYSNAV_LIBS=""
while IFS= read -r prefix; do
  [[ -d "$prefix/share/ament_index" ]] || continue
  SYSNAV_AMENT="${SYSNAV_AMENT:+$SYSNAV_AMENT:}$prefix"
  [[ -d "$prefix/lib/python3.12/site-packages" ]] && \
    SYSNAV_PYTHON="${SYSNAV_PYTHON:+$SYSNAV_PYTHON:}$prefix/lib/python3.12/site-packages"
  [[ -d "$prefix/lib" ]] && SYSNAV_LIBS="${SYSNAV_LIBS:+$SYSNAV_LIBS:}$prefix/lib"
done < <(find -L "$SYSNAV_WS/install" -mindepth 1 -maxdepth 1 -type d -print | sort)
export AMENT_PREFIX_PATH="$SYSNAV_AMENT:$AMENT_PREFIX_PATH"
export CMAKE_PREFIX_PATH="$SYSNAV_AMENT:$CMAKE_PREFIX_PATH"
export COLCON_PREFIX_PATH="$SYSNAV_AMENT"
export PYTHONPATH="${SYSNAV_PYTHON:+$SYSNAV_PYTHON:}$PYTHONPATH"
export LD_LIBRARY_PATH="${SYSNAV_LIBS:+$SYSNAV_LIBS:}$LD_LIBRARY_PATH"
while IFS= read -r build_prefix; do
  if find -L "$build_prefix" -maxdepth 1 \
      \( -name '*.egg-info' -o -name '*.dist-info' \) -print -quit | grep -q .; then
    export PYTHONPATH="$build_prefix:$PYTHONPATH"
  fi
done < <(find -L "$SYSNAV_WS/build" -mindepth 1 -maxdepth 1 -type d -print | sort)

export PYTHONNOUSERSITE=1 PYTHONUNBUFFERED=1
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp ROS_DOMAIN_ID=92
export TORCH_HOME="$STORE/cache/torch"
export ULTRALYTICS_CONFIG_DIR="$STORE/cache/ultralytics"
unset ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT FASTDDS_BUILTIN_TRANSPORTS

declare -a PIDS=()
cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  ((${#PIDS[@]} == 0)) || kill -INT "${PIDS[@]}" 2>/dev/null || true
  sleep 2
  ((${#PIDS[@]} == 0)) || kill -TERM "${PIDS[@]}" 2>/dev/null || true
  ((${#PIDS[@]} == 0)) || wait "${PIDS[@]}" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT INT TERM HUP

wait_log() {
  local pid=$1 file=$2 pattern=$3 timeout=${4:-300}
  local elapsed=0
  while ((elapsed < timeout)); do
    kill -0 "$pid" 2>/dev/null || { tail -80 "$file" >&2; return 1; }
    grep -q "$pattern" "$file" 2>/dev/null && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  tail -80 "$file" >&2
  return 1
}

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
  exec ros2 run insta360_x5_media_ros2 x5_media_stitcher_node --ros-args \
    -p port:=42101 -p output_width:=1920 -p output_height:=960 \
    -p crop_top:=160 -p crop_bottom:=160 -p publish_fps:=5.0
) >"$LOG_DIR/stitcher.log" 2>&1 &
STITCHER_PID=$!
PIDS+=("$STITCHER_PID")
wait_log "$STITCHER_PID" "$LOG_DIR/stitcher.log" 'Listening for official X5 CameraSDK stream'

python3 "$SAVER" --topic /camera/image --output "$LOG_DIR/panorama.jpg" --timeout 90 \
  >"$LOG_DIR/saver.log" 2>&1 &
SAVER_PID=$!
PIDS+=("$SAVER_PID")

python3 "$REPLAY" --capture "$CAPTURE" \
  --pause-after-video-count 60 --pause-seconds 120 \
  >"$LOG_DIR/replay.log" 2>&1 &
REPLAY_PID=$!
PIDS+=("$REPLAY_PID")

wait "$SAVER_PID"
test -s "$LOG_DIR/panorama.jpg"
grep -q 'Publishing official stitched X5 panorama' "$LOG_DIR/stitcher.log"
kill -0 "$STITCHER_PID" "$REPLAY_PID"

ros2 run semantic_mapping detection_node --ros-args \
  -p detector_backend:=yoloe -p detector_model:="$MODEL" \
  -p device:=cuda -p annotate_image:=true \
  >"$LOG_DIR/detection.log" 2>&1 &
DETECT_PID=$!
PIDS+=("$DETECT_PID")
wait_log "$DETECT_PID" "$LOG_DIR/detection.log" 'Detection node has been started' 600

cd "$SYSNAV_WS/src/SysNav"
ros2 run semantic_mapping semantic_mapping_node --ros-args \
  -p platform:=go2_x5 -p device:=cuda -p object_file:="$OBJECTS" \
  -p annotate_image:=true >"$LOG_DIR/semantic-mapping.log" 2>&1 &
MAPPING_PID=$!
PIDS+=("$MAPPING_PID")
wait_log "$MAPPING_PID" "$LOG_DIR/semantic-mapping.log" 'Semantic mapping node has been started' 600

timeout 180 ros2 topic echo /detection_result --once \
  >"$LOG_DIR/detection-result.txt" 2>&1 &
RESULT_PID=$!
PIDS+=("$RESULT_PID")

wait "$REPLAY_PID"
kill -0 "$STITCHER_PID" "$DETECT_PID" "$MAPPING_PID"
wait "$RESULT_PID"
test -s "$LOG_DIR/detection-result.txt"
printf 'PASS stitcher_initialized_before_models=1 detection_alive=1 semantic_mapping_alive=1\n'
