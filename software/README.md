# Software Integration Record

This directory preserves the scripts, ROS 2 package, validation utilities, and upstream patches used while reproducing and integrating navigation and panoramic-perception components on the IADC GO2 EDU platform.

The goal is practical reproducibility. Many components are upstream research systems and were used with limited or no algorithmic modification. The work recorded here is primarily environment construction, interface adaptation, hardware bring-up, failure diagnosis, test automation, and measured deployment. A stable run is itself the intended engineering outcome; this repository does not relabel reproduction as a new algorithm.

## Contents

| Path | What it contains |
| --- | --- |
| `ros2_packages/insta360_x5_ros2` | Lightweight X5 UVC/GStreamer ROS 2 driver and launch/config files |
| `scripts/hardware/go2` | Go2 network checks, LiDAR-off guard, bridge management, and supervised motion helpers |
| `scripts/hardware/mid360` | Mid-360 capture, timestamp/FoV analysis, FAST-LIO2 diagnostics, and map export |
| `scripts/hardware/elevator_lio` | Elevator-LIO launch and monitoring helpers |
| `scripts/hardware/scanplanner` | SCAN-Planner safe launch, simulation/preview checks, dynamic-obstacle validation, and patches |
| `scripts/hardware/sysnav` | SysNav launch, monitoring, semantic bridge, runtime guard, and baseline capture |
| `scripts/hardware/x5` | X5 capture, MediaSDK/UVC utilities, TCP transport, calibration, and SysNav checks |
| `scripts/hardware/nomachine` | Remote visualization session helpers |
| `scripts/tracking` | Panoramic SOT, ReID, spherical-state recovery, DAP service/client, evaluation, and setup scripts |
| `patches` | Selected upstream patches kept separately for review and replay |

## Verified Scope

- SysNav simulation and source-level pipeline analysis.
- X5, Mid-360, Jetson, and Go2 sensor/interface bring-up.
- FAST-LIO2 mapping and data capture; Elevator-LIO build, replay, and static-sensor checks.
- SCAN-Planner build, simulation, adapter, and planner-only trajectory output. The controller was deliberately disabled in the documented preview.
- Distributed X5 semantic/depth experiments using DAP and open-vocabulary detections.
- Panoramic person-tracking frontend with ODTrack, OSNet, spherical Kalman prediction, detector-based recovery, event-triggered SAM2, and asynchronous DAP support.

The following were not completed as end-to-end claims: autonomous SysNav robot missions, closed-loop SCAN-Planner chassis execution, cross-room person following, paper-level SRU/ViPlanner training reproduction, and a general long-horizon task agent.

## Configuration Before Use

Public copies replace institution-specific login hosts and VPN addresses with placeholders. Before using cluster or remote-compute helpers, configure the relevant host, SSH key, storage root, and ROS network for your own machines. Do not run the motion scripts without a supervised robot, a working stop path, and verified localization.

Models, datasets, bags, virtual environments, proprietary SDK archives, and credentials are intentionally excluded. See [UPSTREAM_COMPONENTS.md](UPSTREAM_COMPONENTS.md) for source repositories and pinned commits.

## License

Original integration scripts in this directory are released under the MIT License in `software/LICENSE`. Files derived from or expressed as patches against upstream projects remain subject to their respective upstream licenses.
