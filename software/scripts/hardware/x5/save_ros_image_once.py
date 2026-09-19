#!/usr/bin/env python3

import argparse
from pathlib import Path
import threading

import cv2
import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import Image


class ImageSaver(Node):
    def __init__(self, topic: str, output: Path) -> None:
        super().__init__("save_ros_image_once")
        self.output = output
        self.done = threading.Event()
        qos = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
        )
        self.subscription = self.create_subscription(Image, topic, self.on_image, qos)

    def on_image(self, message: Image) -> None:
        if self.done.is_set() or message.encoding not in ("bgr8", "rgb8"):
            return
        frame = np.frombuffer(message.data, dtype=np.uint8).reshape(
            message.height, message.step
        )[:, : message.width * 3].reshape(message.height, message.width, 3)
        if message.encoding == "rgb8":
            frame = cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
        self.output.parent.mkdir(parents=True, exist_ok=True)
        if not cv2.imwrite(str(self.output), frame):
            raise RuntimeError(f"failed to write {self.output}")
        self.get_logger().info(
            f"saved {message.width}x{message.height} {message.encoding} to {self.output}"
        )
        self.done.set()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--topic", default="/camera/x5_lens/image")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    rclpy.init()
    node = ImageSaver(args.topic, args.output)
    deadline = node.get_clock().now().nanoseconds + int(args.timeout * 1e9)
    try:
        while not node.done.is_set() and node.get_clock().now().nanoseconds < deadline:
            rclpy.spin_once(node, timeout_sec=0.2)
        if not node.done.is_set():
            raise TimeoutError(f"no image received from {args.topic}")
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
