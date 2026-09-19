# 香港科技大学（广州）IADC 实习技术交接

更新时间：2026-09-20
交接人：练瑷玮
范围：VLN 文献学习、SysNav 复现、Go2 真机部署、定位与规划适配、分布式语义感知、全景人物跟踪，以及后续研究方向调研。

## 1. 这份文档解决什么问题

这不是一份只列“装过哪些仓库”的流水账，而是要回答四件事：

1. 我从最初进入 VLN 开始，沿着什么思路推进到 SysNav 和真机系统。
2. Jetson 每个工作区、每个主要 ROS 包分别负责什么。
3. 哪些工作只是读过或审计过，哪些真正构建、运行或用真机传感器验证过。
4. 后续接手者从哪里继续，怎样避免覆盖已有修改、误启动机器人或重复踩坑。

全文采用以下状态口径：

- **已阅读**：读过论文、课程或代码说明，理解其输入、输出和方法位置。
- **已审计**：检查过源码、依赖、许可证、模型、数据和部署条件。
- **已通过最小验证**：完成构建、导入、离线回放、存储帧推理或仿真测试。
- **已通过传感器验证**：真实 X5、Mid-360 或 Go2 接口确实在线并产生数据。
- **已通过运动闭环**：机器人真实运动并完成相应功能。除明确写出外，本文不会把“规划器有轨迹输出”描述成运动闭环完成。

## 2. 总体技术路线

整个实习工作的主线不是让大模型直接控制机器人，而是：

```text
语言与视觉模型负责理解目标、提供语义证据或候选建议
                         ↓
LIO / SLAM、地图、可达性、碰撞检查和规划器负责约束与执行
                         ↓
Go2 底层接口负责真实运动
```

SysNav 被选为唯一的主系统骨架，因为它已经包含：

- Mid-360 定位与点云；
- Room-Viewpoint-Object 表示；
- TARE 探索与全局/局部候选；
- 开放词汇检测、分割和三维对象投影；
- 房间与对象层面的 VLM 推理；
- Go2 的真实执行接口。

后续研究过的 ApexNav、DualMap、DAP、FARM、OmniTrack、OA-VAT、SRU、ViPlanner 和 SCAN-Planner，都应作为可替换模块、对照或灵感来源，而不是再并行运行一套完整地图和规划系统。

## 3. 从头到尾的工作时间线

| 时间 | 工作内容与结果 |
|---|---|
| 2026 年 7 月 | 学习 VLN 基础、R2R、VLN-CE、VLFM、LOVON、视频式 VLA、学习式局部导航、空间记忆和安全执行。建立论文矩阵，并选择 SysNav 作为主 baseline。 |
| 8 月 4 日 | 完成 SysNav、ApexNav 和 DualMap 的源码接口审计，明确不维护三套并行地图和规划器。 |
| 8 月 7-10 日 | 整理 Jetson 工作区；构建 FAST-LIO2、SCAN-Planner、SysNav 和 SRU；建立 Tailscale、NoMachine 和分布式计算路径；采集 Mid-360 数据并保存地图；打通 X5 到服务器的传输。 |
| 8 月 8-12 日 | 构建 Elevator-LIO；完成同一数据包回放；定义 LIO 到 SCAN-Planner 的消息接口；在禁用控制器的条件下验证 SCAN 的地图、搜索和轨迹输出。 |
| 8 月 12-18 日 | 审计 SysNav 的 Go2 控制边界；重建规范的 Jetson baseline；完成分布式 ROS、语义推理与若干无运动全链路验证。 |
| 8 月 14 日 | 对照官方源码恢复 baseline 参数，定位早期分布式语义链只回传标注图、不回传结构化对象消息的问题。 |
| 8 月 15-20 日 | 调研 X5 CameraSDK、MediaSDK、实时拼接、时间戳、全景传输和语义模型共载。 |
| 8 月 26-30 日 | 进行 X5-Mid-360 时间与空间标定；增加运行监控；分析玻璃隔断和墙面缺失导致的房间分裂、合并和 Room ID 抖动。 |
| 8 月 31 日-9 月 1 日 | 统一审计 DAP、FARM、OmniTrack、OA-VAT、LH-VLN 和 SAM 3；其中 DAP 完成服务器与 Jetson 最小部署，其余项目按依赖和数据条件完成源码审计或最小验证；用 X5 数据运行 DAP/YOLOE，验证稀疏 LiDAR 融合，并拒绝跨姿态不一致的外参优化结果。 |
| 9 月 9-10 日 | 实现全景长时单目标人物跟踪、身份保护、球面 Kalman 预测、检测/ReID 恢复、按需 SAM2 和异步 DAP 客户端，并在 QuadTrack 子集和 X5 实时图像上测试。 |
| 9 月 20 日 | 重新检查 Jetson 当前目录和 Git 状态；保存脏仓库补丁和未跟踪配置；形成中文交接、代码清单和 AI 接手 Prompt。 |

