# Upstream Components

This repository does not vendor full copies of the following research projects. The table records the source and revision used during deployment so the environment can be reconstructed without obscuring upstream authorship.

| Component | Upstream | Revision used | Local role |
| --- | --- | --- | --- |
| SysNav | <https://github.com/zwandering/SysNav> | `478727e5a559be22822d5d093b57431449336287` | Main VLN/navigation baseline |
| SCAN-Planner | <https://github.com/wuyi2121/SCAN-Planner> | `d0b921c9b05a6d291d144d60882b2e0e88d2c0e0` | Local trajectory-generation baseline |
| Elevator-LIO | <https://github.com/xiaofan4122/Elevator-LIO> | `1d79af77f3d9747ea57ef52a9b01d326a8ec561a` | Alternative LIO path |
| FAST-LIO ROS 2 | <https://github.com/Ericsii/FAST_LIO_ROS2> | `2fffc570a25d0df172720bac034fbdb6a13d2162` | Mapping and adapter tests |
| ApexNav | <https://github.com/Robotics-STAR-Lab/ApexNav> | `1ec9d155fc972fb8a139bd57f43b65247237601e` | Semantic/geometric exploration study |
| Direct visual-LiDAR calibration | <https://github.com/koide3/direct_visual_lidar_calibration> | `02a0dc039f5509708f384be4ff3228e0ae09352d` | X5-Mid-360 calibration experiments |
| SRU robot deployment | <https://github.com/leggedrobotics/sru-robot-deployment> | `568a96c6c704d9dede4d7293fa09b98d9cbff4e0` | Learning-based navigation study and smoke tests |
| ViPlanner | <https://github.com/leggedrobotics/viplanner> | `6fcf3c60f6fa3b28b3a11af054d6033825923789` | Learning-based planner study |
| Unitree Go2 driver | <https://github.com/Unitree-Go2-Robot/go2_driver> | `5a921a7df9b84b433cb5f62ab38ae4c553d39249` | Robot interface |
| Unitree ROS 2 | <https://github.com/unitreerobotics/unitree_ros2> | `0dfa8f2e444713c52c96c7b70c433b2609879a31` | Unitree messages and examples |

Additional perception experiments used DAP, ODTrack, deep-person-reid/OSNet, SAM2, YOLOE, OmniTrack, OA-VAT, FARM, and LH-VLN. Their code and model files are not redistributed here. Setup and evaluation scripts remain as an environment record and must be used with the official repositories and their licenses.
