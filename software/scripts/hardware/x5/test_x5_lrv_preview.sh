#!/usr/bin/env bash
set -Eeo pipefail

ROOT="$HOME/lianaiwei"
RUN="$ROOT/logs/x5-lrv-preview-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"

camera_pid=""
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ -n "$camera_pid" ]]; then
    kill -INT -- "-$camera_pid" 2>/dev/null || true
    sleep 2
    kill -TERM -- "-$camera_pid" 2>/dev/null || true
    wait "$camera_pid" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

source /opt/ros/humble/setup.bash
source "$ROOT/src/camera_x5_ws/install/setup.bash"
set -u
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0

if pgrep -af 'x5_sdk_node' >"$RUN/process-collisions.txt" 2>/dev/null; then
  echo "an X5 CameraSDK node is already running" >&2
  exit 2
fi
if ! lsusb | grep -q '2e1a:0002'; then
  echo "X5 is not connected in CameraSDK mode" >&2
  exit 3
fi
if ros2 topic info /cmd_vel 2>/dev/null | grep -qE 'Publisher count: [1-9]'; then
  echo "refusing test while /cmd_vel has an active publisher" >&2
  exit 4
fi

setsid ros2 run insta360_x5_sdk_ros2 x5_sdk_node --ros-args \
  -p source_resolution:=1440x720 \
  -p source_bitrate:=524288 \
  -p using_lrv:=true \
  -p enable_in_camera_stitching:=true \
  -p stitch_transport_enabled:=false \
  -p output_width:=1024 \
  -p output_height:=512 \
  -p output_fps:=10.0 \
  -p publish_raw:=true \
  -p raw_topic:=/camera/x5_lrv/image \
  -p compressed_topic:=/camera/x5_lrv/image/compressed \
  >"$RUN/camera.log" 2>&1 &
camera_pid=$!

for _ in $(seq 1 60); do
  kill -0 "$camera_pid" 2>/dev/null || {
    tail -80 "$RUN/camera.log" >&2
    exit 5
  }
  grep -q 'Publishing decoded X5 frames' "$RUN/camera.log" && break
  sleep 1
done

python3 "$ROOT/scripts/save_ros_image_once.py" \
  --topic /camera/x5_lrv/image --output "$RUN/frame.jpg" --timeout 20 \
  >"$RUN/capture.log" 2>&1
timeout 12 ros2 topic hz /camera/x5_lrv/image >"$RUN/camera-hz.txt" 2>&1 || true
ros2 topic info /cmd_vel >"$RUN/cmd-vel-info.txt" 2>&1 || true
printf 'COMPLETE run=%s\n' "$RUN"
