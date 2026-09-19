#!/usr/bin/env python3
import argparse
import json
import signal
from pathlib import Path

import numpy as np
import rclpy
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import PointCloud2
from sensor_msgs_py import point_cloud2


def rotation_matrix(quaternion):
    x, y, z, w = quaternion
    norm = np.linalg.norm(quaternion)
    if norm < 1e-12:
        raise ValueError("zero-length quaternion")
    x, y, z, w = quaternion / norm
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ],
        dtype=np.float32,
    )


def stamp_key(message):
    stamp = message.header.stamp
    return stamp.sec * 1_000_000_000 + stamp.nanosec


class WorldCloudCollector(Node):
    def __init__(self, topic, odom_topic, voxel_size, flush_frames):
        super().__init__("world_cloud_map_collector")
        self.voxel_size = voxel_size
        self.flush_frames = flush_frames
        self.frame_count = 0
        self.point_count = 0
        self.pending = []
        self.voxels = np.empty((0, 3), dtype=np.int32)
        self.odom_topic = odom_topic
        self.cloud_messages = {}
        self.odom_messages = {}
        self.create_subscription(PointCloud2, topic, self.cloud_callback, qos_profile_sensor_data)
        if odom_topic:
            self.create_subscription(
                Odometry, odom_topic, self.odom_callback, qos_profile_sensor_data
            )

    def cloud_callback(self, message):
        if self.odom_topic:
            key = stamp_key(message)
            self.cloud_messages[key] = message
            self.process_pair(key)
            self.trim_unmatched()
            return
        self.add_cloud(message, None)

    def odom_callback(self, message):
        key = stamp_key(message)
        self.odom_messages[key] = message
        self.process_pair(key)
        self.trim_unmatched()

    def process_pair(self, key):
        if key not in self.cloud_messages or key not in self.odom_messages:
            return
        cloud = self.cloud_messages.pop(key)
        odom = self.odom_messages.pop(key)
        self.add_cloud(cloud, odom)

    def trim_unmatched(self):
        for messages in (self.cloud_messages, self.odom_messages):
            if len(messages) > 100:
                for key in sorted(messages)[:-50]:
                    del messages[key]

    def add_cloud(self, message, odometry):
        points = point_cloud2.read_points_numpy(
            message, field_names=("x", "y", "z"), skip_nans=True
        )
        points = np.asarray(points, dtype=np.float32).reshape(-1, 3)
        points = points[np.all(np.isfinite(points), axis=1)]
        if not points.size:
            return
        if odometry is not None:
            pose = odometry.pose.pose
            rotation = rotation_matrix(
                np.array(
                    [
                        pose.orientation.x,
                        pose.orientation.y,
                        pose.orientation.z,
                        pose.orientation.w,
                    ],
                    dtype=np.float32,
                )
            )
            translation = np.array(
                [pose.position.x, pose.position.y, pose.position.z], dtype=np.float32
            )
            points = points @ rotation.T + translation

        self.frame_count += 1
        self.point_count += len(points)
        frame_voxels = np.floor(points / self.voxel_size).astype(np.int32)
        self.pending.append(np.unique(frame_voxels, axis=0))
        if len(self.pending) >= self.flush_frames:
            self.flush()

    def flush(self):
        if not self.pending:
            return
        chunks = [self.voxels] if self.voxels.size else []
        chunks.extend(self.pending)
        self.voxels = np.unique(np.concatenate(chunks, axis=0), axis=0)
        self.pending.clear()

    def save(self, output_prefix):
        self.flush()
        points = (self.voxels.astype(np.float32) + 0.5) * self.voxel_size
        output_prefix.parent.mkdir(parents=True, exist_ok=True)
        np.savez_compressed(output_prefix.with_suffix(".npz"), points=points)
        with output_prefix.with_suffix(".pcd").open("w", encoding="ascii") as stream:
            stream.write("# .PCD v0.7 - Point Cloud Data file format\n")
            stream.write("VERSION 0.7\nFIELDS x y z\nSIZE 4 4 4\n")
            stream.write("TYPE F F F\nCOUNT 1 1 1\n")
            stream.write(f"WIDTH {len(points)}\nHEIGHT 1\n")
            stream.write("VIEWPOINT 0 0 0 1 0 0 0\n")
            stream.write(f"POINTS {len(points)}\nDATA ascii\n")
            np.savetxt(stream, points, fmt="%.4f %.4f %.4f")
        summary = {
            "cloud_frames": self.frame_count,
            "input_points": self.point_count,
            "voxel_points": len(points),
            "voxel_size_m": self.voxel_size,
            "unmatched_cloud_messages": len(self.cloud_messages),
            "unmatched_odom_messages": len(self.odom_messages),
            "minimum_xyz_m": points.min(axis=0).tolist() if len(points) else None,
            "maximum_xyz_m": points.max(axis=0).tolist() if len(points) else None,
        }
        output_prefix.with_suffix(".json").write_text(
            json.dumps(summary, indent=2) + "\n", encoding="ascii"
        )
        print(json.dumps(summary, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--topic", required=True)
    parser.add_argument("--odom-topic")
    parser.add_argument("--output-prefix", type=Path, required=True)
    parser.add_argument("--voxel-size", type=float, default=0.10)
    parser.add_argument("--flush-frames", type=int, default=40)
    args = parser.parse_args()

    rclpy.init()
    node = WorldCloudCollector(args.topic, args.odom_topic, args.voxel_size, args.flush_frames)
    stop = False

    def request_stop(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    try:
        while rclpy.ok() and not stop:
            rclpy.spin_once(node, timeout_sec=0.2)
        node.save(args.output_prefix)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
