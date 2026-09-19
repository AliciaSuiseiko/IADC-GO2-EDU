#!/usr/bin/env python3

import os
import socket
import struct
import threading
import time

import cv2
import numpy as np
import rclpy
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from sensor_msgs.msg import CompressedImage, Image


HEADER = struct.Struct("!4sIIIH")
MAGIC = b"X5P1"
MAX_JPEG_BYTES = 12 * 1024 * 1024


def read_exact(connection: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = connection.recv(size - len(chunks))
        if not chunk:
            raise ConnectionError("stitched-panorama connection closed")
        chunks.extend(chunk)
    return bytes(chunks)


class PanoramaTcpReceiver(Node):
    def __init__(self) -> None:
        super().__init__("x5_panorama_tcp_receiver")
        self.host = os.environ.get("X5_TCP_SERVER", "127.0.0.1")
        self.port = int(os.environ.get("X5_PANORAMA_PORT", "42105"))
        self.image_publisher = self.create_publisher(Image, "/camera/image", 2)
        self.compressed_publisher = self.create_publisher(
            CompressedImage, "/camera/image/compressed", 2
        )
        self.connection = None
        self.stopping = threading.Event()
        self.next_connect = 0.0
        self.last_warning = 0.0
        self.frames = 0
        self.last_report = time.monotonic()
        self.last_report_frames = 0
        self.received_bytes = 0
        self.last_report_bytes = 0
        self.thread = threading.Thread(target=self.receive_loop, daemon=True)
        self.thread.start()

    def connect(self) -> bool:
        now = time.monotonic()
        if now < self.next_connect:
            return False
        try:
            self.connection = socket.create_connection((self.host, self.port), timeout=2.0)
            self.connection.settimeout(3.0)
            self.get_logger().info(
                f"Connected to official stitched panorama at {self.host}:{self.port}"
            )
            return True
        except OSError as error:
            self.next_connect = now + 2.0
            if now - self.last_warning >= 60.0:
                self.get_logger().warning(f"Stitched panorama unavailable: {error}")
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
                    raise ValueError("invalid stitched-panorama frame")
                frame_id = read_exact(self.connection, frame_id_size).decode(
                    "utf-8", errors="replace"
                )
                jpeg = read_exact(self.connection, jpeg_size)
                self.received_bytes += jpeg_size
                frame = cv2.imdecode(np.frombuffer(jpeg, dtype=np.uint8), cv2.IMREAD_COLOR)
                if frame is None:
                    raise ValueError("failed to decode stitched panorama")

                raw = Image()
                raw.header.stamp.sec = sec
                raw.header.stamp.nanosec = nanosec
                raw.header.frame_id = frame_id
                raw.height, raw.width = frame.shape[:2]
                raw.encoding = "bgr8"
                raw.is_bigendian = False
                raw.step = raw.width * 3
                raw.data = frame.tobytes()
                self.image_publisher.publish(raw)

                compressed = CompressedImage()
                compressed.header = raw.header
                compressed.format = "jpeg"
                compressed.data = jpeg
                self.compressed_publisher.publish(compressed)
                self.frames += 1
                if self.frames == 1:
                    self.get_logger().info(
                        f"Publishing official stitched panorama at {raw.width}x{raw.height}"
                    )
                now = time.monotonic()
                elapsed = now - self.last_report
                if elapsed >= 5.0:
                    self.get_logger().info(
                        "Panorama TCP receiver: %.2f frames/s (%.2f Mbit/s)"
                        % (
                            (self.frames - self.last_report_frames) / elapsed,
                            (self.received_bytes - self.last_report_bytes)
                            * 8.0
                            / elapsed
                            / 1.0e6,
                        )
                    )
                    self.last_report = now
                    self.last_report_frames = self.frames
                    self.last_report_bytes = self.received_bytes
            except socket.timeout:
                continue
            except (ConnectionError, OSError, ValueError) as error:
                if not self.stopping.is_set():
                    self.get_logger().warning(f"Stitched panorama reset: {error}")
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
    node = PanoramaTcpReceiver()
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
