# IADC GO2 EDU Jetson 与全景相机固定结构

<p align="center">
  <img src="assets/jetson-base-cad.png" alt="GO2 EDU Jetson 底座 CAD 视图" width="720">
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>中文</strong>
</p>

本仓库记录了我在香港科技大学（广州）开展 GO2 EDU 导航与真机部署时完成的一套硬件适配。它在原有机器人传感器结构上增加了两层载荷空间，用于安装 Jetson、外部供电附件和 Insta360 X5 全景相机。

本设计基于 `zhechen003` 开源的 [GO2-EDU Sensor Layout](https://github.com/zhechen003/GO2-EDU-sensor_layout) 修改。仓库保留了原作者、上游零件和 CERN-OHL-P-2.0 许可证。我的改动主要面向 Jetson/供电载荷底座和高位 X5 支架，不把上游的 Mid-360、RealSense 或 GO2 主安装结构作为个人原创。

## 设计目的

- 在下层为 Jetson AGX Orin 提供固定位置，并为充电宝或其他供电附件保留空间。
- 将 Insta360 X5 抬高，减少机身和载荷对 ERP 全景图像的遮挡。
- 在支架顶部使用相机通用的 1/4 英寸固定接口。
- 尽量保留原平台的 Mid-360 安装方式和模块化快拆结构。
- 同时保留 SolidWorks 源文件、STL/3MF 打印文件和设计截图，方便后续修改与复现。

## 结构说明

![Insta360 X5 高位支架 CAD 视图](assets/x5-camera-holder-cad.png)

较宽的结构是计算与供电底座，用于承载 Jetson 并为后部电源附件留出位置；较高的结构安装在底座上方，用于固定 X5 全景相机。这套结构服务于 SysNav 和 SCAN-Planner 真机复现平台，使全景视觉、LiDAR 和边缘计算能够同时安装在 GO2 EDU 上。

## 本工作版本新增或调整的文件

| 文件 | 用途 |
| --- | --- |
| `BatteryHolder.SLDPRT` / `BatteryHolder.STL` | 后部电池或供电附件限位结构 |
| `camera_support.SLDPRT` / `camera_support.STL` | 面向 Insta360 X5 调整的高位支架 |
| `backborad1.SLDPRT` / `backborad1.STL` | 载荷底座/背板工作版本 |
| `piece.SLDPRT` / `piece.STL` | 小型辅助固定件 |
| `BambooPrinting/backborad1.3mf` | 底板打印工程文件 |
| `assets/jetson-base-cad.png` | 计算与供电底座 CAD 记录图 |
| `assets/x5-camera-holder-cad.png` | X5 高位支架 CAD 记录图 |

仓库也保留了上游 GO2 头部、Mid-360、RealSense 和快拆零件，使改造后的文件仍处于完整装配语境中。SolidWorks 二进制文件的差异可能同时包含保存历史或元数据变化；建议结合截图和 STL 文件检查实际可打印几何。

## 对应的研究工作

这套硬件用于支持：

- Unitree GO2 EDU、Jetson 和传感器集成；
- Insta360 X5 全景图像采集；
- Mid-360 LiDAR 与 LIO 实验；
- SysNav 从仿真到真机平台的接口适配；
- SCAN-Planner 轨迹生成测试；
- 分布式全景深度与开放词汇感知实验。

本仓库记录的是机械适配与真机部署工作，不主张对上游 GO2 传感器结构、SysNav、SCAN-Planner 或其算法的原创贡献。

## 制造与安全说明

- 打印前请在 SolidWorks 中复核尺寸；该版本是研究过程中的工作版本，不是商业产品。
- 机器人运动前必须检查载荷重心、螺纹啮合、线缆余量、相机视野以及支架与机身/腿部的干涉。
- 顶部接口按相机通用 1/4 英寸固定方式设计，实际装配时仍需核对 Insta360 转接件。
- 每次改变载荷后，应先在人工监督下进行低速测试。

## 署名与许可证

本项目基于采用 CERN Open Hardware Licence Version 2, Permissive 的 [zhechen003/GO2-EDU-sensor_layout](https://github.com/zhechen003/GO2-EDU-sensor_layout)。本仓库保留原始 `LICENSE`，衍生文件继续采用相同许可证。

硬件适配与部署记录维护者：[练瑷玮](https://aliciasuiseiko.github.io/)。
