#!/usr/bin/env bash
set -eo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
EXPECTED_BAG="$ROOT/logs/hardware/mid360-motion-20260810-205807"
BAG="${1:-$EXPECTED_BAG}"
FAST_WS="$ROOT/src/fastlio2_ws"
ELEVATOR_WS="$ROOT/src/elevator_lio_ws"
TOOLS="$ROOT/scripts/hardware/mid360"
SESSION="${2:-$ROOT/logs/hardware/lio-map-comparison-$(date +%Y%m%d-%H%M%S)}"
MODE="${3:-all}"

if [[ "$(realpath "$BAG")" != "$(realpath "$EXPECTED_BAG")" ]]; then
  echo "REFUSED: only $EXPECTED_BAG is approved for this comparison" >&2
  exit 64
fi
if pgrep -u "$USER" -f 'fastlio_mapping|/lio/lio|ros2 bag play' >/dev/null; then
  echo "BLOCKED: an LIO or bag replay process is already running" >&2
  exit 2
fi

mkdir -p "$SESSION/fastlio2" "$SESSION/elevator_lio"
printf '%s\n' "$BAG" >"$SESSION/approved_bag.txt"

cleanup_group() {
  local pid="${1:-}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -INT -- "-$pid" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$pid" 2>/dev/null || return 0
      sleep 0.25
    done
    kill -TERM -- "-$pid" 2>/dev/null || true
  fi
}

run_fastlio2() {
  source /opt/ros/humble/setup.bash
  source "$FAST_WS/install/setup.bash"
  local mapping_pid adapter_pid collector_pid
  trap 'cleanup_group "${collector_pid:-}"; cleanup_group "${adapter_pid:-}"; cleanup_group "${mapping_pid:-}"' RETURN

  setsid ros2 run fast_lio fastlio_mapping --ros-args \
    --params-file "$FAST_WS/src/FAST_LIO_ROS2/config/mid360_real.yaml" \
    >"$SESSION/fastlio2/lio.log" 2>&1 < /dev/null &
  mapping_pid=$!
  setsid ros2 launch fastlio2_go2_adapter mid360_go2_adapter.launch.py \
    >"$SESSION/fastlio2/adapter.log" 2>&1 < /dev/null &
  adapter_pid=$!
  setsid python3 "$TOOLS/collect_world_cloud_map.py" \
    --topic /cloud_registered_go2_body --odom-topic /Odometry_go2 \
    --output-prefix "$SESSION/fastlio2/map_go2" \
    >"$SESSION/fastlio2/collector.log" 2>&1 < /dev/null &
  collector_pid=$!
  sleep 4
  kill -0 "$mapping_pid" && kill -0 "$adapter_pid" && kill -0 "$collector_pid"

  ros2 bag play "$BAG" --rate 1.0 >"$SESSION/fastlio2/bag.log" 2>&1
  sleep 3
  cleanup_group "$collector_pid"
  collector_pid=""
  test -s "$SESSION/fastlio2/map_go2.npz"
  cleanup_group "$adapter_pid"
  adapter_pid=""
  cleanup_group "$mapping_pid"
  mapping_pid=""
  trap - RETURN
}

run_elevator_lio() {
  source /opt/ros/humble/setup.bash
  source "$ELEVATOR_WS/install/setup.bash"
  local lio_pid collector_pid
  trap 'cleanup_group "${collector_pid:-}"; cleanup_group "${lio_pid:-}"' RETURN

  setsid ros2 launch lio start_ros2.launch.py \
    use_rviz:=false config_path:=root_mid360_go2.yaml \
    >"$SESSION/elevator_lio/lio.log" 2>&1 < /dev/null &
  lio_pid=$!
  setsid python3 "$TOOLS/collect_world_cloud_map.py" \
    --topic /LIO/clouds_lidar --output-prefix "$SESSION/elevator_lio/map" \
    >"$SESSION/elevator_lio/collector.log" 2>&1 < /dev/null &
  collector_pid=$!
  sleep 4
  kill -0 "$lio_pid" && kill -0 "$collector_pid"

  ros2 bag play "$BAG" --rate 1.0 \
    --remap /lidar/scan:=/livox/lidar /imu/data:=/livox/imu \
    >"$SESSION/elevator_lio/bag.log" 2>&1
  sleep 3
  cleanup_group "$collector_pid"
  collector_pid=""
  test -s "$SESSION/elevator_lio/map.npz"
  cleanup_group "$lio_pid"
  lio_pid=""
  trap - RETURN
}

case "$MODE" in
  all)
    run_fastlio2
    run_elevator_lio
    ;;
  fast-only)
    run_fastlio2
    test -s "$SESSION/elevator_lio/map.npz"
    ;;
  *)
    echo "REFUSED: mode must be all or fast-only" >&2
    exit 64
    ;;
esac

"$ROOT/venvs/sysnav/bin/python" "$TOOLS/render_lio_map_comparison.py" \
  --fast "$SESSION/fastlio2/map_go2.npz" \
  --elevator "$SESSION/elevator_lio/map.npz" \
  --output "$SESSION/map-comparison.png" \
  --manifest "$SESSION/manifest.json"

printf 'SESSION=%s\n' "$SESSION"
printf 'SCREENSHOT=%s\n' "$SESSION/map-comparison.png"
