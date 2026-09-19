#!/usr/bin/env bash
set -euo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
LOG_ROOT="$ROOT/logs/hardware/scanplanner-dynamic-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_ROOT"

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/scanplanner_ws/install/setup.bash"
set -u

export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-37}"
export ROS_LOCALHOST_ONLY=1

cleanup() {
  if [[ -n "${LAUNCH_PID:-}" ]] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
    kill -INT -- "-$LAUNCH_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$LAUNCH_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -TERM -- "-$LAUNCH_PID" 2>/dev/null || true
    sleep 0.5
    kill -KILL -- "-$LAUNCH_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

setsid "$ROOT/scripts/hardware/scanplanner/run_scanplanner.sh" sim \
  init_x:=-10.0 init_y:=0.0 init_z:=0.3 \
  >"$LOG_ROOT/launch.log" 2>&1 &
LAUNCH_PID=$!
echo "$LAUNCH_PID" >"$LOG_ROOT/launch.pid"

python3 "$ROOT/scripts/hardware/scanplanner/validate_reactive_stop.py" \
  --output "$LOG_ROOT/result.json" --timeout 25 \
  >"$LOG_ROOT/validator.log" 2>&1 &
VALIDATOR_PID=$!

for _ in $(seq 1 200); do
  grep -q "ODOM_READY" "$LOG_ROOT/validator.log" 2>/dev/null && break
  sleep 0.1
done
if ! grep -q "ODOM_READY" "$LOG_ROOT/validator.log"; then
  echo "validator did not receive simulated odometry" >&2
  exit 1
fi

ros2 topic pub --once /move_base_simple/goal geometry_msgs/msg/PoseStamped \
  "{header: {frame_id: world}, pose: {position: {x: -8.0, y: 0.0, z: 0.3}, orientation: {w: 1.0}}}" \
  >"$LOG_ROOT/goal.log" 2>&1

wait "$VALIDATOR_PID"

if ! grep -q "Obstacle discovered; emergency stop" "$LOG_ROOT/launch.log"; then
  echo "planner log did not report the emergency-stop branch" >&2
  exit 1
fi

python3 - "$LOG_ROOT/result.json" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps(result, indent=2))
if not result["passed"]:
    raise SystemExit(result["reason"])
PY

echo "PASS: dynamic obstacle produced a stationary trajectory and zero command"
echo "log_dir=$LOG_ROOT"
