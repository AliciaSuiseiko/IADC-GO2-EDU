#!/usr/bin/env bash
set -euo pipefail

ROOT="${HOME}/lianaiwei"
TRACKING_ROOT="${ROOT}/tracking_deployment"
SCRIPT="${TRACKING_ROOT}/scripts/panorama_person_tracker.py"
BOT_CONFIG="${TRACKING_ROOT}/config/botsort_panorama.yaml"

source /opt/ros/humble/setup.bash
source "${ROOT}/venvs/sysnav/bin/activate"
if [[ -f "${ROOT}/src/sysnav_ws/install/setup.bash" ]]; then
  source "${ROOT}/src/sysnav_ws/install/setup.bash"
fi

if [[ -n "${PERSON_TRACKER_MODEL:-}" ]]; then
  MODEL="${PERSON_TRACKER_MODEL}"
else
  MODEL=""
  for model_name in yolo11n.pt yoloe-v8l-seg.pt yoloe-26x-seg.engine; do
    MODEL="$(find "${ROOT}" -type f -name "${model_name}" \
      -size +1M -print -quit 2>/dev/null || true)"
    [[ -n "${MODEL}" ]] && break
  done
  MODEL="${MODEL:-yolo11n.pt}"
fi

exec python3 "${SCRIPT}" --ros-args \
  -p input_topic:="${PERSON_TRACKER_INPUT_TOPIC:-/camera/image}" \
  -p model_path:="${MODEL}" \
  -p tracker_config:="${BOT_CONFIG}" \
  -p fallback_tracker_config:=bytetrack.yaml \
  -p device:="${PERSON_TRACKER_DEVICE:-0}" \
  -p confidence:="${PERSON_TRACKER_CONFIDENCE:-0.25}" \
  -p image_size:="${PERSON_TRACKER_IMAGE_SIZE:-960}" \
  -p process_every_n:="${PERSON_TRACKER_PROCESS_EVERY_N:-1}" \
  -p target_lost_frames:="${PERSON_TRACKER_TARGET_LOST_FRAMES:-30}" \
  -p body_forward_offset_deg:="${PERSON_TRACKER_BODY_FORWARD_OFFSET_DEG:-0.0}"
