#!/usr/bin/env bash
set -Eeo pipefail

ROOT="$HOME/lianaiwei"
TRACKING_ROOT="$ROOT/tracking_deployment"
RUN="$TRACKING_ROOT/runs/panorama-long-term-sot-uvc-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"

tracker_pid=""
camera_pid=""
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  for pid in "${camera_pid:-}" "${tracker_pid:-}"; do
    if [[ -n "$pid" ]]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
    fi
  done
  sleep 2
  for pid in "${camera_pid:-}" "${tracker_pid:-}"; do
    if [[ -n "$pid" ]]; then
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  pgrep -af 'panorama_long_term_sot_node.py|receiveX5' \
    >"$RUN/remaining-processes.txt" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

source /opt/ros/humble/setup.bash
source "$ROOT/src/sysnav_ws/install/setup.bash"
set -u
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
ros2 daemon stop >/dev/null 2>&1 || true

if pgrep -af 'panorama_long_term_sot_node.py|receiveX5|x5_sdk_node' \
  >"$RUN/process-collisions.txt" 2>/dev/null; then
  echo "tracking or X5 process already active" >&2
  exit 2
fi
if ! lsusb | grep -q '2e1a:0005'; then
  echo "X5 is not connected in Webcam/UVC mode" >&2
  exit 3
fi
if ros2 topic info /cmd_vel 2>/dev/null | grep -qE 'Publisher count: [1-9]'; then
  echo "refusing smoke test while /cmd_vel has an active publisher" >&2
  exit 4
fi

setsid env TRACKING_IMAGE_TOPIC=/camera/image/compressed TRACKING_COMPRESSED_INPUT=true \
  "$TRACKING_ROOT/scripts/run_panorama_long_term_sot_jetson.sh" \
  >"$RUN/tracker.log" 2>&1 &
tracker_pid=$!
for _ in $(seq 1 90); do
  kill -0 "$tracker_pid" 2>/dev/null || {
    tail -100 "$RUN/tracker.log" >&2
    exit 5
  }
  grep -q 'Ready; initialize' "$RUN/tracker.log" && break
  sleep 1
done
grep -q 'Ready; initialize' "$RUN/tracker.log"

setsid ros2 launch receive_x5 receive_x5_tracking.launch \
  >"$RUN/camera.log" 2>&1 &
camera_pid=$!
for _ in $(seq 1 45); do
  kill -0 "$camera_pid" 2>/dev/null || {
    tail -100 "$RUN/camera.log" >&2
    exit 6
  }
  grep -q 'Publishing 1920x960' "$RUN/camera.log" && break
  sleep 1
done

if [[ -n "${TRACKING_INIT_BBOX:-}" ]]; then
  sleep 2
  ros2 topic pub --once /tracking/initialize_target std_msgs/msg/String \
    "{data: '${TRACKING_INIT_BBOX}'}" >"$RUN/initialize-target.txt" 2>&1
fi

sleep 15
grep 'Published .* FPS' "$RUN/camera.log" >"$RUN/camera-hz.txt" 2>&1 || true
timeout 20 ros2 topic echo /tracking/diagnostics --once --full-length \
  >"$RUN/diagnostics.txt" 2>&1 || true
timeout 20 python3 "$ROOT/scripts/save_ros_image_once.py" \
  --topic /tracking/annotated_image --output "$RUN/annotated.jpg" --timeout 15 \
  >"$RUN/capture.log" 2>&1 || true
timeout 5 tegrastats --interval 1000 >"$RUN/tegrastats.txt" 2>&1 || true
ros2 topic info /cmd_vel >"$RUN/cmd-vel-info.txt" 2>&1 || true

grep -q 'Validated stitched ERP input: 1920x960' "$RUN/tracker.log"
printf 'COMPLETE run=%s\n' "$RUN"
