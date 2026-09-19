import os

from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description():
    config_path = os.path.expanduser(
        "~/lianaiwei/scripts/elevator_lio/MID360_config.json"
    )
    return LaunchDescription([
        Node(
            package="livox_ros_driver2",
            executable="livox_ros_driver2_node",
            name="livox_lidar_publisher_elevator_lio",
            output="screen",
            parameters=[
                {"xfer_format": 1},
                {"multi_topic": 0},
                {"data_src": 0},
                {"publish_freq": 10.0},
                {"output_data_type": 0},
                {"frame_id": "livox_frame"},
                {"lvx_file_path": "/tmp/livox_test.lvx"},
                {"user_config_path": config_path},
                {"cmdline_input_bd_code": "livox0000000001"},
            ],
        )
    ])
