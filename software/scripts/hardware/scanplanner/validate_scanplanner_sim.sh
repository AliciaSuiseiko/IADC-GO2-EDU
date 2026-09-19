#!/usr/bin/env bash
set -euo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
LOG_ROOT="$ROOT/logs/hardware/scanplanner-sim-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_ROOT"

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/scanplanner_ws/install/setup.bash"
set -u

cleanup() {
  if [[ -n "${LAUNCH_PID:-}" ]] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
    kill -INT -- "-$LAUNCH_PID" 2>/dev/null || true
    wait "$LAUNCH_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

setsid "$ROOT/scripts/hardware/scanplanner/run_scanplanner.sh" sim \
  init_x:=-10.0 init_y:=0.0 init_z:=0.3 \
  >"$LOG_ROOT/launch.log" 2>&1 &
LAUNCH_PID=$!
echo "$LAUNCH_PID" >"$LOG_ROOT/launch.pid"

for _ in $(seq 1 40); do
  if timeout 1 ros2 topic echo /quad_0/body_pose --once >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
timeout 5 ros2 topic echo /quad_0/body_pose --once >"$LOG_ROOT/start_pose.yaml"

timeout 25 ros2 topic echo /planning/bspline --once \
  >"$LOG_ROOT/bspline.yaml" 2>"$LOG_ROOT/bspline.err" &
ECHO_PID=$!
sleep 1
ros2 topic pub --once /move_base_simple/goal geometry_msgs/msg/PoseStamped \
  "{header: {frame_id: world}, pose: {position: {x: -8.5, y: 0.0, z: 0.3}, orientation: {w: 1.0}}}" \
  >"$LOG_ROOT/goal.log" 2>&1

wait "$ECHO_PID"
sleep 8
timeout 5 ros2 topic echo /quad_0/body_pose --once >"$LOG_ROOT/end_pose.yaml"

if ! grep -q '^pos_pts:' "$LOG_ROOT/bspline.yaml"; then
  echo "SCAN-Planner did not publish a B-spline trajectory" >&2
  exit 1
fi

python3 - "$LOG_ROOT/start_pose.yaml" "$LOG_ROOT/end_pose.yaml" <<'PY'
import math
import re
import sys

def xyz(path):
    text = open(path, encoding="utf-8").read()
    block = text.split("position:", 1)[1].split("orientation:", 1)[0]
    values = {k: float(v) for k, v in re.findall(r"^\s*([xyz]):\s*([-+0-9.eE]+)", block, re.M)}
    return values["x"], values["y"], values["z"]

start = xyz(sys.argv[1])
end = xyz(sys.argv[2])
distance = math.dist(start, end)
print(f"start={start}")
print(f"end={end}")
print(f"displacement_m={distance:.3f}")
if distance < 0.25:
    raise SystemExit("simulated robot did not execute the trajectory")
PY

echo "PASS: trajectory published and simulated body moved"
echo "log_dir=$LOG_ROOT"
