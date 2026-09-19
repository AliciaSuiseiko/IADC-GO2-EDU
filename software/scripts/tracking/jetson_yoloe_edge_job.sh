#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
RUN="$ROOT/runs/yoloe_edge_20260901_retry1"
MODEL_DIR="$ROOT/models/yoloe_edge"
STATUS_DIR="$ROOT/status"
TRTEXEC=/usr/src/tensorrt/bin/trtexec
SOURCE_ONNX=/home/orin/lianaiwei/src/sysnav_ws/src/SysNav/src/semantic_mapping/semantic_mapping/external/yoloe-26x-seg.onnx
SOURCE_IMAGE=/home/orin/lianaiwei/logs/sysnav-preview-20260813-150927/x5-current.jpg
ENGINE="$MODEL_DIR/yoloe-26x-seg-orin-trt86-fp16.engine"
PREPARE="$ROOT/scripts/prepare_yoloe_input.py"

mkdir -p "$RUN/logs" "$RUN/output" "$MODEL_DIR" "$STATUS_DIR"
printf 'RUNNING\n' > "$STATUS_DIR/yoloe_edge.status"

on_exit() {
    rc=$?
    if (( rc != 0 )); then
        printf 'FAILED rc=%s log=%s\n' "$rc" "$RUN/logs/job.log" > "$STATUS_DIR/yoloe_edge.status"
    fi
}
trap on_exit EXIT

for path in "$TRTEXEC" "$SOURCE_ONNX" "$SOURCE_IMAGE" "$PREPARE"; do
    if [[ ! -e "$path" ]]; then
        printf 'required path missing: %s\n' "$path" >&2
        exit 2
    fi
done

ln -sfn "$SOURCE_ONNX" "$MODEL_DIR/yoloe-26x-seg.onnx"

cat > "$RUN/manifest.txt" <<EOF
host=$(hostname)
architecture=$(uname -m)
jetson_release=$(head -1 /etc/nv_tegra_release)
source_onnx=$SOURCE_ONNX
engine=$ENGINE
input_image=$SOURCE_IMAGE
input_shape=1x3x640x1920
precision=FP16
tensorrt=8.6.2
purpose=offline real-camera TensorRT compatibility smoke; no ROS nodes or motion commands
EOF

if [[ -f "$ENGINE" ]]; then
    if ! "$TRTEXEC" --loadEngine="$ENGINE" --skipInference > "$RUN/logs/engine_check.log" 2>&1; then
        mv "$ENGINE" "$ENGINE.rejected.$(date +%Y%m%d-%H%M%S)"
    fi
fi

if [[ ! -f "$ENGINE" ]]; then
    build_started=$(date +%s)
    "$TRTEXEC" \
        --onnx="$SOURCE_ONNX" \
        --saveEngine="$ENGINE" \
        --fp16 \
        --memPoolSize=workspace:4096 \
        --builderOptimizationLevel=3 \
        --skipInference \
        > "$RUN/logs/build.log" 2>&1
    printf 'build_wall_seconds=%s\n' "$(( $(date +%s) - build_started ))" > "$RUN/build_resources.txt"
fi

/usr/bin/python3 "$PREPARE" \
    --image "$SOURCE_IMAGE" \
    --output "$RUN/input-images-fp32.raw" \
    --metadata "$RUN/input.json"

inference_started=$(date +%s)
"$TRTEXEC" \
    --loadEngine="$ENGINE" \
    --loadInputs="images:$RUN/input-images-fp32.raw" \
    --warmUp=300 \
    --duration=3 \
    --iterations=20 \
    --useCudaGraph \
    --exportTimes="$RUN/output/times.json" \
    --exportOutput="$RUN/output/tensors.json" \
    > "$RUN/logs/inference.log" 2>&1
printf 'inference_wall_seconds=%s\n' "$(( $(date +%s) - inference_started ))" > "$RUN/inference_resources.txt"

test -s "$RUN/output/times.json"
test -s "$RUN/output/tensors.json"

{
    printf 'engine_bytes=%s\n' "$(stat -c %s "$ENGINE")"
    printf 'input_bytes=%s\n' "$(stat -c %s "$RUN/input-images-fp32.raw")"
    printf 'times_bytes=%s\n' "$(stat -c %s "$RUN/output/times.json")"
    printf 'outputs_bytes=%s\n' "$(stat -c %s "$RUN/output/tensors.json")"
    grep -E 'Throughput:|GPU Compute Time:|Latency:|Total Host Walltime:|Total GPU Compute Time:' "$RUN/logs/inference.log" || true
} > "$RUN/result.txt"

printf 'COMPLETE run=%s engine=%s\n' "$RUN" "$ENGINE" > "$STATUS_DIR/yoloe_edge.status"
trap - EXIT