## 4. 前期 VLN 学习与论文调研

### 4.1 基础阶段

首先通过深蓝学院 VLN 课程、三篇 VLN 综述以及 R2R、VLN-CE 建立基础概念：

- 离散导航图与连续空间的区别；
- SR、SPL、NE、OSR、nDTW、sDTW 等指标；
- 指令编码、视觉编码、跨模态对齐、动作空间与训练方式；
- 仿真成功不等于真机系统具备定位、避障和实时执行能力。

资料位置：

- `Wk1/2022 VLN Survey.pdf`
- `Wk1/2024 VLN Survey.pdf`
- `Wk1/2026 VLN Survey.pdf`
- `Wk2/深蓝学院VLN入门/`
- `Wk2/读的paper/USTGZ Majun/paper_notes/`

### 4.2 地图和 Frontier 路线

重点阅读了 VLFM、CA-Nav、LOVON，以及后续的 SysNav、ApexNav：

- VLFM 将图像语言相似度投影到价值地图，再对 Frontier 排序。
- CA-Nav 加入约束和子指令阶段管理。
- LOVON 面向腿式机器人，将 LLM 任务规划、开放词汇感知和真实执行结合起来。
- ApexNav 通过 Frontier 语义分布统计决定何时启用语义探索。
- SysNav 用 Room-Viewpoint-Object 表示和 TARE 探索形成更完整的系统骨架。

这一阶段形成的核心认识是：VLM 可以决定“哪里更值得去”，但几何地图和规划器仍应决定“能不能去、怎样安全到达”。

### 4.3 视频式和端到端 VLN/VLA 路线

阅读了 NaVid、Uni-NaVid、StreamVLN、NavDP、AgentVLN、SpaceVLN 等工作：

- NaVid/Uni-NaVid 从 RGB 视频和文本直接输出动作。
- StreamVLN 用 KV cache 保存短期历史，用深度和位姿将长期视觉 token 投影到三维并去重，通过 SFT 和 DAgger 训练。
- NavDP/NoMaD 使用 diffusion 生成局部轨迹或 waypoint。
- AgentVLN 和 SpaceVLN 增加工具、记忆、空间地图、反思或回退。

这些论文提供了学习式策略的上界，但也暴露了实时性、解释性、训练数据和安全边界问题。因此当前部署没有让 VLM 直接输出 `/cmd_vel`。

### 4.4 学习式局部导航

对 SRU Navigation、ViPlanner、NoMaD、NavDP、SaferPath、SkyVLN 和 SCAN-Planner 做了重点学习：

- SRU：Depth 经 RegNet、FPN、Attention 和 SRU 空间记忆，最后用 PPO 训练速度策略。
- ViPlanner：Depth、语义图和目标经双 ResNet-18 与 planning head，预测三维关键点和碰撞概率；用显式几何/语义 cost 训练，不是 RL。
- SaferPath/SkyVLN：学习模块提出指导，MPC/NMPC 或显式安全层约束执行。
- SCAN-Planner：使用显式占据地图、搜索和 B 样条优化输出局部轨迹。

RSL 轻量环境完成了源码导入和 CUDA smoke，但没有安装完整 Isaac Sim/Isaac Lab，也没有宣称完成论文级训练复现。

## 5. SysNav 原始系统如何工作

### 5.1 几何与导航链

```text
Mid-360 + IMU
    ↓
ARISE-SLAM / LIO
    ↓
/state_estimation + /registered_scan
    ↓
terrain analysis + room segmentation
    ↓
keypose graph + candidate viewpoints + coverage state
    ↓
TARE global/local planning
    ↓
waypoint + local planner
    ↓
Go2 执行接口
```

### 5.2 语义链

```text
X5 全景图像
    ↓
YOLOE / YOLO-World 检测 + BoT-SORT 短时 ID
    ↓
SAM2 实例 mask
    ↓
结合点云和位姿做三维反投影
    ↓
ObjectNode 更新
    ↓
Room-Viewpoint-Object 表示与目标验证
```

BoT-SORT 的 ID 只能用于短时连续跟踪，不等于跨房间、跨时间或重启后的永久对象身份。长期对象记忆仍需要三维位置、外观、类别后验、时间和负证据共同维护。

### 5.3 VLM 链

VLM 节点处理：

