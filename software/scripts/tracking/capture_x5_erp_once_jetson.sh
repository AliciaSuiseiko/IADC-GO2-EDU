#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
RUN="$ROOT/runs/x5_erp_live_20260901"
STATUS="$ROOT/status/x5_erp_live.status"
DRIVER=/home/orin/lianaiwei/scripts/calibration/run_x5_stitched_calibration_camera.sh
SAVER="$ROOT/scripts/save_ros_image_once.py"

mkdir -p "$RUN/logs" "$ROOT/status"
printf 'RUNNING\n' > "$STATUS"

driver_pid=
cleanup() {
    rc=$?
    if [[ -n "$driver_pid" ]]; then
        kill -TERM "$driver_pid" 2>/dev/null || true
        for _ in $(seq 1 15); do
            kill -0 "$driver_pid" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$driver_pid" 2>/dev/null || true
        wait "$driver_pid" 2>/dev/null || true
    fi
    if (( rc != 0 )); then
        printf 'FAILED rc=%s driver_log=%s\n' "$rc" "$RUN/logs/driver.log" > "$STATUS"
    fi
}
trap cleanup EXIT

if pgrep -af '[x]5_sdk_node|[x]5_media_stitcher|[x]5_panorama' > "$RUN/process-collisions.txt"; then
    printf 'X5 process already active\n' >&2
    exit 2
fi
lsusb | grep -q '2e1a:0002'

setsid "$DRIVER" > "$RUN/logs/driver.log" 2>&1 &
driver_pid=$!

set +u
source /opt/ros/humble/setup.bash
source /home/orin/lianaiwei/src/camera_x5_ws/install/setup.bash
set -u
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0

/usr/bin/python3 "$SAVER" \
    --topic /camera/image \
    --output "$RUN/x5-erp-live.jpg" \
    --timeout 180 \
    > "$RUN/logs/save.log" 2>&1

test -s "$RUN/x5-erp-live.jpg"
/usr/bin/python3 - <<PY > "$RUN/result.txt"
import cv2
from pathlib import Path
p = Path("$RUN/x5-erp-live.jpg")
x = cv2.imread(str(p))
print(f"shape={x.shape}")
print(f"bytes={p.stat().st_size}")
PY

kill -TERM "$driver_pid" 2>/dev/null || true
for _ in $(seq 1 20); do
    kill -0 "$driver_pid" 2>/dev/null || break
    sleep 1
done
kill -KILL "$driver_pid" 2>/dev/null || true
wait "$driver_pid" 2>/dev/null || true
driver_pid=

printf 'COMPLETE image=%s\n' "$RUN/x5-erp-live.jpg" > "$STATUS"
trap - EXIT
