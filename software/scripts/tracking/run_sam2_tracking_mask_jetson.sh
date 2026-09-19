#!/usr/bin/env bash
set -eo pipefail

ROOT=/home/orin/lianaiwei
source /opt/ros/humble/setup.bash
source "$ROOT/venvs/sysnav/bin/activate"
source "$ROOT/src/sysnav_ws/install/setup.bash"
set -u

export PYTHONPATH="$ROOT/src/sysnav_ws/src/SysNav/src/semantic_mapping/semantic_mapping/external/sam2:${PYTHONPATH:-}"

exec python "$ROOT/tracking_deployment/scripts/sam2_tracking_mask_node.py" --ros-args \
  -p image_topic:="${TRACKING_IMAGE_TOPIC:-/camera/image/compressed}" \
  -p compressed_input:="${TRACKING_COMPRESSED_INPUT:-true}" \
  -p state_topic:="${TRACKING_STATE_TOPIC:-/tracking/target_state}" \
  -p output_topic:="${TRACKING_REFINED_MASK_TOPIC:-/tracking/target_mask_refined}" \
  -p sam2_repo:="$ROOT/src/sysnav_ws/src/SysNav/src/semantic_mapping/semantic_mapping/external/sam2" \
  -p checkpoint:="$ROOT/src/sysnav_ws/src/SysNav/src/semantic_mapping/semantic_mapping/external/sam2/checkpoints/sam2.1_hiera_base_plus.pt" \
  -p device:=cuda
