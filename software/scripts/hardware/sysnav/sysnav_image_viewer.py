#!/usr/bin/env python3

import threading

import cv2
import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import CompressedImage


class SysNavImageViewer(Node):
    def __init__(self) -> None:
        super().__init__("sysnav_image_viewer")
        self.frames: dict[str, np.ndarray] = {}
        self.window_positions = {
            "SysNav YOLOE + SAM2": (940, 36),
        }
        self.initialized_windows: set[str] = set()
        self.lock = threading.Lock()
        self.create_subscription(
            CompressedImage,
            "/annotated_image/compressed",
            lambda message: self.decode("SysNav YOLOE + SAM2", message),
            qos_profile_sensor_data,
        )
        self.create_timer(0.05, self.render)

    def decode(self, title: str, message: CompressedImage) -> None:
        frame = cv2.imdecode(np.frombuffer(message.data, dtype=np.uint8), cv2.IMREAD_COLOR)
        if frame is not None:
            with self.lock:
                self.frames[title] = frame

    def render(self) -> None:
        with self.lock:
            frames = list(self.frames.items())
        for title, frame in frames:
            if title not in self.initialized_windows:
                cv2.namedWindow(title, cv2.WINDOW_NORMAL)
                cv2.resizeWindow(title, 960, 320)
                cv2.moveWindow(title, *self.window_positions[title])
                try:
                    cv2.setWindowProperty(title, cv2.WND_PROP_TOPMOST, 1)
                except cv2.error as error:
                    self.get_logger().warning(f"Unable to keep image window above RViz: {error}")
                self.initialized_windows.add(title)
            cv2.imshow(title, frame)
        cv2.waitKey(1)

def main() -> None:
    rclpy.init()
    node = SysNavImageViewer()
    try:
        rclpy.spin(node)
    finally:
        cv2.destroyAllWindows()
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
