#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/lianaiwei"
STORE="/mnt/slurmfs-4090node3/user_data/$USER/lianaiwei"
ZIP="$ROOT/downloads/insta360/Linux_CameraSDK-2.1.1_MediaSDK-3.1.1.zip"
ARCHIVE_MEMBER="Linux_CameraSDK-2.1.1_MediaSDK-3.1.1/libMediaSDK-dev-3.1.1.0-amd64.tar_1758540334111.xz"
DEB_MEMBER="libMediaSDK-dev-3.1.1.0-20250922_191110-amd64/libMediaSDK-dev-3.1.1.0-20250922_191110-amd64.deb"
VENDOR="$STORE/vendor/insta360/mediasdk-3.1.1"
RUNTIME_VENDOR="$ROOT/vendor/insta360/mediasdk-3.1.1"
DEB="$STORE/downloads/insta360/libMediaSDK-dev-3.1.1.0-amd64.deb"
WS="$STORE/src/camera_x5_ws"

[[ -r "$ZIP" ]] || {
  echo "missing official Insta360 SDK archive: $ZIP" >&2
  exit 2
}
mkdir -p "$(dirname "$DEB")" "$VENDOR" "$WS/src"

if [[ ! -r "$DEB" ]]; then
  unzip -p "$ZIP" "$ARCHIVE_MEMBER" | tar -xJOf - "$DEB_MEMBER" >"$DEB"
fi
dpkg-deb -x "$DEB" "$VENDOR/root"

set +u
source "$ROOT/miniforge3/etc/profile.d/conda.sh"
conda activate "$STORE/envs/sysnav-jazzy"
set -u
export INSTA360_MEDIA_SDK_ROOT="$VENDOR/root/usr"
export LD_LIBRARY_PATH="$INSTA360_MEDIA_SDK_ROOT/lib:${LD_LIBRARY_PATH:-}"

cd "$WS"
colcon build --packages-select insta360_x5_media_ros2 \
  --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release

set +u
source "$WS/install/setup.bash"
set -u
ros2 pkg executables insta360_x5_media_ros2 | grep -q 'x5_media_stitcher_node'

# Keep the large runtime libraries on the node1 home mount. Loading the
# 318 MB MediaSDK library directly from node3 can stall compute-node startup.
mkdir -p "$RUNTIME_VENDOR/root"
cp -a "$VENDOR/root/." "$RUNTIME_VENDOR/root/"

echo "COMPLETE MediaSDK root=$INSTA360_MEDIA_SDK_ROOT runtime=$RUNTIME_VENDOR/root/usr workspace=$WS"
