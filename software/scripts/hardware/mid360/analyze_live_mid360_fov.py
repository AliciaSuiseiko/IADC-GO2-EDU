#!/usr/bin/env python3
import argparse
import json
import math
import time

import rclpy
from livox_ros_driver2.msg import CustomMsg
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data


class FovAnalyzer(Node):
    def __init__(self, frames: int, blind: float) -> None:
        super().__init__("mid360_live_fov_analyzer")
        self.target_frames = frames
        self.blind = blind
        self.frames = 0
        self.raw_bins = [0] * 36
        self.valid_bins = [0] * 36
        self.blind_bins = [0] * 36
        self.raw_points = 0
        self.valid_points = 0
        self.points_outside_blind = 0
        self.range_min = math.inf
        self.range_max = 0.0
        self.elevation_min = math.inf
        self.elevation_max = -math.inf
        self.subscription = self.create_subscription(
            CustomMsg, "/livox/lidar", self.on_cloud, qos_profile_sensor_data
        )

    @staticmethod
    def bin_index(x: float, y: float) -> int:
        degrees = math.degrees(math.atan2(y, x))
        return min(35, int((degrees + 180.0) // 10.0))

    def on_cloud(self, message: CustomMsg) -> None:
        for point in message.points:
            radius_xy = math.hypot(point.x, point.y)
            distance = math.sqrt(radius_xy * radius_xy + point.z * point.z)
            if distance <= 0.0:
                continue
            index = self.bin_index(point.x, point.y)
            self.raw_bins[index] += 1
            self.raw_points += 1
            self.range_min = min(self.range_min, distance)
            self.range_max = max(self.range_max, distance)
            elevation = math.degrees(math.atan2(point.z, radius_xy))
            self.elevation_min = min(self.elevation_min, elevation)
            self.elevation_max = max(self.elevation_max, elevation)

            tag_valid = (point.tag & 0x30) in (0x00, 0x10)
            if point.line < 6 and tag_valid:
                self.valid_bins[index] += 1
                self.valid_points += 1
                if distance >= self.blind:
                    self.blind_bins[index] += 1
                    self.points_outside_blind += 1
        self.frames += 1

    def complete(self) -> bool:
        return self.frames >= self.target_frames

    def result(self) -> dict:
        return {
            "frames": self.frames,
            "bin_start_degrees": list(range(-180, 180, 10)),
            "raw_points_per_10deg": self.raw_bins,
            "valid_points_per_10deg": self.valid_bins,
            "points_outside_blind_per_10deg": self.blind_bins,
            "raw_points": self.raw_points,
            "valid_points": self.valid_points,
            "points_outside_blind": self.points_outside_blind,
            "nonempty_raw_bins": sum(value > 0 for value in self.raw_bins),
            "nonempty_outside_blind_bins": sum(value > 0 for value in self.blind_bins),
            "range_min_m": None if self.range_min == math.inf else self.range_min,
            "range_max_m": self.range_max,
            "elevation_min_deg": None if self.elevation_min == math.inf else self.elevation_min,
            "elevation_max_deg": None if self.elevation_max == -math.inf else self.elevation_max,
            "blind_radius_m": self.blind,
        }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=int, default=30)
    parser.add_argument("--blind", type=float, default=0.8)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--output")
    args = parser.parse_args()

    rclpy.init()
    node = FovAnalyzer(args.frames, args.blind)
    deadline = time.monotonic() + args.timeout
    try:
        while rclpy.ok() and not node.complete() and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.2)
        result = node.result()
        text = json.dumps(result, indent=2)
        print(text)
        if args.output:
            with open(args.output, "w", encoding="ascii") as handle:
                handle.write(text + "\n")
        if not node.complete():
            raise SystemExit("insufficient live Mid-360 frames")
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
