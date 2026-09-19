#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$HOME/lianaiwei"
WS="$ROOT/src/direct_visual_lidar_calibration_ws"
ACTIVATE="$ROOT/scripts/calibration/activate_direct_visual_lidar_calibration.sh"

usage() {
  cat <<'EOF'
Usage:
  x5_mid360_spatial_calibration.sh status
  x5_mid360_spatial_calibration.sh record DATASET BAG [IMAGE_TOPIC] [POINTS_TOPIC] [SECONDS]
  x5_mid360_spatial_calibration.sh preprocess DATASET [IMAGE_TOPIC] [POINTS_TOPIC]
  x5_mid360_spatial_calibration.sh initial DATASET
  x5_mid360_spatial_calibration.sh calibrate DATASET [calibrate options...]
  x5_mid360_spatial_calibration.sh view DATASET

Defaults:
  IMAGE_TOPIC=/camera/image
  POINTS_TOPIC=/livox/lidar
  SECONDS=15

Use the full 2:1 stitched X5 panorama and a sensor_msgs/msg/PointCloud2
published in the native Mid-360 frame. Keep the rigid sensor rig still while
each bag is recorded. Collect 5-10 bags from distinct poses.
EOF
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    echo "invalid name: $1" >&2
    exit 2
  }
}

require_dataset() {
  local dataset="$1"
  valid_name "$dataset"
  test -d "$WS/data/bags/$dataset" || {
    echo "dataset not found: $WS/data/bags/$dataset" >&2
    exit 3
  }
}

require_preprocessed() {
  local dataset="$1"
  valid_name "$dataset"
  test -f "$WS/data/preprocessed/$dataset/calib.json" || {
    echo "preprocessed dataset not found: $WS/data/preprocessed/$dataset" >&2
    exit 4
  }
}

ensure_display() {
  if command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo >/dev/null 2>&1; then
    return
  fi

  local session_env="$ROOT/scripts/hardware/nomachine/nomachine-session-env.sh"
  test -f "$session_env" || {
    echo "no graphical display and no NoMachine session helper found" >&2
    exit 11
  }
  source "$session_env"
  xdpyinfo >/dev/null 2>&1 || {
    echo "unable to access the active graphical display" >&2
    exit 11
  }
}

test -f "$ACTIVATE" || {
  echo "missing activation file: $ACTIVATE" >&2
  exit 5
}
source "$ACTIVATE"

command="${1:-}"
case "$command" in
  status)
    echo "workspace: $WS"
    echo "package: $(ros2 pkg prefix direct_visual_lidar_calibration)"
    ros2 pkg executables direct_visual_lidar_calibration
    echo "bag datasets:"
    find "$WS/data/bags" -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' 2>/dev/null | sort
    ;;

  record)
    dataset="${2:-}"
    bag="${3:-}"
    image_topic="${4:-/camera/image}"
    points_topic="${5:-/livox/lidar}"
    seconds="${6:-15}"
    valid_name "$dataset"
    valid_name "$bag"
    [[ "$seconds" =~ ^[0-9]+$ ]] && (( seconds >= 10 )) || {
      echo "SECONDS must be an integer of at least 10" >&2
      exit 2
    }

    image_type="$(ros2 topic type "$image_topic")"
    points_type="$(ros2 topic type "$points_topic")"
    [[ "$image_type" == sensor_msgs/msg/Image ]] || {
      echo "$image_topic must be sensor_msgs/msg/Image so its full panorama dimensions can be verified; got $image_type" >&2
      exit 6
    }
    [[ "$points_type" == sensor_msgs/msg/PointCloud2 ]] || {
      echo "$points_topic must be sensor_msgs/msg/PointCloud2; got $points_type" >&2
      exit 7
    }
    if [[ "$image_topic" == /camera/image ]]; then
      image_info="$(ros2 topic info "$image_topic" --verbose)"
      grep -q '^Node name: x5_panorama_tcp_receiver$' <<<"$image_info" || {
        echo "$image_topic must be published by x5_panorama_tcp_receiver; refusing an unverified X5 lens stream" >&2
        exit 6
      }
    fi
    image_sample="$(timeout 8 ros2 topic echo "$image_topic" --once --no-arr)"
    image_width="$(awk '$1 == "width:" {print $2; exit}' <<<"$image_sample")"
    image_height="$(awk '$1 == "height:" {print $2; exit}' <<<"$image_sample")"
    [[ "$image_width" == 1920 && "$image_height" == 960 ]] || {
      echo "$image_topic must be the full 1920x960 X5 equirectangular panorama; got ${image_width:-unknown}x${image_height:-unknown}" >&2
      exit 6
    }
    timeout 8 ros2 topic echo "$points_topic" --once >/dev/null

    output="$WS/data/bags/$dataset/$bag"
    test ! -e "$output" || {
      echo "refusing to overwrite existing bag: $output" >&2
      exit 8
    }
    mkdir -p "$(dirname "$output")"
    echo "Recording $seconds seconds while the rig remains stationary."
    set +e
    timeout --signal=INT --kill-after=8 "${seconds}s" \
      ros2 bag record -o "$output" "$image_topic" "$points_topic"
    rc=$?
    set -e
    [[ $rc -eq 0 || $rc -eq 124 || $rc -eq 130 ]] || exit "$rc"
    test -f "$output/metadata.yaml" || {
      echo "bag did not finalize correctly: $output" >&2
      exit 9
    }
    ros2 bag info "$output"
    ;;

  preprocess)
    dataset="${2:-}"
    image_topic="${3:-/camera/image}"
    points_topic="${4:-/livox/lidar}"
    require_dataset "$dataset"
    output="$WS/data/preprocessed/$dataset"
    test ! -e "$output" || {
      echo "refusing to overwrite preprocessed data: $output" >&2
      exit 10
    }
    ros2 run direct_visual_lidar_calibration preprocess \
      "$WS/data/bags/$dataset" "$output" \
      --image_topic "$image_topic" \
      --points_topic "$points_topic" \
      --camera_model equirectangular \
      --intensity_channel auto \
      --voxel_resolution "${VLCAL_VOXEL_RESOLUTION:-0.01}" \
      --min_distance "${VLCAL_MIN_DISTANCE:-0.5}"
    ;;

  initial)
    dataset="${2:-}"
    require_preprocessed "$dataset"
    ensure_display
    exec ros2 run direct_visual_lidar_calibration initial_guess_manual \
      "$WS/data/preprocessed/$dataset"
    ;;

  calibrate)
    dataset="${2:-}"
    require_preprocessed "$dataset"
    ensure_display
    shift 2
    exec ros2 run direct_visual_lidar_calibration calibrate \
      "$WS/data/preprocessed/$dataset" "$@"
    ;;

  view)
    dataset="${2:-}"
    require_preprocessed "$dataset"
    ensure_display
    exec ros2 run direct_visual_lidar_calibration viewer \
      "$WS/data/preprocessed/$dataset"
    ;;

  -h|--help|help|"")
    usage
    ;;

  *)
    echo "unknown command: $command" >&2
    usage >&2
    exit 2
    ;;
esac
