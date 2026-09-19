#!/usr/bin/env bash
set -euo pipefail

ROOT="${HOME}/lianaiwei"
SCRIPT_DIR="${ROOT}/scripts/sysnav"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${ROOT}/logs/sysnav-standalone-preview-${STAMP}"
LAUNCH_PID=""

cleanup() {
  if [[ -n "${LAUNCH_PID}" ]] && kill -0 "${LAUNCH_PID}" 2>/dev/null; then
    kill -- "-${LAUNCH_PID}" 2>/dev/null || kill "${LAUNCH_PID}" 2>/dev/null || true
    sleep 2
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "${LOG_DIR}"
set +u
source /opt/ros/humble/setup.bash
source "${ROOT}/src/elevator_lio_ws/install/setup.bash"
source "${ROOT}/src/sysnav_ws/install/setup.bash"
source "${ROOT}/src/sysnav_ws/install-standalone-preview/setup.bash"
set -u

if pgrep -af 'pathFollower' | grep -v grep >"${LOG_DIR}/path_follower.preflight"; then
  echo "Refusing preview: a pathFollower process is already running." >&2
  exit 2
fi

setsid ros2 launch "${SCRIPT_DIR}/sysnav_standalone_preview.launch.py" \
  map_file:="${LOG_DIR}/pointcloud_local.txt" \
  start_planner:=true >"${LOG_DIR}/launch.log" 2>&1 &
LAUNCH_PID=$!
echo "${LAUNCH_PID}" >"${LOG_DIR}/launch.pid"

sleep 8
if ! kill -0 "${LAUNCH_PID}" 2>/dev/null; then
  echo "SysNav standalone launch exited during startup." >&2
  tail -n 80 "${LOG_DIR}/launch.log" >&2
  exit 3
fi

python3 "${SCRIPT_DIR}/monitor_sysnav_standalone.py" \
  --duration "${SYSNAV_PREVIEW_DURATION:-30}" \
  --output "${LOG_DIR}/result.json" | tee "${LOG_DIR}/monitor.log"

python3 - "${LOG_DIR}/result.json" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
required = ("state_estimation", "registered_scan", "terrain_map", "sensor_scan")
missing = [name for name in required if result["counts"][name] == 0]
if not result["safe_no_cmd_vel_publisher"]:
    raise SystemExit("Unsafe: a production /cmd_vel publisher was detected")
if missing:
    raise SystemExit("Missing required preview outputs: " + ", ".join(missing))
PY

printf 'COMPLETE %s\n' "$(date --iso-8601=seconds)" >"${LOG_DIR}/status"
printf '%s\n' "${LOG_DIR}"
