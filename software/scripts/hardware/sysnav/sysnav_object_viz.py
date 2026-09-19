#!/usr/bin/env python3

import rclpy
from builtin_interfaces.msg import Duration
from rclpy.node import Node
from visualization_msgs.msg import Marker, MarkerArray


class SysNavObjectViz(Node):
    def __init__(self) -> None:
        super().__init__("sysnav_object_viz")
        self.declare_parameter("marker_lifetime_sec", 30.0)
        self.declare_parameter("text_height", 0.18)
        self.declare_parameter("box_alpha", 0.65)
        self.marker_lifetime = self.duration(
            float(self.get_parameter("marker_lifetime_sec").value)
        )
        self.text_height = float(self.get_parameter("text_height").value)
        self.box_alpha = float(self.get_parameter("box_alpha").value)

        self.label_pub = self.create_publisher(
            MarkerArray, "/sysnav_viz/obj_labels", 10
        )
        self.box_pub = self.create_publisher(
            MarkerArray, "/sysnav_viz/obj_boxes", 10
        )
        self.create_subscription(MarkerArray, "/obj_labels", self.on_labels, 10)
        self.create_subscription(MarkerArray, "/obj_boxes", self.on_boxes, 10)

    @staticmethod
    def duration(seconds: float) -> Duration:
        whole = int(seconds)
        return Duration(sec=whole, nanosec=int((seconds - whole) * 1e9))

    def on_labels(self, message: MarkerArray) -> None:
        for marker in message.markers:
            if marker.action == Marker.ADD:
                marker.scale.z = self.text_height
                marker.lifetime = self.marker_lifetime
        self.label_pub.publish(message)

    def on_boxes(self, message: MarkerArray) -> None:
        for marker in message.markers:
            if marker.action == Marker.ADD:
                marker.color.a = min(marker.color.a, self.box_alpha)
                marker.lifetime = self.marker_lifetime
        self.box_pub.publish(message)


def main() -> None:
    rclpy.init()
    node = SysNavObjectViz()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
