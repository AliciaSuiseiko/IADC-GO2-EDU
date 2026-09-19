#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/lianaiwei"
WS="$ROOT/src/fastlio2_ros1_ws"
ENV_DIR="$ROOT/envs/fastlio2_ros1"
IMAGE="lianaiwei/fastlio2-ros1:noetic-arm64"
PATCH_FILE="$ENV_DIR/fastlio_ros1_livox_driver2.patch"
PREPROCESS_PATCH_FILE="$ENV_DIR/fastlio_ros1_preprocess_driver2.patch"

mkdir -p "$WS"/{src,build,install,log} "$ENV_DIR"

if [ ! -f "$WS/src/FAST_LIO/CMakeLists.txt" ]; then
  git clone --depth 1 --branch main --recurse-submodules https://github.com/hku-mars/FAST_LIO.git "$WS/src/FAST_LIO"
fi

if [ -d "$WS/src/FAST_LIO/.git" ]; then
  git -C "$WS/src/FAST_LIO" submodule update --init --recursive
fi

if [ ! -f "$WS/src/livox_ros_driver2/CMakeLists.txt" ]; then
  git clone --depth 1 --branch master https://github.com/Livox-SDK/livox_ros_driver2.git "$WS/src/livox_ros_driver2"
fi

if [ ! -f "$WS/src/livox_ros_driver2/package.xml" ]; then
  cp "$WS/src/livox_ros_driver2/package_ROS1.xml" "$WS/src/livox_ros_driver2/package.xml"
fi

if [ -d "$WS/src/FAST_LIO/.git" ] && ! git -C "$WS/src/FAST_LIO" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  git -C "$WS/src/FAST_LIO" apply --check "$PATCH_FILE"
  git -C "$WS/src/FAST_LIO" apply "$PATCH_FILE"
fi

if [ -d "$WS/src/FAST_LIO/.git" ] && ! git -C "$WS/src/FAST_LIO" apply --reverse --check "$PREPROCESS_PATCH_FILE" >/dev/null 2>&1; then
  git -C "$WS/src/FAST_LIO" apply --check "$PREPROCESS_PATCH_FILE"
  git -C "$WS/src/FAST_LIO" apply "$PREPROCESS_PATCH_FILE"
fi

if ! sudo -n docker image inspect "$IMAGE" >/dev/null 2>&1; then
  sudo -n docker build --platform linux/arm64 -t "$IMAGE" "$ENV_DIR"
fi

sudo -n docker run --rm --name fastlio2-ros1-build \
  --platform linux/arm64 \
  --user "$(id -u):$(id -g)" \
  -v "$WS:/work/fastlio2_ros1_ws" \
  "$IMAGE" \
  bash -lc 'source /opt/ros/noetic/setup.bash; cd /work/fastlio2_ros1_ws; catkin config --install --build-space build --install-space install --log-space log --devel-space build/devel --cmake-args -DROS_EDITION=ROS1; catkin build'
