import os

from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description():
    config = os.path.expanduser(
        "~/lianaiwei/src/fastlio2_ws/src/livox_ros_driver2/config/MID360_config.json"
    )
    return LaunchDescription(
        [
            Node(
                package="livox_ros_driver2",
                executable="livox_ros_driver2_node",
                name="livox_calibration_publisher",
                output="screen",
                parameters=[
                    {"xfer_format": 0},
                    {"multi_topic": 0},
                    {"data_src": 0},
                    {"publish_freq": 10.0},
                    {"output_data_type": 0},
                    {"frame_id": "livox_frame"},
                    {"lvx_file_path": "/home/orin/lianaiwei/tracking_deployment/unused.lvx"},
                    {"user_config_path": config},
                    {"cmdline_input_bd_code": "livox0000000001"},
                ],
                remappings=[("livox/lidar", "/livox/lidar"), ("livox/imu", "/livox/imu")],
            )
        ]
    )