- 任务字段拆解；
- 房间类型判断；
- 跨房间选择；
- 候选对象确认；
- 空间关系确认；
- 部分停止与切换决策。

VLM 不负责底层定位、碰撞检查和速度控制。

## 6. Jetson 总体目录

连接方式：

```bash
ssh <jetson-user>@<jetson-vpn-ip>
```

规范根目录：

```text
<workspace-root>
```

目录职责：

| 目录 | 用途 |
|---|---|
| `src` | 各算法独立 ROS/源码工作区 |
| `scripts` | 构建、启动、诊断、标定和部署脚本 |
| `venvs` | SysNav、SRU 等 Python 环境，含绝对路径，不应随意移动 |
| `tracking_envs` | DAP、tracking 等独立环境 |
| `models` | 主系统模型文件 |
| `tracking_deployment/models` | Tracking、DAP、ReID 和 TensorRT 模型 |
| `recordings` | X5、Mid-360 与实验录像 |
| `logs` | 历次运行日志和状态文件 |
| `diagnostics` | 精选诊断结果 |
| `archive` | 旧源码、上游快照和本次补丁归档 |
| `downloads` | 可复用安装包、wheel 和外部依赖 |
| `vendor` | 第三方源码、相机 SDK 和本地补丁 |

## 7. 每个 Workspace 和包的职责

### 7.1 `sysnav_ws`：当前唯一活跃的 SysNav 工作区

路径：`<workspace-root>/src/sysnav_ws`

这是交接后应优先理解的工作区。`sysnav_official_ws` 只用于和上游比较，不能与它混用。

#### 定位与基础依赖

| 包 | 作用 |
|---|---|
| `arise_slam_mid360` | 读取 Mid-360/IMU，运行特征提取、IMU 预积分和激光建图，输出位姿与注册点云。 |
| `arise_slam_mid360_msgs` | ARISE-SLAM 自定义 ROS 消息。 |
| `livox_ros_driver2` | Livox Mid-360 驱动和 CustomMsg。 |
| `Sophus` | SE(3)/SO(3) 李群运算依赖。 |
| `ceres-solver` | 非线性最小二乘优化依赖。 |
| `gtsam` | 图优化和状态估计依赖。 |

#### 几何处理与局部执行

| 包 | 作用 |
|---|---|
| `sensor_scan_generation` | 将地图坐标系中的注册点云转换为传感器局部扫描表示。 |
| `terrain_analysis` | 计算近场地形高度、障碍和可通行性。 |
| `terrain_analysis_ext` | 在更大尺度上维护扩展地形信息。 |
| `local_planner` | 包含 `localPlanner` 和 `pathFollower`，接收 waypoint/路径并形成底层跟踪接口。 |
| `vehicle_simulator` | 仿真车辆状态、传感器和系统级 launch，也包含真机组合 launch。 |
| `waypoint_example` | 产生示例 waypoint，用于独立测试局部规划链。 |

#### TARE 探索与房间拓扑

| 包 | 作用 |
|---|---|
| `tare_planner` | 核心探索器；维护 keypose graph、viewpoint、覆盖状态、房间分割、全局 TSP、局部候选和最终 waypoint。主要可执行程序为 `tare_planner_node`、`room_segmentation` 和 `navigationBoundary`。 |
| `boundary_handler` | 从边界或地图信息构建/维护导航边界图。 |
| `graph_decoder` | 解码可见性图或房间级图结构。 |
| `visibility_graph_msg` | 定义可见性图 ROS 消息。 |

#### 语义和语言

| 包 | 作用 |
|---|---|
| `semantic_mapping` | `detection_node` 做开放词汇检测与短时跟踪；`semantic_mapping_node` 调用分割、点云反投影和对象合并，发布对象节点。 |
| `vlm_node` | `vlm_reasoning_node` 处理房间分类、任务拆解、房间选择、对象和空间关系确认；`keyboard_input` 用于交互式任务输入。 |

#### 相机、机器人和通信

| 包 | 作用 |
|---|---|
| `receive_x5` | 本项目加入的 Insta360 X5 UVC 全景适配，发布 SysNav 可用图像。 |
| `receive_theta` | 上游 Ricoh Theta 相机驱动，主要用于官方基线对照。 |
| `unitree_webrtc_ros` | 通过 WebRTC 与 Go2 通信。 |
| `domain_bridge` | 跨 ROS Domain 转发指定 topic，用于隔离不同子系统。 |
| `ros_tcp_endpoint` | Unity/ROS TCP 通信，用于仿真和工具链。 |
| `serial` | 串口通用依赖。 |

#### 可视化和操作工具

