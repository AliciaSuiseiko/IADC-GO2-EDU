#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/lianaiwei"
BASE="$ROOT/recordings/sysnav-demo"
ACTIVE_FILE="$BASE/.active-run"
SESSION_ENV="$ROOT/scripts/hardware/nomachine/nomachine-session-env.sh"

usage() {
  echo "usage: $0 start|stop|status" >&2
  exit 2
}

source_ros() {
  set +u
  source /opt/ros/humble/setup.bash
  source "$ROOT/src/sysnav_ws/install/setup.bash"
  set -u
  unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
  export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0
}

pid_alive() {
  local pid_file=$1
  [[ -r "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

current_run() {
  [[ -r "$ACTIVE_FILE" ]] && cat "$ACTIVE_FILE"
}

wait_for_window() {
  local title=$1
  local timeout=${2:-20}
  local elapsed=0
  while ((elapsed < timeout)); do
    if xwininfo -root -tree 2>/dev/null | grep -Fq "$title"; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "Required recording window did not appear within ${timeout}s: $title" >&2
  return 1
}

start_recording() {
  mkdir -p "$BASE"
  local previous
  previous="$(current_run || true)"
  if [[ -n "$previous" ]] && { pid_alive "$previous/screen.pid" || pid_alive "$previous/bag.pid"; }; then
    echo "A demo recording is already active: $previous" >&2
    exit 1
  fi

  source_ros
  local active_topics
  active_topics="$(ros2 topic list)"
  for topic in /camera/image/compressed /annotated_image/compressed /state_estimation; do
    grep -Fxq "$topic" <<<"$active_topics" || {
      echo "Required topic is not active: $topic" >&2
      exit 1
    }
  done

  # Reuse the actual NoMachine GNOME session rather than capturing the client stream.
  source "$SESSION_ENV"
  wait_for_window "SysNav YOLOE + SAM2" 20
  local dimensions width height stamp run_dir
  dimensions="$(xrandr --current | awk '/ current / {gsub(",", "", $10); print $8 "x" $10; exit}')"
  width=${dimensions%x*}
  height=${dimensions#*x}
  [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]] || {
    echo "Unable to determine desktop dimensions: $dimensions" >&2
    exit 1
  }

  stamp="$(date +%Y%m%d-%H%M%S)"
  run_dir="$BASE/$stamp"
  mkdir -p "$run_dir"
  printf '%s\n' "$run_dir" >"$ACTIVE_FILE"
  {
    printf 'started_at=%s\n' "$(date -Is)"
    printf 'display=%s\n' "$DISPLAY"
    printf 'resolution=%sx%s\n' "$width" "$height"
    printf 'ros_domain_id=0\n'
  } >"$run_dir/manifest.txt"

  nohup env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
    gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false do-timestamp=true \
      ! "video/x-raw,framerate=15/1,width=$width,height=$height" \
      ! queue max-size-buffers=4 leaky=downstream \
      ! videoconvert \
      ! nvvidconv \
      ! 'video/x-raw(memory:NVMM),format=NV12' \
      ! nvv4l2h264enc bitrate=10000000 insert-sps-pps=true iframeinterval=30 \
      ! h264parse \
      ! qtmux \
      ! filesink location="$run_dir/jetson-rviz.mp4" \
    >"$run_dir/screen.log" 2>&1 </dev/null &
  printf '%s\n' "$!" >"$run_dir/screen.pid"

  nohup ros2 bag record \
    --output "$run_dir/sysnav-demo-bag" \
    /camera/image/compressed \
    /annotated_image/compressed \
    /vlm_answer \
    /state_estimation \
    /state_estimation_health \
    /global_path \
    /local_path \
    /exploration_path \
    /path \
    /way_point \
    /stop \
    /room_boundaries \
    /room_type_vis \
    /chosen_room_boundary \
    /obj_boxes \
    /obj_labels \
    /sysnav_viz/obj_boxes \
    /sysnav_viz/obj_labels \
    /cmd_vel \
    >"$run_dir/bag.log" 2>&1 </dev/null &
  printf '%s\n' "$!" >"$run_dir/bag.pid"

  sleep 3
  if ! pid_alive "$run_dir/screen.pid" || ! pid_alive "$run_dir/bag.pid"; then
    echo "Recording startup failed. Inspect $run_dir/screen.log and $run_dir/bag.log" >&2
    "$0" stop || true
    exit 1
  fi
  printf 'Recording started: %s\n' "$run_dir"
}

stop_one() {
  local pid_file=$1
  [[ -r "$pid_file" ]] || return 0
  local pid
  pid="$(cat "$pid_file")"
  kill -INT "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  kill -TERM "$pid" 2>/dev/null || true
}

stop_recording() {
  local run_dir
  run_dir="$(current_run || true)"
  [[ -n "$run_dir" ]] || {
    echo "No active demo recording."
    return 0
  }
  stop_one "$run_dir/bag.pid"
  stop_one "$run_dir/screen.pid"
  printf 'stopped_at=%s\n' "$(date -Is)" >>"$run_dir/manifest.txt"
  rm -f "$ACTIVE_FILE"
  echo "Recording stopped: $run_dir"
  find "$run_dir" -maxdepth 2 -type f -printf '%p %k KiB\n' | sort
}

show_status() {
  local run_dir
  run_dir="$(current_run || true)"
  if [[ -z "$run_dir" ]]; then
    echo "No active demo recording."
    return 0
  fi
  printf 'run=%s\n' "$run_dir"
  pid_alive "$run_dir/screen.pid" && echo 'screen=running' || echo 'screen=stopped'
  pid_alive "$run_dir/bag.pid" && echo 'bag=running' || echo 'bag=stopped'
  du -sh "$run_dir"
}

case "${1:-}" in
  start) start_recording ;;
  stop) stop_recording ;;
  status) show_status ;;
  *) usage ;;
esac
