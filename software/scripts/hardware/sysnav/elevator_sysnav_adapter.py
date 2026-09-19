#!/usr/bin/env python3

import copy
import math

import rclpy
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.executors import ExternalShutdownException
from rclpy.qos import QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import PointCloud2
from std_msgs.msg import Bool


class ElevatorSysnavAdapter(Node):
    def __init__(self):
        super().__init__("elevator_sysnav_adapter")
        self.declare_parameter("body_to_sensor_x", 0.32)
        self.declare_parameter("body_to_sensor_y", 0.0)
        self.declare_parameter("body_to_sensor_z", 0.15)
        self.body_to_sensor = (
            self.get_parameter("body_to_sensor_x").value,
            self.get_parameter("body_to_sensor_y").value,
            self.get_parameter("body_to_sensor_z").value,
        )
        self.last_odom_stamp = None
        self.odom_ready = False

        qos = QoSProfile(depth=20, reliability=ReliabilityPolicy.RELIABLE)
        self.state_publisher = self.create_publisher(
            Odometry, "/state_estimation", qos
        )
        self.scan_odom_publisher = self.create_publisher(
            Odometry, "/aft_mapped_to_init_incremental", qos
        )
        self.scan_publisher = self.create_publisher(
            PointCloud2, "/registered_scan", qos
        )
        self.health_publisher = self.create_publisher(
            Bool, "/state_estimation_health", qos
        )
        self.create_subscription(
            Odometry, "/LIO/odom_vehicle", self.on_odometry, qos
        )
        self.create_subscription(
            PointCloud2, "/LIO/clouds_lidar", self.on_cloud, qos
        )

    def publish_health(self, value):
        message = Bool()
        message.data = value
        self.health_publisher.publish(message)

    @staticmethod
    def finite_pose(message):
        point = message.pose.pose.position
        quaternion = message.pose.pose.orientation
        values = (
            point.x,
            point.y,
            point.z,
            quaternion.x,
            quaternion.y,
            quaternion.z,
            quaternion.w,
        )
        return all(math.isfinite(value) for value in values)

    @staticmethod
    def rotate(quaternion, vector):
        norm = math.sqrt(
            quaternion.x**2
            + quaternion.y**2
            + quaternion.z**2
            + quaternion.w**2
        )
        if norm < 1e-9:
            raise ValueError("invalid zero-norm orientation")
        qx = quaternion.x / norm
        qy = quaternion.y / norm
        qz = quaternion.z / norm
        qw = quaternion.w / norm
        vx, vy, vz = vector
        tx = 2.0 * (qy * vz - qz * vy)
        ty = 2.0 * (qz * vx - qx * vz)
        tz = 2.0 * (qx * vy - qy * vx)
        return (
            vx + qw * tx + qy * tz - qz * ty,
            vy + qw * ty + qz * tx - qx * tz,
            vz + qw * tz + qx * ty - qy * tx,
        )

    def on_odometry(self, message):
        stamp = float(message.header.stamp.sec) + float(message.header.stamp.nanosec) * 1e-9
        if not self.finite_pose(message):
            self.publish_health(False)
            return
        if self.last_odom_stamp is not None and stamp <= self.last_odom_stamp:
            self.publish_health(False)
            return

        output = copy.deepcopy(message)
        offset = self.rotate(output.pose.pose.orientation, self.body_to_sensor)
        output.pose.pose.position.x += offset[0]
        output.pose.pose.position.y += offset[1]
        output.pose.pose.position.z += offset[2]
        output.header.frame_id = "map"
        output.child_frame_id = "sensor"
        self.state_publisher.publish(output)
        self.scan_odom_publisher.publish(output)
        self.publish_health(True)
        self.last_odom_stamp = stamp
        self.odom_ready = True

    def on_cloud(self, message):
        if not self.odom_ready:
            return
        output = copy.deepcopy(message)
        output.header.frame_id = "map"
        self.scan_publisher.publish(output)


def main():
    rclpy.init()
    node = ElevatorSysnavAdapter()
    try:
        rclpy.spin(node)
    except (ExternalShutdownException, KeyboardInterrupt):
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
