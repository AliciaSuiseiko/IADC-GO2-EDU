#!/usr/bin/env python3
import argparse
import json
import math
import time

import rclpy
from nav_msgs.msg import Odometry
from rclpy.node import Node


class OdomMonitor(Node):
    def __init__(self, topic: str, duration: float) -> None:
        super().__init__("fastlio_odom_monitor")
        self.deadline = time.monotonic() + duration
        self.count = 0
        self.first = None
        self.last = None
        self.max_radius = 0.0
        self.max_step = 0.0
        self.max_speed = 0.0
        self.large_steps = 0
        self.last_stamp = None
        self.largest_steps = []
        self.position_min = [math.inf, math.inf, math.inf]
        self.position_max = [-math.inf, -math.inf, -math.inf]
        self.create_subscription(Odometry, topic, self.on_odom, 50)

    def on_odom(self, msg: Odometry) -> None:
        point = msg.pose.pose.position
        current = (point.x, point.y, point.z)
        stamp = float(msg.header.stamp.sec) + float(msg.header.stamp.nanosec) * 1e-9
        if self.first is None:
            self.first = current
        for axis, value in enumerate(current):
            self.position_min[axis] = min(self.position_min[axis], value)
            self.position_max[axis] = max(self.position_max[axis], value)
        if self.last is not None:
            step = math.dist(self.last, current)
            self.max_step = max(self.max_step, step)
            dt = stamp - self.last_stamp
            speed = step / dt if dt > 1e-6 else math.inf
            self.max_speed = max(self.max_speed, speed)
            self.largest_steps.append(
                {
                    "stamp": stamp,
                    "dt_sec": dt,
                    "step_m": step,
                    "speed_mps": speed,
                    "position_m": current,
                }
            )
            self.largest_steps.sort(key=lambda item: item["step_m"], reverse=True)
            del self.largest_steps[10:]
            if step > 1.0:
                self.large_steps += 1
        self.last = current
        self.last_stamp = stamp
        self.max_radius = max(self.max_radius, math.dist(self.first, current))
        self.count += 1

    def finished(self) -> bool:
        return time.monotonic() >= self.deadline

    def summary(self) -> dict:
        return {
            "messages": self.count,
            "first_position_m": self.first,
            "last_position_m": self.last,
            "max_displacement_from_start_m": self.max_radius,
            "max_single_step_m": self.max_step,
            "max_step_speed_mps": self.max_speed,
            "steps_over_1m": self.large_steps,
            "position_min_m": self.position_min if self.count else None,
            "position_max_m": self.position_max if self.count else None,
            "largest_steps": self.largest_steps,
        }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--topic", default="/Odometry")
    parser.add_argument("--duration", type=float, default=60.0)
    parser.add_argument("--output")
    args = parser.parse_args()

    rclpy.init()
    monitor = OdomMonitor(args.topic, args.duration)
    try:
        while rclpy.ok() and not monitor.finished():
            rclpy.spin_once(monitor, timeout_sec=0.2)
    finally:
        result = json.dumps(monitor.summary(), indent=2)
        print(result)
        if args.output:
            with open(args.output, "w", encoding="ascii") as handle:
                handle.write(result + "\n")
        monitor.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
