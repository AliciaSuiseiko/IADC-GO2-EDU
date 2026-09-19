#!/usr/bin/env python3

import argparse
from collections import deque
import socket
import struct
import threading
import zlib

import rclpy
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy
from rclpy.serialization import deserialize_message, serialize_message
from rosidl_runtime_py.utilities import get_message


MAGIC = b"SNR1"
HEADER = struct.Struct("!4sBBII")
MAX_PAYLOAD = 128 * 1024 * 1024
SENSOR_QOS = QoSProfile(
    history=HistoryPolicy.KEEP_LAST,
    depth=1,
    reliability=ReliabilityPolicy.BEST_EFFORT,
    durability=DurabilityPolicy.VOLATILE,
)
RELIABLE_QOS = QoSProfile(
    history=HistoryPolicy.KEEP_LAST,
    depth=20,
    reliability=ReliabilityPolicy.RELIABLE,
    durability=DurabilityPolicy.VOLATILE,
)
MAX_PENDING_EVENTS = 256

UPLINK = {
    1: ("/registered_scan", "sensor_msgs/msg/PointCloud2"),
    2: ("/state_estimation", "nav_msgs/msg/Odometry"),
    3: ("/viewpoint_rep_header", "tare_planner/msg/ViewpointRep"),
    4: ("/aft_mapped_to_init_incremental", "nav_msgs/msg/Odometry"),
    5: ("/room_type_query", "tare_planner/msg/RoomType"),
    6: ("/room_navigation_query", "tare_planner/msg/NavigationQuery"),
    7: ("/room_early_stop_1", "tare_planner/msg/RoomEarlyStop1"),
    8: ("/object_type_query", "tare_planner/msg/ObjectType"),
    9: ("/target_object_query", "tare_planner/msg/TargetObject"),
    10: ("/target_object_spatial_query", "tare_planner/msg/TargetObjectWithSpatial"),
    11: ("/anchor_object_query", "tare_planner/msg/TargetObject"),
    12: ("/keyboard_input", "std_msgs/msg/String"),
}

DOWNLINK = {
    1: ("/object_nodes_list", "tare_planner/msg/ObjectNodeList"),
    2: ("/obj_points", "sensor_msgs/msg/PointCloud2"),
    3: ("/obj_boxes", "visualization_msgs/msg/MarkerArray"),
    4: ("/obj_labels", "visualization_msgs/msg/MarkerArray"),
    5: ("/cloud_image", "sensor_msgs/msg/Image"),
    6: ("/room_type_answer", "tare_planner/msg/RoomType"),
    7: ("/room_navigation_answer", "tare_planner/msg/VlmAnswer"),
    8: ("/object_type_answer", "tare_planner/msg/ObjectType"),
    9: ("/target_object_instruction", "tare_planner/msg/TargetObjectInstruction"),
    10: ("/target_object_answer", "tare_planner/msg/TargetObject"),
    11: ("/anchor_object_answer", "tare_planner/msg/TargetObject"),
    12: ("/vlm_answer", "rviz_2d_overlay_msgs/msg/OverlayText"),
}


