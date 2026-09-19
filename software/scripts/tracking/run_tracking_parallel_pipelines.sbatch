#!/usr/bin/env bash
#SBATCH --job-name=tracking-4gpu
#SBATCH --partition=GPU
#SBATCH --gres=gpu:4090:4
#SBATCH --cpus-per-task=24
#SBATCH --mem=160G
#SBATCH --time=04:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/tracking-4gpu-%j.out

set -uo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
ENVS="$HOME/lianaiwei/tracking_envs"
SRC="$ROOT/src"
MODELS="$ROOT/models"
DATASETS="$ROOT/datasets"
RUN="$ROOT/runs/parallel_4gpu_${SLURM_JOB_ID}"
STATUS="$ROOT/status/parallel_4gpu.status"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds data root: %s\n' "$ROOT" >&2; exit 1 ;;
esac
case "$ENVS" in
  "$HOME"/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds environment root: %s\n' "$ENVS" >&2; exit 1 ;;
esac

mkdir -p "$RUN" "$ROOT/logs" "$ROOT/status" "$MODELS/oavat"
printf 'RUNNING job=%s host=%s time=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
nvidia-smi --query-gpu=index,name,uuid,memory.total --format=csv,noheader > "$RUN/gpus.start.csv"

worker_oavat() {
  local env="$ENVS/oavat"
  [[ -x "$env/bin/python" ]] || { printf 'missing env: %s\n' "$env" >&2; return 20; }
  cd "$MODELS/oavat"
  "$env/bin/python" - "$RUN" <<'PY'
import json
import os
import sys
import numpy as np
import torch
from ultralytics import YOLO

run = sys.argv[1]
model = YOLO("yoloe-11l-seg.pt")
image = np.zeros((320, 640, 3), dtype=np.uint8)
result = model.predict(image, device=0, verbose=False)[0]
payload = {
    "pipeline": "OA-VAT/YOLOE",
    "physical_slot": 0,
    "visible_gpu": torch.cuda.get_device_name(0),
    "boxes": len(result.boxes),
    "gpu_peak_bytes": torch.cuda.max_memory_allocated(),
}
with open(os.path.join(run, "oavat.json"), "w") as f:
    json.dump(payload, f, indent=2)
print(payload)
PY
}

worker_dap() {
  local env="$ENVS/dap"
  local runtime="$RUN/dap"
  [[ -x "$env/bin/python" ]] || { printf 'missing env: %s\n' "$env" >&2; return 20; }
  [[ -s "$MODELS/dap/model.pth" ]] || { printf 'missing DAP model\n' >&2; return 21; }
  mkdir -p "$runtime/input" "$runtime/output"
  "$env/bin/python" - "$runtime/input/panorama.png" <<'PY'
import sys
import numpy as np
from PIL import Image
h, w = 256, 512
x = np.linspace(0, 255, w, dtype=np.uint8)[None, :]
y = np.linspace(0, 255, h, dtype=np.uint8)[:, None]
rgb = np.stack((np.broadcast_to(x, (h, w)), np.broadcast_to(y, (h, w)), np.full((h, w), 127, np.uint8)), axis=-1)
Image.fromarray(rgb).save(sys.argv[1])
PY
  printf '%s\n' "$runtime/input/panorama.png" > "$runtime/input.txt"
  cat > "$runtime/infer.yaml" <<EOF
model:
  name: dap
  args:
    midas_model_type: vitl
    fine_tune_type: hypersim
    min_depth: 0.01
    max_depth: 1.0
    train_decoder: True
median_align: False
load_weights_dir: $MODELS/dap
input:
  height: 512
  width: 1024
inference:
  batch_size: 1
  num_workers: 1
  save_colormap: True
  colormap_type: jet
EOF
  cd "$SRC/DAP"
  "$env/bin/python" test/infer.py --config "$runtime/infer.yaml" \
    --txt "$runtime/input.txt" --output "$runtime/output" --gpu 0
  test -s "$runtime/output/depth_npy/000001.npy"
  "$env/bin/python" - "$runtime/output/depth_npy/000001.npy" "$RUN" <<'PY'
import json
import os
import sys
import numpy as np
import torch
a = np.load(sys.argv[1])
assert a.ndim == 2 and np.isfinite(a).all()
payload = {
    "pipeline": "DAP",
    "physical_slot": 1,
    "visible_gpu": torch.cuda.get_device_name(0),
    "shape": list(a.shape),
    "range": [float(a.min()), float(a.max())],
    "gpu_peak_bytes": torch.cuda.max_memory_allocated(),
}
with open(os.path.join(sys.argv[2], "dap.json"), "w") as f:
    json.dump(payload, f, indent=2)
print(payload)
PY
}

