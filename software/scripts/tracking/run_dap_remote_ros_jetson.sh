#!/usr/bin/env bash
set -eo pipefail

ROOT="$HOME/lianaiwei"
source /opt/ros/humble/setup.bash
source "$ROOT/venvs/sysnav/bin/activate"
set -u
export PYTHONPATH="/opt/ros/humble/lib/python3.10/site-packages:${PYTHONPATH:-}"

exec python3 "$ROOT/tracking_deployment/scripts/dap_remote_ros_client.py" --ros-args \
  -p image_topic:="${DAP_IMAGE_TOPIC:-/camera/image/compressed}" \
  -p depth_topic:="${DAP_DEPTH_TOPIC:-/camera/depth_dap}" \
  -p server_host:="${DAP_SERVER_HOST:-login.example}" \
  -p server_port:="${DAP_SERVER_PORT:-18761}" \
  -p request_hz:="${DAP_REQUEST_HZ:-4.0}" \
  -p timeout_sec:="${DAP_TIMEOUT_SEC:-2.0}" \
  -p depth_scale:="${DAP_DEPTH_SCALE:-100.0}" \
  -p request_width:="${DAP_REQUEST_WIDTH:-1024}" \
  -p jpeg_quality:="${DAP_JPEG_QUALITY:-88}"
