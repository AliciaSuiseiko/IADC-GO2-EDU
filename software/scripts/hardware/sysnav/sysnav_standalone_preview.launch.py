#!/usr/bin/env python3

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


PREFIX = "/sysnav_standalone_preview"


def generate_launch_description():
    arise_share = get_package_share_directory("arise_slam_mid360")
    planner_share = get_package_share_directory("local_planner")
    arise_config = os.path.join(arise_share, "config", "livox_mid360.yaml")
    arise_calibration = os.path.join(
        arise_share, "config", "livox", "livox_mid360_calibration.yaml"
    )
    planner_config = os.path.join(planner_share, "config", "omniDir.yaml")
    robot_config = os.path.join(
        planner_share, "config", "unitree", "unitree_go2_fast.yaml"
    )

    shared_arise_overrides = {
        "PROJECT_NAME": PREFIX,
        "laser_topic": "/livox/lidar",
        "imu_topic": "/livox/imu",
        "odom_topic": PREFIX + "/unused_visual_odom",
        "world_frame": "sysnav_preview_map",
        "world_frame_rot": "sysnav_preview_map_rot",
        "sensor_frame": "sysnav_preview_sensor",
        "sensor_frame_rot": "sysnav_preview_sensor_rot",
        "calibration_file": arise_calibration,
    }

    feature_extraction = Node(
        package="arise_slam_mid360",
        executable="feature_extraction_node",
        name="feature_extraction_node",
        output="screen",
        parameters=[arise_config, shared_arise_overrides],
    )

    laser_mapping = Node(
        package="arise_slam_mid360",
        executable="laser_mapping_node",
        name="laser_mapping_node",
        output="screen",
        parameters=[
            arise_config,
            shared_arise_overrides,
            {"map_dir": LaunchConfiguration("map_file")},
        ],
    )

    imu_preintegration = Node(
        package="arise_slam_mid360",
        executable="imu_preintegration_node",
        name="imu_preintegration_node",
        output="screen",
        parameters=[arise_config, shared_arise_overrides],
    )

    sensor_scan = Node(
        package="sensor_scan_generation",
        executable="sensorScanGeneration",
        name="sensorScanGeneration",
        output="screen",
        condition=IfCondition(LaunchConfiguration("start_planner")),
        remappings=[
            ("/state_estimation", PREFIX + "/state_estimation"),
            ("/registered_scan", PREFIX + "/registered_scan"),
            ("/state_estimation_at_scan", PREFIX + "/state_estimation_at_scan"),
            ("/sensor_scan", PREFIX + "/sensor_scan"),
        ],
    )

    terrain_analysis = Node(
        package="terrain_analysis",
        executable="terrainAnalysis",
        name="terrainAnalysis",
        output="screen",
        condition=IfCondition(LaunchConfiguration("start_planner")),
        parameters=[{
            "scanVoxelSize": 0.05,
            "decayTime": 1.0,
            "noDecayDis": 1.75,
            "clearingDis": 8.0,
            "useSorting": True,
            "quantileZ": 0.25,
            "considerDrop": False,
            "limitGroundLift": False,
            "maxGroundLift": 0.15,
            "clearDyObs": True,
            "minDyObsDis": 0.14,
            "absDyObsRelZThre": 0.2,
            "minDyObsVFOV": -30.0,
            "maxDyObsVFOV": 35.0,
            "minDyObsPointNum": 1,
            "minOutOfFovPointNum": 10,
            "obstacleHeightThre": 0.1,
            "noDataObstacle": False,
            "noDataBlockSkipNum": 0,
            "minBlockPointNum": 10,
            "vehicleHeight": 1.5,
            "voxelPointUpdateThre": 100,
            "voxelTimeUpdateThre": 2.0,
            "minRelZ": -1.5,
            "maxRelZ": 0.3,
            "disRatioZ": 0.2,
        }],
        remappings=[
            ("/state_estimation", PREFIX + "/state_estimation"),
            ("/registered_scan", PREFIX + "/registered_scan"),
            ("/joy", PREFIX + "/unused_joy"),
            ("/map_clearing", PREFIX + "/unused_map_clearing"),
            ("/terrain_map", PREFIX + "/terrain_map"),
        ],
    )

    local_planner = Node(
        package="local_planner",
        executable="localPlanner",
        name="localPlanner",
        output="screen",
        condition=IfCondition(LaunchConfiguration("start_planner")),
        parameters=[
            {
                "pathFolder": os.path.join(planner_share, "paths"),
                "twoWayDrive": False,
                "laserVoxelSize": 0.05,
                "terrainVoxelSize": 0.2,
                "useTerrainAnalysis": True,
                "checkObstacle": True,
                "checkRotObstacle": False,
                "adjacentRange": 3.5,
                "obstacleHeightThre": 0.1,
                "groundHeightThre": 0.1,
                "costHeightThre1": 0.1,
                "costHeightThre2": 0.05,
                "useCost": False,
                "slowPathNumThre": 5,
                "slowGroupNumThre": 1,
                "pointPerPathThre": 2,
                "minRelZ": -0.4,
                "maxRelZ": 0.3,
                "dirWeight": 0.02,
                "dirThre": 90.0,
                "dirToVehicle": False,
                "pathScale": 0.875,
                "minPathScale": 0.675,
                "pathScaleStep": 0.1,
                "pathScaleBySpeed": True,
                "minPathRange": 0.8,
                "pathRangeStep": 0.6,
                "pathRangeBySpeed": True,
                "pathCropByGoal": True,
                "autonomyMode": False,
                "joyToSpeedDelay": 2.0,
                "joyToCheckObstacleDelay": 5.0,
                "freezeAng": 90.0,
                "freezeTime": 0.0,
                "goalX": 0.0,
                "goalY": 0.0,
                "sensorOffsetX": 0.32,
                "sensorOffsetY": 0.0,
            },
            planner_config,
            robot_config,
            {
                "autonomyMode": False,
                "sensorOffsetX": 0.32,
                "sensorOffsetY": 0.0,
            },
        ],
        remappings=[
            ("/state_estimation", PREFIX + "/state_estimation"),
            ("/registered_scan", PREFIX + "/registered_scan"),
            ("/terrain_map", PREFIX + "/terrain_map"),
            ("/joy", PREFIX + "/unused_joy"),
            ("/way_point", PREFIX + "/unused_way_point"),
            ("/speed", PREFIX + "/unused_speed"),
            ("/navigation_boundary", PREFIX + "/unused_navigation_boundary"),
            ("/added_obstacles", PREFIX + "/unused_added_obstacles"),
            ("/check_obstacle", PREFIX + "/unused_check_obstacle"),
            ("/slow_down", PREFIX + "/slow_down"),
            ("/path", PREFIX + "/path"),
            ("/free_paths", PREFIX + "/free_paths"),
        ],
    )

    return LaunchDescription([
        DeclareLaunchArgument(
            "map_file",
            default_value=os.path.expanduser(
                "~/lianaiwei/logs/sysnav-standalone-preview/pointcloud_local.txt"
            ),
        ),
        DeclareLaunchArgument("start_planner", default_value="true"),
        feature_extraction,
        laser_mapping,
        imu_preintegration,
        sensor_scan,
        terrain_analysis,
        local_planner,
    ])