| 包 | 作用 |
|---|---|
| `visualization_tools` | 发布和显示地图、轨迹与系统状态。 |
| `goalpoint_rviz_plugin` | 在 RViz 中设置目标点。 |
| `waypoint_rviz_plugin` | 在 RViz 中设置 waypoint。 |
| `teleop_rviz_plugin` / `teleop_rviz_plugin_plus` | RViz 遥控工具。 |
| `teleop_joy_controller` | 手柄遥控。 |
| `rviz_2d_overlay_msgs` / `rviz_2d_overlay_plugins` | 在 RViz 中显示二维文字和状态覆盖层。 |

稳定入口：

```bash
source <workspace-root>/scripts/activate_sysnav.sh
<workspace-root>/scripts/build_sysnav.sh
```

### 7.2 `sysnav_official_ws`：官方对照树

路径：`<workspace-root>/src/sysnav_official_ws`

包含与活跃树近似的 31 个包，但没有本项目加入的 `receive_x5`。用途是比较官方参数、launch 和源码行为。不要在该目录继续部署或把它误当作生产工作区。

### 7.3 `fastlio2_ws`：ROS 2 FAST-LIO2

| 包 | 作用 |
|---|---|
| `fast_lio` | FAST-LIO2 激光惯性里程计和建图，主可执行程序为 `fastlio_mapping`。 |
| `fastlio2_go2_adapter` | 把 FAST-LIO2 的 odometry、body cloud 和 occupancy 输入转换成 Go2、SysNav 或 SCAN 所需坐标和 topic。 |
| `livox_ros_driver2` | Mid-360 ROS 2 驱动。 |

当前重要文件：`config/mid360_real.yaml` 尚未提交，已单独归档。FAST-LIO2 已完成直播建图、地图保存和数据包采集，但在当前安装与部分运动条件下出现漂移或发散，因此没有被当成最终稳定定位结论。

### 7.4 `fastlio2_ros1_ws`：ROS 1 对照路径

包含 `fast_lio` 和 `livox_ros_driver2`。用于兼容官方 ROS 1 生态或做行为对照，不是当前 SysNav 主链。

### 7.5 `elevator_lio_ws`：Elevator-LIO

| 包 | 作用 |
|---|---|
| `lio` | Elevator-LIO 主体，针对普通运动和电梯/退化运动维持连续定位；本地增加了 Go2/Mid-360 配置和发布适配。 |
| `livox_ros_driver2` | Mid-360 驱动。 |

该工作区完成 ARM64 构建、完整数据包回放、静止真传感器测试，并接入 SCAN-Planner。真实移动场景的长期精度仍需统一数据集比较。

### 7.6 `scanplanner_ws`：SCAN-Planner 独立局部规划链

| 包 | 作用 |
|---|---|
| `plan_env` | 维护局部占据地图、距离/碰撞查询和射线投射。 |
| `path_searching` | 在局部地图中做动态 A* 等初始路径搜索。 |
| `bspline_opt` | 将离散初始路径优化成平滑 B 样条轨迹。 |
| `scan_planner` | 主规划节点，负责地图更新、搜索、优化、重规划和轨迹发布。 |
| `scan_planner_msgs` | SCAN 自定义消息。 |
| `traj_utils` | B 样条、轨迹和可视化工具。 |
| `local_sensing_node` | 在仿真中生成局部点云/深度感知。 |
| `map_generator` | 发布 PCD 测试地图。 |
| `mockamap` | 程序化生成测试点云环境。 |
| `waypoint_generator` | 将 RViz 目标转换为规划 waypoint。 |
| `odom_visualization` | 显示里程计并发布相关 TF。 |
| `pose_utils` | 位姿和矩阵转换工具。 |
| `go2_description` | Go2 URDF、RViz 和仿真描述。 |

已完成 13 包构建、B 样条测试、确定性仿真、FAST-LIO2/Elevator-LIO 适配和真实 Mid-360 的 planner-only 输出。控制器曾被刻意禁用，因此不能把这部分写成完整 Go2 自主运动。

### 7.7 `camera_x5_ws`：Insta360 X5 与标定

| 包 | 作用 |
|---|---|
| `insta360_x5_ros2` | UVC/GStreamer ROS 2 节点，当前首选真实全景输入。 |
| `insta360_x5_sdk_ros2` | CameraSDK 预览流适配，用于测试 SDK 能力和双鱼眼/拼接路径。 |
| `extrinsic_latency_calib` | 视觉-LiDAR 外参和延迟标定工具，本地源码有修改。 |
| `receive_theta` | 上游 Theta 驱动，主要作对照。 |

结论：X5 UVC 模式可直接提供机内拼接、稳像的 `2880x1440` ERP MJPEG，是当前实时路径。MediaSDK 能产生正确 ERP，但测试链约 4.4-4.6 FPS。

