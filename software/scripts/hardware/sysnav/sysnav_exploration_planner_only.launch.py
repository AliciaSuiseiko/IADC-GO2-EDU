#!/usr/bin/env python3

import os

from ament_index_python.packages import PackageNotFoundError, get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess, IncludeLaunchDescription
from launch.conditions import IfCondition
from launch.launch_description_sources import (
    FrontendLaunchDescriptionSource,
    PythonLaunchDescriptionSource,
)
from launch.substitutions import LaunchConfiguration, PythonExpression
from launch_ros.actions import Node


# Measured Go2 payload geometry. Both localization backends expose a
# gravity-aligned sensor origin while the planner needs the Go2 body center.
LIDAR_FORWARD_OF_BODY_M = 0.32
LIDAR_HEIGHT_ABOVE_GROUND_M = 0.48
LIDAR_ABOVE_BODY_CENTER_M = 0.15
ROBOT_LENGTH_M = 0.60
ROBOT_WIDTH_M = 0.45
# Terrain analysis interprets vehicleHeight from the local ground surface, not
# from the LiDAR origin. The X5 center is about 0.79 m above ground; its vertical
# half-size is about 0.062 m. Use a 0.90 m full payload envelope with margin.
ROBOT_COLLISION_HEIGHT_M = 0.90
OBSTACLE_HEIGHT_THRESHOLD_M = 0.10
MAX_LINEAR_SPEED_MPS = 0.5
MAX_LINEAR_ACCEL_MPS2 = 0.5
MAX_YAW_RATE_DEG_S = 28.647890  # 0.5 rad/s


def share_file(package, *parts):
    return os.path.join(get_package_share_directory(package), *parts)


