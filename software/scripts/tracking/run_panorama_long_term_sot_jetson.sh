#!/usr/bin/env bash
set -eo pipefail

ROOT="${HOME}/lianaiwei"
TRACKING_ROOT="${ROOT}/tracking_deployment"
SCRIPT="${TRACKING_ROOT}/scripts/panorama_long_term_sot_node.py"

source /opt/ros/humble/setup.bash
source "${ROOT}/venvs/sysnav/bin/activate"
if [[ -f "${ROOT}/src/sysnav_ws/install/setup.bash" ]]; then
  source "${ROOT}/src/sysnav_ws/install/setup.bash"
fi
set -u
export PYTHONPATH="${TRACKING_ROOT}/pydeps:/opt/ros/humble/lib/python3.10/site-packages:${TRACKING_ROOT}/scripts:${PYTHONPATH:-}"

ODTRACK_REPO="${ODTRACK_REPO:-${TRACKING_ROOT}/src/ODTrack}"
ODTRACK_CHECKPOINT="${ODTRACK_CHECKPOINT:-${TRACKING_ROOT}/models/odtrack/Base-Fulldata-300ep/ODTrack_ep0300.pth.tar}"
TORCHREID_REPO="${TORCHREID_REPO:-${TRACKING_ROOT}/src/deep-person-reid}"
REID_CHECKPOINT="${REID_CHECKPOINT:-${TRACKING_ROOT}/models/osnet/osnet_ain_x1_0_msmt17_256x128_amsgrad_ep50_lr0.0015_coslr_b64_fb10_softmax_labsmth_flip_jitter.pth}"
DETECTOR_MODEL="${DETECTOR_MODEL:-${TRACKING_ROOT}/models/tbd/yolo11n.pt}"

for required in "${SCRIPT}" "${ODTRACK_REPO}" "${ODTRACK_CHECKPOINT}" \
  "${TORCHREID_REPO}" "${REID_CHECKPOINT}" "${DETECTOR_MODEL}"; do
  if [[ ! -e "${required}" ]]; then
    printf 'Missing required tracking asset: %s\n' "${required}" >&2
    exit 1
  fi
done

exec python3 "${SCRIPT}" --ros-args \
  -p image_topic:="${TRACKING_IMAGE_TOPIC:-/camera/image}" \
  -p compressed_input:="${TRACKING_COMPRESSED_INPUT:-false}" \
  -p depth_topic:="${TRACKING_DEPTH_TOPIC:-}" \
  -p refined_mask_topic:="${TRACKING_REFINED_MASK_TOPIC:-}" \
  -p depth_scale:="${TRACKING_DEPTH_SCALE:-1.0}" \
  -p depth_is_metric:="${TRACKING_DEPTH_IS_METRIC:-false}" \
  -p auxiliary_max_age_sec:="${TRACKING_AUXILIARY_MAX_AGE_SEC:-0.35}" \
  -p odtrack_repo:="${ODTRACK_REPO}" \
  -p odtrack_checkpoint:="${ODTRACK_CHECKPOINT}" \
  -p odtrack_config:="${ODTRACK_CONFIG:-baseline}" \
  -p torchreid_repo:="${TORCHREID_REPO}" \
  -p reid_checkpoint:="${REID_CHECKPOINT}" \
  -p detector_model:="${DETECTOR_MODEL}" \
  -p device:="${TRACKING_DEVICE:-cuda}" \
  -p detector_interval:="${TRACKING_DETECTOR_INTERVAL:-5}" \
  -p identity_interval:="${TRACKING_IDENTITY_INTERVAL:-3}" \
  -p max_prediction_sec:="${TRACKING_MAX_PREDICTION_SEC:-0.5}" \
  -p max_processing_fps:="${TRACKING_MAX_FPS:-10.0}" \
  -p body_forward_offset_deg:="${TRACKING_BODY_FORWARD_OFFSET_DEG:-0.0}" \
  -p require_erp:="${TRACKING_REQUIRE_ERP:-true}"