### 7.8 `direct_visual_lidar_calibration_ws`

只有一个主包 `direct_visual_lidar_calibration`，通过图像和点云直接配准估计相机-LiDAR 外参。当前仓库为适配 ROS 2、GTSAM 和数据预处理做过本地修改。

多个物理姿态的优化结果触碰旋转 trust region，且不同姿态不一致，因此候选外参被拒绝，没有写入生产配置。这一点必须保留，不能只挑一个数值看起来更好的结果。

### 7.9 `sru_ws`：SRU 学习与部署研究

源码分为四部分：

- `sru-depth-pretraining`：带噪深度 VAE/编码器预训练。
- `sru-pytorch-spatial-learning`：SRU 空间循环单元实现。
- `sru-navigation-learning`：PPO 导航策略、网络和训练逻辑。
- `sru-robot-deployment`：B2W 仿真和 ROS 2 推理部署。

ROS 包：

| 包 | 作用 |
|---|---|
| `rl_nav_controller` | 加载 SRU 导航策略并输出机器人导航控制接口。 |
| `b2w_collision_monitor` | 使用力矩和点云监控碰撞。 |
| `b2w_controllers` | B2W 底层控制和 ONNX Runtime 推理接口。 |
| `b2w_description_ros2` | B2W 机器人描述。 |
| `b2w_gazebo_ros2` | Gazebo 仿真启动。 |
| `b2w_joystick_control` | 手柄遥控。 |
| `b2w_sim_worlds` | B2W 仿真世界和 mesh 发布。 |

完成了 CUDA cell、ActorCriticSRU 和短训练 smoke；Jetson 的 ONNX Runtime ARM64 文件被本地替换，仓库处于脏状态。没有完成完整论文训练和 Go2 策略迁移。

### 7.10 `viplanner_ws`

| 包 | 作用 |
|---|---|
| `viplanner_node` | ViPlanner ROS wrapper，接收深度、语义和目标并输出路径。 |
| `path_follower` | 执行 ViPlanner 输出路径。 |
| `viplanner_viz` | 显示预测路径、目标和局部信息。 |
| `viplanner_pkgs` | 元包。 |
| `waypoint_rviz_plugin` | RViz 目标设置。 |
| `joy` / `ps3joy` | 手柄驱动。 |

该工作区主要用于源码学习和部署准备。尚未完成官方模型在当前 X5/Mid-360/Go2 系统上的完整真机验证。

### 7.11 `apexnav_ws`

| 包 | 作用 |
|---|---|
| `exploration_manager` | Frontier 提取、价值图和混合语义/几何探索。 |
| `path_searching` | ApexNav 自身路径搜索。 |
| `plan_env` | ApexNav 地图环境。 |
| `trajectory_manager` | 轨迹管理和服务。 |
| `lkh_mtsp_solver` | TSP/多旅行商求解。 |
| `vis_utils` | 可视化工具。 |

ApexNav 的增量价值是候选语义价值和自适应开关。它自己的 SDF、A*、TSP 和轨迹管理与 SysNav 重复，因此没有接成第二个在线 planner。

### 7.12 `dualmap_ws`

DualMap 是 Python 研究仓库，没有 ROS `package.xml`，因此结构化 ROS 扫描显示 0 包。其主要模块是：

- Detector 和 LocalObservation；
- 结合三维 overlap 与 MobileCLIP 的 Tracker；
- LocalObject 状态、稳定性和 mobility；
- LocalMapManager；
- GlobalObject / GlobalMapManager；
- 持久化和语言查询。

它适合借鉴长期对象关联和移动状态，不适合把 RGB-D frontend 整套并到 SysNav，因为 SysNav 已经有 X5、YOLOE、SAM2 和 LiDAR 反投影。

### 7.13 `unitree_go2_ws`

| 包 | 作用 |
|---|---|
| `go2_driver` | Go2 ROS 2 驱动和启动入口。 |
| `go2_interfaces` | Go2 自定义 ROS 消息和服务。 |
| `unitree_api` | Unitree SDK API 消息。 |
| `unitree_go` | Go2 低层和状态消息。 |
| `unitree_hg` | Unitree 人形/高层相关消息定义。 |
| `unitree_ros2_example` | 状态读取、Sport Client、低层控制和录包示例。 |

部分仓库是 detached HEAD，修改前必须记录 commit。低层控制示例不能在无人监督时启动。

### 7.14 `tracking_deployment`：独立 Tracking 与 DAP 区域

这不是一个单一 ROS workspace，而是与 SysNav 隔离的实验区：

