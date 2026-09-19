#!/usr/bin/env python3
"""Inject a synthetic wall into SCAN-Planner's isolated simulator."""

import argparse
import json
import math
import struct
import time
from pathlib import Path

import rclpy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from scan_planner_msgs.msg import Bspline
from sensor_msgs.msg import PointCloud2, PointField


class ReactiveStopValidator(Node):
    def __init__(self, output_path: Path, timeout_sec: float) -> None:
        super().__init__("scanplanner_reactive_stop_validator")
        self.output_path = output_path
        self.timeout_sec = timeout_sec
        self.started_at = time.monotonic()
        self.initial_x = None
        self.latest_pose = None
        self.latest_speed = 0.0
        self.triggered_at = None
        self.stop_trajectory_at = None
        self.zero_command_at = None
        self.obstacle_x = None
        self.obstacle_y = None
        self.peak_speed_before_trigger = 0.0
        self.max_forward_progress_after_trigger = 0.0
        self.trajectory_spreads = []
        self.result_written = False
        self.ready_reported = False

        self.cloud_pub = self.create_publisher(
            PointCloud2, "/quad_0/cloud", qos_profile_sensor_data
        )
        self.create_subscription(
            Odometry, "/quad_0/body_pose", self.odom_callback, qos_profile_sensor_data
        )
        self.create_subscription(Twist, "/quad_0/cmd_vel", self.cmd_callback, 20)
        self.create_subscription(Bspline, "/planning/bspline", self.bspline_callback, 10)
        self.create_timer(0.01, self.timer_callback)
        self.get_logger().info("validator ready")

    def odom_callback(self, msg: Odometry) -> None:
        x = msg.pose.pose.position.x
        y = msg.pose.pose.position.y
        if self.initial_x is None:
            self.initial_x = x
            print("ODOM_READY", flush=True)
        self.latest_pose = (x, y, msg.pose.pose.position.z)
        if self.triggered_at is not None:
            self.max_forward_progress_after_trigger = max(
                self.max_forward_progress_after_trigger, x - (self.obstacle_x - 0.65)
            )

    def cmd_callback(self, msg: Twist) -> None:
        speed = math.hypot(msg.linear.x, msg.linear.y)
        self.latest_speed = speed
        if self.triggered_at is None:
            self.peak_speed_before_trigger = max(self.peak_speed_before_trigger, speed)
        elif self.stop_trajectory_at is not None and speed < 0.03 and self.zero_command_at is None:
            self.zero_command_at = time.monotonic()

    def bspline_callback(self, msg: Bspline) -> None:
        if self.triggered_at is None or not msg.pos_pts:
            return
        origin = msg.pos_pts[0]
        spread = max(
            math.sqrt(
                (point.x - origin.x) ** 2
                + (point.y - origin.y) ** 2
                + (point.z - origin.z) ** 2
            )
            for point in msg.pos_pts
        )
        self.trajectory_spreads.append(spread)
        if spread < 0.02 and self.stop_trajectory_at is None:
            self.stop_trajectory_at = time.monotonic()
            self.get_logger().info(f"stationary trajectory received; spread={spread:.6f}m")

    def make_wall(self) -> PointCloud2:
        points = []
        for y_step in range(-30, 31):
            for z_step in range(-4, 13):
                points.append(
                    (
                        self.obstacle_x,
                        self.obstacle_y + y_step * 0.05,
                        0.30 + z_step * 0.05,
                    )
                )
        msg = PointCloud2()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = "world"
        msg.height = 1
        msg.width = len(points)
        msg.fields = [
            PointField(name="x", offset=0, datatype=PointField.FLOAT32, count=1),
            PointField(name="y", offset=4, datatype=PointField.FLOAT32, count=1),
            PointField(name="z", offset=8, datatype=PointField.FLOAT32, count=1),
        ]
        msg.is_bigendian = False
        msg.point_step = 12
        msg.row_step = msg.point_step * msg.width
        msg.is_dense = True
        msg.data = b"".join(struct.pack("<fff", *point) for point in points)
        return msg

    def write_result(self, passed: bool, reason: str) -> None:
        if self.result_written:
            return
        self.result_written = True
        now = time.monotonic()
        result = {
            "passed": passed,
            "reason": reason,
            "peak_speed_before_trigger_mps": self.peak_speed_before_trigger,
            "obstacle_x_m": self.obstacle_x,
            "obstacle_y_m": self.obstacle_y,
            "stationary_trajectory_latency_sec": (
                None if self.stop_trajectory_at is None else self.stop_trajectory_at - self.triggered_at
            ),
            "zero_command_latency_sec": (
                None if self.zero_command_at is None else self.zero_command_at - self.triggered_at
            ),
            "max_forward_progress_after_trigger_m": self.max_forward_progress_after_trigger,
            "minimum_trajectory_spread_m": (
                None if not self.trajectory_spreads else min(self.trajectory_spreads)
            ),
            "elapsed_sec": now - self.started_at,
        }
        self.output_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, sort_keys=True), flush=True)

    def timer_callback(self) -> None:
        now = time.monotonic()
        if now - self.started_at > self.timeout_sec:
            self.write_result(False, "timed out before observing reactive stop")
            return

        if self.latest_pose is None or self.initial_x is None:
            return

        x, y, _ = self.latest_pose
        if self.triggered_at is None:
            if self.latest_speed > 0.12 and x - self.initial_x > 0.08:
                self.triggered_at = now
                self.obstacle_x = x + 0.65
                self.obstacle_y = y
                self.get_logger().warn(
                    f"injecting wall at x={self.obstacle_x:.3f}, y={self.obstacle_y:.3f}"
                )
            return

        self.cloud_pub.publish(self.make_wall())
        if self.stop_trajectory_at is not None and self.zero_command_at is not None:
            latency = self.zero_command_at - self.triggered_at
            passed = latency < 1.0
            self.write_result(passed, "reactive stop observed" if passed else "stop latency exceeded 1s")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=25.0)
    args = parser.parse_args()
    rclpy.init()
    node = ReactiveStopValidator(args.output, args.timeout)
    try:
        while rclpy.ok() and not node.result_written:
            rclpy.spin_once(node, timeout_sec=0.1)
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()
    if not args.output.exists():
        return 1
    return 0 if json.loads(args.output.read_text(encoding="utf-8"))["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
