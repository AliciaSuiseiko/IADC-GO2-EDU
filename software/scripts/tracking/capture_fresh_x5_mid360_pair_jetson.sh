#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
POSE_ID="${1:-pose01}"
if [[ ! "$POSE_ID" =~ ^pose[0-9][0-9]$ ]]; then
    echo "Usage: $0 poseNN" >&2
    exit 2
fi
POSE_NUMBER="${POSE_ID#pose}"
ATTEMPT="${2:-}"
if [[ -n "$ATTEMPT" && ! "$ATTEMPT" =~ ^retry[0-9]+$ ]]; then
    echo "Usage: $0 poseNN [retryN]" >&2
    exit 2
fi
RUN_SUFFIX="$POSE_ID${ATTEMPT:+_$ATTEMPT}"
RUN="$ROOT/runs/fresh_x5_mid360_20260901_$RUN_SUFFIX"
BAGS="$RUN/bags"
BAG_NAME="pose-live-$POSE_NUMBER"
BAG="$BAGS/$BAG_NAME"
PREPROCESSED="$RUN/preprocessed"
STATUS="$RUN/status"
LIDAR_LAUNCH="$ROOT/scripts/mid360_pointcloud2_launch.py"
CAMERA_DRIVER=/home/orin/lianaiwei/scripts/calibration/run_x5_stitched_calibration_camera.sh

mkdir -p "$RUN/logs" "$BAGS"
printf 'RUNNING started=%s\n' "$(date -Is)" > "$STATUS"

lidar_pid=
camera_pid=
recorder_pid=
stop_group() {
    local pid="${1:-}"
    [[ -n "$pid" ]] || return 0
    kill -INT -- "-$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done
    kill -TERM -- "-$pid" 2>/dev/null || true
    sleep 2
    kill -KILL -- "-$pid" 2>/dev/null || true
}
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    stop_group "$recorder_pid"
    stop_group "$camera_pid"
    stop_group "$lidar_pid"
    if (( rc != 0 )); then
        printf 'FAILED rc=%s lidar_log=%s camera_log=%s\n' \
            "$rc" "$RUN/logs/lidar.log" "$RUN/logs/camera.log" > "$STATUS"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

[[ ! -e "$BAG" ]]
[[ ! -e "$PREPROCESSED" ]]
lsusb | grep -q '2e1a:0002'
ping -c 1 -W 1 192.168.1.148 >/dev/null
if ps -eo args | grep -q '[/]livox_ros_driver2_node'; then
    echo "Livox driver already active" >&2
    exit 2
fi
if ps -eo args | grep -Eq '[/]x5_sdk_node|[/]x5_media_stitcher_node|[/]x5_panorama_tcp_receiver.py'; then
    echo "X5 process already active" >&2
    exit 2
fi

setsid bash -lc "source /opt/ros/humble/setup.bash; source /home/orin/lianaiwei/src/fastlio2_ws/install/setup.bash; exec ros2 launch '$LIDAR_LAUNCH'" \
    > "$RUN/logs/lidar.log" 2>&1 < /dev/null &
lidar_pid=$!

setsid "$CAMERA_DRIVER" > "$RUN/logs/camera.log" 2>&1 < /dev/null &
camera_pid=$!

set +u
source /opt/ros/humble/setup.bash
source /home/orin/lianaiwei/src/fastlio2_ws/install/setup.bash
source /home/orin/lianaiwei/src/camera_x5_ws/install/setup.bash
set -u
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0

for _ in $(seq 1 120); do
    kill -0 "$lidar_pid" "$camera_pid" 2>/dev/null || break
    image_type="$(ros2 topic type /camera/image 2>/dev/null || true)"
    points_type="$(ros2 topic type /livox/lidar 2>/dev/null || true)"
    if [[ "$image_type" == sensor_msgs/msg/Image && "$points_type" == sensor_msgs/msg/PointCloud2 ]]; then
        break
    fi
    sleep 1
done
[[ "$(ros2 topic type /camera/image)" == sensor_msgs/msg/Image ]]
[[ "$(ros2 topic type /livox/lidar)" == sensor_msgs/msg/PointCloud2 ]]

image_info="$(ros2 topic info /camera/image --verbose)"
grep -q '^Node name: x5_panorama_tcp_receiver$' <<< "$image_info"
image_sample="$(timeout 8 ros2 topic echo /camera/image --once --no-arr)"
width="$(awk '$1 == "width:" {print $2; exit}' <<< "$image_sample")"
height="$(awk '$1 == "height:" {print $2; exit}' <<< "$image_sample")"
[[ "$width" == 1920 && "$height" == 960 ]]
timeout 8 ros2 topic echo /livox/lidar --once >/dev/null

setsid ros2 bag record -o "$BAG" /camera/image /livox/lidar \
    > "$RUN/logs/record.log" 2>&1 < /dev/null &
recorder_pid=$!
for _ in $(seq 1 30); do
    kill -0 "$recorder_pid" 2>/dev/null || break
    [[ -d "$BAG" ]] && find "$BAG" -maxdepth 1 -type f -name '*.db3' -print -quit | grep -q . && break
    sleep 1
done
kill -0 "$recorder_pid"
find "$BAG" -maxdepth 1 -type f -name '*.db3' -print -quit | grep -q .
sleep 15
kill -INT -- "-$recorder_pid" 2>/dev/null || true
for _ in $(seq 1 30); do
    kill -0 "$recorder_pid" 2>/dev/null || break
    sleep 1
done
if kill -0 "$recorder_pid" 2>/dev/null; then
    echo "ros2 bag recorder did not stop cleanly" >&2
    exit 3
fi
wait "$recorder_pid" || [[ $? -eq 130 ]]
recorder_pid=
[[ -f "$BAG/metadata.yaml" ]]
ros2 bag info "$BAG" > "$RUN/bag-info.txt"

stop_group "$camera_pid"
camera_pid=
stop_group "$lidar_pid"
lidar_pid=

set +u
source /home/orin/lianaiwei/scripts/calibration/activate_direct_visual_lidar_calibration.sh
set -u
ros2 run direct_visual_lidar_calibration preprocess \
    "$BAGS" "$PREPROCESSED" \
    --image_topic /camera/image \
    --points_topic /livox/lidar \
    --camera_model equirectangular \
    --intensity_channel intensity \
    --voxel_resolution 0.01 \
    --min_distance 0.5 \
    > "$RUN/logs/preprocess.log" 2>&1

[[ -s "$PREPROCESSED/$BAG_NAME.png" ]]
[[ -s "$PREPROCESSED/$BAG_NAME.ply" ]]
printf 'COMPLETE bag=%s preprocessed=%s finished=%s\n' \
    "$BAG" "$PREPROCESSED" "$(date -Is)" > "$STATUS"
trap - EXIT
