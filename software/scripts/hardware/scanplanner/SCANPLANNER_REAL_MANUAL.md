# SCAN-Planner + Elevator-LIO + Go2 manual run

This is the staged real-robot startup used on the Jetson. Start each command in
its own terminal and keep it running. Do not run FAST-LIO2 at the same time.

## 0. Power and wired readiness

Power the Go2 and its Ethernet switch. The Jetson wired profile autoconnects
with both required addresses:

```bash
ip -br addr show eth0
ping -I eth0 -c 1 192.168.1.148
ping -I eth0 -c 1 192.168.123.161
tail -n 20 ~/lianaiwei/logs/hardware/go2-lidar-auto-off.log
```

Expected addresses are `192.168.1.5/24` and `192.168.123.99/24`. The automatic
watcher publishes exactly one official `/utlidar/switch` `OFF` after Go2 DDS is
ready. If `OFF_PUBLISHED once` is absent after the controller is reachable:

```bash
source ~/lianaiwei/scripts/hardware/go2/unitree_go2_env.sh >/dev/null 2>&1
ros2 topic pub --once --qos-reliability best_effort --qos-durability volatile \
  /utlidar/switch std_msgs/msg/String "{data: 'OFF'}"
```

## 1. Mid-360 driver

```bash
source /opt/ros/humble/setup.bash
source ~/lianaiwei/src/elevator_lio_ws/install/setup.bash
ros2 launch ~/lianaiwei/scripts/elevator_lio/mid360_driver_launch.py
```

## 2. Elevator-LIO

Keep the robot still for at least 10 seconds while this process initializes:

```bash
~/lianaiwei/scripts/hardware/elevator_lio/run_elevator_lio_regular_safe.sh
```

## 3. Read-only Go2 check

```bash
~/lianaiwei/scripts/hardware/go2/inspect_go2_connection.sh
```

Continue only after it prints `COMPLETE`.

## 4. Go2 cmd_vel bridge

Keep the robot clear and the physical stop control available:

```bash
source ~/lianaiwei/scripts/hardware/go2/unitree_go2_env.sh
ros2 component standalone go2_driver go2_driver::Go2Driver --no-daemon
```

This starts only the existing `cmd_vel` to Unitree Sport API bridge. Do not use
the package's full launch file because it also starts the built-in LiDAR path.

## 5. SCAN-Planner

```bash
~/lianaiwei/scripts/hardware/scanplanner/run_scanplanner.sh real
```

The real launch consumes Elevator-LIO and starts SCAN-Planner's closed-loop
controller. Its current limits are `vx=0.75`, `vy=0.35`, and `vyaw=1.0`.

## 6. RViz

```bash
source /opt/ros/humble/setup.bash
source ~/lianaiwei/src/scanplanner_ws/install/setup.bash
ros2 launch scan_planner rviz.launch.py
```

Keep Fixed Frame `world`. Choose `2D Goal Pose`, click a clear destination, and
drag the arrow to choose final heading. Do not click a goal before odometry,
point cloud, and occupancy are visibly updating.

For a numeric goal with zero yaw:

```bash
source /opt/ros/humble/setup.bash
ros2 topic pub --once /move_base_simple/goal geometry_msgs/msg/PoseStamped \
  "{header: {frame_id: 'world'}, pose: {position: {x: 1.0, y: 0.0, z: 0.0}, orientation: {w: 1.0}}}"
```

## Stop

Run this first from any Jetson terminal or over SSH:

```bash
~/lianaiwei/scripts/hardware/go2/go2_sport_safe.sh stop
```

Then press `Ctrl-C` in the SCAN-Planner, Go2 bridge, Elevator-LIO, Mid-360, and
RViz terminals. Do not send another goal while stopping.
