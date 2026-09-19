#!/usr/bin/env python3
import argparse
import json
import math
import time

import rclpy
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data


def rpy_deg(q):
    sinr = 2.0 * (q.w * q.x + q.y * q.z)
    cosr = 1.0 - 2.0 * (q.x * q.x + q.y * q.y)
    roll = math.atan2(sinr, cosr)
    sinp = 2.0 * (q.w * q.y - q.z * q.x)
    pitch = math.asin(max(-1.0, min(1.0, sinp)))
    siny = 2.0 * (q.w * q.z + q.x * q.y)
    cosy = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    yaw = math.atan2(siny, cosy)
    return [math.degrees(value) for value in (roll, pitch, yaw)]


class Monitor(Node):
    def __init__(self, imu_topic, body_topic):
        super().__init__("elevator_lio_body_extrinsic_monitor")
        self.samples = {"imu": [], "body": []}
        self.create_subscription(
            Odometry, imu_topic, lambda msg: self.add("imu", msg), qos_profile_sensor_data
        )
        self.create_subscription(
            Odometry, body_topic, lambda msg: self.add("body", msg), qos_profile_sensor_data
        )

    def add(self, name, msg):
        p = msg.pose.pose.position
        self.samples[name].append(([p.x, p.y, p.z], rpy_deg(msg.pose.pose.orientation)))


def summarize(samples):
    if not samples:
        return {"messages": 0}
    start = samples[0][0]
    max_displacement = 0.0
    max_step = 0.0
    previous = start
    for position, _ in samples:
        max_displacement = max(max_displacement, math.dist(start, position))
        max_step = max(max_step, math.dist(previous, position))
        previous = position
    initial = samples[: min(30, len(samples))]
    mean_rpy = [sum(item[1][axis] for item in initial) / len(initial) for axis in range(3)]
    return {
        "messages": len(samples),
        "initial_mean_rpy_deg": mean_rpy,
        "max_displacement_m": max_displacement,
        "max_step_m": max_step,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, default=45.0)
    parser.add_argument("--imu-topic", default="/LIO/odom_imu")
    parser.add_argument("--body-topic", default="/LIO/odom_vehicle")
    args = parser.parse_args()
    rclpy.init()
    node = Monitor(args.imu_topic, args.body_topic)
    try:
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
        result = {name: summarize(samples) for name, samples in node.samples.items()}
        print(json.dumps(result, indent=2))
        if result["body"]["messages"] < 50:
            raise SystemExit("insufficient body odometry")
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
