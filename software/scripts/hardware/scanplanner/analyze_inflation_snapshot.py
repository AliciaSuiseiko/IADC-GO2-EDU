#!/usr/bin/env python3
"""Compare SCAN-Planner's visible occupancy and inflated occupancy layers."""

import argparse
import math
import struct
import sys
import time

import numpy as np
import rclpy
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import PointCloud2


def cloud_xyz(msg: PointCloud2) -> np.ndarray:
    offsets = {field.name: field.offset for field in msg.fields}
    if not {"x", "y", "z"}.issubset(offsets):
        raise RuntimeError("PointCloud2 does not contain x/y/z fields")

    endian = ">" if msg.is_bigendian else "<"
    count = msg.width * msg.height
    points = np.empty((count, 3), dtype=np.float64)
    unpack = struct.Struct(f"{endian}f").unpack_from
    data = memoryview(msg.data)
    for index in range(count):
        base = index * msg.point_step
        points[index, 0] = unpack(data, base + offsets["x"])[0]
        points[index, 1] = unpack(data, base + offsets["y"])[0]
        points[index, 2] = unpack(data, base + offsets["z"])[0]
    return points[np.isfinite(points).all(axis=1)]


def stamp_seconds(msg) -> float:
    return msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9


def quaternion_matrix(msg: Odometry) -> np.ndarray:
    q = msg.pose.pose.orientation
    x, y, z, w = q.x, q.y, q.z, q.w
    norm = math.sqrt(x * x + y * y + z * z + w * w)
    if norm < 1e-9:
        return np.eye(3)
    x, y, z, w = x / norm, y / norm, z / norm, w / norm
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ]
    )


def voxel_keys(points: np.ndarray, resolution: float) -> np.ndarray:
    indices = np.floor(points / resolution + 1e-6).astype(np.int64)
    bias = 1 << 20
    shifted = indices + bias
    if np.any(shifted < 0) or np.any(shifted >= (1 << 21)):
        raise RuntimeError("voxel index exceeds diagnostic key range")
    return (shifted[:, 0] << 42) | (shifted[:, 1] << 21) | shifted[:, 2]


def inflation_offsets(resolution: float, radius: float, z_up: float, z_down: float) -> np.ndarray:
    xy_steps = math.ceil(radius / resolution)
    z_up_steps = math.ceil(z_up / resolution)
    z_down_steps = math.ceil(z_down / resolution)
    offsets = []
    for x in range(-xy_steps, xy_steps + 1):
        for y in range(-xy_steps, xy_steps + 1):
            if math.hypot(x * resolution, y * resolution) >= radius:
                continue
            for z in range(-z_down_steps, z_up_steps + 1):
                offsets.append((x, y, z))
    return np.asarray(offsets, dtype=np.int64)


class Snapshot(Node):
    def __init__(self):
        super().__init__("scanplanner_inflation_snapshot")
        self.occupancy = None
        self.inflated = None
        self.sensor_odom = None
        self.create_subscription(
            PointCloud2, "/grid_map/occupancy", self._occupancy_cb, qos_profile_sensor_data
        )
        self.create_subscription(
            PointCloud2,
            "/grid_map/occupancy_inflate",
            self._inflated_cb,
            qos_profile_sensor_data,
        )
        self.create_subscription(
            Odometry, "/LIO/odom_imu", self._sensor_odom_cb, qos_profile_sensor_data
        )

    def _occupancy_cb(self, msg):
        self.occupancy = msg

    def _inflated_cb(self, msg):
        self.inflated = msg

    def _sensor_odom_cb(self, msg):
        self.sensor_odom = msg

    def ready(self):
        if self.occupancy is None or self.inflated is None or self.sensor_odom is None:
            return False
        return abs(stamp_seconds(self.occupancy) - stamp_seconds(self.inflated)) <= 0.15


def describe_relative(name: str, points: np.ndarray, odom: Odometry):
    if points.size == 0:
        print(f"{name}: none")
        return
    p = odom.pose.pose.position
    origin = np.array([p.x, p.y, p.z])
    relative = (points - origin) @ quaternion_matrix(odom)
    near = relative[np.linalg.norm(relative, axis=1) <= 1.0]
    print(
        f"{name}: count={len(points)} z_from_sensor=[{relative[:, 2].min():.3f},"
        f" {relative[:, 2].max():.3f}] near_1m={len(near)}"
    )
    if len(near):
        print(
            f"{name}_near_1m_bounds: x=[{near[:, 0].min():.3f},{near[:, 0].max():.3f}] "
            f"y=[{near[:, 1].min():.3f},{near[:, 1].max():.3f}] "
            f"z=[{near[:, 2].min():.3f},{near[:, 2].max():.3f}]"
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--resolution", type=float, default=0.05)
    parser.add_argument("--radius", type=float, default=0.25)
    parser.add_argument("--z-up", type=float, default=0.10)
    parser.add_argument("--z-down", type=float, default=0.40)
    args = parser.parse_args()

    rclpy.init()
    node = Snapshot()
    deadline = time.monotonic() + args.timeout
    while rclpy.ok() and time.monotonic() < deadline and not node.ready():
        rclpy.spin_once(node, timeout_sec=0.2)

    if not node.ready():
        node.destroy_node()
        rclpy.shutdown()
        print("ERROR: timed out waiting for synchronized map snapshots", file=sys.stderr)
        return 2

    occupancy = cloud_xyz(node.occupancy)
    inflated = cloud_xyz(node.inflated)
    odom = node.sensor_odom
    offsets = inflation_offsets(args.resolution, args.radius, args.z_up, args.z_down)
    occ_indices = np.floor(occupancy / args.resolution + 1e-6).astype(np.int64)
    visible_dilation = np.unique(
        np.concatenate(
            [voxel_keys((occ_indices + offset) * args.resolution, args.resolution) for offset in offsets]
        )
    )
    explained = np.isin(voxel_keys(inflated, args.resolution), visible_dilation)
    unresolved = inflated[~explained]

    print(f"snapshot_stamp_delta_s={abs(stamp_seconds(node.occupancy) - stamp_seconds(node.inflated)):.4f}")
    print(f"inflation_kernel_voxels={len(offsets)}")
    print(f"visible_occupancy={len(occupancy)} inflated={len(inflated)}")
    print(
        f"inflated_explained_by_visible={int(explained.sum())} "
        f"({100.0 * explained.mean() if len(explained) else 100.0:.2f}%) "
        f"unresolved={len(unresolved)}"
    )
    describe_relative("visible_occupancy", occupancy, odom)
    describe_relative("unresolved_inflated", unresolved, odom)

    node.destroy_node()
    rclpy.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
