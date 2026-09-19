#!/usr/bin/env python3

import argparse
import json
import math
import time
from pathlib import Path

import rclpy
from geometry_msgs.msg import TwistStamped
from livox_ros_driver2.msg import CustomMsg
from nav_msgs.msg import Odometry, Path as RosPath
from rclpy.node import Node
from sensor_msgs.msg import CompressedImage, Imu, PointCloud2
from std_msgs.msg import Bool


class LiveMonitor(Node):
    def __init__(self, lightweight=False):
        super().__init__("sysnav_fastlio2_live_monitor")
        self.started = time.monotonic()
        self.counts = {}
        self.odom_samples = []
        self.health = {"true": 0, "false": 0}
        self.max_cloud_points = {}
        self.max_command = {"linear_x": 0.0, "linear_y": 0.0, "angular_z": 0.0}

        self._subscribe(Odometry, "/state_estimation", "state_estimation", self._odom)
        self._subscribe(
            Bool, "/state_estimation_health", "state_estimation_health", self._health
        )
        if not lightweight:
            self._subscribe(CustomMsg, "/livox/lidar", "livox_lidar", self._count)
            self._subscribe(Imu, "/livox/imu", "livox_imu", self._count)
            self._subscribe(
                CompressedImage,
                "/camera/image/compressed",
                "camera_compressed",
                self._count,
            )
            self._subscribe(
                CompressedImage,
                "/annotated_image/compressed",
                "annotated_image_compressed",
                self._count,
            )
            for topic, key in (
                ("/registered_scan", "registered_scan"),
                ("/terrain_map", "terrain_map"),
                ("/terrain_map_ext", "terrain_map_ext"),
                ("/free_paths", "free_paths"),
            ):
                self._subscribe(PointCloud2, topic, key, self._cloud)
            self._subscribe(RosPath, "/path", "path", self._count)
            self._subscribe(
                TwistStamped,
                "/cmd_vel",
                "exploration_cmd_vel",
                self._command,
            )

    def _subscribe(self, msg_type, topic, key, callback):
        self.counts[key] = 0
        self.create_subscription(
            msg_type, topic, lambda message: callback(key, message), 20
        )

    def _count(self, key, _message):
        self.counts[key] += 1

    def _health(self, key, message):
        self.counts[key] += 1
        self.health["true" if message.data else "false"] += 1

    def _cloud(self, key, message):
        self.counts[key] += 1
        points = int(message.width) * int(message.height)
        self.max_cloud_points[key] = max(self.max_cloud_points.get(key, 0), points)

    def _odom(self, key, message):
        self.counts[key] += 1
        position = message.pose.pose.position
        values = (position.x, position.y, position.z)
        if all(math.isfinite(value) for value in values):
            self.odom_samples.append((time.monotonic() - self.started, values))

    def _command(self, key, message):
        self.counts[key] += 1
        self.max_command["linear_x"] = max(
            self.max_command["linear_x"], abs(message.twist.linear.x)
        )
        self.max_command["linear_y"] = max(
            self.max_command["linear_y"], abs(message.twist.linear.y)
        )
        self.max_command["angular_z"] = max(
            self.max_command["angular_z"], abs(message.twist.angular.z)
        )

    @staticmethod
    def _motion(samples):
        positions = [position for _, position in samples]
        if not positions:
            return {"samples": 0, "max_displacement_m": None, "max_step_m": None}
        origin = positions[0]
        timed_steps = [
            (current_time, math.dist(previous, current))
            for (previous_time, previous), (current_time, current) in zip(
                samples, samples[1:]
            )
        ]
        steps = [step for _, step in timed_steps]
        max_step_time, max_step = max(timed_steps, key=lambda item: item[1], default=(None, 0.0))
        return {
            "samples": len(positions),
            "max_displacement_m": round(
                max(math.dist(origin, position) for position in positions), 6
            ),
            "max_step_m": round(max_step, 6),
            "max_step_time_sec": (
                round(max_step_time, 3) if max_step_time is not None else None
            ),
            "steps_over_0_02_m": sum(step > 0.02 for step in steps),
            "steps_over_0_05_m": sum(step > 0.05 for step in steps),
            "last_position_m": [round(value, 6) for value in positions[-1]],
        }

    def report(self):
        duration = time.monotonic() - self.started
        post_warmup = [sample for sample in self.odom_samples if sample[0] >= 10.0]
        cmd_vel_publishers = sorted(
            {
                f"{info.node_namespace.rstrip('/')}/{info.node_name}"
                for info in self.get_publishers_info_by_topic("/cmd_vel")
            }
        )
        return {
            "duration_sec": round(duration, 3),
            "counts": self.counts,
            "rates_hz": {
                key: round(count / duration, 3) for key, count in self.counts.items()
            },
            "health_messages": self.health,
            "motion_full_window": self._motion(self.odom_samples),
            "motion_post_10s_warmup": self._motion(post_warmup),
            "max_cloud_points": self.max_cloud_points,
            "max_exploration_command": {
                key: round(value, 6) for key, value in self.max_command.items()
            },
            "production_cmd_vel_publishers": cmd_vel_publishers,
            "safe_no_cmd_vel_publisher": not cmd_vel_publishers,
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=60.0)
    parser.add_argument("--output", required=True)
    parser.add_argument("--lightweight", action="store_true")
    args = parser.parse_args()

    rclpy.init()
    node = LiveMonitor(lightweight=args.lightweight)
    deadline = time.monotonic() + args.duration
    try:
        while rclpy.ok() and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.2)
        report = node.report()
        Path(args.output).write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(json.dumps(report, sort_keys=True))
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
