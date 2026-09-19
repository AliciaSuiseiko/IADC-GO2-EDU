#!/usr/bin/env bash
set -euo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"

if [[ $# -ne 0 ]]; then
  echo "usage: $0" >&2
  echo "the active pipeline is fixed to Elevator-LIO" >&2
  exit 2
fi

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/scanplanner_ws/install/setup.bash"
set -u

unset ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT FASTDDS_BUILTIN_TRANSPORTS
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"

PLANNER_YAML="$(ros2 pkg prefix --share scan_planner)/config/planner.yaml"

BODY_POSE=/LIO/odom_vehicle
SENSOR_POSE=/LIO/odom_imu
CLOUD=/LIO/clouds_lidar
CLOUD_IS_WORLD=true

for topic in "$BODY_POSE" "$SENSOR_POSE" "$CLOUD"; do
  if ! timeout 5 ros2 topic echo "$topic" --once >/dev/null 2>&1; then
    echo "required Elevator-LIO topic is unavailable: $topic" >&2
    exit 1
  fi
done

if ros2 node list 2>/dev/null | grep -qx '/closed_loop_controller'; then
  echo "refusing preview while /closed_loop_controller is running" >&2
  exit 3
fi
if ros2 node list 2>/dev/null | grep -qx '/open_loop_controller'; then
  echo "refusing preview while /open_loop_controller is running" >&2
  exit 3
fi

echo "SCAN-Planner RViz preview: Elevator-LIO"
echo "goal input: /move_base_simple/goal"
echo "trajectory output: /planning/bspline"
echo "controller: DISABLED (this process does not publish /cmd_vel)"

exec ros2 run scan_planner scan_planner_node --ros-args \
  --params-file "$PLANNER_YAML" \
  -p fsm.navi_mode:=1 \
  -p grid_map.sensor_type:=lidar \
  -p grid_map.cloud_is_world:="$CLOUD_IS_WORLD" \
  -p grid_map.need_extrinsic:=false \
  -r body_pose:="$BODY_POSE" \
  -r sensor_pose:="$SENSOR_POSE" \
  -r cloud:="$CLOUD" \
  -r depth:=/scanplanner/unused_depth \
  -r move_base_simple/goal:=/move_base_simple/goal \
  -r initial_path:=/initial_path \
  -r planning/bspline:=/planning/bspline
