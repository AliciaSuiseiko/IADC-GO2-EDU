# Jetson to Go2

This directory contains the source-of-truth scripts for the isolated Jetson
workspace at `~/lianaiwei/src/unitree_go2_ws`.

The workspace also pins the unmodified Humble branch of
`Unitree-Go2-Robot/go2_driver`. It converts `geometry_msgs/Twist` on
`/cmd_vel` to Unitree `unitree_api/Request` messages on
`/api/sport/request`. This is a community driver, not an official Unitree
package. It is installed but never launched automatically.

After the wired state-only checks and zero-command test have passed, start only
the driver component needed by SCAN-Planner:

```bash
source ~/lianaiwei/scripts/hardware/go2/unitree_go2_env.sh
ros2 component standalone go2_driver go2_driver::Go2Driver --no-daemon
```

Do not use the package's full `go2_driver.launch.py` in this pipeline. It also
starts conversion for Go2's built-in lidar, while this deployment uses the
separate Mid-360 and Elevator-LIO topics.

## Network profiles

- The active `eth0` profile has both `192.168.123.99/24` for Go2 and
  `192.168.1.5/24` for Mid-360, with no default route.
- Both devices attach through the Go2-powered Ethernet switch.

## Safe connection check

```bash
~/lianaiwei/scripts/hardware/go2/go2_network_profile.sh up
~/lianaiwei/scripts/hardware/go2/inspect_go2_connection.sh
```

The inspection script only discovers topics and reads one motion-state sample.
It does not publish commands.

`go2_service_list` is also read-only. Do not use the upstream
`go2_robot_state_client` example for inspection: that example deliberately
switches `sport_mode` off and on before listing services.

The locally built `go2_service_switch` only accepts `unitree_lidar`,
`unitree_lidar_slam`, `obstacles_avoid`, and `voxel_height_mapping`. It requires
the service name to be repeated after `--confirm`; building the tool does not
execute it.

Do not disable obstacle avoidance or a lidar service while the robot can move.
First place Go2 in a clear area, keep the remote controller and emergency stop
available, and identify the exact service returned by `go2_service_list`.

## Built-in LiDAR automatic OFF

Unitree documents the built-in LiDAR control as DDS topic
`rt/utlidar/switch`, message type `std_msgs::msg::dds_::String_`, with exact
payload `OFF` or `ON`. The automatic watcher uses the ROS 2 publisher supplied
by ROS itself to publish one `OFF` after `192.168.123.161` comes online and its
DDS subscriber becomes discoverable. It does not stop services, publish `ON`,
or send robot motion commands.

The watcher rearms only after five consecutive failed reachability probes. It
therefore publishes once per observed Go2 connection rather than continuously:

```bash
~/lianaiwei/scripts/hardware/go2/go2_lidar_auto_off_watcher.sh
```

Its user crontab entry starts it after each Jetson reboot. Runtime output is
kept in `~/lianaiwei/logs/hardware/go2-lidar-auto-off.log`.

## Safe manual sport smoke

`go2_sport_safe.sh` uses the API IDs and request payloads from Unitree's
official ROS 2 `SportClient` example. It exposes only `StandUp`, a fixed
0.10 m/s one-second forward smoke followed by `StopMove`, and an explicit
`StopMove` command.

## SysNav to official Sport API

SysNav follows the official repository's Go2 chain: `pathFollower` publishes
`geometry_msgs/TwistStamped` on `/cmd_vel`, and the installed
`unitree_webrtc_ros/unitree_control` node converts it to Unitree WebRTC control.
The manager only starts and stops that official node; it contains no custom
motion protocol or dry-run bridge.

Motion is never armed by validation mode. Arm it explicitly only when the robot
is ready to follow the active planner output:

```bash
~/lianaiwei/scripts/hardware/go2/manage_sysnav_go2_bridge.sh arm
```

Stopping first publishes a zero `/cmd_vel`, then terminates the official
controller:

```bash
~/lianaiwei/scripts/hardware/go2/manage_sysnav_go2_bridge.sh stop
```


## Wired topology

The field topology is:

```text
Go2 battery -> Ethernet switch power
Ethernet switch -> Go2 controller (192.168.123.161)
Ethernet switch -> Mid-360 (192.168.1.148)
Ethernet switch -> external Jetson eth0
```

Powering Go2 off also powers the switch off, so both wired sensor/control paths
disappear together. The Jetson may remain powered from its separate battery.
