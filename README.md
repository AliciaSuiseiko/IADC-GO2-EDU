# IADC GO2 EDU Jetson and Panoramic-Camera Mount

<p align="center">
  <img src="assets/jetson-base-cad.png" alt="CAD view of the GO2 EDU Jetson base" width="720">
</p>

<p align="center">
  <strong>English</strong> · <a href="README_CN.md">中文</a>
</p>

This repository records a hardware adaptation developed for a Unitree GO2 EDU navigation platform at HKUST(GZ). The assembly adds a two-level payload structure for onboard computing and panoramic perception while retaining compatibility with the existing robot-mounted sensing frame.

The work is a derivative of the open-source [GO2-EDU Sensor Layout](https://github.com/zhechen003/GO2-EDU-sensor_layout) by `zhechen003`. The original license and upstream parts are retained. My additions and adaptations focus on the Jetson/power payload base and an elevated Insta360 X5 support rather than the original RealSense holder.

## Design Intent

- Provide a lower deck for a Jetson AGX Orin and leave usable space for an external battery or power accessories.
- Raise the Insta360 X5 above the onboard payload to reduce body occlusion in the equirectangular panorama.
- Use a standard 1/4-inch camera attachment at the top of the support.
- Preserve access to the Mid-360 and the modular quick-release structure used by the upstream platform.
- Keep editable SolidWorks parts and printable STL/3MF files together with the deployment record.

## Adapted Structure

![CAD view of the elevated Insta360 X5 holder](assets/x5-camera-holder-cad.png)

The wider structure is the computing and power base. The taller structure is the panoramic-camera support mounted above it. This layout was developed for the SysNav and SCAN-Planner reproduction platform, where panoramic vision, LiDAR, and edge computing needed to coexist on the GO2 EDU.

## Files Added or Adapted in This Working Version

| File | Purpose |
| --- | --- |
| `BatteryHolder.SLDPRT` / `BatteryHolder.STL` | Rear battery or power-accessory restraint |
| `camera_support.SLDPRT` / `camera_support.STL` | Elevated support adapted for the Insta360 X5 |
| `backborad1.SLDPRT` / `backborad1.STL` | Payload base/backboard working version |
| `piece.SLDPRT` / `piece.STL` | Small auxiliary mounting piece |
| `BambooPrinting/backborad1.3mf` | Print-ready base-plate project |
| `assets/jetson-base-cad.png` | CAD record of the computing/power base |
| `assets/x5-camera-holder-cad.png` | CAD record of the elevated X5 support |

The repository also retains upstream GO2 head, Mid-360, RealSense, and quick-release parts so that the adapted files remain usable in context. Binary SolidWorks files may contain save-history or metadata changes in addition to geometry edits; use the screenshots and STL files to inspect the intended printable geometry.

## Research Use

This hardware supported the following engineering work:

- Unitree GO2 EDU sensor and Jetson integration;
- Insta360 X5 panoramic image acquisition;
- Mid-360 LiDAR and LIO experiments;
- SysNav simulation-to-platform integration;
- SCAN-Planner trajectory-generation tests;
- distributed panoramic depth and open-vocabulary perception experiments.

This repository documents a mechanical adaptation and deployment artifact. It does not claim authorship of the upstream GO2 sensor layout, SysNav, SCAN-Planner, or their algorithms.

## Manufacturing Notes

- Inspect dimensions in SolidWorks before printing; this is a research working version rather than a commercial product.
- Check payload balance, screw engagement, cable clearance, camera visibility, and leg/body interference before operating the robot.
- Verify the top camera fastener against the actual Insta360 adapter. The intended interface is the standard 1/4-inch camera mount.
- Start with supervised, low-speed tests after any payload change.

## Attribution and License

Based on [zhechen003/GO2-EDU-sensor_layout](https://github.com/zhechen003/GO2-EDU-sensor_layout), which is licensed under the CERN Open Hardware Licence Version 2, Permissive. This derivative repository retains the original `LICENSE` and is distributed under the same license.

Adaptation and deployment record maintained by [Aiwei Lian](https://aliciasuiseiko.github.io/).
