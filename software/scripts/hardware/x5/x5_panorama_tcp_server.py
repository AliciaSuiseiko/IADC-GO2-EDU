#!/usr/bin/env python3

import os
import socket
import struct
import threading
import time

import cv2
from cv_bridge import CvBridge
import rclpy
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from sensor_msgs.msg import Image


HEADER = struct.Struct("!4sIIIH")
MAGIC = b"X5P1"


class PanoramaTcpServer(Node):
    def __init__(self) -> None:
        super().__init__("x5_panorama_tcp_server")
        self.bridge = CvBridge()
        self.port = int(os.environ.get("X5_PANORAMA_PORT", "42105"))
        self.quality = int(os.environ.get("X5_PANORAMA_JPEG_QUALITY", "80"))
        self.condition = threading.Condition()
        self.packet = None
        self.sequence = 0
        self.stopping = False
        self.received_frames = 0
        self.sent_frames = 0
        self.received_bytes = 0
        self.sent_bytes = 0
        self.last_report = time.monotonic()
        self.last_received_report = 0
        self.last_sent_report = 0
        self.last_received_bytes_report = 0
        self.last_sent_bytes_report = 0
        self.subscription = self.create_subscription(
            Image, "/camera/image", self.on_image, 2
        )
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(("0.0.0.0", self.port))
        self.server.listen(1)
        self.server.settimeout(1.0)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        self.get_logger().info(f"Listening for stitched-panorama clients on port {self.port}")

    def on_image(self, message: Image) -> None:
        frame = self.bridge.imgmsg_to_cv2(message, desired_encoding="bgr8")
        ok, encoded = cv2.imencode(
            ".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, self.quality]
        )
        if not ok:
            return
        frame_id = message.header.frame_id.encode("utf-8")[:65535]
        jpeg = encoded.tobytes()
        packet = HEADER.pack(
            MAGIC,
            len(jpeg),
            message.header.stamp.sec,
            message.header.stamp.nanosec,
            len(frame_id),
        ) + frame_id + jpeg
        with self.condition:
            self.packet = packet
            self.sequence += 1
            self.received_frames += 1
            self.received_bytes += len(jpeg)
            self.condition.notify_all()
        self.report_rate()

    def report_rate(self) -> None:
        now = time.monotonic()
        elapsed = now - self.last_report
        if elapsed < 5.0:
            return
        received = self.received_frames
        sent = self.sent_frames
        received_bytes = self.received_bytes
        sent_bytes = self.sent_bytes
        self.get_logger().info(
            "Panorama TCP throughput: received %.2f frames/s (%.2f Mbit/s), "
            "sent %.2f frames/s (%.2f Mbit/s)"
            % (
                (received - self.last_received_report) / elapsed,
                (received_bytes - self.last_received_bytes_report) * 8.0 / elapsed / 1.0e6,
                (sent - self.last_sent_report) / elapsed,
                (sent_bytes - self.last_sent_bytes_report) * 8.0 / elapsed / 1.0e6,
            )
        )
        self.last_received_report = received
        self.last_sent_report = sent
        self.last_received_bytes_report = received_bytes
        self.last_sent_bytes_report = sent_bytes
        self.last_report = now

    def serve(self) -> None:
        while not self.stopping:
            try:
                connection, address = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.get_logger().info(f"Accepted stitched-panorama client {address[0]}")
            sent_sequence = -1
            with connection:
                while not self.stopping:
                    with self.condition:
                        self.condition.wait_for(
                            lambda: self.stopping or self.sequence != sent_sequence,
                            timeout=1.0,
                        )
                        if self.stopping:
                            return
                        packet = self.packet
                        sent_sequence = self.sequence
                    if packet is None:
                        continue
                    try:
                        connection.sendall(packet)
                        self.sent_frames += 1
                        self.sent_bytes += len(packet)
                    except OSError:
                        break

    def stop(self) -> None:
        self.stopping = True
        with self.condition:
            self.condition.notify_all()
        self.server.close()
        self.thread.join(timeout=2.0)


def main() -> None:
    rclpy.init()
    node = PanoramaTcpServer()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.stop()
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