| 路径 | 作用 |
|---|---|
| `src/ODTrack` | 单目标跟踪器。 |
| `src/deep-person-reid` | OSNet ReID。 |
| `src/DAP` | X5 ERP 全景深度。 |
| `src/x5_mid360_bounded_refiner_ws` | 隔离的有界外参优化。 |
| `models/odtrack` | ODTrack checkpoint。 |
| `models/osnet` | OSNet 身份模型。 |
| `models/tbd` | 人物检测模型。 |
| `models/yoloe_edge` | Jetson 本机构建的 TensorRT engine。 |
| `runs` | DAP、标定、X5 和长时 SOT 的保留输出。 |
| `status` | 简明状态文件。 |

## 8. 真机与部署工作的详细结果

### 8.1 Mid-360 与定位

- Jetson 网口配置为 `192.168.1.5/24`，Mid-360 为 `192.168.1.148`。
- FAST-LIO2 完成实时建图、地图保存和 323 秒数据包采集。
- Elevator-LIO 完成 ARM64 构建、完整数据包回放和静止真实传感器测试。
- 当前不能只根据一次静止结果宣布某个 LIO 全面更优；下一步应在相同移动 Go2 数据上比较漂移、失效事件和地图一致性。

### 8.2 SCAN-Planner

- 构建、单元测试、仿真、LIO 适配和占据地图更新通过。
- 输出了三次 B 样条轨迹消息。
- 安全测试时 `/cmd_vel` 没有发布者，控制器未启动。
- 真实运动必须按 `scripts/hardware/scanplanner/SCANPLANNER_REAL_MANUAL.md` 进行人工监督。

### 8.3 X5

- CameraSDK、MediaSDK 和 UVC 三条路径都做过测试。
- 当前首选 UVC 的机内拼接 ERP。
- 增加了随 Go2 yaw 动态滚动全景的显示节点，使机头方向保持在图像中央。
- X5 与 Mid-360 的完整六自由度外参仍需更多刚性多姿态数据。

### 8.4 分布式语义感知

- X5 图像可由 Jetson 压缩后发送至 4090。
- YOLOE、SAM2 和三维对象投影完成无运动链路验证。
- 检测到的 chair 曾成功投影为 map-frame `ObjectNode`。
- 早期链路只回传标注 JPEG，后续才补齐结构化语义处理；接手者必须检查实际运行的是哪套脚本。

### 8.5 DAP

- 服务器单帧和服务模式通过；Jetson 本地也能运行，但较慢。
- `1024x512` 服务器 warm inference 约百毫秒量级，完整往返约 4 Hz。
- 当前工程输出仍按相对深度使用，不能取代 Mid-360 的度量安全几何。
- DAP 可用于目标内部深度、遮挡关系、可见性过滤和弱深度补全。

### 8.6 SysNav 可靠性修复

- 对照官方源码恢复 TARE 和坐标参数。
- 将无界并发 VLM 请求改为单调度器去重。
- 增加外部 VLM 请求最小间隔。
- 增加 Qwen 兼容的结构化 JSON 输出。
- 将等待状态改为已有 `/stop=2` hold，恢复时发布 `/stop=0`。
- 恢复 Go2 内部 LiDAR 的官方 `OFF` 路径。
- 调整 room height、door cloud clearing、墙面阈值和 dilation，分析玻璃隔断导致的 Room ID 抖动。

仍未解决：

- 玻璃、开放区域和墙面缺失下的房间分割稳定性；
- 同一对象离开后重访时的长期身份和去重；
- 统一条件下的 LIO 稳定性；
- 完整自主运动安全验收。

## 9. 全景人物 Tracking 专题

### 9.1 已实现模块

`panorama_long_term_sot_node.py` 包含：

- ERP 目标中心视口；
- ODTrack 可见阶段跟踪；
- 低频人物检测；
- 固定 OSNet anchor 和有限 gallery；
- 首尾接缝和球面 bearing/elevation；
- `UNINITIALIZED / VISIBLE / OCCLUDED / LOST / REACQUIRED` 状态；
- 角速度、置信度、时间戳、诊断和标注图输出。

### 9.2 评测与瓶颈

- 修正目标中心投影后，ODTrack 在 QuadTrack 多数目标上表现稳定。
- 4090 上 YOLO26n 完整路径比 YOLO11n 略快。
- 球面 Kalman 预测、检测搜索和 ReID 恢复已实现。
- YOLO11x 高分辨率能恢复部分 gap；轻量检测器对远处小人物召回不足。
- SAM2 只在初始化或恢复时触发，避免逐帧高开销。
- X5 实时 tracker 已运行，但完整 person-following 控制闭环尚未完成。

