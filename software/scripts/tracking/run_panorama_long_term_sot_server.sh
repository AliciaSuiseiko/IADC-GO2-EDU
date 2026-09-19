#!/usr/bin/env bash
set -Eeo pipefail

STORE="/mnt/slurmfs-4090node3/user_data/${USER}/lianaiwei"
TRACKING_ROOT="$STORE/tracking_deployment"
ENV="$STORE/envs/sysnav-jazzy"
PYDEPS="$HOME/lianaiwei/tracking_envs/panorama_sot_pydeps"
X5_WS="$STORE/src/camera_x5_ws"
SCRIPT="$TRACKING_ROOT/scripts/panorama_long_term_sot_node.py"

source "$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
source "$X5_WS/install/setup.bash"
set -u

export PYTHONNOUSERSITE=1
export PYTHONPATH="$PYDEPS:$TRACKING_ROOT/src/ODTrack:$TRACKING_ROOT/scripts:${PYTHONPATH:-}"

ODTRACK_CHECKPOINT="$TRACKING_ROOT/models/odtrack/Base-Fulldata-300ep/ODTrack_ep0300.pth.tar"
REID_CHECKPOINT="$TRACKING_ROOT/models/osnet/osnet_ain_x1_0_msmt17_256x128_amsgrad_ep50_lr0.0015_coslr_b64_fb10_softmax_labsmth_flip_jitter.pth"
DETECTOR_MODEL="${DETECTOR_MODEL:-$TRACKING_ROOT/models/tbd/yolo11n.pt}"

for required in "$SCRIPT" "$TRACKING_ROOT/src/ODTrack" "$ODTRACK_CHECKPOINT" \
  "$TRACKING_ROOT/src/deep-person-reid" "$REID_CHECKPOINT" "$DETECTOR_MODEL"; do
  if [[ ! -e "$required" ]]; then
    printf 'Missing required tracking asset: %s\n' "$required" >&2
    exit 1
  fi
done

exec python "$SCRIPT" --ros-args \
  -p image_topic:=/camera/image \
  -p odtrack_repo:="$TRACKING_ROOT/src/ODTrack" \
  -p odtrack_checkpoint:="$ODTRACK_CHECKPOINT" \
  -p odtrack_config:=baseline \
  -p torchreid_repo:="$TRACKING_ROOT/src/deep-person-reid" \
  -p reid_checkpoint:="$REID_CHECKPOINT" \
  -p detector_model:="$DETECTOR_MODEL" \
  -p device:=cuda \
  -p detector_interval:="${TRACKING_DETECTOR_INTERVAL:-5}" \
  -p identity_interval:="${TRACKING_IDENTITY_INTERVAL:-3}" \
  -p max_prediction_sec:=0.5 \
  -p max_processing_fps:=10.0 \
  -p body_forward_offset_deg:="${TRACKING_BODY_FORWARD_OFFSET_DEG:-0.0}" \
  -p require_erp:=true
