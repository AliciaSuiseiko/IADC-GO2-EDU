#!/usr/bin/env python3

import cv2
import numpy as np
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import CompressedImage, Image


class CompressedToRaw(Node):
    def __init__(self) -> None:
        super().__init__("x5_compressed_to_raw")
        self.publisher = self.create_publisher(Image, "/camera/image", 2)
        self.subscription = self.create_subscription(
            CompressedImage,
            "/camera/image/compressed",
            self.convert,
            2,
        )
        self.frames = 0

    def convert(self, message: CompressedImage) -> None:
        encoded = np.frombuffer(message.data, dtype=np.uint8)
        frame = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
        if frame is None:
            self.get_logger().error("Failed to decode X5 JPEG frame")
            return

        output = Image()
        output.header = message.header
        output.height, output.width = frame.shape[:2]
        output.encoding = "bgr8"
        output.is_bigendian = False
        output.step = output.width * 3
        output.data = frame.tobytes()
        self.publisher.publish(output)

        self.frames += 1
        if self.frames == 1:
            self.get_logger().info(
                f"Publishing X5 raw frames at {output.width}x{output.height}"
            )


def main() -> None:
    rclpy.init()
    node = CompressedToRaw()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
