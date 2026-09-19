#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
YAW_DEG="${1:-0.0}"
ODOM_TOPIC="${2:-/state_estimation}"

if pgrep -af '[/]x5_forward_center_view.py' >/dev/null; then
    echo "x5 forward-centered view is already running" >&2
    exit 2
fi
[[ "$YAW_DEG" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
[[ "$ODOM_TOPIC" =~ ^/[A-Za-z0-9_/]+$ ]]

set +u
source /opt/ros/humble/setup.bash
source /home/orin/lianaiwei/src/fastlio2_ws/install/setup.bash
source /home/orin/lianaiwei/src/camera_x5_ws/install/setup.bash
set -u
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0

exec python3 "$ROOT/scripts/x5_forward_center_view.py" --ros-args \
    -p input_topic:=/camera/image \
    -p output_topic:=/camera/image_forward_centered \
    -p source_forward_yaw_deg:="$YAW_DEG" \
    -p follow_odometry:=true \
    -p odom_topic:="$ODOM_TOPIC"