当前最重要的科学与工程问题不是再叠一个大模型，而是：远处小人物 proposal、身份连续性、遮挡后恢复以及目标状态到安全可达 goal 的接口。

## 10. 截图中各专题进程的交接

### 10.1 “总结 SysNav baseline”

完成内容：源码级 pipeline、官方差异、仿真复现、Go2 控制边界、对象/房间/VLM 接口分析。对应主文档为 `SYSNAV_BASELINE_AUDIT_2026-08-14.md` 和 `CURRENT_STATE.md`。

### 10.2 “监督修复跨环境安装链（单独跑 SCAN-Planner）”

完成内容：ROS 2 SCAN 构建、Elevator-LIO/FAST-LIO2 适配、安全启动脚本、NoMachine 可视化、planner-only 验证。没有宣称自动运动闭环。

### 10.3 “搭建 RSL 复现环境”

完成内容：SRU 三个源码仓库、ViPlanner、CUDA PyTorch、Open3D/OpenCV 环境与最小训练/导入验证。重型仿真和完整论文训练未完成。

### 10.4 “搭建 RSL 复现环境（硬件）”

完成内容：Jetson、X5、Mid-360 和 Go2 的安装与结构讨论，传感器位置测量，网络接口和机械固定需求。重力只能确定 roll/pitch，不能确定 yaw。

### 10.5 “审计部署视觉导航项目”

审计对象：OmniTrack、OA-VAT、DAP、LH-VLN、SAM 3，后来加入 FARM。

- DAP：服务器和 Jetson 最小推理通过。
- FARM：原生组件 smoke 通过，完整 Docker/ROS 2 运行未完成。
- OmniTrack：环境和 CUDA 扩展通过，完整 checkpoint/JRDB 资产受限。
- OA-VAT：环境和 simulator 路径审计过，完整复现受 UE4 和依赖影响。
- LH-VLN：公开 Habitat 测试场景通过，完整 HM3D 评测需要授权数据。
- SAM 3：源码导入通过，但官方权重受访问限制，不能写成完整部署。

### 10.6 “审计全景 SOT 前端候选”

比较了 ODTrack、LiteTrack、SUTrack、BoT-SORT/ByteTrack、OSNet、OmniTrack 和全景数据集。最终用目标中心投影的 ODTrack + OSNet 形成当前前端，轻量 ONNX/TensorRT tracker 仍待验证。

### 10.7 “Tracking 专题”

整理了模块化 Tracking 和 VLA Tracking 两条路线。模块化路线更适合当前系统，因为目标身份、二维/三维状态、地图和 planner 都能单独检查。相关笔记位于 `Tracking_Research_CV_VLA_2026/03_notes/`。

### 10.8 “Tracking 专题部署”

完成 X5 UVC、全景 SOT、ReID、球面状态、恢复、SAM2 和 DAP 的工程组合与部分评测。它是 perception frontend，不等于完整跟随机器人。

### 10.9 “Multi-Agent 专题”

调研 HoloAgent/FSR-VLN、ARNA、NavCoT、EvolveNav、Physical Agentic AI、LangGraph、AgenticROS 等。结论是不要把多个 LLM 角色聊天当贡献；更合理的是 typed task graph、固定工具接口、执行验证和恢复边。尚未接入生产 SysNav。

### 10.10 “Safety Corridor 专题”

调研视觉语义可通行性、ViPlanner、SaferPath、学习式 corridor/cost field 和传统安全规划。当前只是候选研究方向，没有部署成 SysNav 模块。若继续做，必须让视觉语义进入训练标签、损失或候选轨迹评分，而不是手写几个权重。

### 10.11 “Implicit Video Topology / Trajectory 专题”

目标是让视频历史服务于地点经验、轨迹和可见性记忆，而不是替代 LIO 定位。当前停留在调研和系统接口设计，没有完成生产代码。

### 10.12 “Monitor Tracking 专题”

研究固定/外部相机提供 world-frame 人物状态、跨相机身份和未来拦截点，再由 SysNav/SCAN 执行。当前没有部署完整固定相机系统，只形成了接口设计和文献路线。

## 11. 当前脏仓库和代码保护

以下仓库存在重要本地修改：

- `src/sru_ws/src/sru-robot-deployment`
- `src/camera_x5_ws/src/360_camera_calibration`
- `src/direct_visual_lidar_calibration_ws/src/direct_visual_lidar_calibration`
- `src/elevator_lio_ws/src/Elevator-LIO`
- `src/fastlio2_ws/src/FAST_LIO_ROS2`
- `tracking_deployment/src/x5_mid360_bounded_refiner_ws/src/direct_visual_lidar_calibration`

