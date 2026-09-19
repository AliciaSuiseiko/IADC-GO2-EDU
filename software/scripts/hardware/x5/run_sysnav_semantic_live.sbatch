#!/usr/bin/env bash
#SBATCH --job-name=sysnav-semantic-live
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --cpus-per-task=8
#SBATCH --gres=gpu:4090:1
#SBATCH --time=04:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/logs/sysnav-semantic-live-%j.out

set -euo pipefail

ROOT="$HOME/lianaiwei"
STORE="/mnt/slurmfs-4090node3/user_data/$USER/lianaiwei"
ENV="$STORE/envs/sysnav-jazzy"
WS="$ROOT/src/sysnav_ws"
X5_WS="$STORE/src/camera_x5_ws"
MEDIA_ROOT="$ROOT/vendor/insta360/mediasdk-3.1.1/root/usr"
STITCHER="$X5_WS/install/insta360_x5_media_ros2/lib/insta360_x5_media_ros2/x5_media_stitcher_node"
MODEL="$WS/src/SysNav/src/semantic_mapping/semantic_mapping/external/yoloe-26x-seg.pt"
OBJECTS="$WS/src/SysNav/src/semantic_mapping/semantic_mapping/config/objects.yaml"
LOG_DIR="$STORE/logs/sysnav-semantic-live-$SLURM_JOB_ID"
STATUS="$STORE/logs/sysnav-semantic-live.status"
VLM_ENV="${SYSNAV_VLM_ENV:-$ROOT/config/sysnav_vlm.env}"
PORT_BASE="${SYSNAV_PORT_BASE:-42100}"
STITCHER_PORT=$((PORT_BASE + 1))
ANNOTATED_PORT=$((PORT_BASE + 2))
UPLINK_PORT=$((PORT_BASE + 3))
DOWNLINK_PORT=$((PORT_BASE + 4))
PANORAMA_PORT=$((PORT_BASE + 5))
X5_IMAGE_LATENCY_MS="${X5_IMAGE_LATENCY_MS:-0.0}"
MIN_GPU_FREE_MIB="${SYSNAV_MIN_GPU_FREE_MIB:-20000}"
GPU_WAIT_SEC="${SYSNAV_GPU_WAIT_SEC:-180}"
mkdir -p "$LOG_DIR" "$STORE/models/sysnav"

# Preserve the pristine Slurm environment for the closed-source MediaSDK.
# The parent shell later adds every SysNav package prefix for YOLOE and SAM2.
STITCHER_BASE_PATH="$PATH"
STITCHER_BASE_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
STITCHER_BASE_PYTHONPATH="${PYTHONPATH:-}"

# Conda's ROS activation hook sources the full node3 prefix and can block in
# _local_setup_util.py on compute nodes. Load the same runtime explicitly.
export CONDA_PREFIX="$ENV"
export CONDA_DEFAULT_ENV="$ENV"
export PATH="$ENV/bin:$PATH"
export PYTHONPATH="$ENV/lib/python/site-packages:$ENV/lib/python3.12/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$ENV/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export INSTA360_MEDIA_SDK_ROOT="$MEDIA_ROOT"
export ROS_DISTRO=jazzy
export ROS_VERSION=2
export ROS_PYTHON_VERSION=3
export ROS_ETC_DIR="$ENV/etc/ros"
export ROS_OS_OVERRIDE=conda:linux
export AMENT_PREFIX_PATH="$ENV"
export CMAKE_PREFIX_PATH="$ENV:$ENV/x86_64-conda-linux-gnu/sysroot/usr"
export COLCON_PYTHON_EXECUTABLE="$ENV/bin/python3.12"

# The SysNav install uses isolated package prefixes. Build the runtime search
# paths directly so startup never invokes the node3-backed colcon helper.
SYSNAV_AMENT=""
SYSNAV_PYTHON=""
SYSNAV_LIBS=""
while IFS= read -r prefix; do
  [[ -d "$prefix/share/ament_index" ]] || continue
  SYSNAV_AMENT="${SYSNAV_AMENT:+$SYSNAV_AMENT:}$prefix"
  [[ -d "$prefix/lib/python3.12/site-packages" ]] && \
    SYSNAV_PYTHON="${SYSNAV_PYTHON:+$SYSNAV_PYTHON:}$prefix/lib/python3.12/site-packages"
  [[ -d "$prefix/lib" ]] && \
    SYSNAV_LIBS="${SYSNAV_LIBS:+$SYSNAV_LIBS:}$prefix/lib"
done < <(find -L "$WS/install" -mindepth 1 -maxdepth 1 -type d -print | sort)
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
done < <(find -L "$WS/build" -mindepth 1 -maxdepth 1 -type d -print | sort)
export PYTHONNOUSERSITE=1
export PYTHONUNBUFFERED=1
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_DOMAIN_ID=1
unset ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT FASTDDS_BUILTIN_TRANSPORTS
export TORCH_HOME="$STORE/cache/torch"
export ULTRALYTICS_CONFIG_DIR="$STORE/cache/ultralytics"
export LD_LIBRARY_PATH="$MEDIA_ROOT/lib:${LD_LIBRARY_PATH:-}"
if [[ -r "$VLM_ENV" ]]; then
  set -a
  source "$VLM_ENV"
  set +a
