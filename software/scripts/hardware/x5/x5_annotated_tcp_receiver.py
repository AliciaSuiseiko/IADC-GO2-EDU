#!/usr/bin/env python3

import os
import socket
import struct
import threading
import time

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import CompressedImage


HEADER = struct.Struct("!4sIIIH")
MAGIC = b"X5A1"
MAX_JPEG_BYTES = 8 * 1024 * 1024


def read_exact(connection: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = connection.recv(size - len(chunks))
        if not chunk:
            raise ConnectionError("annotated-image connection closed")
        chunks.extend(chunk)
    return bytes(chunks)


class AnnotatedTcpReceiver(Node):
    def __init__(self) -> None:
        super().__init__("x5_annotated_tcp_receiver")
        self.host = os.environ.get("X5_TCP_SERVER", "127.0.0.1")
        self.port = int(os.environ.get("X5_ANNOTATED_PORT", "42102"))
        self.publisher = self.create_publisher(
            CompressedImage, "/annotated_image/compressed", 2
        )
        self.connection = None
        self.stopping = threading.Event()
        self.next_connect = 0.0
        self.last_warning = 0.0
        self.thread = threading.Thread(target=self.receive_loop, daemon=True)
        self.thread.start()

    def connect(self) -> bool:
        now = time.monotonic()
        if now < self.next_connect:
            return False
        try:
            self.connection = socket.create_connection((self.host, self.port), timeout=2.0)
            # Read one complete framed JPEG before returning to the ROS executor.
            # A short nonblocking timeout can discard a partial TCP frame.
            self.connection.settimeout(3.0)
            self.get_logger().info(f"Connected to annotated stream at {self.host}:{self.port}")
            return True
        except OSError as error:
            self.next_connect = now + 2.0
            if now - self.last_warning >= 60.0:
                self.get_logger().warning(f"Annotated stream unavailable: {error}")
                self.last_warning = now
            return False

    def receive_loop(self) -> None:
        while not self.stopping.is_set():
            if self.connection is None and not self.connect():
                self.stopping.wait(0.2)
                continue
            try:
                magic, jpeg_size, sec, nanosec, frame_id_size = HEADER.unpack(
                    read_exact(self.connection, HEADER.size)
                )
                if magic != MAGIC or not 0 < jpeg_size <= MAX_JPEG_BYTES:
                    raise ValueError("invalid annotated-image frame")
                frame_id = read_exact(self.connection, frame_id_size).decode(
                    "utf-8", errors="replace"
                )
                jpeg = read_exact(self.connection, jpeg_size)
                message = CompressedImage()
                message.header.stamp.sec = sec
                message.header.stamp.nanosec = nanosec
                message.header.frame_id = frame_id
                message.format = "jpeg"
                message.data = jpeg
                self.publisher.publish(message)
            except socket.timeout:
                continue
            except (ConnectionError, OSError, ValueError) as error:
                if not self.stopping.is_set():
                    self.get_logger().warning(f"Annotated stream reset: {error}")
                if self.connection is not None:
                    self.connection.close()
                self.connection = None
                self.next_connect = time.monotonic() + 1.0

    def stop(self) -> None:
        self.stopping.set()
        if self.connection is not None:
            self.connection.close()
        self.thread.join(timeout=2.0)


def main() -> None:
    rclpy.init()
    node = AnnotatedTcpReceiver()
    try:
        rclpy.spin(node)
    finally:
        node.stop()
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
