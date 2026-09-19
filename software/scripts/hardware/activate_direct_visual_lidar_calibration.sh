#!/usr/bin/env bash

VLCAL_ROOT="$HOME/lianaiwei"
VLCAL_WS="$VLCAL_ROOT/src/direct_visual_lidar_calibration_ws"
VLCAL_PREFIX="$VLCAL_ROOT/deps/direct_visual_lidar_calibration"

set +u
source /opt/ros/humble/setup.bash
source "$VLCAL_WS/install/setup.bash"
set -u

export CMAKE_PREFIX_PATH="$VLCAL_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$VLCAL_PREFIX/lib:/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export VLCAL_ROOT VLCAL_WS VLCAL_PREFIX
