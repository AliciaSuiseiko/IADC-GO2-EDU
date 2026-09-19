# SCAN-Planner real run from macOS terminals

All commands below run on the Mac. Keep each long-running command in its own
Terminal tab. Jetson is reached over Tailscale at `<jetson-tailscale-ip>`.

## One-command full stack

The supervised launcher defaults to safe preview: it performs the wired checks,
publishes one official L1 LiDAR `OFF`, and starts Mid-360, Elevator-LIO,
planner-only SCAN-Planner and RViz. The controller and Go2 `/cmd_vel` bridge are
hard-disabled, so an RViz goal can produce a trajectory but cannot move Go2:

```bash
ssh -t orin@<jetson-tailscale-ip> \
  '~/lianaiwei/scripts/hardware/scanplanner/run_scanplanner_full_stack.sh'
```

Automated safe validation starts the same isolated graph, checks live LIO and
occupancy, publishes a nearby planner-only goal, requires a B-spline, verifies
that `/cmd_vel` has no publisher, then stops everything:

```bash
ssh -t orin@<jetson-tailscale-ip> \
  '~/lianaiwei/scripts/hardware/scanplanner/run_scanplanner_full_stack.sh --validate'
```

Only a supervised real motion run may explicitly enable the controller and Go2
bridge. It never stands the robot up and never sends a goal. On `Control-C` or
SSH loss it publishes Unitree `StopMove` before stopping every child process:

```bash
ssh -t orin@<jetson-tailscale-ip> \
  '~/lianaiwei/scripts/hardware/scanplanner/run_scanplanner_full_stack.sh --arm-motion'
```

Read-only preflight, with no `OFF` and no processes started:

```bash
ssh -t orin@<jetson-tailscale-ip> \
  '~/lianaiwei/scripts/hardware/scanplanner/run_scanplanner_full_stack.sh --check'
```

The remaining sections document the equivalent manual sequence for diagnosis.

## Display and NoMachine

The boot service selects the display automatically. Connect a physical monitor
before powering the Jetson when local display is required; otherwise it creates
a NoMachine headless desktop. In both cases, open the connection from the Mac:

```bash
open "$HOME/Documents/NoMachine/Jetson Orin.nxs"
```

Manual overrides from the Mac are only needed after plugging or unplugging a
monitor while the Jetson is already running:

```bash
ssh -t orin@<jetson-tailscale-ip> \
  '~/lianaiwei/scripts/hardware/nomachine/nomachine-display-mode.sh headless'

ssh -t orin@<jetson-tailscale-ip> \
  '~/lianaiwei/scripts/hardware/nomachine/nomachine-display-mode.sh shared'
```

`shared` gives the physical monitor and NoMachine the same normal `orin` GNOME
desktop. `local` is an alias for `shared`.

## 0. Wired devices and automatic L1 OFF

```bash
ssh orin@<jetson-tailscale-ip> '
  ip -br addr show eth0
  ping -I eth0 -c 1 192.168.1.148
  ping -I eth0 -c 1 192.168.123.161
  tail -n 20 ~/lianaiwei/logs/hardware/go2-lidar-auto-off.log
'
```

Continue after both devices reply and the log says `OFF_PUBLISHED once`.

Official manual fallback:

```bash
ssh -t orin@<jetson-tailscale-ip> '
  source ~/lianaiwei/scripts/hardware/go2/unitree_go2_env.sh >/dev/null 2>&1
  ros2 topic pub --once \
    --qos-reliability best_effort \
    --qos-durability volatile \
    /utlidar/switch std_msgs/msg/String "{data: '\''OFF'\''}"
'
```

## 1. Mid-360 driver

```bash
ssh -t orin@<jetson-tailscale-ip> '
  source /opt/ros/humble/setup.bash
  source ~/lianaiwei/src/elevator_lio_ws/install/setup.bash
  exec ros2 launch ~/lianaiwei/scripts/elevator_lio/mid360_driver_launch.py
'
```

## 2. Elevator-LIO

Keep Go2 still for at least ten seconds after starting this command:

```bash
ssh -t orin@<jetson-tailscale-ip> \
  'exec ~/lianaiwei/scripts/hardware/elevator_lio/run_elevator_lio_regular_safe.sh'
```

## 3. Read-only Go2 check

```bash
ssh -t orin@<jetson-tailscale-ip> \
  '~/lianaiwei/scripts/hardware/go2/inspect_go2_connection.sh'
```

Continue only after it prints `COMPLETE`.

## 4. Go2 cmd_vel bridge

```bash
ssh -t orin@<jetson-tailscale-ip> '
  source ~/lianaiwei/scripts/hardware/go2/unitree_go2_env.sh
  exec ros2 component standalone go2_driver go2_driver::Go2Driver --no-daemon
'
```

## 5. SCAN-Planner

```bash
ssh -t orin@<jetson-tailscale-ip> \
  'exec ~/lianaiwei/scripts/hardware/scanplanner/run_scanplanner.sh real'
```

## 6. RViz in the NoMachine desktop

```bash
ssh -t orin@<jetson-tailscale-ip> '
  source ~/lianaiwei/scripts/hardware/nomachine/nomachine-session-env.sh
  source /opt/ros/humble/setup.bash
  source ~/lianaiwei/src/scanplanner_ws/install/setup.bash
  exec ros2 launch scan_planner rviz.launch.py
'
```

In RViz, use Fixed Frame `world`, then `2D Goal Pose` to click and drag a goal.

## Numeric goal from the Mac

The example sends `(x=1.0, y=0.0)` with zero yaw:

```bash
ssh -t orin@<jetson-tailscale-ip> '
  source /opt/ros/humble/setup.bash
  ros2 topic pub --once /move_base_simple/goal geometry_msgs/msg/PoseStamped \
    "{header: {frame_id: '\''world'\''}, pose: {position: {x: 1.0, y: 0.0, z: 0.0}, orientation: {w: 1.0}}}"
'
```

## Emergency stop and shutdown

Run StopMove first:

```bash
ssh orin@<jetson-tailscale-ip> \
  '~/lianaiwei/scripts/hardware/go2/go2_sport_safe.sh stop'
```

Then press `Control-C` in the SCAN-Planner, Go2 bridge, Elevator-LIO,
Mid-360, and RViz Terminal tabs.
