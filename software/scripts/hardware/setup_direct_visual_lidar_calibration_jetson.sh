#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$HOME/lianaiwei"
WS="$ROOT/src/direct_visual_lidar_calibration_ws"
PREFIX="$ROOT/deps/direct_visual_lidar_calibration"

test -f "$WS/src/direct_visual_lidar_calibration/package.xml" || {
  echo "missing source: $WS/src/direct_visual_lidar_calibration" >&2
  exit 2
}
test -f "$PREFIX/lib/cmake/iridescence/iridescence-config.cmake" || {
  echo "missing user-local Iridescence install: $PREFIX" >&2
  exit 3
}

set +u
source /opt/ros/humble/setup.bash
set -u

export CMAKE_PREFIX_PATH="$PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$PREFIX/lib:/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cd "$WS"
colcon build \
  --packages-select direct_visual_lidar_calibration \
  --cmake-args \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$PREFIX"

set +u
source "$WS/install/setup.bash"
set -u
ros2 pkg executables direct_visual_lidar_calibration
