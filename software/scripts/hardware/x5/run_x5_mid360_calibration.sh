#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/lianaiwei"
WS="$ROOT/src/camera_x5_ws"
MODE="${1:-}"
DATA="$WS/src/360_camera_calibration/src/extrinsic_latency_calib/data"
DATA_PARAMETER_BASE="$WS/src/360_camera_calibration/install/extrinsic_latency_calib/data"

usage() {
  echo "usage: $0 {extrinsic|latency-session|latency-verify|latency-record|latency-analyze}" >&2
  exit 2
}

[[ -n "$MODE" ]] || usage
mkdir -p "$DATA"

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/fastlio2_ws/install/setup.bash"
source "$ROOT/src/elevator_lio_ws/install/setup.bash"
source "$WS/install/setup.bash"
set -u
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0

case "$MODE" in
  latency-session)
    source "$ROOT/scripts/hardware/nomachine/nomachine-session-env.sh"
    exec ros2 launch "$ROOT/scripts/x5/x5_mid360_latency.launch.py"
    ;;
  latency-verify)
    source "$ROOT/scripts/hardware/nomachine/nomachine-session-env.sh"
    exec ros2 launch "$ROOT/scripts/x5/x5_mid360_latency.launch.py" \
      timestamp_delay_sec:=0.218
    ;;
  extrinsic)
    timeout 5 ros2 topic echo /camera/image --once >/dev/null
    timeout 5 ros2 topic echo /registered_scan --once >/dev/null
    timeout 5 ros2 topic echo /state_estimation --once >/dev/null
    exec ros2 run extrinsic_latency_calib extrinsicCalib --ros-args \
      -r /laser_odometry:=/state_estimation \
      -p minRange:=0.5 -p maxRange:=10.0 -p angAdjustment:=0.01 \
      -p voxelSize:=0.02 -p imageSkipYaw:=10.0 -p imageSkipNum:=2 \
      -p camRoll:=-1.5707963 -p camPitch:=0.0 -p camYaw:=-1.5707963 \
      -p camX:=-0.32 -p camY:=0.0 -p camZ:=0.31 \
      -p is360Cam:=true -p imageWidth:=1920 -p imageHeight:=640
    ;;
  latency-record)
    timeout 5 ros2 topic echo /camera/image --once >/dev/null
    timeout 5 ros2 topic echo /livox/imu --once >/dev/null
    exec ros2 run extrinsic_latency_calib latencyCalib --ros-args \
      -r /imu/data:=/livox/imu \
      -p imu_save_dir:="$DATA_PARAMETER_BASE/imu_latency.txt" \
      -p image_save_dir:="$DATA_PARAMETER_BASE/image_latency.txt" \
      -p resizeImageWidth:=960 -p maxTrackDis:=100.0 -p boundary:=20
    ;;
  latency-analyze)
    [[ -s "$DATA/imu_latency.txt" && -s "$DATA/image_latency.txt" ]] || {
      echo "latency samples are missing; run latency-session while rotating the rig" >&2
      exit 3
    }
    source "$ROOT/scripts/hardware/nomachine/nomachine-session-env.sh"
    cd "$WS/src/360_camera_calibration/src/extrinsic_latency_calib/script"
    exec python3 latencyCalib.py
    ;;
  *) usage ;;
esac
