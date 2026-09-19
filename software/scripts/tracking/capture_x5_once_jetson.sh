#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
RUN="$ROOT/runs/x5_live_20260901"
STATUS="$ROOT/status/x5_live.status"
X5_WS=/home/orin/lianaiwei/src/camera_x5_ws
CONFIG="$X5_WS/install/insta360_x5_sdk_ros2/share/insta360_x5_sdk_ros2/config/x5_sdk.yaml"
SAVER="$ROOT/scripts/save_ros_image_once.py"

mkdir -p "$RUN/logs" "$ROOT/status"
printf 'RUNNING\n' > "$STATUS"

camera_pid=
cleanup() {
    rc=$?
    if [[ -n "$camera_pid" ]]; then
        kill -INT "$camera_pid" 2>/dev/null || true
        sleep 1
        kill -TERM "$camera_pid" 2>/dev/null || true
        wait "$camera_pid" 2>/dev/null || true
    fi
    if (( rc != 0 )); then
        printf 'FAILED rc=%s log=%s\n' "$rc" "$RUN/logs/camera.log" > "$STATUS"
    fi
}
trap cleanup EXIT

if pgrep -af '[x]5_sdk_node|[x]5_media_stitcher|[x]5_panorama' > "$RUN/process-collisions.txt"; then
    printf 'X5 process already active\n' >&2
    exit 2
fi
lsusb | grep -q '2e1a:0002'

set +u
source /opt/ros/humble/setup.bash
source "$X5_WS/install/setup.bash"
set -u
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0

ros2 run insta360_x5_sdk_ros2 x5_sdk_node --ros-args \
    --params-file "$CONFIG" \
    > "$RUN/logs/camera.log" 2>&1 &
camera_pid=$!

/usr/bin/python3 "$SAVER" \
    --topic /camera/image \
    --output "$RUN/x5-live.jpg" \
    --timeout 30 \
    > "$RUN/logs/save.log" 2>&1

test -s "$RUN/x5-live.jpg"
/usr/bin/python3 - <<PY > "$RUN/result.txt"
import cv2
from pathlib import Path
p = Path("$RUN/x5-live.jpg")
x = cv2.imread(str(p))
print(f"shape={x.shape}")
print(f"bytes={p.stat().st_size}")
PY

printf 'COMPLETE image=%s\n' "$RUN/x5-live.jpg" > "$STATUS"
trap - EXIT
kill -INT "$camera_pid" 2>/dev/null || true
wait "$camera_pid" 2>/dev/null || true
