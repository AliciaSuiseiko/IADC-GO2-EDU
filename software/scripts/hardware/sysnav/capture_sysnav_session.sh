#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/logs/sysnav-session-snapshot-$STAMP"
LATEST="$(find "$ROOT/logs" -maxdepth 1 -type d -name 'sysnav-foreground-*' -print | sort | tail -1)"
mkdir -p "$OUT"

printf 'snapshot=%s\nsource_run=%s\ncreated=%s\n' \
  "$OUT" "$LATEST" "$(date -Is)" >"$OUT/README.txt"
if [[ -n "$LATEST" && -d "$LATEST" ]]; then
  cp -a "$LATEST" "$OUT/foreground-run"
fi

ps -eo user,pid,ppid,pgid,lstart,pcpu,pmem,args >"$OUT/processes.txt"
ip -br address >"$OUT/network.txt"
df -h "$ROOT" >"$OUT/disk.txt"

set +u
source /opt/ros/humble/setup.bash
source "$ROOT/src/elevator_lio_ws/install/setup.bash" 2>/dev/null || true
source "$ROOT/src/camera_x5_ws/install/setup.bash" 2>/dev/null || true
source "$ROOT/src/sysnav_ws/install/setup.bash" 2>/dev/null || true
source "$ROOT/src/sysnav_ws/install-standalone-preview/setup.bash" 2>/dev/null || true
set -u
unset RMW_IMPLEMENTATION CYCLONEDDS_URI ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT
export ROS_DOMAIN_ID=0 ROS_LOCALHOST_ONLY=0

ros2 topic list -t >"$OUT/topics-and-types.txt" 2>&1 || true
ros2 node list >"$OUT/nodes.txt" 2>&1 || true
while read -r topic; do
  printf '\n===== %s =====\n' "$topic"
  timeout 3 ros2 topic info -v "$topic" 2>&1 || true
done < <(ros2 topic list 2>/dev/null) >"$OUT/topic-graph.txt"

for node in /feature_extraction_node /laser_mapping_node \
  /imu_preintegration_node /terrainAnalysis /terrainAnalysisExt \
  /localPlanner /pathFollower /tare_planner_node /room_segmentation; do
  printf '\n===== %s =====\n' "$node"
  timeout 5 ros2 param dump "$node" 2>&1 || true
done >"$OUT/parameters.yaml"

topics=(
  /state_estimation /registered_scan /terrain_map /terrain_map_ext
  /way_point /path /local_path /free_paths
  /viewpoint_vis_cloud /selected_viewpoint_vis_cloud
  /uncovered_frontier_cloud /explore_areas_new
  /cmd_vel /annotated_image/compressed
  /room_segmentation/segmented_map /room_segmentation/room_markers
  /object_node_markers /object_nodes
)
available=()
topic_list="$(ros2 topic list 2>/dev/null || true)"
for topic in "${topics[@]}"; do
  if grep -Fxq "$topic" <<<"$topic_list"; then
    available+=("$topic")
  fi
done

if ((${#available[@]})); then
  timeout -s INT 8 ros2 bag record -o "$OUT/key-topics" "${available[@]}" \
    >"$OUT/rosbag-record.log" 2>&1 || true
fi

sync
printf '%s\n' "$OUT"
du -sh "$OUT"
