#!/usr/bin/env python3

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, EmitEvent, RegisterEventHandler
from launch.event_handlers import OnProcessExit
from launch.events import Shutdown
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    timestamp_delay_sec = LaunchConfiguration("timestamp_delay_sec")
    root = os.path.expanduser("~/lianaiwei")
    camera_ws = os.path.join(root, "src", "camera_x5_ws")
    x5_config = os.path.join(
        get_package_share_directory("insta360_x5_sdk_ros2"),
        "config",
        "x5_sdk.yaml",
    )
    mid360_config = os.path.join(
        root, "scripts", "elevator_lio", "MID360_config.json"
    )
    data_parameter_base = os.path.join(
        camera_ws,
        "src",
        "360_camera_calibration",
        "install",
        "extrinsic_latency_calib",
        "data",
    )

    mid360 = Node(
        package="livox_ros_driver2",
        executable="livox_ros_driver2_node",
        name="livox_lidar_publisher_latency_calib",
        output="screen",
        parameters=[
            {
                "xfer_format": 1,
                "multi_topic": 0,
                "data_src": 0,
                "publish_freq": 10.0,
                "output_data_type": 0,
                "frame_id": "livox_frame",
                "lvx_file_path": "/tmp/livox_latency_calib.lvx",
                "user_config_path": mid360_config,
                "cmdline_input_bd_code": "livox0000000001",
            }
        ],
    )

    x5 = Node(
        package="insta360_x5_sdk_ros2",
        executable="x5_sdk_node",
        name="x5_sdk_node",
        output="screen",
        parameters=[
            x5_config,
            {
                "timestamp_delay_sec": ParameterValue(
                    timestamp_delay_sec, value_type=float
                )
            },
        ],
    )

    latency = Node(
        package="extrinsic_latency_calib",
        executable="latencyCalib",
        name="latencyCalib",
        output="screen",
        remappings=[("/imu/data", "/livox/imu")],
        parameters=[
            {
                # The upstream node rewrites /install/ to /src/ internally.
                "imu_save_dir": os.path.join(
                    data_parameter_base, "imu_latency.txt"
                ),
                "image_save_dir": os.path.join(
                    data_parameter_base, "image_latency.txt"
                ),
                "resizeImageWidth": 960,
                "maxTrackDis": 100.0,
                "boundary": 20,
            }
        ],
    )

    shutdown_handlers = [
        RegisterEventHandler(
            OnProcessExit(
                target_action=node,
                on_exit=[EmitEvent(event=Shutdown(reason=f"{name} exited"))],
            )
        )
        for node, name in (
            (mid360, "Mid-360 driver"),
            (x5, "X5 SDK"),
            (latency, "latency recorder"),
        )
    ]

    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "timestamp_delay_sec",
                default_value="0.0",
                description="Seconds subtracted from X5 image timestamps",
            ),
            mid360,
            x5,
            latency,
            *shutdown_handlers,
        ]
    )