fi
if [[ -z "${DASHSCOPE_API_KEY:-}" && -z "${GEMINI_API_KEY:-}" ]]; then
  printf 'BLOCKED job=%s missing_vlm_api_env=%s %s\n' \
    "$SLURM_JOB_ID" "$VLM_ENV" "$(date -Is)" >"$STATUS"
  exit 3
fi

gpu_memory() {
  python3 - <<'PY'
import torch

free_bytes, total_bytes = torch.cuda.mem_get_info(0)
print(free_bytes // (1024 * 1024), total_bytes // (1024 * 1024))
PY
}

printf 'WAITING_GPU job=%s host=%s %s\n' \
  "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" >"$STATUS"
GPU_WAITED_SEC=0
while true; do
  read -r GPU_FREE_MIB GPU_TOTAL_MIB < <(gpu_memory)
  printf 'GPU allocation cuda_visible_devices=%s free_mib=%s total_mib=%s waited_sec=%s\n' \
    "${CUDA_VISIBLE_DEVICES:-unset}" "$GPU_FREE_MIB" "$GPU_TOTAL_MIB" "$GPU_WAITED_SEC"
  if ((GPU_FREE_MIB >= MIN_GPU_FREE_MIB)); then
    break
  fi
  if ((GPU_WAITED_SEC >= GPU_WAIT_SEC)); then
    printf 'FAILED job=%s insufficient_gpu_memory free_mib=%s required_mib=%s waited_sec=%s %s\n' \
      "$SLURM_JOB_ID" "$GPU_FREE_MIB" "$MIN_GPU_FREE_MIB" \
      "$GPU_WAITED_SEC" "$(date -Is)" >"$STATUS"
    exit 5
  fi
  sleep 5
  GPU_WAITED_SEC=$((GPU_WAITED_SEC + 5))
done

printf 'STARTING job=%s host=%s %s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" >"$STATUS"
[[ -x "$STITCHER" ]] || {
  printf 'FAILED job=%s missing_stitcher=%s %s\n' \
    "$SLURM_JOB_ID" "$STITCHER" "$(date -Is)" >"$STATUS"
  exit 4
}

cleanup() {
  local rc=$?
  kill -INT "${VLM_PID:-}" "${DOWNLINK_PID:-}" "${MAPPING_PID:-}" "${UPLINK_PID:-}" \
    "${ANNOTATED_PID:-}" "${PANORAMA_PID:-}" "${DETECT_PID:-}" "${STITCHER_PID:-}" \
    2>/dev/null || true
  sleep 2
  kill -TERM "${VLM_PID:-}" "${DOWNLINK_PID:-}" "${MAPPING_PID:-}" "${UPLINK_PID:-}" \
    "${ANNOTATED_PID:-}" "${PANORAMA_PID:-}" "${DETECT_PID:-}" "${STITCHER_PID:-}" \
    2>/dev/null || true
  wait "${VLM_PID:-}" "${DOWNLINK_PID:-}" "${MAPPING_PID:-}" "${UPLINK_PID:-}" \
    "${ANNOTATED_PID:-}" "${PANORAMA_PID:-}" "${DETECT_PID:-}" "${STITCHER_PID:-}" \
    2>/dev/null || true
  printf 'STOPPED job=%s rc=%s %s\n' "$SLURM_JOB_ID" "$rc" "$(date -Is)" >"$STATUS"
}
trap cleanup EXIT INT TERM

wait_for_log() {
  local pid=$1
  local file=$2
  local pattern=$3
  local label=$4
  local timeout=${5:-300}
  local elapsed=0
  while (( elapsed < timeout )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      printf 'FAILED job=%s component=%s exited_before_ready %s\n' \
        "$SLURM_JOB_ID" "$label" "$(date -Is)" >"$STATUS"
      tail -40 "$file" >&2 2>/dev/null || true
      return 1
    fi
    if grep -q "$pattern" "$file" 2>/dev/null; then
      printf 'READY component=%s elapsed=%ss\n' "$label" "$elapsed"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  printf 'FAILED job=%s component=%s startup_timeout=%ss %s\n' \
    "$SLURM_JOB_ID" "$label" "$timeout" "$(date -Is)" >"$STATUS"
  tail -40 "$file" >&2 2>/dev/null || true
  return 1
}

cd "$STORE/models/sysnav"
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
    -p port:="$STITCHER_PORT" \
    -p output_width:=1920 \
    -p output_height:=960 \
    -p crop_top:=160 \
    -p crop_bottom:=160 \
    -p publish_fps:=5.0 \
    -p image_latency_ms:="$X5_IMAGE_LATENCY_MS"
) >"$LOG_DIR/stitcher.log" 2>&1 &
STITCHER_PID=$!
wait_for_log "$STITCHER_PID" "$LOG_DIR/stitcher.log" \
  'Listening for official X5 CameraSDK stream' media_stitcher

X5_PANORAMA_PORT="$PANORAMA_PORT" \
  python3 -u "$ROOT/scripts/x5_panorama_tcp_server.py" \
  >"$LOG_DIR/panorama-server.log" 2>&1 &
PANORAMA_PID=$!
wait_for_log "$PANORAMA_PID" "$LOG_DIR/panorama-server.log" \
  'Listening for stitched-panorama clients' panorama_server

python3 -u "$ROOT/scripts/sysnav_semantic_bridge.py" server-uplink \
  --host 0.0.0.0 --port "$UPLINK_PORT" \
  >"$LOG_DIR/semantic-uplink.log" 2>&1 &
UPLINK_PID=$!
wait_for_log "$UPLINK_PID" "$LOG_DIR/semantic-uplink.log" \
  "Listening on 0.0.0.0:$UPLINK_PORT" semantic_uplink

# MediaSDK creates its Vulkan decoder/blender lazily on the first panorama.
# Finish that initialization before PyTorch allocates the GPU for YOLOE/SAM2.
wait_for_log "$STITCHER_PID" "$LOG_DIR/stitcher.log" \
  'Publishing official stitched X5 panorama' media_stitcher_first_frame 180

ros2 run semantic_mapping detection_node --ros-args \
  -p detector_backend:=yoloe \
  -p detector_model:="$MODEL" \
  -p device:=cuda \
  -p annotate_image:=true \
  >"$LOG_DIR/detection.log" 2>&1 &
DETECT_PID=$!
wait_for_log "$DETECT_PID" "$LOG_DIR/detection.log" \
  'Detection node has been started' detection 600

cd "$WS/src/SysNav"
ros2 run semantic_mapping semantic_mapping_node --ros-args \
  -p platform:=go2_x5 \
  -p device:=cuda \
  -p object_file:="$OBJECTS" \
  -p annotate_image:=true \
  >"$LOG_DIR/semantic-mapping.log" 2>&1 &
MAPPING_PID=$!
wait_for_log "$MAPPING_PID" "$LOG_DIR/semantic-mapping.log" \
  'Semantic mapping node has been started' semantic_mapping

python3 -u "$ROOT/scripts/sysnav_semantic_bridge.py" server-downlink \
  --host 0.0.0.0 --port "$DOWNLINK_PORT" \
  >"$LOG_DIR/semantic-downlink.log" 2>&1 &
DOWNLINK_PID=$!
wait_for_log "$DOWNLINK_PID" "$LOG_DIR/semantic-downlink.log" \
  "Listening on 0.0.0.0:$DOWNLINK_PORT" semantic_downlink

X5_ANNOTATED_PORT="$ANNOTATED_PORT" \
  python3 -u "$ROOT/scripts/x5_annotated_tcp_server.py" \
  >"$LOG_DIR/annotated-server.log" 2>&1 &
ANNOTATED_PID=$!
wait_for_log "$ANNOTATED_PID" "$LOG_DIR/annotated-server.log" \
  'Listening for annotated-image clients' annotated_server

VLM_RUN_DIR="$LOG_DIR/vlm-runtime"
mkdir -p "$VLM_RUN_DIR/src/semantic_mapping/semantic_mapping/config"
cp "$OBJECTS" "$VLM_RUN_DIR/src/semantic_mapping/semantic_mapping/config/objects.yaml"
cd "$VLM_RUN_DIR"
ros2 run vlm_node vlm_reasoning_node --ros-args \
  -p platform:=mecanum \
  -p log_dir:="$LOG_DIR/vlm" \
  >"$LOG_DIR/vlm.log" 2>&1 &
VLM_PID=$!
wait_for_log "$VLM_PID" "$LOG_DIR/vlm.log" 'VLM initialized' vlm 600

for _ in $(seq 1 180); do
  kill -0 "$STITCHER_PID" "$PANORAMA_PID" "$DETECT_PID" "$ANNOTATED_PID" \
    "$UPLINK_PID" "$MAPPING_PID" "$DOWNLINK_PID" "$VLM_PID"
  if grep -q 'Accepted annotated-image client' "$LOG_DIR/annotated-server.log" 2>/dev/null && \
     grep -q 'Publishing official stitched X5 panorama' "$LOG_DIR/stitcher.log" 2>/dev/null && \
     grep -q 'Accepted stitched-panorama client' "$LOG_DIR/panorama-server.log" 2>/dev/null && \
     grep -q 'Semantic mapping node has been started' "$LOG_DIR/semantic-mapping.log" 2>/dev/null && \
     grep -q 'VLM initialized' "$LOG_DIR/vlm.log" 2>/dev/null && \
     grep -q 'Accepted bridge client' "$LOG_DIR/semantic-uplink.log" 2>/dev/null && \
     grep -q 'Accepted bridge client' "$LOG_DIR/semantic-downlink.log" 2>/dev/null; then
    printf 'READY job=%s host=%s %s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" >"$STATUS"
    break
  fi
  sleep 2
done

grep -q '^READY ' "$STATUS"
wait -n "$STITCHER_PID" "$PANORAMA_PID" "$DETECT_PID" "$ANNOTATED_PID" \
  "$UPLINK_PID" "$MAPPING_PID" "$DOWNLINK_PID" "$VLM_PID"
