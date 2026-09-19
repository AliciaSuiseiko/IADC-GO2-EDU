#!/usr/bin/env bash
set -euo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/scanplanner_ws/install/setup.bash"
set -u

PLANNER_YAML="$(ros2 pkg prefix --share scan_planner)/config/planner.yaml"

for topic in /Odometry_go2 /cloud_registered_go2_body; do
  if ! timeout 5 ros2 topic echo "$topic" --once >/dev/null 2>&1; then
    echo "required FAST-LIO2 topic is unavailable: $topic" >&2
    exit 1
  fi
done

# Validation mode deliberately starts no controller and publishes no cmd_vel.
exec ros2 run scan_planner scan_planner_node --ros-args \
  --params-file "$PLANNER_YAML" \
  -p fsm.navi_mode:=1 \
  -p grid_map.sensor_type:=lidar \
  -p grid_map.cloud_is_world:=false \
  -p grid_map.need_extrinsic:=false \
  -r body_pose:=/Odometry_go2 \
  -r sensor_pose:=/Odometry_go2 \
  -r cloud:=/cloud_registered_go2_body \
  -r depth:=/validation/scanplanner/unused_depth \
  -r move_base_simple/goal:=/validation/scanplanner/goal \
  -r initial_path:=/validation/scanplanner/initial_path \
  -r planning/bspline:=/validation/scanplanner/bspline
