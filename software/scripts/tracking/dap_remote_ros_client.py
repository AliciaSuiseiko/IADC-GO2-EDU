#!/usr/bin/env python3
"""Asynchronous ROS 2 client for the bounded DAP TCP inference service."""

from __future__ import annotations

from concurrent.futures import Future, ThreadPoolExecutor
import json
import socket
import struct
import threading
import time
import zlib

import cv2
import numpy as np
import rclpy
from cv_bridge import CvBridge
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import CompressedImage, Image
from std_msgs.msg import String


def receive_exact(connection: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = connection.recv(size - len(chunks))
        if not chunk:
            raise ConnectionError("connection closed before payload completed")
        chunks.extend(chunk)
    return bytes(chunks)


def infer_remote(host: str, port: int, timeout: float, jpeg: bytes) -> tuple[dict, np.ndarray]:
    with socket.create_connection((host, port), timeout=timeout) as connection:
        connection.settimeout(timeout)
        connection.sendall(struct.pack("!I", len(jpeg)))
        connection.sendall(jpeg)
        header_size, payload_size = struct.unpack("!II", receive_exact(connection, 8))
        if header_size > 64 * 1024 or payload_size > 32 * 1024 * 1024:
            raise ValueError("DAP response exceeds configured protocol limits")
        metadata = json.loads(receive_exact(connection, header_size))
        compressed = receive_exact(connection, payload_size)
    raw = zlib.decompress(compressed)
    depth = np.frombuffer(raw, dtype=np.float16).reshape(metadata["shape"]).astype(np.float32)
    return metadata, depth


class DapRemoteRosClient(Node):
    def __init__(self) -> None:
        super().__init__("dap_remote_ros_client")
        self.declare_parameter("image_topic", "/camera/image/compressed")
        self.declare_parameter("depth_topic", "/camera/depth_dap")
        self.declare_parameter("server_host", "login.example")
        self.declare_parameter("server_port", 18761)
        self.declare_parameter("request_hz", 4.0)
        self.declare_parameter("timeout_sec", 2.0)
        self.declare_parameter("depth_scale", 100.0)
        self.declare_parameter("request_width", 1024)
        self.declare_parameter("jpeg_quality", 88)
        sensor_qos = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
        )
        self.bridge = CvBridge()
        self.lock = threading.Lock()
        self.latest = None
        self.last_requested_stamp = -1
        self.pending: Future | None = None
        self.retry_after = 0.0
        self.consecutive_errors = 0
        self.rpc_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="dap-rpc")
        self.depth_pub = self.create_publisher(Image, self.get_parameter("depth_topic").value, sensor_qos)
        self.diagnostics_pub = self.create_publisher(String, "/tracking/dap_diagnostics", 5)
        self.create_subscription(
            CompressedImage,
            self.get_parameter("image_topic").value,
            self._image_callback,
            sensor_qos,
        )
        self.create_timer(1.0 / float(self.get_parameter("request_hz").value), self._request_latest)

    def _image_callback(self, message: CompressedImage) -> None:
        stamp = int(message.header.stamp.sec) * 1_000_000_000 + int(message.header.stamp.nanosec)
        jpeg = bytes(message.data)
        request_width = int(self.get_parameter("request_width").value)
        if request_width > 0:
            frame = cv2.imdecode(np.frombuffer(jpeg, dtype=np.uint8), cv2.IMREAD_COLOR)
            if frame is None:
                self.get_logger().warning("Cannot decode DAP input JPEG")
                return
            request_height = max(1, request_width // 2)
            if frame.shape[1] != request_width or frame.shape[0] != request_height:
                frame = cv2.resize(frame, (request_width, request_height), interpolation=cv2.INTER_AREA)
            encoded, buffer = cv2.imencode(
                ".jpg",
                frame,
                [cv2.IMWRITE_JPEG_QUALITY, int(self.get_parameter("jpeg_quality").value)],
            )
            if not encoded:
                self.get_logger().warning("Cannot encode resized DAP request")
                return
            jpeg = buffer.tobytes()
        with self.lock:
            self.latest = (jpeg, message.header, stamp)

    def _request_latest(self) -> None:
        if time.monotonic() < self.retry_after:
            return
        if self.pending is not None and not self.pending.done():
            return
        with self.lock:
            packet = self.latest
        if packet is None or packet[2] == self.last_requested_stamp:
            return
        self.last_requested_stamp = packet[2]
        started = time.perf_counter()
        self.pending = self.rpc_executor.submit(
            infer_remote,
            str(self.get_parameter("server_host").value),
            int(self.get_parameter("server_port").value),
            float(self.get_parameter("timeout_sec").value),
            packet[0],
        )
        self.pending.add_done_callback(
            lambda future, header=packet[1], start=started: self._publish_result(future, header, start)
        )

    def _publish_result(self, future: Future, header, started: float) -> None:
        try:
            metadata, depth = future.result()
            depth *= float(self.get_parameter("depth_scale").value)
            message = self.bridge.cv2_to_imgmsg(depth, encoding="32FC1")
            message.header = header
            self.depth_pub.publish(message)
            payload = {
                "state": "OK",
                "roundtrip_ms": round((time.perf_counter() - started) * 1000.0, 3),
                "server_infer_ms": metadata.get("server_infer_ms"),
                "depth_shape": list(depth.shape),
                "depth_scale": float(self.get_parameter("depth_scale").value),
                "depth_is_metric": False,
            }
            self.consecutive_errors = 0
            self.retry_after = 0.0
        except Exception as error:
            self.consecutive_errors += 1
            delay = min(10.0, 0.25 * (2 ** min(self.consecutive_errors, 6)))
            self.retry_after = time.monotonic() + delay
            payload = {"state": "ERROR", "error": str(error)}
            self.get_logger().warning(f"DAP request failed; retry in {delay:.1f}s: {error}")
        diagnostics = String()
        diagnostics.data = json.dumps(payload, separators=(",", ":"))
        if rclpy.ok():
            self.diagnostics_pub.publish(diagnostics)

    def destroy_node(self):
        self.rpc_executor.shutdown(wait=False, cancel_futures=True)
        return super().destroy_node()


def main() -> None:
    rclpy.init()
    node = DapRemoteRosClient()
    try:
        rclpy.spin(node)
    except rclpy.executors.ExternalShutdownException:
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
