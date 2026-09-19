#!/usr/bin/env python3

import os
import socket
import struct
import time

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import CompressedImage


HEADER = struct.Struct("!4sIIIH")
MAGIC = b"X5J1"


class X5TcpSender(Node):
    def __init__(self) -> None:
        super().__init__("x5_tcp_sender")
        self.host = os.environ.get("X5_TCP_SERVER", "127.0.0.1")
        self.port = int(os.environ.get("X5_TCP_PORT", "42101"))
        self.connection: socket.socket | None = None
        self.frames = 0
        self.next_connect_attempt = 0.0
        self.last_connect_warning = 0.0
        self.subscription = self.create_subscription(
            CompressedImage,
            "/camera/image/compressed",
            self.send,
            1,
        )

    def connect(self) -> bool:
        now = time.monotonic()
        if now < self.next_connect_attempt:
            return False
        try:
            connection = socket.create_connection((self.host, self.port), timeout=2.0)
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            connection.settimeout(2.0)
            self.connection = connection
            self.get_logger().info(f"Connected to X5 receiver at {self.host}:{self.port}")
            return True
        except OSError as error:
            self.next_connect_attempt = now + 2.0
            if now - self.last_connect_warning >= 60.0:
                self.get_logger().warning(
                    f"X5 receiver unavailable at {self.host}:{self.port}: {error}"
                )
                self.last_connect_warning = now
            return False

    def disconnect(self) -> None:
        if self.connection is not None:
            try:
                self.connection.close()
            except OSError:
                pass
            self.connection = None

    def send(self, message: CompressedImage) -> None:
        if self.connection is None and not self.connect():
            return

        frame_id = message.header.frame_id.encode("utf-8")[:65535]
        jpeg = bytes(message.data)
        header = HEADER.pack(
            MAGIC,
            len(jpeg),
            message.header.stamp.sec,
            message.header.stamp.nanosec,
            len(frame_id),
        )
        try:
            self.connection.sendall(header + frame_id + jpeg)
        except OSError as error:
            self.get_logger().warning(f"X5 TCP send failed: {error}")
            self.disconnect()
            return

        self.frames += 1
        if self.frames == 1:
            self.get_logger().info(f"Forwarding X5 JPEG frames ({len(jpeg)} bytes first frame)")


def main() -> None:
    rclpy.init()
    node = X5TcpSender()
    try:
        rclpy.spin(node)
    finally:
        node.disconnect()
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
