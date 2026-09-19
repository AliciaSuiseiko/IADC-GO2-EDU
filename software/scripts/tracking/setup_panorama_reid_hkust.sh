#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
REPO="$ROOT/src/deep-person-reid"
MODEL_DIR="$ROOT/models/osnet"
MODEL_NAME=osnet_ain_x1_0_msmt17_256x128_amsgrad_ep50_lr0.0015_coslr_b64_fb10_softmax_labsmth_flip_jitter.pth
MODEL_URL="https://huggingface.co/kaiyangzhou/osnet/resolve/main/$MODEL_NAME?download=true"

mkdir -p "$ROOT/src" "$MODEL_DIR"
if [[ ! -d "$REPO/.git" ]]; then
  git clone --depth 1 https://github.com/KaiyangZhou/deep-person-reid.git "$REPO"
fi
if [[ ! -s "$MODEL_DIR/$MODEL_NAME" ]]; then
  curl -fL --retry 5 --retry-delay 5 -o "$MODEL_DIR/$MODEL_NAME.part" "$MODEL_URL"
  mv "$MODEL_DIR/$MODEL_NAME.part" "$MODEL_DIR/$MODEL_NAME"
fi

git -C "$REPO" rev-parse HEAD
sha256sum "$MODEL_DIR/$MODEL_NAME"
