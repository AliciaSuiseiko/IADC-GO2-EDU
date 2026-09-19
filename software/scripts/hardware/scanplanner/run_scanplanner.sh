#!/usr/bin/env bash
set -euo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
MODE="${1:-real}"
shift || true

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/scanplanner_ws/install/setup.bash"
set -u

# SCAN-Planner's robot description invokes xacro as an executable.
export PATH="$ROOT/envs/ros-tools/bin:$PATH"

case "$MODE" in
  real)
    IS_REAL_WORLD=true
    ;;
  sim)
    IS_REAL_WORLD=false
    ;;
  *)
    echo "usage: $0 {real|sim} [ros2 launch arguments...]" >&2
    exit 2
    ;;
esac

exec ros2 launch scan_planner run.launch.py \
  "is_real_world:=$IS_REAL_WORLD" \
  navi_mode:=1 \
  sensor_type:=lidar \
  controller_mode:=closed_loop \
  use_gpu:=false \
  "$@"
