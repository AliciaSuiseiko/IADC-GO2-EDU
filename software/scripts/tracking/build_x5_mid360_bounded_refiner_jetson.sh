#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
SOURCE=/home/orin/lianaiwei/src/direct_visual_lidar_calibration_ws/src/direct_visual_lidar_calibration
WS="$ROOT/src/x5_mid360_bounded_refiner_ws"
PATCH="$ROOT/scripts/x5_mid360_bounded_refiner.patch"
OUTER_PATCH="$ROOT/scripts/x5_mid360_single_outer_loop.patch"
BOUND_PATCH="$ROOT/scripts/x5_mid360_global_bound.patch"
RUN="$ROOT/runs/x5_mid360_bounded_refiner_build_20260901"

mkdir -p "$WS/src" "$RUN"
if [[ ! -d "$WS/src/direct_visual_lidar_calibration" ]]; then
    cp -a "$SOURCE" "$WS/src/direct_visual_lidar_calibration"
fi
if ! grep -q 'max_outer_iterations = 1' "$WS/src/direct_visual_lidar_calibration/include/vlcal/calib/visual_camera_calibration.hpp"; then
    patch -d "$WS/src/direct_visual_lidar_calibration" -p1 < "$PATCH"
fi
if ! grep -q 'for (int i = 0; i < 1; i++)' "$WS/src/direct_visual_lidar_calibration/src/vlcal/calib/visual_camera_calibration.cpp"; then
    patch -d "$WS/src/direct_visual_lidar_calibration" -p1 < "$OUTER_PATCH"
fi
if ! grep -q 'delta.translation().norm() > 0.05' "$WS/src/direct_visual_lidar_calibration/src/vlcal/calib/visual_camera_calibration.cpp"; then
    patch -d "$WS/src/direct_visual_lidar_calibration" -p1 < "$BOUND_PATCH"
fi

set +u
source /opt/ros/humble/setup.bash
source /home/orin/lianaiwei/src/direct_visual_lidar_calibration_ws/install/setup.bash
set -u

cd "$WS"
colcon build \
    --packages-select direct_visual_lidar_calibration \
    --cmake-args \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH=/home/orin/lianaiwei/deps/direct_visual_lidar_calibration \
    >"$RUN/build.log" 2>&1

test -x "$WS/install/direct_visual_lidar_calibration/lib/direct_visual_lidar_calibration/calibrate"
printf 'COMPLETE workspace=%s\n' "$WS" > "$RUN/status"
