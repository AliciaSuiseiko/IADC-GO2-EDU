#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$HOME/lianaiwei"
RUN_DIR="$ROOT/logs/x5-spatial-calibration-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"

camera_pid=""
receiver_pid=""
tunnel_pid=""
job_id=""

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  kill -INT "${receiver_pid:-}" "${camera_pid:-}" 2>/dev/null || true
  sleep 2
  kill -TERM "${receiver_pid:-}" "${camera_pid:-}" 2>/dev/null || true
  wait "${receiver_pid:-}" "${camera_pid:-}" 2>/dev/null || true
  [[ -r "$RUN_DIR/hkust-tunnel.pid" ]] && tunnel_pid="$(cat "$RUN_DIR/hkust-tunnel.pid")"
  [[ -n "$tunnel_pid" ]] && kill "$tunnel_pid" 2>/dev/null || true
  if [[ -r "$RUN_DIR/server-job.env" ]]; then
    job_id="$(awk -F= '$1 == "job_id" {print $2}' "$RUN_DIR/server-job.env")"
  fi
  if [[ -n "$job_id" ]]; then
    ssh -i "$HOME/.ssh/id_ed25519" -o BatchMode=yes -o ConnectTimeout=8 \
      robot@login.example "scancel '$job_id'" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

pgrep -af 'x5_sdk_node|x5_panorama_tcp_receiver' >"$RUN_DIR/process-collisions.txt" 2>/dev/null && {
  echo "an X5 camera or panorama receiver process is already running" >&2
  exit 2
}
lsusb | grep -q '2e1a:0002' || {
  echo "Insta360 X5 is not visible in CameraSDK mode" >&2
  exit 3
}

X5_CALIBRATION_RUN_DIR="$RUN_DIR" \
  "$ROOT/scripts/calibration/start_x5_stitch_calibration_link.sh" \
  | tee "$RUN_DIR/link.log"

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/camera_x5_ws/install/setup.bash"
set -u
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0

X5_TCP_SERVER=127.0.0.1 python3 "$ROOT/scripts/x5_panorama_tcp_receiver.py" \
  >"$RUN_DIR/panorama-receiver.log" 2>&1 &
receiver_pid=$!

ros2 run insta360_x5_sdk_ros2 x5_sdk_node --ros-args \
  --params-file "$ROOT/src/camera_x5_ws/install/insta360_x5_sdk_ros2/share/insta360_x5_sdk_ros2/config/x5_sdk.yaml" \
  --params-file "$ROOT/scripts/sysnav/x5_sysnav.yaml" \
  >"$RUN_DIR/x5-camera.log" 2>&1 &
camera_pid=$!

for _ in $(seq 1 45); do
  kill -0 "$camera_pid" "$receiver_pid" 2>/dev/null || break
  if timeout 8 ros2 topic echo /camera/image --once --no-arr >/dev/null 2>&1; then
    echo "Official stitched X5 panorama is available on /camera/image"
    echo "Logs: $RUN_DIR"
    wait "$camera_pid" "$receiver_pid"
    exit
  fi
  sleep 1
done

tail -40 "$RUN_DIR/x5-camera.log" >&2 || true
tail -40 "$RUN_DIR/panorama-receiver.log" >&2 || true
echo "stitched X5 panorama did not become ready" >&2
exit 4