worker_omnitrack() {
  local env="$ENVS/omnitrack"
  [[ -x "$env/bin/python" ]] || { printf 'missing env: %s\n' "$env" >&2; return 20; }
  cd "$SRC/OmniTrack"
  PYTHONPATH="$SRC/OmniTrack" "$env/bin/python" - "$RUN" <<'PY'
import json
import os
import sys
import torch
from mmcv import Config
from mmdet.models import build_detector

cfg = Config.fromfile("projects/configs/JRDB_OmniTrack.py")
if cfg.get("plugin", False):
    import projects.mmdet3d_plugin
model = build_detector(cfg.model, train_cfg=cfg.get("train_cfg"), test_cfg=cfg.get("test_cfg")).cuda().eval()
payload = {
    "pipeline": "OmniTrack",
    "physical_slot": 2,
    "visible_gpu": torch.cuda.get_device_name(0),
    "model": type(model).__name__,
    "parameters": sum(p.numel() for p in model.parameters()),
    "gpu_peak_bytes": torch.cuda.max_memory_allocated(),
}
with open(os.path.join(sys.argv[1], "omnitrack.json"), "w") as f:
    json.dump(payload, f, indent=2)
print(payload)
PY
}

worker_lhvln() {
  local env="$ENVS/lhvln"
  local scene
  [[ -x "$env/bin/python" ]] || { printf 'missing env: %s\n' "$env" >&2; return 20; }
  scene="$(find "$DATASETS/habitat_test" -type f -name '*.glb' -print -quit 2>/dev/null || true)"
  [[ -n "$scene" && -s "$scene" ]] || { printf 'missing Habitat test scene\n' >&2; return 21; }
  "$env/bin/python" - "$scene" "$RUN" <<'PY'
import json
import os
import sys
import habitat_sim
import numpy as np

scene, run = sys.argv[1:]
sim_cfg = habitat_sim.SimulatorConfiguration()
sim_cfg.scene_id = scene
sensor = habitat_sim.CameraSensorSpec()
sensor.uuid = "color_sensor"
sensor.sensor_type = habitat_sim.SensorType.COLOR
sensor.resolution = [256, 256]
sensor.position = [0.0, 1.5, 0.0]
agent_cfg = habitat_sim.agent.AgentConfiguration()
agent_cfg.sensor_specifications = [sensor]
with habitat_sim.Simulator(habitat_sim.Configuration(sim_cfg, [agent_cfg])) as sim:
    sim.initialize_agent(0)
    obs = sim.step("turn_left")
    frame = np.asarray(obs["color_sensor"])[..., :3]
    assert frame.shape == (256, 256, 3)
payload = {"pipeline": "LH-VLN/Habitat", "physical_slot": 3, "scene": scene,
           "frame_shape": list(frame.shape), "frame_mean": float(frame.mean())}
with open(os.path.join(run, "lhvln.json"), "w") as f:
    json.dump(payload, f, indent=2)
print(payload)
PY
}

names=(oavat dap omnitrack lhvln)
functions=(worker_oavat worker_dap worker_omnitrack worker_lhvln)
pids=()
for gpu in 0 1 2 3; do
  name="${names[$gpu]}"
  function_name="${functions[$gpu]}"
  (
    export CUDA_DEVICE_ORDER=PCI_BUS_ID
    export CUDA_VISIBLE_DEVICES="$gpu"
    export PYTHONNOUSERSITE=1
    export HF_HOME="$ROOT/cache/huggingface"
    export TORCH_HOME="$ROOT/cache/torch"
    "$function_name"
  ) > "$RUN/$name.log" 2>&1 &
  pid=$!
  pids+=("$pid")
  printf '%s\tgpu=%s\tpid=%s\n' "$name" "$gpu" "$pid" >> "$RUN/workers.tsv"
done

failed=0
for index in 0 1 2 3; do
  name="${names[$index]}"
  if wait "${pids[$index]}"; then
    printf '%s\tCOMPLETE\tlog=%s\n' "$name" "$RUN/$name.log" | tee -a "$RUN/results.tsv"
  else
    rc=$?
    printf '%s\tFAILED\trc=%s\tlog=%s\n' \
      "$name" "$rc" "$RUN/$name.log" | tee -a "$RUN/results.tsv"
    failed=1
  fi
done

nvidia-smi --query-gpu=index,name,memory.used,utilization.gpu --format=csv,noheader > "$RUN/gpus.end.csv"
if (( failed == 0 )); then
  printf 'COMPLETE job=%s run=%s time=%s\n' "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
else
  printf 'PARTIAL job=%s run=%s time=%s\n' "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
fi

exit "$failed"
