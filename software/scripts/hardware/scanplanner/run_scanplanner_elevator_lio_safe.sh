#!/usr/bin/env bash
set -euo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/elevator_lio_ws/install/setup.bash"
source "$ROOT/src/scanplanner_ws/install/setup.bash"
set -u

unset ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT FASTDDS_BUILTIN_TRANSPORTS
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"

PLANNER_YAML="$(ros2 pkg prefix --share scan_planner)/config/planner.yaml"

for topic in /LIO/odom_vehicle /LIO/odom_imu /LIO/clouds_lidar; do
  if ! timeout 5 ros2 topic echo "$topic" --once >/dev/null 2>&1; then
    echo "required Elevator-LIO topic is unavailable: $topic" >&2
    exit 1
  fi
done

# Validation mode starts no controller and never publishes cmd_vel.
exec ros2 run scan_planner scan_planner_node --ros-args \
  --params-file "$PLANNER_YAML" \
  -p fsm.navi_mode:=1 \
  -p grid_map.sensor_type:=lidar \
  -p grid_map.cloud_is_world:=true \
  -p grid_map.need_extrinsic:=false \
  -r body_pose:=/LIO/odom_vehicle \
  -r sensor_pose:=/LIO/odom_imu \
  -r cloud:=/LIO/clouds_lidar \
  -r depth:=/validation/scanplanner_elevator/unused_depth \
  -r move_base_simple/goal:=/validation/scanplanner_elevator/goal \
  -r initial_path:=/validation/scanplanner_elevator/initial_path \
  -r planning/bspline:=/validation/scanplanner_elevator/bspline