def read_exact(connection: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise ConnectionError("bridge connection closed")
        data.extend(chunk)
    return bytes(data)


class FifoSender(Node):
    def __init__(self, topics, endpoint, listen, latest_only, latest_priority):
        super().__init__("sysnav_semantic_sender")
        self.endpoint = endpoint
        self.listen = listen
        self.latest_only = set(latest_only)
        self.latest_priority = tuple(latest_priority)
        self.pending_events = deque()
        self.pending_latest = {}
        self.condition = threading.Condition()
        self.stopping = threading.Event()
        self.connection = None
        self.server = None
        for topic_id, (topic, type_name) in topics.items():
            message_type = get_message(type_name)
            self.create_subscription(
                message_type,
                topic,
                lambda message, i=topic_id: self.capture(i, message),
                SENSOR_QOS if topic_id in self.latest_only else RELIABLE_QOS,
            )
        self.worker = threading.Thread(target=self.send_loop, daemon=True)
        self.worker.start()

    def capture(self, topic_id, message):
        raw = bytes(serialize_message(message))
        with self.condition:
            if topic_id in self.latest_only:
                self.pending_latest[topic_id] = raw
            else:
                if len(self.pending_events) >= MAX_PENDING_EVENTS:
                    self.pending_events.popleft()
                    self.get_logger().warning("Semantic event queue full; dropped oldest event")
                self.pending_events.append((topic_id, raw))
            self.condition.notify()

    def pop_pending(self):
        if self.pending_events:
            return self.pending_events.popleft()
        for topic_id in self.latest_priority:
            raw = self.pending_latest.pop(topic_id, None)
            if raw is not None:
                return topic_id, raw
        if self.pending_latest:
            return self.pending_latest.popitem()
        return None

    def connect(self):
        if self.listen:
            if self.server is None:
                self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                self.server.bind(self.endpoint)
                self.server.listen(1)
                self.server.settimeout(1.0)
                self.get_logger().info(
                    f"Listening on {self.endpoint[0]}:{self.endpoint[1]}"
                )
            try:
                connection, address = self.server.accept()
            except socket.timeout:
                return None
            self.get_logger().info(f"Accepted bridge client from {address[0]}")
        else:
            try:
                connection = socket.create_connection(self.endpoint, timeout=2.0)
            except OSError:
                return None
            self.get_logger().info(
                f"Connected to {self.endpoint[0]}:{self.endpoint[1]}"
            )
        connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        connection.settimeout(5.0)
        return connection

    def send_loop(self):
        while not self.stopping.is_set():
            if self.connection is None:
                try:
                    self.connection = self.connect()
                except OSError as error:
                    self.get_logger().warning(f"Bridge connect failed: {error}")
                if self.connection is None:
                    self.stopping.wait(1.0)
                    continue
            with self.condition:
                self.condition.wait_for(
                    lambda: self.stopping.is_set()
                    or bool(self.pending_events)
                    or bool(self.pending_latest),
                    timeout=1.0,
                )
                if self.stopping.is_set():
                    return
                item = self.pop_pending()
                if item is None:
                    continue
                topic_id, raw = item
            raw_size = len(raw)
            payload = zlib.compress(raw, level=1)
            try:
                self.connection.sendall(
                    HEADER.pack(MAGIC, topic_id, 1, raw_size, len(payload)) + payload
                )
            except OSError as error:
                self.get_logger().warning(f"Bridge send reset: {error}")
                with self.condition:
                    if topic_id in self.latest_only:
                        self.pending_latest.setdefault(topic_id, raw)
                    else:
                        self.pending_events.appendleft((topic_id, raw))
                try:
                    self.connection.close()
                except OSError:
                    pass
                self.connection = None

    def stop(self):
        self.stopping.set()
        with self.condition:
            self.condition.notify_all()
        if self.connection is not None:
            self.connection.close()
        if self.server is not None:
            self.server.close()
        self.worker.join(timeout=3.0)


class Receiver(Node):
    def __init__(self, topics, endpoint, listen):
        super().__init__("sysnav_semantic_receiver")
        self.endpoint = endpoint
        self.listen = listen
        self.types = {}
        self.topic_publishers = {}
        self.stopping = threading.Event()
        self.connection = None
        self.server = None
        for topic_id, (topic, type_name) in topics.items():
            message_type = get_message(type_name)
            self.types[topic_id] = message_type
            self.topic_publishers[topic_id] = self.create_publisher(
                message_type, topic, RELIABLE_QOS
            )
        self.worker = threading.Thread(target=self.receive_loop, daemon=True)
        self.worker.start()

    def connect(self):
        if self.listen:
            if self.server is None:
                self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                self.server.bind(self.endpoint)
                self.server.listen(1)
                self.server.settimeout(1.0)
                self.get_logger().info(
                    f"Listening on {self.endpoint[0]}:{self.endpoint[1]}"
                )
            try:
                connection, address = self.server.accept()
            except socket.timeout:
                return None
            self.get_logger().info(f"Accepted bridge client from {address[0]}")
        else:
            try:
                connection = socket.create_connection(self.endpoint, timeout=2.0)
            except OSError:
                return None
            self.get_logger().info(
                f"Connected to {self.endpoint[0]}:{self.endpoint[1]}"
            )
        connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        connection.settimeout(5.0)
        return connection

    def receive_loop(self):
        while not self.stopping.is_set():
            if self.connection is None:
                try:
                    self.connection = self.connect()
                except OSError as error:
                    self.get_logger().warning(f"Bridge connect failed: {error}")
                if self.connection is None:
                    self.stopping.wait(1.0)
                    continue
            try:
                magic, topic_id, flags, raw_size, payload_size = HEADER.unpack(
                    read_exact(self.connection, HEADER.size)
                )
                if magic != MAGIC or topic_id not in self.types:
                    raise ValueError("invalid bridge frame")
                if payload_size <= 0 or payload_size > MAX_PAYLOAD:
                    raise ValueError(f"invalid payload size: {payload_size}")
                payload = read_exact(self.connection, payload_size)
                raw = zlib.decompress(payload) if flags & 1 else payload
                if len(raw) != raw_size:
                    raise ValueError("bridge payload size mismatch")
                message = deserialize_message(raw, self.types[topic_id])
                self.topic_publishers[topic_id].publish(message)
            except socket.timeout:
                continue
            except (ConnectionError, OSError, ValueError, zlib.error) as error:
                if not self.stopping.is_set():
                    self.get_logger().warning(f"Bridge receive reset: {error}")
                try:
                    self.connection.close()
                except OSError:
                    pass
                self.connection = None

    def stop(self):
        self.stopping.set()
        if self.connection is not None:
            self.connection.close()
        if self.server is not None:
            self.server.close()
        self.worker.join(timeout=3.0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "role",
        choices=("jetson-uplink", "server-uplink", "server-downlink", "jetson-downlink"),
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int)
    args = parser.parse_args()

    settings = {
        "jetson-uplink": (FifoSender, UPLINK, False, 42103, {1, 2, 4}, (2, 4, 1)),
        "server-uplink": (Receiver, UPLINK, True, 42103, set(), ()),
        "server-downlink": (FifoSender, DOWNLINK, True, 42104, {1, 2, 3, 4, 5}, (1, 2, 3, 4, 5)),
        "jetson-downlink": (Receiver, DOWNLINK, False, 42104, set(), ()),
    }
    node_class, topics, listen, default_port, latest_only, latest_priority = settings[args.role]
    rclpy.init()
    if node_class is FifoSender:
        node = node_class(
            topics,
            (args.host, args.port or default_port),
            listen,
            latest_only,
            latest_priority,
        )
    else:
        node = node_class(topics, (args.host, args.port or default_port), listen)
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
