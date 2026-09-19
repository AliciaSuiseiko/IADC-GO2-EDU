#!/usr/bin/env python3
"""Publish one stored ERP image and target state repeatedly for ROS smoke tests."""

from __future__ import annotations

import argparse
import json
import time

import cv2
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import CompressedImage
from std_msgs.msg import String


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--bbox", nargs=4, type=float, required=True)
    parser.add_argument("--repeats", type=int, default=10)
    parser.add_argument("--image-only", action="store_true")
    args = parser.parse_args()
    frame = cv2.imread(args.image, cv2.IMREAD_COLOR)
    if frame is None:
        raise RuntimeError(f"cannot read {args.image}")
    ok, encoded = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 90])
    if not ok:
        raise RuntimeError("JPEG encoding failed")

    rclpy.init()
    node = Node("tracking_smoke_input")
    image_pub = node.create_publisher(CompressedImage, "/camera/image/compressed", 5)
    state_pub = node.create_publisher(String, "/tracking/target_state", 5)
    payload = {
        "state": "VISIBLE",
        "recovery_source": "bbox_init",
        "bbox_erp_xywh": args.bbox,
        "wraps_seam": args.bbox[0] + args.bbox[2] > frame.shape[1],
    }
    try:
        for _ in range(args.repeats):
            stamp = node.get_clock().now().to_msg()
            image = CompressedImage()
            image.header.stamp = stamp
            image.header.frame_id = "x5_erp"
            image.format = "jpeg"
            image.data = encoded.tobytes()
            image_pub.publish(image)
            if not args.image_only:
                state_pub.publish(String(data=json.dumps(payload)))
            rclpy.spin_once(node, timeout_sec=0.05)
            time.sleep(0.1)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
