#!/usr/bin/env bash
#SBATCH --job-name=farm-smoke
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=10:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/farm-smoke-%j.out

set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
SRC="$ROOT/src/FARM-Project"
RUN="$ROOT/runs/farm_${SLURM_JOB_ID}"
STATUS="$ROOT/status/farm.status"
PODMAN_ROOT="$ROOT/runtime/farm_podman/storage-fuse"
IMAGE="localhost/scene_graph:farm-smoke"

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/src" "$ROOT/logs" "$ROOT/status" "$ROOT/runtime/farm_podman" \
  "$RUN/data/out/sample_npz"
printf 'RUNNING job=%s host=%s time=%s\n' \
  "$SLURM_JOB_ID" "$(hostname)" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

if [[ ! -d "$SRC/.git" ]]; then
  git clone --recursive --depth 1 --shallow-submodules \
    https://github.com/GoldenGait/FARM-Project.git "$SRC"
else
  git -C "$SRC" submodule update --init --recursive --depth 1
fi

test -s "$SRC/LICENSE"
commit="$(git -C "$SRC" rev-parse HEAD)"
driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"

python3 - "$RUN/manifest.json" "$commit" "$driver" <<'PY'
import json
import sys

output, commit, driver = sys.argv[1:]
with open(output, "w") as f:
    json.dump(
        {
            "repository": "https://github.com/GoldenGait/FARM-Project.git",
            "commit": commit,
            "license": "AGPL-3.0-or-later",
            "driver": driver,
            "official_runtime": "Docker",
            "server_runtime": "rootless Podman with the official Dockerfile",
            "container_storage": "node3 fuse-overlayfs",
            "gated_dinov3_used": False,
            "optional_siglip2_used": False,
            "smoke": "synthetic NPZ reconstruction",
        },
        f,
        indent=2,
    )
PY

cd "$SRC"

prefetch_hf_asset() {
  local repo=$1 name=$2 min_bytes=$3
  local dest="$SRC/models/yoloe/$name"
  if [[ -f "$dest" ]] && [[ $(stat -c%s "$dest") -ge $min_bytes ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  local sam_python="$HOME/lianaiwei/tracking_envs/sam3/bin/python"
  if ! HF_ENDPOINT=https://hf-mirror.com HF_HOME="$ROOT/cache/farm_huggingface" \
    "$sam_python" - "$repo" "$name" "$(dirname "$dest")" <<'PY'
import sys
from huggingface_hub import hf_hub_download

repo, name, local_dir = sys.argv[1:]
print(hf_hub_download(repo_id=repo, filename=name, local_dir=local_dir))
PY
  then
    if [[ -s "$dest.part.single-connection" ]] && [[ ! -e "$dest.part" ]]; then
      mv "$dest.part.single-connection" "$dest.part"
    fi
    curl -fL --retry 8 -C - \
      -o "$dest.part" "https://hf-mirror.com/$repo/resolve/main/$name"
    mv "$dest.part" "$dest"
  fi
}

# Direct Hugging Face TLS is frequently reset from this cluster. The mirror
# serves the same public repository assets and preserves resumable transfers.
prefetch_hf_asset jameslahm/yoloe yoloe-v8l-seg.pt 100000000
prefetch_hf_asset jameslahm/yoloe yoloe-v8l-seg-pf.pt 100000000
./bootstrap_models.sh --skip-siglip2

PODMAN=(podman --storage-driver overlay \
  --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs \
  --root "$PODMAN_ROOT")
"${PODMAN[@]}" info > "$RUN/podman-info.txt"
"${PODMAN[@]}" build --layers=false \
  --build-arg "UID=$(id -u)" --build-arg "GID=$(id -g)" \
  -t "$IMAGE" -f "$SRC/docker/Dockerfile" "$SRC"

cat > "$RUN/data/make_sample_npz.py" <<'PY'
import os
import numpy as np

os.makedirs("/data/out/sample_npz", exist_ok=True)
n, height, width = 30, 240, 320
rng = np.random.default_rng(0)
images = rng.integers(0, 255, (n, height, width, 3), dtype=np.uint8)
depths = np.full((n, height, width), 2.0, np.float32)
intrinsics = np.array(
    [[160, 0, width / 2], [0, 160, height / 2], [0, 0, 1]],
    np.float32,
)
poses = np.stack([np.eye(4, dtype=np.float32) for _ in range(n)])
poses[:, 0, 3] = np.linspace(0, 0.5, n)
np.savez(
    "/data/out/sample_npz/frames_000.npz",
    images=images,
    depths=depths,
    camtoworlds=poses,
    K=intrinsics,
    pose_convention="opencv",
)
PY

"${PODMAN[@]}" run --rm --network host --ipc host --shm-size=16g \
  --hooks-dir=/usr/share/containers/oci/hooks.d \
  --security-opt=label=disable \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
  -v "$RUN/data:/data" \
  "$IMAGE" bash -lc \
  'python /data/make_sample_npz.py && python -m scene_graph.offline.run --source npz --npz-dir /data/out/sample_npz --camera sample --save-path /data/out/sample.pt'

test -s "$RUN/data/out/sample.pt"
printf 'COMPLETE job=%s run=%s time=%s\n' \
  "$SLURM_JOB_ID" "$RUN" "$(date -Is)" > "$STATUS"
