#!/usr/bin/env bash

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
WS="$ROOT/src/unitree_go2_ws"
GO2_IFACE="${GO2_IFACE:-eth0}"
GO2_ADDRESS="${GO2_ADDRESS:-192.168.123.99}"

_go2_restore_nounset=0
case "$-" in
  *u*) _go2_restore_nounset=1; set +u ;;
esac

source /opt/ros/humble/setup.bash
source "$WS/install/ros2_messages/setup.bash"
if [ -f "$WS/install/go2_bridge/setup.bash" ]; then
  source "$WS/install/go2_bridge/setup.bash"
fi
if [ -f "$WS/install/ros2_examples/setup.bash" ]; then
  source "$WS/install/ros2_examples/setup.bash"
fi

if [ "$_go2_restore_nounset" -eq 1 ]; then
  set -u
fi
unset _go2_restore_nounset

export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
export ROS_LOCALHOST_ONLY=0
export ROS2CLI_NO_DAEMON=1
export CYCLONEDDS_URI="<CycloneDDS><Domain><General><Interfaces><NetworkInterface address=\"$GO2_ADDRESS\" priority=\"default\" multicast=\"default\" /></Interfaces></General></Domain></CycloneDDS>"
export LD_LIBRARY_PATH="$WS/install/sdk2/lib:${LD_LIBRARY_PATH:-}"
