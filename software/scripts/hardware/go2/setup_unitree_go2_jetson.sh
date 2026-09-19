#!/usr/bin/env bash
set -euo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
WS="$ROOT/src/unitree_go2_ws"
ROS2_REPO="$WS/src/unitree_ros2"
SDK2_REPO="$WS/src/unitree_sdk2"
GO2_DRIVER_REPO="$WS/src/go2_driver"
GO2_INTERFACES_REPO="$WS/src/go2_interfaces"
ROS2_TAG="v0.2.0"
ROS2_COMMIT="0dfa8f2e444713c52c96c7b70c433b2609879a31"
SDK2_COMMIT="21d0a3b2c46ee48c8fdf2783becb6be3beb0a59b"
GO2_DRIVER_COMMIT="5a921a7df9b84b433cb5f62ab38ae4c553d39249"
GO2_INTERFACES_COMMIT="8a26a182952ab5cf3548f31169ff02a052718451"
SCRIPT_DIR="$ROOT/scripts/hardware/go2"

mkdir -p "$WS"/{src,build,install,log} "$SCRIPT_DIR" "$ROOT/logs/hardware/go2"

if [ ! -d "$ROS2_REPO/.git" ]; then
  git clone --branch "$ROS2_TAG" --depth 1 \
    https://github.com/unitreerobotics/unitree_ros2.git "$ROS2_REPO"
fi
if [ ! -d "$SDK2_REPO/.git" ]; then
  git clone https://github.com/unitreerobotics/unitree_sdk2.git "$SDK2_REPO"
fi
if [ ! -d "$GO2_DRIVER_REPO/.git" ]; then
  git clone --branch humble https://github.com/Unitree-Go2-Robot/go2_driver.git "$GO2_DRIVER_REPO"
fi
if [ ! -d "$GO2_INTERFACES_REPO/.git" ]; then
  git clone --branch humble https://github.com/Unitree-Go2-Robot/go2_interfaces.git "$GO2_INTERFACES_REPO"
fi

git -C "$ROS2_REPO" fetch --depth 1 origin tag "$ROS2_TAG"
git -C "$ROS2_REPO" checkout --detach "$ROS2_COMMIT"
git -C "$SDK2_REPO" fetch origin "$SDK2_COMMIT"
git -C "$SDK2_REPO" checkout --detach "$SDK2_COMMIT"
git -C "$GO2_DRIVER_REPO" fetch origin "$GO2_DRIVER_COMMIT"
git -C "$GO2_DRIVER_REPO" checkout --detach "$GO2_DRIVER_COMMIT"
git -C "$GO2_INTERFACES_REPO" fetch origin "$GO2_INTERFACES_COMMIT"
git -C "$GO2_INTERFACES_REPO" checkout --detach "$GO2_INTERFACES_COMMIT"

missing_packages=()
for package in \
  ros-humble-rmw-cyclonedds-cpp \
  ros-humble-rosidl-generator-dds-idl \
  libyaml-cpp-dev; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || \
    missing_packages+=("$package")
done
if ((${#missing_packages[@]})); then
  echo "Missing apt packages: ${missing_packages[*]}" >&2
  echo "Install them, then rerun this script." >&2
  exit 2
fi

set +u
source /opt/ros/humble/setup.bash
set -u

colcon --log-base "$WS/log/ros2_messages" build \
  --base-paths "$ROS2_REPO/cyclonedds_ws/src/unitree" \
  --build-base "$WS/build/ros2_messages" \
  --install-base "$WS/install/ros2_messages" \
  --packages-select unitree_api unitree_go unitree_hg \
  --cmake-args -DCMAKE_BUILD_TYPE=Release

set +u
source "$WS/install/ros2_messages/setup.bash"
set -u
colcon --log-base "$WS/log/go2_bridge" build \
  --base-paths "$GO2_DRIVER_REPO" "$GO2_INTERFACES_REPO" \
  --build-base "$WS/build/go2_bridge" \
  --install-base "$WS/install/go2_bridge" \
  --packages-select go2_interfaces go2_driver \
  --cmake-args -DCMAKE_BUILD_TYPE=Release

colcon --log-base "$WS/log/ros2_examples" build \
  --base-paths "$ROS2_REPO/example" \
  --build-base "$WS/build/ros2_examples" \
  --install-base "$WS/install/ros2_examples" \
  --packages-select unitree_ros2_example \
  --cmake-args -DCMAKE_BUILD_TYPE=Release

cmake -S "$SDK2_REPO" -B "$WS/build/sdk2" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$WS/install/sdk2" \
  -DBUILD_EXAMPLES=ON
cmake --build "$WS/build/sdk2" --parallel "$(nproc)"
cmake --install "$WS/build/sdk2"

cmake -S "$SCRIPT_DIR/service_list" -B "$WS/build/service_list" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$WS/install/sdk2" \
  -DCMAKE_INSTALL_PREFIX="$WS/install/go2_tools"
cmake --build "$WS/build/service_list" --parallel "$(nproc)"
cmake --install "$WS/build/service_list"

printf 'Unitree ROS2: %s\n' "$(git -C "$ROS2_REPO" rev-parse HEAD)"
printf 'Unitree SDK2: %s\n' "$(git -C "$SDK2_REPO" rev-parse HEAD)"
printf 'Go2 ROS cmd_vel driver: %s\n' "$(git -C "$GO2_DRIVER_REPO" rev-parse HEAD)"
echo "COMPLETE: Unitree Go2 SDK, ROS 2 messages, cmd_vel bridge, and tools built in $WS"
