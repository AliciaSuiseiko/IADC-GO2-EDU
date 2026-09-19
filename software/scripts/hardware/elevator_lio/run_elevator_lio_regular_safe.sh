#!/usr/bin/env bash
set -euo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
CONFIG="${ELEVATOR_LIO_CONFIG:-root_mid360_go2.yaml}"

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/elevator_lio_ws/install/setup.bash"
set -u

unset ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT FASTDDS_BUILTIN_TRANSPORTS
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"

test -f "$(ros2 pkg prefix --share lio)/yaml/$CONFIG"
for topic in /livox/lidar /livox/imu; do
  if ! timeout 5 ros2 topic echo "$topic" --once >/dev/null 2>&1; then
    echo "required Mid-360 topic is unavailable: $topic" >&2
    exit 1
  fi
done

# Regular mode keeps elevator-specific constraints disabled until a dedicated test.
exec ros2 run lio lio --ros-args \
  -p config_path:="$CONFIG"
