import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description():
    config = os.path.join(
        get_package_share_directory("insta360_x5_sdk_ros2"),
        "config",
        "x5_sdk.yaml",
    )
    return LaunchDescription(
        [
            Node(
                package="insta360_x5_sdk_ros2",
                executable="x5_sdk_node",
                name="x5_sdk_node",
                parameters=[config],
                output="screen",
            )
        ]
    )
