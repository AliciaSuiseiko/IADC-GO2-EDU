#!/usr/bin/env python3
import json
import time

import rclpy
from geometry_msgs.msg import PoseStamped
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from scan_planner_msgs.msg import Bspline
from sensor_msgs.msg import PointCloud2


class PreviewValidator(Node):
    def __init__(self):
        super().__init__("scanplanner_elevator_preview_validator")
        self.odom = None
        self.occupancy_messages = 0
        self.bspline = None
        self.goal = None
        self.create_subscription(
            Odometry, "/LIO/odom_vehicle", self.odom_callback, qos_profile_sensor_data
        )
        self.create_subscription(
            PointCloud2, "/grid_map/occupancy", self.occupancy_callback, qos_profile_sensor_data
        )
        self.create_subscription(Bspline, "/planning/bspline", self.bspline_callback, 10)
        self.goal_publisher = self.create_publisher(PoseStamped, "/move_base_simple/goal", 10)

    def odom_callback(self, message):
        self.odom = message

    def occupancy_callback(self, _message):
        self.occupancy_messages += 1

    def bspline_callback(self, message):
        self.bspline = message

    def publish_goal(self, dx, dy):
        goal = PoseStamped()
        goal.header.stamp = self.get_clock().now().to_msg()
        goal.header.frame_id = "world"
        goal.pose.position.x = self.odom.pose.pose.position.x + dx
        goal.pose.position.y = self.odom.pose.pose.position.y + dy
        # The planner replaces an RViz goal's height with the initialized body
        # height, but rejects incoming goals below -0.1 m before that step.
        goal.pose.position.z = 0.0
        goal.pose.orientation.w = 1.0
        self.goal = [goal.pose.position.x, goal.pose.position.y, goal.pose.position.z]
        self.goal_publisher.publish(goal)


def spin_until(node, predicate, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.1)
        if predicate():
            return True
    return False


def main():
    rclpy.init()
    node = PreviewValidator()
    try:
        if not spin_until(
            node, lambda: node.odom is not None and node.occupancy_messages > 0, 20.0
        ):
            raise SystemExit("missing Elevator-LIO odometry or SCAN occupancy map")

        # One-metre goals can be rejected by SCAN-Planner's unchanged dynamic
        # feasibility gate because the short spline leaves too little time for
        # its configured acceleration limit. Try useful local-planning distances
        # and several headings without relaxing any planner safety parameter.
        offsets = (
            (2.5, -0.75),
            (2.5, 0.0),
            (2.0, 1.5),
            (0.0, 2.5),
            (-2.0, 1.5),
            (-2.5, 0.0),
            (-2.0, -1.5),
            (0.0, -2.5),
        )
        for offset in offsets:
            node.bspline = None
            node.publish_goal(*offset)
            if spin_until(node, lambda: node.bspline is not None, 7.0):
                break

        if node.bspline is None:
            raise SystemExit("SCAN-Planner did not publish a B-spline for nearby goals")
        result = {
            "status": "PASS",
            "goal_offset_xy": offset,
            "goal_xyz": node.goal,
            "occupancy_messages": node.occupancy_messages,
            "trajectory_id": node.bspline.traj_id,
            "trajectory_order": node.bspline.order,
            "trajectory_control_points": len(node.bspline.pos_pts),
            "trajectory_knots": len(node.bspline.knots),
        }
        print(json.dumps(result, indent=2), flush=True)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
