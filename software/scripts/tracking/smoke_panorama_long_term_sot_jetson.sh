#!/usr/bin/env bash
set -eo pipefail

MODE="${1:-erp}"
if [[ "${MODE}" != "erp" && "${MODE}" != "dual" ]]; then
  echo "usage: $0 [erp|dual]" >&2
  exit 2
fi

ROOT="${HOME}/lianaiwei"
TRACKING_ROOT="${ROOT}/tracking_deployment"
RUN="${TRACKING_ROOT}/runs/panorama-long-term-sot-smoke-$(date +%Y%m%d-%H%M%S)-${MODE}"
mkdir -p "${RUN}"
touch "${RUN}/start.marker"

source /opt/ros/humble/setup.bash
source "${ROOT}/src/camera_x5_ws/install/setup.bash"
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
set -u
ros2 daemon stop >/dev/null 2>&1 || true

tracker_pid=""
camera_pid=""
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  for pid in "${camera_pid:-}" "${tracker_pid:-}"; do
    if [[ -n "${pid}" ]]; then
      kill -TERM -- "-${pid}" 2>/dev/null || true
    fi
  done
  while IFS= read -r job_env; do
    job_id="$(awk -F= '$1 == "job_id" {print $2}' "${job_env}")"
    if [[ -n "${job_id}" ]]; then
      ssh -i "${HOME}/.ssh/id_ed25519" -o BatchMode=yes -o ConnectTimeout=8 \
        robot@login.example "scancel '${job_id}'" 2>/dev/null || true
    fi
  done < <(
    find "${ROOT}/logs" -maxdepth 2 -type f -name server-job.env \
      -newer "${RUN}/start.marker" 2>/dev/null
  )
  sleep 2
  for pid in "${camera_pid:-}" "${tracker_pid:-}"; do
    if [[ -n "${pid}" ]]; then
      kill -KILL -- "-${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  pgrep -af 'panorama_long_term_sot_node.py|x5_sdk_node|x5_panorama_tcp_receiver' \
    >"${RUN}/remaining-processes.txt" 2>/dev/null || true
  exit "${rc}"
}
trap cleanup EXIT INT TERM

if pgrep -af 'panorama_long_term_sot_node.py|x5_sdk_node|x5_panorama_tcp_receiver' \
  >"${RUN}/process-collisions.txt" 2>/dev/null; then
  echo "tracking or X5 process already active" >&2
  exit 3
fi
if ! lsusb | grep -q '2e1a:0002'; then
  echo "X5 is not connected in CameraSDK mode" >&2
  exit 4
fi
if ros2 topic info /cmd_vel 2>/dev/null | grep -qE 'Publisher count: [1-9]'; then
  echo "refusing smoke test while /cmd_vel has an active publisher" >&2
  exit 5
fi

setsid "${TRACKING_ROOT}/scripts/run_panorama_long_term_sot_jetson.sh" \
  >"${RUN}/tracker.log" 2>&1 &
tracker_pid=$!
for _ in $(seq 1 60); do
  kill -0 "${tracker_pid}" 2>/dev/null || {
    tail -80 "${RUN}/tracker.log" >&2
    exit 6
  }
  grep -q 'Ready; initialize' "${RUN}/tracker.log" && break
  sleep 1
done
grep -q 'Ready; initialize' "${RUN}/tracker.log" || {
  tail -80 "${RUN}/tracker.log" >&2
  exit 7
}

if [[ "${MODE}" == "dual" ]]; then
  CONFIG="${ROOT}/src/camera_x5_ws/install/insta360_x5_sdk_ros2/share/insta360_x5_sdk_ros2/config/x5_sdk.yaml"
  setsid ros2 run insta360_x5_sdk_ros2 x5_sdk_node --ros-args \
    --params-file "${CONFIG}" >"${RUN}/camera.log" 2>&1 &
else
  setsid "${ROOT}/scripts/calibration/run_x5_stitched_calibration_camera.sh" \
    >"${RUN}/camera.log" 2>&1 &
fi
camera_pid=$!

for _ in $(seq 1 150); do
  kill -0 "${camera_pid}" 2>/dev/null || {
    tail -100 "${RUN}/camera.log" >&2
    exit 8
  }
  if [[ "${MODE}" == "dual" ]] && grep -q 'Publishing decoded X5 frames' "${RUN}/camera.log"; then
    break
  fi
  if [[ "${MODE}" == "erp" ]] && grep -q 'Official stitched X5 panorama is available' "${RUN}/camera.log"; then
    break
  fi
  sleep 1
done

sleep 3
timeout 12 ros2 topic hz /camera/image >"${RUN}/camera-hz.txt" 2>&1 || true

timeout 20 ros2 topic echo /tracking/target_state --once --full-length \
  >"${RUN}/target-state.txt" 2>&1 || true
timeout 20 ros2 topic echo /tracking/diagnostics --once --full-length \
  >"${RUN}/diagnostics.txt" 2>&1 || true
ros2 topic list --no-daemon | sort >"${RUN}/topics.txt"
ros2 topic info /cmd_vel >"${RUN}/cmd-vel-info.txt" 2>&1 || true

if [[ "${MODE}" == "dual" ]]; then
  grep -q 'Rejected /camera/image' "${RUN}/tracker.log" || {
    echo "dual-fisheye input was not rejected" >&2
    exit 9
  }
else
  grep -q 'Validated stitched ERP input: 1920x960' "${RUN}/tracker.log" || {
    echo "stitched ERP input was not validated" >&2
    exit 10
  }
fi

printf 'COMPLETE mode=%s run=%s\n' "${MODE}" "${RUN}"
