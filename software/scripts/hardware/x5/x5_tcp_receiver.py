#!/usr/bin/env python3

import os
import socket
import struct
import threading

import cv2
import numpy as np
import rclpy
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from sensor_msgs.msg import Image


HEADER = struct.Struct("!4sIIIH")
MAGIC = b"X5J1"
MAX_JPEG_BYTES = 8 * 1024 * 1024


def read_exact(connection: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = connection.recv(size - len(chunks))
        if not chunk:
            raise ConnectionError("X5 TCP connection closed")
        chunks.extend(chunk)
    return bytes(chunks)


class X5TcpReceiver(Node):
    def __init__(self) -> None:
        super().__init__("x5_tcp_receiver")
        self.bind_host = os.environ.get("X5_TCP_BIND", "0.0.0.0")
        self.port = int(os.environ.get("X5_TCP_PORT", "42101"))
        self.publisher = self.create_publisher(Image, "/camera/image", 2)
        self.frames = 0
        self.stopping = threading.Event()
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind((self.bind_host, self.port))
        self.server.listen(1)
        self.server.settimeout(1.0)
        self.thread = threading.Thread(target=self.receive_loop, daemon=True)
        self.thread.start()
        self.get_logger().info(f"Listening for X5 JPEG stream on {self.bind_host}:{self.port}")

    def receive_loop(self) -> None:
        while not self.stopping.is_set():
            try:
                connection, address = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return

            self.get_logger().info(f"Accepted X5 stream from {address[0]}:{address[1]}")
            with connection:
                try:
                    self.receive_connection(connection)
                except (ConnectionError, OSError, ValueError) as error:
                    if not self.stopping.is_set():
                        self.get_logger().warning(f"X5 TCP stream reset: {error}")

    def receive_connection(self, connection: socket.socket) -> None:
        while not self.stopping.is_set():
            magic, jpeg_size, sec, nanosec, frame_id_size = HEADER.unpack(
                read_exact(connection, HEADER.size)
            )
            if magic != MAGIC:
                raise ValueError("invalid X5 TCP frame magic")
            if jpeg_size <= 0 or jpeg_size > MAX_JPEG_BYTES:
                raise ValueError(f"invalid X5 JPEG size: {jpeg_size}")

            frame_id = read_exact(connection, frame_id_size).decode("utf-8", errors="replace")
            encoded = np.frombuffer(read_exact(connection, jpeg_size), dtype=np.uint8)
            frame = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
            if frame is None:
                self.get_logger().error("Failed to decode X5 TCP JPEG frame")
                continue

            message = Image()
            message.header.stamp.sec = sec
            message.header.stamp.nanosec = nanosec
            message.header.frame_id = frame_id
            message.height, message.width = frame.shape[:2]
            message.encoding = "bgr8"
            message.is_bigendian = False
            message.step = message.width * 3
            message.data = frame.tobytes()
            try:
                self.publisher.publish(message)
            except Exception:
                if self.stopping.is_set() or not rclpy.ok():
                    return
                raise

            self.frames += 1
            if self.frames == 1:
                self.get_logger().info(
                    f"Publishing X5 raw frames at {message.width}x{message.height}"
                )

    def stop(self) -> None:
        self.stopping.set()
        self.server.close()
        self.thread.join(timeout=2.0)


def main() -> None:
    rclpy.init()
    node = X5TcpReceiver()
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
