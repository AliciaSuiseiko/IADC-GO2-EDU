from pathlib import Path

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description():
    config = Path(get_package_share_directory("fastlio2_go2_adapter")) / "config" / "mid360_go2.yaml"
    return LaunchDescription(
        [
            Node(
                package="fastlio2_go2_adapter",
                executable="fastlio2_go2_adapter",
                name="fastlio2_go2_adapter",
                parameters=[str(config)],
                output="screen",
            )
        ]
    )