已在 Jetson 保存：

```text
<workspace-root>/archive/2026-09-20-handoff/
```

其中包括：

- Git commit、branch 和 origin 清单；
- `git status`；
- 二进制 patch；
- 未跟踪 YAML、ONNX Runtime 文件和标定源码备份；
- SHA-256 校验文件。

禁止在未备份前执行 `git reset --hard`、`git clean` 或切换分支。

## 12. 接手后的推荐顺序

### 第一阶段：恢复同一 baseline

1. 阅读本文件、`CURRENT_STATE.md`、`SYSNAV_BASELINE_AUDIT_2026-08-14.md`。
2. 检查 Git 状态、模型路径和环境。
3. 做一次无运动验收：X5/Mid-360 输入、LIO、Room/Object 消息、VLM 调度和 planner 状态。
4. 保存 ROS graph、topic rate、参数和日志。

### 第二阶段：统一定位比较

1. 用同一段刚性安装的移动 Go2 数据比较 ARISE、FAST-LIO2 和 Elevator-LIO。
2. 记录漂移、失效、处理频率和点云一致性。
3. 确定一个生产定位源后再进行运动实验。

### 第三阶段：语义地图一致性

1. 多视角反复观察同一对象。
2. 离开房间再回来。
3. 统计重复对象、track ID 重置、Room ID 抖动和对象移动后的旧位置。
4. 采用三维几何 + appearance + 时间证据维护 persistent identity。

### 第四阶段：Tracking 延续

1. 录制 X5 的接缝穿越、远近尺度变化、相似行人交叉、短遮挡、长遮挡和跨房间数据。
2. 提升小人物检测召回。
3. 测试轻量 tracker 或 ONNX/TensorRT。
4. 将 PersonTrack 放在独立动态层，再生成安全可达的跟随/恢复目标。

## 13. 安全边界

每次启动前：

```bash
ps -ef | grep -E 'ros|lio|scan|tare|go2|track' | grep -v grep
ros2 node list
ros2 topic info /cmd_vel -v
```

必须遵守：

- 环境检查、感知测试和 planner 测试时不得启动运动控制器。
- 不把有轨迹消息描述成机器人已执行。
- 不在无人监督时运行 Unitree 低层控制示例。
- 不让 VLM、VLA 或远端 API 直接发布 `/cmd_vel`。
- 外部推理结果必须带时间戳，并检查是否仍对应当前地图和机器人状态。
- 不删除日志、录包和 archive，除非先完成索引和备份。

## 14. 关键资料索引

- `CURRENT_STATE.md`：当前状态摘要。
- `SYSNAV_BASELINE_AUDIT_2026-08-14.md`：官方基线差异和语义链缺口。
- `README_SYSNAV_JETSON_CANONICAL.md`：Jetson 规范路径和激活方式。
- `README-real-deployment.md`：分布式 ROS 架构。
- `DEPLOYMENT_DIARY_2026-08-07.md` 至 `DEPLOYMENT_DIARY_2026-09-10.md`：按日期的实验事实。
- `X5_MID360_SPATIAL_CALIBRATION.md`：标定假设、结果和拒绝项。
- `scripts/deployment/tracking/PANORAMA_PERSON_TRACKER.md`：Tracking 使用说明。
- `scripts/hardware/scanplanner/SCANPLANNER_REAL_MANUAL.md`：SCAN 人工监督流程。
- `../SysNav_ApexNav_DualMap_Interface_Audit.md`：三套系统接口审计。
- `../../Wk2/读的paper/USTGZ Majun/literature_matrix.md`：VLN 论文矩阵。
- `jetson_ros_inventory_2026-09-20.json`：从 Jetson `package.xml` 自动生成的源码清单。

## 15. 最终状态判断

最扎实、可交接的成果是：

1. 完整理解并复现 SysNav 仿真与源码 pipeline。
2. 将 SysNav 相关组件迁移到 Go2、Mid-360、X5、Jetson 和 4090 的真实部署环境。
3. 建立定位、SCAN 局部规划、分布式感知、全景深度和全景人物跟踪的可重复实验入口。
4. 对真实部署暴露的定位、Room ID、对象一致性、VLM 并发和 stop 行为进行了诊断与修复。
5. 对多个后续方向做了源码和可复现性审计，明确哪些能继续，哪些尚停留在研究候选。

尚不能声称完成的内容包括：完整自主 SysNav 真机任务、可靠的跨房间人物跟随、完整移动目标恢复、ViPlanner/SRU 论文级复现、SAM 3 带官方权重部署，以及通用长程任务 Agent。
