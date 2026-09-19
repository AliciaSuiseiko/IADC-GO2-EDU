#!/usr/bin/env python3
import argparse
import json
import time
from pathlib import Path

import numpy as np
import rclpy
from livox_ros_driver2.msg import CustomMsg
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data


class Sampler(Node):
    def __init__(self, topic: str, message_limit: int) -> None:
        super().__init__("livox_validation_sampler")
        self.message_limit = message_limit
        self.arrivals = []
        self.stamps = []
        self.point_counts = []
        self.points = []
        self.create_subscription(CustomMsg, topic, self.callback, qos_profile_sensor_data)

    def callback(self, message: CustomMsg) -> None:
        self.arrivals.append(time.monotonic())
        self.stamps.append(message.header.stamp.sec + message.header.stamp.nanosec * 1e-9)
        xyz = np.asarray([(point.x, point.y, point.z) for point in message.points], dtype=np.float32)
        self.point_counts.append(len(xyz))
        if len(xyz):
            self.points.append(xyz[::10])

    @property
    def complete(self) -> bool:
        return len(self.arrivals) >= self.message_limit


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--topic", default="/lidar/scan")
    parser.add_argument("--messages", type=int, default=50)
    parser.add_argument("--timeout", type=float, default=12.0)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    rclpy.init()
    node = Sampler(args.topic, args.messages)
    deadline = time.monotonic() + args.timeout
    while not node.complete and time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.2)

    points = np.concatenate(node.points) if node.points else np.empty((0, 3), dtype=np.float32)
    valid = np.isfinite(points).all(axis=1)
    ranges = np.linalg.norm(points[valid], axis=1)
    arrival_intervals = np.diff(node.arrivals)
    stamp_intervals = np.diff(node.stamps)
    summary = {
        "topic": args.topic,
        "requested_messages": args.messages,
        "received_messages": len(node.arrivals),
        "elapsed_s": node.arrivals[-1] - node.arrivals[0] if len(node.arrivals) > 1 else 0.0,
        "rate_hz": 1.0 / float(np.mean(arrival_intervals)) if arrival_intervals.size else 0.0,
        "arrival_interval_ms": {
            "median": float(np.median(arrival_intervals) * 1000) if arrival_intervals.size else None,
            "p99": float(np.percentile(arrival_intervals, 99) * 1000) if arrival_intervals.size else None,
            "max": float(np.max(arrival_intervals) * 1000) if arrival_intervals.size else None,
        },
        "stamp_interval_ms": {
            "median": float(np.median(stamp_intervals) * 1000) if stamp_intervals.size else None,
            "max": float(np.max(stamp_intervals) * 1000) if stamp_intervals.size else None,
        },
        "points_per_message": {
            "min": int(np.min(node.point_counts)) if node.point_counts else 0,
            "median": float(np.median(node.point_counts)) if node.point_counts else 0.0,
            "max": int(np.max(node.point_counts)) if node.point_counts else 0,
        },
        "sampled_points": int(len(points)),
        "finite_fraction": float(np.mean(valid)) if len(valid) else 0.0,
        "range_m": {
            "min": float(np.min(ranges)) if len(ranges) else None,
            "p10": float(np.percentile(ranges, 10)) if len(ranges) else None,
            "median": float(np.median(ranges)) if len(ranges) else None,
            "p90": float(np.percentile(ranges, 90)) if len(ranges) else None,
            "p99": float(np.percentile(ranges, 99)) if len(ranges) else None,
            "max": float(np.max(ranges)) if len(ranges) else None,
        },
    }

    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    np.save(output / "points_sample.npy", points)
    (output / "lidar_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    node.destroy_node()
    rclpy.shutdown()
    if len(node.arrivals) < args.messages:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
