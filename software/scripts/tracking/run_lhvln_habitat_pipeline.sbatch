#!/usr/bin/env bash
#SBATCH --job-name=lhvln-habitat
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/lhvln-habitat-%j.out

set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
ENV="$HOME/lianaiwei/tracking_envs/lhvln"
DATA="$ROOT/datasets/habitat_test"
TASK_DATA="$ROOT/datasets/LHPR-VLN"
RUN="$ROOT/runs/lhvln_habitat_${SLURM_JOB_ID}"
STATUS="$ROOT/status/lhvln_habitat.status"

mkdir -p "$DATA" "$RUN" "$ROOT/status" "$ROOT/logs"
printf 'RUNNING job=%s host=%s time=%s\n' "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

set +u
source "$HOME/lianaiwei/miniforge3/etc/profile.d/conda.sh"
conda activate "$ENV"
set -u
export PYTHONNOUSERSITE=1
export HF_HOME="$ROOT/cache/huggingface"
export HF_ENDPOINT=https://hf-mirror.com

python -m pip install huggingface_hub
python - "$TASK_DATA" <<'PY'
import sys
from huggingface_hub import hf_hub_download
for filename in ("episode_task.zip", "step_task.zip", "task.zip"):
    path = hf_hub_download(
        repo_id="Starry123/LHPR-VLN",
        filename=filename,
        repo_type="dataset",
        local_dir=sys.argv[1],
    )
    print("lhpr_asset_ready", path)
PY

SCENE="$(find "$DATA" -type f -name '*.glb' -print -quit 2>/dev/null || true)"
if [[ -z "$SCENE" ]]; then
  python - "$DATA" <<'PY'
import sys
from huggingface_hub import hf_hub_download

for filename in ("skokloster-castle.glb", "skokloster-castle.navmesh"):
    print(hf_hub_download(
        repo_id="ai-habitat/habitat_test_scenes",
        filename=filename,
        repo_type="dataset",
        local_dir=sys.argv[1],
    ))
PY
  SCENE="$(find "$DATA" -type f -name '*.glb' -print -quit)"
fi
test -s "$SCENE"

python - "$SCENE" "$RUN" <<'PY'
import json
import os
import sys
import habitat_sim
import numpy as np
from PIL import Image

scene, run = sys.argv[1:]
sim_cfg = habitat_sim.SimulatorConfiguration()
sim_cfg.scene_id = scene
sim_cfg.enable_physics = False
sensor = habitat_sim.CameraSensorSpec()
sensor.uuid = "color_sensor"
sensor.sensor_type = habitat_sim.SensorType.COLOR
sensor.resolution = [256, 256]
sensor.position = [0.0, 1.5, 0.0]
agent_cfg = habitat_sim.agent.AgentConfiguration()
agent_cfg.sensor_specifications = [sensor]
cfg = habitat_sim.Configuration(sim_cfg, [agent_cfg])

with habitat_sim.Simulator(cfg) as sim:
    sim.initialize_agent(0)
    frames = []
    for action in ("turn_left", "turn_right", "move_forward", "stop"):
        if action == "stop":
            obs = sim.get_sensor_observations()
        else:
            obs = sim.step(action)
        frame = np.asarray(obs["color_sensor"])[..., :3]
        assert frame.shape == (256, 256, 3)
        frames.append(float(frame.mean()))
    Image.fromarray(frame.astype(np.uint8)).save(os.path.join(run, "habitat_frame.png"))
    with open(os.path.join(run, "manifest.json"), "w") as f:
        json.dump({"scene": scene, "frame_means": frames,
                   "task_assets": "/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/datasets/LHPR-VLN"}, f, indent=2)
    print("lhvln_habitat_sim_ok", scene, frames)
PY

test -s "$RUN/habitat_frame.png"
printf 'COMPLETE job=%s run=%s time=%s\n' "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