def generate_launch_description():
    try:
        arise_share = get_package_share_directory("arise_slam_mid360")
    except PackageNotFoundError:
        # Elevator/FAST-LIO2 runs do not require ARISE to be installed. Keep its
        # source-side config discoverable without making it a parse-time dependency.
        arise_share = os.path.expanduser(
            "~/lianaiwei/src/sysnav_ws/src/SysNav/src/slam/arise_slam_mid360"
        )
    fastlio_adapter_share = get_package_share_directory("fastlio2_go2_adapter")
    local_planner_share = get_package_share_directory("local_planner")
    tare_share = get_package_share_directory("tare_planner")

    lio_backend = LaunchConfiguration("lio_backend")
    use_arise = IfCondition(
        PythonExpression(["'", lio_backend, "' == 'arise'"])
    )
    use_fastlio2 = IfCondition(
        PythonExpression(["'", lio_backend, "' == 'fastlio2'"])
    )
    use_elevator = IfCondition(
        PythonExpression(["'", lio_backend, "' == 'elevator'"])
    )
    enable_local_planner = IfCondition(LaunchConfiguration("enable_local_planner"))
    enable_path_follower = IfCondition(LaunchConfiguration("enable_path_follower"))

    arise_config = os.path.join(arise_share, "config", "livox_mid360.yaml")
    arise_calibration = os.path.join(
        arise_share, "config", "livox", "livox_mid360_calibration.yaml"
    )
    arise_parameters = [
        arise_config,
        {
            "laser_topic": "/livox/lidar",
            "imu_topic": "/livox/imu",
            "calibration_file": arise_calibration,
            "map_dir": os.path.expanduser(
                "~/lianaiwei/logs/sysnav-exploration/pointcloud_local.txt"
            ),
        },
    ]

    feature_extraction = Node(
        package="arise_slam_mid360",
        executable="feature_extraction_node",
        name="feature_extraction_node",
        output="screen",
        parameters=arise_parameters,
        condition=use_arise,
    )
    laser_mapping = Node(
        package="arise_slam_mid360",
        executable="laser_mapping_node",
        name="laser_mapping_node",
        output="screen",
        parameters=arise_parameters,
        condition=use_arise,
    )
    imu_preintegration = Node(
        package="arise_slam_mid360",
        executable="imu_preintegration_node",
        name="imu_preintegration_node",
        output="screen",
        parameters=arise_parameters,
        condition=use_arise,
    )

    fastlio2 = Node(
        package="fast_lio",
        executable="fastlio_mapping",
        name="fastlio_mapping",
        output="screen",
        parameters=[
            LaunchConfiguration("fastlio2_config"),
            {
                "common.lid_topic": "/livox/lidar",
                "common.imu_topic": "/livox/imu",
            },
        ],
        condition=use_fastlio2,
    )
    fastlio2_sysnav_adapter = Node(
        package="fastlio2_go2_adapter",
        executable="fastlio2_sysnav_adapter",
        name="fastlio2_sysnav_adapter",
        output="screen",
        parameters=[
            os.path.join(
                fastlio_adapter_share, "config", "mid360_sysnav.yaml"
            )
        ],
        condition=use_fastlio2,
    )
    elevator_lio = Node(
        package="lio",
        executable="lio",
        name="elevator_lio",
        output="screen",
        parameters=[{"config_path": LaunchConfiguration("elevator_config")}],
        condition=use_elevator,
    )
    elevator_sysnav_adapter = ExecuteProcess(
        cmd=["python3", LaunchConfiguration("elevator_adapter_script")],
        output="screen",
        condition=use_elevator,
    )

    sensor_scan = IncludeLaunchDescription(
        FrontendLaunchDescriptionSource(
            share_file(
                "sensor_scan_generation", "launch", "sensor_scan_generation.launch"
            )
        )
    )
    terrain_analysis = Node(
        package="terrain_analysis",
        executable="terrainAnalysis",
        name="terrainAnalysis",
        output="screen",
        parameters=[
            {
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
                "obstacleHeightThre": OBSTACLE_HEIGHT_THRESHOLD_M,
                "noDataObstacle": False,
                "noDataBlockSkipNum": 0,
                "minBlockPointNum": 10,
                "vehicleHeight": ROBOT_COLLISION_HEIGHT_M,
                "voxelPointUpdateThre": 100,
                "voxelTimeUpdateThre": 2.0,
                "minRelZ": -0.65,
                "maxRelZ": 0.45,
                "disRatioZ": 0.2,
            }
        ],
    )
    terrain_analysis_ext = Node(
        package="terrain_analysis_ext",
        executable="terrainAnalysisExt",
        name="terrainAnalysisExt",
        output="screen",
        parameters=[
            {
                "scanVoxelSize": 0.1,
                "decayTime": 4.0,
                "noDecayDis": 0.0,
                "clearingDis": 30.0,
                "useSorting": True,
                "quantileZ": 0.1,
                "vehicleHeight": ROBOT_COLLISION_HEIGHT_M,
                "voxelPointUpdateThre": 100,
                "voxelTimeUpdateThre": 2.0,
                "lowerBoundZ": -0.65,
                "upperBoundZ": 0.45,
                "disRatioZ": 0.1,
                "checkTerrainConn": True,
                "terrainConnThre": 0.5,
                "terrainUnderVehicle": -LIDAR_HEIGHT_ABOVE_GROUND_M,
                "ceilingFilteringThre": 1.0,
                "localTerrainMapRadius": 4.0,
            }
        ],
    )

    local_planner = Node(
        package="local_planner",
        executable="localPlanner",
        name="localPlanner",
        output="screen",
        parameters=[
            os.path.join(local_planner_share, "config", "omniDir.yaml"),
            os.path.join(
                local_planner_share,
                "config",
                "unitree",
                "unitree_go2_fast.yaml",
            ),
            {
                "pathFolder": os.path.join(local_planner_share, "paths"),
                # Keep planning and execution forward-only on the Go2. Reverse
                # goals require turning first instead of selecting a backward path.
                "twoWayDrive": False,
                "autonomyMode": True,
                "useTerrainAnalysis": True,
                "checkObstacle": True,
                "checkRotObstacle": False,
                "sensorOffsetX": LIDAR_FORWARD_OF_BODY_M,
                "sensorOffsetY": 0.0,
                "vehicleLength": ROBOT_LENGTH_M,
                "vehicleWidth": ROBOT_WIDTH_M,
                "obstacleHeightThre": OBSTACLE_HEIGHT_THRESHOLD_M,
                "minRelZ": -0.65,
                "maxRelZ": 0.45,
                "maxSpeed": MAX_LINEAR_SPEED_MPS,
                "autonomySpeed": MAX_LINEAR_SPEED_MPS,
            },
        ],
        condition=enable_local_planner,
    )
    path_follower = Node(
        package="local_planner",
        executable="pathFollower",
        name="pathFollower",
        output="screen",
        parameters=[
            os.path.join(local_planner_share, "config", "omniDir.yaml"),
            os.path.join(
                local_planner_share,
                "config",
                "unitree",
                "unitree_go2_fast.yaml",
            ),
            {
                # Match the forward-only local-planner policy on the Go2.
                # Reverse goals require turning before driving forward.
                "twoWayDrive": False,
                "autonomyMode": True,
                "sensorOffsetX": LIDAR_FORWARD_OF_BODY_M,
                "sensorOffsetY": 0.0,
                "maxSpeed": MAX_LINEAR_SPEED_MPS,
                "autonomySpeed": MAX_LINEAR_SPEED_MPS,
                "maxAccel": MAX_LINEAR_ACCEL_MPS2,
                "maxYawRate": MAX_YAW_RATE_DEG_S,
            },
        ],
        condition=enable_path_follower,
    )

    vehicle_transform = Node(
        package="tf2_ros",
        executable="static_transform_publisher",
        name="vehicleTransPublisher",
        arguments=[
            str(-LIDAR_FORWARD_OF_BODY_M),
            "0",
            str(-LIDAR_ABOVE_BODY_CENTER_M),
            "0",
            "0",
            "0",
            "/sensor",
            "/vehicle",
        ],
    )

    tare = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(os.path.join(tare_share, "explore_world.launch")),
        launch_arguments={
            "scenario": "matterport_real",
            "use_sim_time": "false",
            "use_boundary": "true",
        }.items(),
    )
    room_segmentation = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            os.path.join(tare_share, "room_segmentation.launch")
        ),
        launch_arguments={
            "scenario": "matterport_real",
            "use_sim_time": "false",
        }.items(),
    )

    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "lio_backend",
                default_value="arise",
                description="Localization backend: arise, fastlio2, or elevator",
            ),
            DeclareLaunchArgument(
                "fastlio2_config",
                default_value=os.path.expanduser(
                    "~/lianaiwei/scripts/hardware/mid360/fastlio2_mid360_real.yaml"
                ),
            ),
            DeclareLaunchArgument(
                "elevator_config",
                default_value="root_mid360_go2.yaml",
            ),
            DeclareLaunchArgument(
                "elevator_adapter_script",
                default_value=os.path.expanduser(
                    "~/lianaiwei/scripts/sysnav/elevator_sysnav_adapter.py"
                ),
            ),
            DeclareLaunchArgument(
                "enable_local_planner",
                default_value="true",
                description=(
                    "Start localPlanner to turn TARE waypoints into local paths."
                ),
            ),
            DeclareLaunchArgument(
                "enable_path_follower",
                default_value="true",
                description=(
                    "Start pathFollower, which publishes velocity commands. "
                    "Set false for manual mapping and planning-only diagnostics."
                ),
            ),
            feature_extraction,
            laser_mapping,
            imu_preintegration,
            fastlio2,
            fastlio2_sysnav_adapter,
            elevator_lio,
            elevator_sysnav_adapter,
            sensor_scan,
            terrain_analysis,
            terrain_analysis_ext,
            local_planner,
            path_follower,
            vehicle_transform,
            tare,
            room_segmentation,
        ]
    )
