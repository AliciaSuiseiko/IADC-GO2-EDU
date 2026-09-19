#!/usr/bin/env python3
"""Publish a display-only ERP view with the robot forward axis at image center."""

from array import array
import math

import rclpy
from nav_msgs.msg import Odometry
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from sensor_msgs.msg import Image


BYTES_PER_PIXEL = {
    "mono8": 1,
    "8UC1": 1,
    "mono16": 2,
    "16UC1": 2,
    "rgb8": 3,
    "bgr8": 3,
    "rgba8": 4,
    "bgra8": 4,
    "32FC1": 4,
}


def roll_rows(data: bytes, height: int, width: int, step: int, bytes_per_pixel: int, shift_pixels: int) -> array:
    row_bytes = width * bytes_per_pixel
    if step < row_bytes or len(data) != height * step:
        raise ValueError("image data size does not match height/width/step")
    shift_bytes = (shift_pixels % width) * bytes_per_pixel
    if shift_bytes == 0:
        return array("B", data)

    source = memoryview(data)
    output = bytearray(data)
    for row in range(height):
        start = row * step
        pixels = source[start : start + row_bytes]
        output[start : start + row_bytes] = pixels[-shift_bytes:].tobytes() + pixels[:-shift_bytes].tobytes()
    return array("B", output)


class ForwardCenteredView(Node):
    def __init__(self) -> None:
        super().__init__("x5_forward_center_view")
        input_topic = self.declare_parameter("input_topic", "/camera/image").value
        output_topic = self.declare_parameter("output_topic", "/camera/image_forward_centered").value
        odom_topic = self.declare_parameter("odom_topic", "/state_estimation").value
        self.source_forward_yaw_deg = float(self.declare_parameter("source_forward_yaw_deg", 0.0).value)
        self.follow_odometry = bool(self.declare_parameter("follow_odometry", True).value)
        self.previous_raw_yaw = None
        self.accumulated_yaw = 0.0
        self.publisher = self.create_publisher(Image, output_topic, 2)
        self.subscription = self.create_subscription(Image, input_topic, self.on_image, 2)
        self.odom_subscription = None
        if self.follow_odometry:
            self.odom_subscription = self.create_subscription(Odometry, odom_topic, self.on_odometry, 20)
        self.get_logger().info(
            f"display-only ERP centering: {input_topic} -> {output_topic}, "
            f"source forward yaw={self.source_forward_yaw_deg:.3f} deg, "
            f"follow_odometry={self.follow_odometry}, odom_topic={odom_topic}"
        )

    def on_odometry(self, message: Odometry) -> None:
        orientation = message.pose.pose.orientation
        sin_yaw = 2.0 * (orientation.w * orientation.z + orientation.x * orientation.y)
        cos_yaw = 1.0 - 2.0 * (orientation.y * orientation.y + orientation.z * orientation.z)
        raw_yaw = math.atan2(sin_yaw, cos_yaw)
        if self.previous_raw_yaw is None:
            self.previous_raw_yaw = raw_yaw
            return
        delta = math.atan2(math.sin(raw_yaw - self.previous_raw_yaw), math.cos(raw_yaw - self.previous_raw_yaw))
        self.accumulated_yaw += delta
        self.previous_raw_yaw = raw_yaw

    def on_image(self, message: Image) -> None:
        bytes_per_pixel = BYTES_PER_PIXEL.get(message.encoding)
        if bytes_per_pixel is None:
            self.get_logger().error(f"unsupported image encoding: {message.encoding}")
            return
        dynamic_yaw_deg = math.degrees(self.accumulated_yaw) if self.follow_odometry else 0.0
        forward_yaw_deg = self.source_forward_yaw_deg + dynamic_yaw_deg
        shift_pixels = -round(message.width * forward_yaw_deg / 360.0)
        if shift_pixels % message.width == 0:
            self.publisher.publish(message)
            return

        centered = Image()
        centered.header = message.header
        centered.height = message.height
        centered.width = message.width
        centered.encoding = message.encoding
        centered.is_bigendian = message.is_bigendian
        centered.step = message.step
        try:
            centered.data = roll_rows(
                bytes(message.data),
                message.height,
                message.width,
                message.step,
                bytes_per_pixel,
                shift_pixels,
            )
        except ValueError as error:
            self.get_logger().error(str(error))
            return
        self.publisher.publish(centered)


def main() -> None:
    rclpy.init()
    node = ForwardCenteredView()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
