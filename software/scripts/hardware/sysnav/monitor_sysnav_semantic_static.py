#!/usr/bin/env python3
"""Summarize a no-motion SysNav semantic mapping validation run."""

from __future__ import annotations

import argparse
import json
import time
from collections import Counter
from pathlib import Path

import rclpy
from nav_msgs.msg import Odometry
from rclpy.node import Node
from sensor_msgs.msg import CompressedImage, Image, PointCloud2
from tare_planner.msg import ObjectNodeList
from visualization_msgs.msg import MarkerArray


class SemanticMonitor(Node):
    def __init__(self) -> None:
        super().__init__("sysnav_semantic_static_monitor")
        self.counts: Counter[str] = Counter()
        self.max_object_nodes = 0
        self.max_object_points = 0
        self.max_box_markers = 0
        self.image_shapes: dict[str, list[int]] = {}
        self.create_subscription(Odometry, "/state_estimation", self.on_odom, 20)
        self.create_subscription(PointCloud2, "/registered_scan", self.on_scan, 20)
        self.create_subscription(ObjectNodeList, "/object_nodes_list", self.on_objects, 20)
        self.create_subscription(PointCloud2, "/obj_points", self.on_object_points, 20)
        self.create_subscription(MarkerArray, "/obj_boxes", self.on_boxes, 20)
        self.create_subscription(Image, "/camera/image", self.on_camera, 5)
        self.create_subscription(Image, "/cloud_image", self.on_cloud_image, 5)
        self.create_subscription(
            CompressedImage,
            "/annotated_image_detection/compressed",
            self.on_annotated,
            5,
        )

    def on_odom(self, _: Odometry) -> None:
        self.counts["state_estimation"] += 1

    def on_scan(self, message: PointCloud2) -> None:
        self.counts["registered_scan"] += 1
        self.counts["registered_scan_points"] += message.width * message.height

    def on_objects(self, message: ObjectNodeList) -> None:
        self.counts["object_node_lists"] += 1
        self.max_object_nodes = max(self.max_object_nodes, len(message.nodes))

    def on_object_points(self, message: PointCloud2) -> None:
        self.counts["object_point_clouds"] += 1
        self.max_object_points = max(
            self.max_object_points, message.width * message.height
        )

    def on_boxes(self, message: MarkerArray) -> None:
        self.counts["object_box_arrays"] += 1
        self.max_box_markers = max(self.max_box_markers, len(message.markers))

    def on_camera(self, message: Image) -> None:
        self.counts["camera_images"] += 1
        self.image_shapes["camera"] = [message.width, message.height, len(message.data)]

    def on_cloud_image(self, message: Image) -> None:
        self.counts["cloud_images"] += 1
        self.image_shapes["cloud"] = [message.width, message.height, len(message.data)]

    def on_annotated(self, _: CompressedImage) -> None:
        self.counts["annotated_images"] += 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=90.0)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    rclpy.init()
    node = SemanticMonitor()
    started = time.monotonic()
    try:
        while time.monotonic() - started < args.duration:
            rclpy.spin_once(node, timeout_sec=0.2)
    finally:
        summary = {
            "duration_sec": time.monotonic() - started,
            "counts": dict(sorted(node.counts.items())),
            "max_object_nodes_per_list": node.max_object_nodes,
            "max_object_points": node.max_object_points,
            "max_object_box_markers": node.max_box_markers,
            "image_shapes_width_height_bytes": node.image_shapes,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(summary, sort_keys=True))
        node.destroy_node()
        rclpy.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
