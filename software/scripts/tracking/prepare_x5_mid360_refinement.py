#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path

import cv2
import numpy as np
from scipy.spatial.transform import Rotation


def read_ply(path: Path) -> tuple[bytes, np.ndarray]:
    raw = path.read_bytes()
    marker = b"end_header\n"
    offset = raw.index(marker) + len(marker)
    header = raw[:offset]
    match = re.search(rb"element vertex (\d+)", header)
    if match is None:
        raise ValueError(f"missing vertex count in {path}")
    count = int(match.group(1))
    points = np.frombuffer(raw, dtype="<f4", count=count * 4, offset=offset).reshape(count, 4).copy()
    return header, points


def write_ply(path: Path, header: bytes, points: np.ndarray) -> None:
    header = re.sub(rb"element vertex \d+", f"element vertex {len(points)}".encode(), header, count=1)
    path.write_bytes(header + np.asarray(points, dtype="<f4").tobytes())


def project(points_lidar: np.ndarray, transform_lidar_camera: np.ndarray, width: int, height: int):
    transform_camera_lidar = np.linalg.inv(transform_lidar_camera)
    points_camera = points_lidar @ transform_camera_lidar[:3, :3].T + transform_camera_lidar[:3, 3]
    ranges = np.linalg.norm(points_camera, axis=1)
    bearing = points_camera / np.maximum(ranges[:, None], 1e-6)
    longitude = np.arctan2(bearing[:, 0], bearing[:, 2])
    latitude = -np.arcsin(np.clip(bearing[:, 1], -1.0, 1.0))
    x = width * (0.5 + longitude / (2.0 * np.pi))
    y = height * (0.5 - latitude / np.pi)
    return x, y, ranges


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--min-row", type=int, default=160)
    parser.add_argument("--max-row", type=int, default=640)
    parser.add_argument("--min-range", type=float, default=0.5)
    parser.add_argument("--max-range", type=float, default=25.0)
    parser.add_argument("--cam-x", type=float, default=-0.32)
    parser.add_argument("--cam-y", type=float, default=0.0)
    parser.add_argument("--cam-z", type=float, default=0.31)
    parser.add_argument("--roll", type=float, default=-90.0)
    parser.add_argument("--pitch", type=float, default=0.0)
    parser.add_argument("--yaw", type=float, default=-90.0)
    parser.add_argument("--depth-root", type=Path)
    parser.add_argument("--depth-scale", type=float, default=100.0)
    parser.add_argument("--minimum-ratio-tolerance", type=float, default=1.5)
    args = parser.parse_args()

    roll, pitch, yaw = np.deg2rad([args.roll, args.pitch, args.yaw])
    rx = np.array([[1, 0, 0], [0, np.cos(roll), -np.sin(roll)], [0, np.sin(roll), np.cos(roll)]])
    ry = np.array([[np.cos(pitch), 0, np.sin(pitch)], [0, 1, 0], [-np.sin(pitch), 0, np.cos(pitch)]])
    rz = np.array([[np.cos(yaw), -np.sin(yaw), 0], [np.sin(yaw), np.cos(yaw), 0], [0, 0, 1]])
    rotation = rz @ ry @ rx
    transform_lidar_camera = np.eye(4)
    transform_lidar_camera[:3, :3] = rotation
    transform_lidar_camera[:3, 3] = [args.cam_x, args.cam_y, args.cam_z]
    quaternion = Rotation.from_matrix(rotation).as_quat()

    config_path = args.data / "calib.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    config.setdefault("results", {})["init_T_lidar_camera"] = [
        args.cam_x,
        args.cam_y,
        args.cam_z,
        *quaternion.tolist(),
    ]
    config["refinement_filter"] = {
        "valid_image_rows": [args.min_row, args.max_row],
        "range_m": [args.min_range, args.max_range],
        "reason": "exclude camera-visible sensor/robot body and unsupported polar regions",
    }
    config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")

    summary = {"initial_T_lidar_camera": transform_lidar_camera.tolist(), "bags": {}}
    for image_path in sorted(args.data.glob("pose-*.png")):
        if "_" in image_path.stem:
            continue
        ply_path = image_path.with_suffix(".ply")
        if not ply_path.exists():
            continue
        image = cv2.imread(str(image_path), cv2.IMREAD_GRAYSCALE)
        header, points = read_ply(ply_path)
        x, y, ranges = project(points[:, :3], transform_lidar_camera, image.shape[1], image.shape[0])
        keep = (
            np.isfinite(points).all(axis=1)
            & (ranges >= args.min_range)
            & (ranges <= args.max_range)
            & (y >= args.min_row)
            & (y < args.max_row)
        )
        depth_summary = None
        if args.depth_root is not None:
            depth = np.load(args.depth_root / image_path.stem / "depth.npy").astype(np.float32) * args.depth_scale
            dx = np.mod(np.rint(x * depth.shape[1] / image.shape[1]).astype(int), depth.shape[1])
            dy = np.clip(np.rint(y * depth.shape[0] / image.shape[0]).astype(int), 0, depth.shape[0] - 1)
            pixel_index = dy * depth.shape[1] + dx
            z_buffer = np.full(depth.size, np.inf, dtype=np.float32)
            np.minimum.at(z_buffer, pixel_index[keep], ranges[keep].astype(np.float32))
            visible = ranges <= z_buffer[pixel_index] + np.maximum(0.10, ranges * 0.02)
            predicted = depth[dy, dx]
            comparable = keep & visible & np.isfinite(predicted) & (predicted > args.min_range)
            log_ratio = np.log(ranges[comparable] / predicted[comparable])
            center = float(np.median(log_ratio))
            mad = float(np.median(np.abs(log_ratio - center)))
            tolerance = max(3.0 * 1.4826 * mad, np.log(args.minimum_ratio_tolerance))
            consistent = np.zeros_like(keep)
            consistent[comparable] = np.abs(log_ratio - center) <= tolerance
            keep &= consistent
            depth_summary = {
                "comparable_points": int(comparable.sum()),
                "median_lidar_to_dap_ratio": float(np.exp(center)),
                "log_ratio_mad": mad,
                "accepted_ratio_interval": [float(np.exp(center - tolerance)), float(np.exp(center + tolerance))],
                "consistent_points": int(keep.sum()),
            }
        filtered = points[keep]
        write_ply(ply_path, header, filtered)

        overlay = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
        px = np.mod(np.rint(x[keep]).astype(int), image.shape[1])
        py = np.clip(np.rint(y[keep]).astype(int), 0, image.shape[0] - 1)
        sampled = np.arange(len(px))[:: max(1, len(px) // 40000)]
        colors = cv2.applyColorMap(
            np.clip(filtered[sampled, 3], 0, 255).astype(np.uint8).reshape(-1, 1), cv2.COLORMAP_TURBO
        ).reshape(-1, 3)
        overlay[py[sampled], px[sampled]] = colors
        cv2.imwrite(str(args.data / f"{image_path.stem}_initial_overlay.png"), overlay)
        summary["bags"][image_path.stem] = {
            "input_points": int(len(points)),
            "kept_points": int(len(filtered)),
            "kept_fraction": float(np.mean(keep)),
            "depth_gate": depth_summary,
        }

    (args.data / "refinement_prepare_summary.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
