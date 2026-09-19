#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/orin/lianaiwei/tracking_deployment
RUN="$ROOT/runs/x5_forward_center_view_smoke_20260901_dynamic_retry2"
[[ ! -e "$RUN" ]]
mkdir -p "$RUN"

node_pid=
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "$node_pid" ]]; then
        kill -INT "$node_pid" 2>/dev/null || true
        wait "$node_pid" 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

set +u
source /opt/ros/humble/setup.bash
source /home/orin/lianaiwei/src/fastlio2_ws/install/setup.bash
source /home/orin/lianaiwei/src/camera_x5_ws/install/setup.bash
set -u

python3 -m py_compile "$ROOT/scripts/x5_forward_center_view.py"
PYTHONPATH="$ROOT/scripts${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
from x5_forward_center_view import roll_rows

source = bytes([0, 1, 2, 3, 9, 10, 11, 12, 13, 9])
expected = [1, 2, 3, 0, 9, 11, 12, 13, 10, 9]
assert list(roll_rows(source, 2, 4, 5, 1, -1)) == expected
print("pixel_roll=PASS")
PY

set +e
timeout --signal=INT --kill-after=3 3 \
    "$ROOT/scripts/run_x5_forward_center_view_jetson.sh" 0.0 \
    > "$RUN/node.log" 2>&1
rc=$?
set -e
[[ $rc -eq 124 || $rc -eq 130 ]]
grep -q 'display-only ERP centering' "$RUN/node.log"
if grep -q 'Traceback' "$RUN/node.log"; then
    echo "centering node emitted a traceback" >&2
    exit 3
fi
if ps -eo args | grep -q '[/]x5_forward_center_view.py'; then
    echo "centering node survived timeout" >&2
    exit 3
fi

python3 "$ROOT/scripts/x5_forward_center_view.py" --ros-args \
    -p input_topic:=/diagnostics/x5_forward_input \
    -p output_topic:=/diagnostics/x5_forward_output \
    -p odom_topic:=/diagnostics/x5_forward_odometry \
    -p source_forward_yaw_deg:=0.0 \
    -p follow_odometry:=true \
    > "$RUN/e2e-node.log" 2>&1 &
node_pid=$!
sleep 1
python3 - <<'PY'
import time

import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from sensor_msgs.msg import Image

rclpy.init()
node = Node("x5_forward_center_smoke")
publisher = node.create_publisher(Image, "/diagnostics/x5_forward_input", 2)
odom_publisher = node.create_publisher(Odometry, "/diagnostics/x5_forward_odometry", 2)
received = []
node.create_subscription(
    Image,
    "/diagnostics/x5_forward_output",
    lambda message: received.append(list(message.data)),
    2,
)
message = Image()
message.height = 1
message.width = 4
message.encoding = "mono8"
message.step = 4
message.data = [0, 1, 2, 3]
deadline = time.monotonic() + 6.0
while (
    (publisher.get_subscription_count() < 1 or odom_publisher.get_subscription_count() < 1)
    and time.monotonic() < deadline
):
    rclpy.spin_once(node, timeout_sec=0.1)
assert publisher.get_subscription_count() >= 1
assert odom_publisher.get_subscription_count() >= 1
odometry = Odometry()
odometry.pose.pose.orientation.w = 1.0
for _ in range(5):
    odom_publisher.publish(odometry)
    rclpy.spin_once(node, timeout_sec=0.2)
odometry.pose.pose.orientation.z = 2.0 ** -0.5
odometry.pose.pose.orientation.w = 2.0 ** -0.5
for _ in range(5):
    odom_publisher.publish(odometry)
    rclpy.spin_once(node, timeout_sec=0.2)
while not received and time.monotonic() < deadline:
    publisher.publish(message)
    rclpy.spin_once(node, timeout_sec=0.1)
assert received and received[-1] == [1, 2, 3, 0], received
received.clear()
odometry.pose.pose.orientation.z = 0.0
odometry.pose.pose.orientation.w = 1.0
for _ in range(5):
    odom_publisher.publish(odometry)
    rclpy.spin_once(node, timeout_sec=0.2)
odometry.pose.pose.orientation.z = -(2.0 ** -0.5)
odometry.pose.pose.orientation.w = 2.0 ** -0.5
for _ in range(5):
    odom_publisher.publish(odometry)
    rclpy.spin_once(node, timeout_sec=0.2)
deadline = time.monotonic() + 6.0
while not received and time.monotonic() < deadline:
    publisher.publish(message)
    rclpy.spin_once(node, timeout_sec=0.1)
assert received and received[-1] == [3, 0, 1, 2], received
print("ros_dynamic_heading_follow_left_right=PASS")
node.destroy_node()
rclpy.shutdown()
PY
kill -INT "$node_pid"
set +e
wait "$node_pid"
node_rc=$?
set -e
[[ $node_rc -eq 0 || $node_rc -eq 130 ]]
node_pid=
if grep -q 'Traceback' "$RUN/e2e-node.log"; then
    echo "end-to-end node emitted a traceback" >&2
    exit 3
fi
printf 'COMPLETE yaw_deg=0.0 topic=/camera/image_forward_centered\n' > "$RUN/status"
cat "$RUN/node.log"
cat "$RUN/e2e-node.log"
cat "$RUN/status"
trap - EXIT
