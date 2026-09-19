#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
OUTPUT_NAME="${1:?output run name is required}"
shift
(( $# >= 2 )) || { echo "at least two source runs are required" >&2; exit 2; }
[[ "$OUTPUT_NAME" =~ ^fresh_x5_mid360_[A-Za-z0-9_]+$ ]]

OUTPUT="$ROOT/runs/$OUTPUT_NAME"
[[ ! -e "$OUTPUT" ]]
mkdir -p "$OUTPUT/preprocessed" "$OUTPUT/refinement/dap"

first=true
for source in "$@"; do
    case "$source" in
        "$ROOT"/runs/fresh_x5_mid360_*) ;;
        *) echo "invalid source run: $source" >&2; exit 2 ;;
    esac
    [[ -d "$source/preprocessed" ]]
    if $first; then
        cp "$source/preprocessed/calib.json" "$OUTPUT/preprocessed/calib.json"
        first=false
    fi
    for image in "$source"/preprocessed/pose-live-[0-9][0-9].png; do
        [[ -s "$image" ]]
        stem="${image%.png}"
        name="${image##*/}"
        bag="${name%.png}"
        [[ ! -e "$OUTPUT/preprocessed/$name" ]]
        cp "$stem.png" "$stem.ply" "$stem"_lidar_indices.png "$stem"_lidar_intensities.png \
            "$OUTPUT/preprocessed/"
        [[ -s "$source/refinement/dap/$bag/depth.npy" ]]
        cp -a "$source/refinement/dap/$bag" "$OUTPUT/refinement/dap/$bag"
    done
done

printf 'COMPLETE sources=%s output=%s\n' "$#" "$OUTPUT" > "$OUTPUT/status"
