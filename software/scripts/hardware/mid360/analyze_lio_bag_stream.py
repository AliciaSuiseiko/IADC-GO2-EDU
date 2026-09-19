#!/usr/bin/env python3

import argparse
import json
import math
import time
from collections import defaultdict
from pathlib import Path

import rclpy
from geometry_msgs.msg import TwistStamped
from livox_ros_driver2.msg import CustomMsg
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import Imu


def stamp_seconds(message):
    return float(message.header.stamp.sec) + float(message.header.stamp.nanosec) * 1e-9


class StreamAnalyzer(Node):
    def __init__(self, duration):
        super().__init__("lio_bag_stream_analyzer")
        self.deadline = time.monotonic() + duration
        self.bins = defaultdict(self.new_bin)
        self.create_subscription(
            Imu, "/livox/imu", self.on_imu, qos_profile_sensor_data
        )
        self.create_subscription(
            CustomMsg, "/livox/lidar", self.on_lidar, qos_profile_sensor_data
        )
        self.create_subscription(Odometry, "/Odometry", self.on_odom, 20)
        self.create_subscription(
            TwistStamped,
            "/sysnav_exploration/cmd_vel_stamped",
            self.on_command,
            50,
        )

    @staticmethod
    def new_bin():
        return {
            "imu_count": 0,
            "lidar_count": 0,
            "odom_count": 0,
            "command_count": 0,
            "accel_norm_min": math.inf,
            "accel_norm_max": -math.inf,
            "gyro_norm_max": 0.0,
            "lidar_points_min": math.inf,
            "lidar_points_max": 0,
            "odom_first": None,
            "odom_last": None,
            "command_linear_max": 0.0,
            "command_yaw_max": 0.0,
        }

    def bucket(self, message):
        return self.bins[int(math.floor(stamp_seconds(message)))]

    def on_imu(self, message):
        bucket = self.bucket(message)
        accel = message.linear_acceleration
        gyro = message.angular_velocity
        accel_norm = math.sqrt(accel.x**2 + accel.y**2 + accel.z**2)
        gyro_norm = math.sqrt(gyro.x**2 + gyro.y**2 + gyro.z**2)
        bucket["imu_count"] += 1
        bucket["accel_norm_min"] = min(bucket["accel_norm_min"], accel_norm)
        bucket["accel_norm_max"] = max(bucket["accel_norm_max"], accel_norm)
        bucket["gyro_norm_max"] = max(bucket["gyro_norm_max"], gyro_norm)

    def on_lidar(self, message):
        bucket = self.bucket(message)
        points = int(message.point_num)
        bucket["lidar_count"] += 1
        bucket["lidar_points_min"] = min(bucket["lidar_points_min"], points)
        bucket["lidar_points_max"] = max(bucket["lidar_points_max"], points)

    def on_odom(self, message):
        bucket = self.bucket(message)
        point = message.pose.pose.position
        position = [point.x, point.y, point.z]
        bucket["odom_count"] += 1
        if bucket["odom_first"] is None:
            bucket["odom_first"] = position
        bucket["odom_last"] = position

    def on_command(self, message):
        bucket = self.bucket(message)
        linear = message.twist.linear
        angular = message.twist.angular
        bucket["command_count"] += 1
        bucket["command_linear_max"] = max(
            bucket["command_linear_max"], math.hypot(linear.x, linear.y)
        )
        bucket["command_yaw_max"] = max(
            bucket["command_yaw_max"], abs(angular.z)
        )

    def report(self):
        result = {}
        for second, bucket in sorted(self.bins.items()):
            clean = dict(bucket)
            for key in ("accel_norm_min", "accel_norm_max", "lidar_points_min"):
                if not math.isfinite(clean[key]):
                    clean[key] = None
            result[str(second)] = clean
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    rclpy.init()
    node = StreamAnalyzer(args.duration)
    try:
        while rclpy.ok() and time.monotonic() < node.deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
        report = node.report()
        Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report))
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
