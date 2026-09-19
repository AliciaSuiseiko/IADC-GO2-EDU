#!/usr/bin/env python3

import argparse
import json
import math
import time
from pathlib import Path

import rclpy
from nav_msgs.msg import Odometry, Path as RosPath
from rclpy.node import Node
from sensor_msgs.msg import PointCloud2
from std_msgs.msg import Bool


PREFIX = "/sysnav_standalone_preview"


class StandaloneMonitor(Node):
    def __init__(self):
        super().__init__("sysnav_standalone_monitor")
        self.started = time.monotonic()
        self.odom_samples = []
        self.health = {"true": 0, "false": 0}
        self.counts = {
            "state_estimation": 0,
            "registered_scan": 0,
            "terrain_map": 0,
            "sensor_scan": 0,
            "path": 0,
            "free_paths": 0,
        }
        self.point_widths = {
            "registered_scan": [],
            "terrain_map": [],
            "sensor_scan": [],
            "free_paths": [],
        }
        self.create_subscription(
            Odometry, PREFIX + "/state_estimation", self._odom, 20
        )
        self.create_subscription(
            Bool, PREFIX + "/state_estimation_health", self._health, 20
        )
        self.create_subscription(
            PointCloud2,
            PREFIX + "/registered_scan",
            lambda msg: self._cloud("registered_scan", msg),
            5,
        )
        self.create_subscription(
            PointCloud2,
            PREFIX + "/terrain_map",
            lambda msg: self._cloud("terrain_map", msg),
            5,
        )
        self.create_subscription(
            PointCloud2,
            PREFIX + "/sensor_scan",
            lambda msg: self._cloud("sensor_scan", msg),
            5,
        )
        self.create_subscription(
            RosPath, PREFIX + "/path", lambda _: self._increment("path"), 5
        )
        self.create_subscription(
            PointCloud2,
            PREFIX + "/free_paths",
            lambda msg: self._cloud("free_paths", msg),
            5,
        )

    def _increment(self, key):
        self.counts[key] += 1

    def _odom(self, msg):
        position = msg.pose.pose.position
        values = (position.x, position.y, position.z)
        if all(math.isfinite(value) for value in values):
            self.odom_samples.append((time.monotonic() - self.started, values))
        self.counts["state_estimation"] += 1

    def _health(self, msg):
        self.health["true" if msg.data else "false"] += 1

    def _cloud(self, key, msg):
        self.counts[key] += 1
        self.point_widths[key].append(int(msg.width) * int(msg.height))

    @staticmethod
    def _motion_metrics(samples):
        displacement = 0.0
        max_step = 0.0
        positions = [position for _, position in samples]
        if positions:
            origin = positions[0]
            displacement = max(
                math.dist(origin, position) for position in positions
            )
        if len(positions) > 1:
            max_step = max(
                math.dist(previous, current)
                for previous, current in zip(
                    positions, positions[1:]
                )
            )
        return {
            "samples": len(positions),
            "max_displacement_from_window_start_m": round(displacement, 6),
            "max_single_step_m": round(max_step, 6),
        }

    def report(self):
        post_warmup = [sample for sample in self.odom_samples if sample[0] >= 10.0]
        publisher_nodes = sorted({
            f"{info.node_namespace.rstrip('/')}/{info.node_name}"
            for info in self.get_publishers_info_by_topic("/cmd_vel")
        })
        return {
            "duration_sec": round(time.monotonic() - self.started, 3),
            "counts": self.counts,
            "max_cloud_points": {
                key: max(values, default=0)
                for key, values in self.point_widths.items()
            },
            "health_messages": self.health,
            "full_window_motion": self._motion_metrics(self.odom_samples),
            "post_10s_warmup_motion": self._motion_metrics(post_warmup),
            "production_cmd_vel_publishers": publisher_nodes,
            "safe_no_cmd_vel_publisher": not publisher_nodes,
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    rclpy.init()
    node = StandaloneMonitor()
    deadline = time.monotonic() + args.duration
    try:
        while rclpy.ok() and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.2)
        report = node.report()
        Path(args.output).write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(json.dumps(report, sort_keys=True))
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
