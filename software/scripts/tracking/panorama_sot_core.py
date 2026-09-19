#!/usr/bin/env python3
"""Model-agnostic spherical geometry and state estimation for panoramic SOT."""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum
from typing import Optional

import numpy as np


def wrap_degrees(angle: float) -> float:
    return (angle + 180.0) % 360.0 - 180.0


def circular_delta_degrees(current: float, previous: float) -> float:
    return wrap_degrees(current - previous)


def erp_pixel_to_angles(x: float, y: float, width: int, height: int) -> tuple[float, float]:
    """Convert an ERP pixel center to longitude/bearing and latitude/elevation."""
    bearing = wrap_degrees(x / width * 360.0 - 180.0)
    elevation = 90.0 - y / height * 180.0
    return bearing, elevation


def angles_to_erp_pixel(
    bearing_deg: float,
    elevation_deg: float,
    width: int,
    height: int,
) -> tuple[float, float]:
    bearing = wrap_degrees(bearing_deg)
    x = (bearing + 180.0) / 360.0 * width
    y = (90.0 - max(-90.0, min(90.0, elevation_deg))) / 180.0 * height
    return x % width, min(max(y, 0.0), height - 1.0)


def perspective_pixel_to_angles(
    x: float,
    y: float,
    width: int,
    height: int,
    center_bearing_deg: float,
    center_elevation_deg: float,
    horizontal_fov_deg: float,
) -> tuple[float, float]:
    """Map one target-centered perspective pixel back to the viewing sphere."""
    horizontal_fov = math.radians(horizontal_fov_deg)
    focal = (width * 0.5) / math.tan(horizontal_fov * 0.5)
    right = (x - width * 0.5) / focal
    down = (y - height * 0.5) / focal

    lon = math.radians(center_bearing_deg)
    lat = math.radians(center_elevation_deg)
    forward = np.array(
        [math.cos(lat) * math.sin(lon), math.sin(lat), math.cos(lat) * math.cos(lon)]
    )
    right_basis = np.array([math.cos(lon), 0.0, -math.sin(lon)])
    up_basis = np.array(
        [-math.sin(lat) * math.sin(lon), math.cos(lat), -math.sin(lat) * math.cos(lon)]
    )
    ray = forward + right * right_basis - down * up_basis
    ray /= np.linalg.norm(ray)
    bearing = math.degrees(math.atan2(ray[0], ray[2]))
    elevation = math.degrees(math.asin(float(np.clip(ray[1], -1.0, 1.0))))
    return wrap_degrees(bearing), elevation


def angular_extent_to_viewport_pixels(
    horizontal_extent_deg: float,
    vertical_extent_deg: float,
    viewport_width: int,
    horizontal_fov_deg: float,
) -> tuple[float, float]:
    focal = (viewport_width * 0.5) / math.tan(math.radians(horizontal_fov_deg) * 0.5)
    width = 2.0 * focal * math.tan(math.radians(horizontal_extent_deg) * 0.5)
    height = 2.0 * focal * math.tan(math.radians(vertical_extent_deg) * 0.5)
    return width, height


def erp_bbox_to_spherical(
    bbox_xywh: tuple[float, float, float, float],
    erp_width: int,
    erp_height: int,
) -> tuple[float, float, float, float]:
    """Convert an ERP box to a BFoV-like center and angular extent."""
    x, y, width, height = bbox_xywh
    center_x = (x + width * 0.5) % erp_width
    center_y = min(max(y + height * 0.5, 0.0), erp_height - 1.0)
    bearing, elevation = erp_pixel_to_angles(center_x, center_y, erp_width, erp_height)
    return bearing, elevation, width / erp_width * 360.0, height / erp_height * 180.0


def centered_viewport_bbox(
    horizontal_extent_deg: float,
    vertical_extent_deg: float,
    viewport_width: int,
    viewport_height: int,
    horizontal_fov_deg: float,
) -> list[float]:
    width, height = angular_extent_to_viewport_pixels(
        horizontal_extent_deg,
        vertical_extent_deg,
        viewport_width,
        horizontal_fov_deg,
    )
    width = min(max(width, 4.0), viewport_width * 0.9)
    height = min(max(height, 4.0), viewport_height * 0.9)
    return [
        viewport_width * 0.5 - width * 0.5,
        viewport_height * 0.5 - height * 0.5,
        width,
        height,
    ]


def viewport_bbox_to_spherical(
    bbox_xywh: tuple[float, float, float, float],
    viewport_width: int,
    viewport_height: int,
    center_bearing_deg: float,
    center_elevation_deg: float,
    horizontal_fov_deg: float,
) -> tuple[float, float, float, float]:
    x, y, width, height = bbox_xywh
    center_x = x + width * 0.5
    center_y = y + height * 0.5
    bearing, elevation = perspective_pixel_to_angles(
        center_x,
        center_y,
        viewport_width,
        viewport_height,
        center_bearing_deg,
        center_elevation_deg,
        horizontal_fov_deg,
    )
    focal = (viewport_width * 0.5) / math.tan(math.radians(horizontal_fov_deg) * 0.5)
    horizontal_extent = math.degrees(2.0 * math.atan(max(width, 1.0) * 0.5 / focal))
    vertical_extent = math.degrees(2.0 * math.atan(max(height, 1.0) * 0.5 / focal))
    return bearing, elevation, horizontal_extent, vertical_extent


def build_erp_viewport_map(
    erp_width: int,
    erp_height: int,
    output_width: int,
    output_height: int,
    center_bearing_deg: float,
    center_elevation_deg: float,
    horizontal_fov_deg: float,
) -> tuple[np.ndarray, np.ndarray]:
    """Build OpenCV remap arrays for a target-centered rectilinear viewport."""
    xs = np.arange(output_width, dtype=np.float32) + 0.5
    ys = np.arange(output_height, dtype=np.float32) + 0.5
    grid_x, grid_y = np.meshgrid(xs, ys)

    horizontal_fov = math.radians(horizontal_fov_deg)
    focal = (output_width * 0.5) / math.tan(horizontal_fov * 0.5)
    right = (grid_x - output_width * 0.5) / focal
    down = (grid_y - output_height * 0.5) / focal

    lon = math.radians(center_bearing_deg)
    lat = math.radians(center_elevation_deg)
    forward = np.array(
        [math.cos(lat) * math.sin(lon), math.sin(lat), math.cos(lat) * math.cos(lon)],
        dtype=np.float32,
    )
    right_basis = np.array([math.cos(lon), 0.0, -math.sin(lon)], dtype=np.float32)
    up_basis = np.array(
        [-math.sin(lat) * math.sin(lon), math.cos(lat), -math.sin(lat) * math.cos(lon)],
        dtype=np.float32,
    )
    rays = (
        forward[None, None, :]
        + right[..., None] * right_basis[None, None, :]
        - down[..., None] * up_basis[None, None, :]
    )
    rays /= np.linalg.norm(rays, axis=2, keepdims=True)
    longitude = np.arctan2(rays[..., 0], rays[..., 2])
    latitude = np.arcsin(np.clip(rays[..., 1], -1.0, 1.0))
    map_x = ((longitude + math.pi) / (2.0 * math.pi) * erp_width) % erp_width
    map_y = np.clip((math.pi * 0.5 - latitude) / math.pi * erp_height, 0, erp_height - 1)
    return map_x.astype(np.float32), map_y.astype(np.float32)


def extract_perspective_viewport(
    erp_frame: np.ndarray,
    center_bearing_deg: float,
    center_elevation_deg: float,
    horizontal_fov_deg: float,
    output_size: tuple[int, int] = (640, 640),
) -> np.ndarray:
    import cv2

    output_width, output_height = output_size
    map_x, map_y = build_erp_viewport_map(
        erp_frame.shape[1],
        erp_frame.shape[0],
        output_width,
        output_height,
        center_bearing_deg,
        center_elevation_deg,
        horizontal_fov_deg,
    )
    return cv2.remap(
        erp_frame,
        map_x,
        map_y,
        interpolation=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_WRAP,
    )


def build_cylindrical_viewport_map(
    source_width: int,
    source_height: int,
    center_bearing_deg: float,
    horizontal_fov_deg: float,
    output_size: tuple[int, int] = (640, 480),
) -> tuple[np.ndarray, np.ndarray]:
    output_width, output_height = output_size
    center_x = (wrap_degrees(center_bearing_deg) + 180.0) / 360.0 * source_width
    source_view_width = horizontal_fov_deg / 360.0 * source_width
    xs = (
        center_x
        + (np.arange(output_width, dtype=np.float32) + 0.5 - output_width * 0.5)
        / output_width
        * source_view_width
    ) % source_width
    ys = (np.arange(output_height, dtype=np.float32) + 0.5) / output_height * source_height
    map_x, map_y = np.meshgrid(xs, ys)
    return map_x.astype(np.float32), map_y.astype(np.float32)


def extract_cylindrical_viewport(
    panorama_frame: np.ndarray,
    center_bearing_deg: float,
    horizontal_fov_deg: float,
    output_size: tuple[int, int] = (640, 480),
) -> np.ndarray:
    """Extract a viewport from a vertically cropped or cylindrical panorama."""
    import cv2

    map_x, map_y = build_cylindrical_viewport_map(
        panorama_frame.shape[1],
        panorama_frame.shape[0],
        center_bearing_deg,
        horizontal_fov_deg,
        output_size,
    )
    return cv2.remap(
        panorama_frame,
        map_x,
        map_y,
        interpolation=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_WRAP,
    )


def centered_cylindrical_bbox(
    horizontal_extent_deg: float,
    vertical_extent_deg: float,
    viewport_width: int,
    viewport_height: int,
    horizontal_fov_deg: float,
) -> list[float]:
    width = horizontal_extent_deg / horizontal_fov_deg * viewport_width
    height = vertical_extent_deg / 180.0 * viewport_height
    width = min(max(width, 4.0), viewport_width * 0.95)
    height = min(max(height, 4.0), viewport_height * 0.98)
    return [
        viewport_width * 0.5 - width * 0.5,
        viewport_height * 0.5 - height * 0.5,
        width,
        height,
    ]


def cylindrical_bbox_to_spherical(
    bbox_xywh: tuple[float, float, float, float],
    viewport_width: int,
    viewport_height: int,
    center_bearing_deg: float,
    horizontal_fov_deg: float,
) -> tuple[float, float, float, float]:
    x, y, width, height = bbox_xywh
    center_x = x + width * 0.5
    center_y = y + height * 0.5
    bearing = wrap_degrees(
        center_bearing_deg + (center_x / viewport_width - 0.5) * horizontal_fov_deg
    )
    elevation = 90.0 - center_y / viewport_height * 180.0
    horizontal_extent = width / viewport_width * horizontal_fov_deg
    vertical_extent = height / viewport_height * 180.0
    return bearing, elevation, horizontal_extent, vertical_extent


class TrackingMode(str, Enum):
    UNINITIALIZED = "UNINITIALIZED"
    VISIBLE = "VISIBLE"
    UNCERTAIN = "UNCERTAIN"
    LOST = "LOST"


@dataclass
class SearchPolicy:
    local_fov_deg: float = 90.0
    uncertain_fov_deg: float = 140.0
    visible_threshold: float = 0.55
    uncertain_frames: int = 12

    def mode(self, confidence: Optional[float], frames_since_seen: int) -> TrackingMode:
        if confidence is not None and confidence >= self.visible_threshold:
            return TrackingMode.VISIBLE
        if frames_since_seen <= self.uncertain_frames:
            return TrackingMode.UNCERTAIN
        return TrackingMode.LOST

    def search_fov(self, mode: TrackingMode) -> float:
        if mode == TrackingMode.VISIBLE:
            return self.local_fov_deg
        if mode == TrackingMode.UNCERTAIN:
            return self.uncertain_fov_deg
        return 360.0


@dataclass
class AngularTargetState:
    bearing_deg: float
    elevation_deg: float
    bearing_velocity_deg_s: float = 0.0
    elevation_velocity_deg_s: float = 0.0
    timestamp_s: float = 0.0
    confidence: float = 1.0

    def predict(self, timestamp_s: float) -> "AngularTargetState":
        dt = max(timestamp_s - self.timestamp_s, 0.0)
        return AngularTargetState(
            bearing_deg=wrap_degrees(self.bearing_deg + self.bearing_velocity_deg_s * dt),
            elevation_deg=max(
                -90.0,
                min(90.0, self.elevation_deg + self.elevation_velocity_deg_s * dt),
            ),
            bearing_velocity_deg_s=self.bearing_velocity_deg_s,
            elevation_velocity_deg_s=self.elevation_velocity_deg_s,
            timestamp_s=timestamp_s,
            confidence=self.confidence,
        )

    def update(
        self,
        bearing_deg: float,
        elevation_deg: float,
        timestamp_s: float,
        confidence: float,
        position_gain: float = 0.65,
        velocity_gain: float = 0.25,
    ) -> "AngularTargetState":
        predicted = self.predict(timestamp_s)
        dt = max(timestamp_s - self.timestamp_s, 1e-3)
        bearing_error = circular_delta_degrees(bearing_deg, predicted.bearing_deg)
        elevation_error = elevation_deg - predicted.elevation_deg
        return AngularTargetState(
            bearing_deg=wrap_degrees(predicted.bearing_deg + position_gain * bearing_error),
            elevation_deg=max(
                -90.0,
                min(90.0, predicted.elevation_deg + position_gain * elevation_error),
            ),
            bearing_velocity_deg_s=(
                predicted.bearing_velocity_deg_s + velocity_gain * bearing_error / dt
            ),
            elevation_velocity_deg_s=(
                predicted.elevation_velocity_deg_s + velocity_gain * elevation_error / dt
            ),
            timestamp_s=timestamp_s,
            confidence=confidence,
        )


@dataclass
class SphericalKalmanState:
    """Constant-velocity Kalman state with an unwrapped horizontal angle."""

    vector: np.ndarray
    covariance: np.ndarray
    timestamp_s: float
    confidence: float = 1.0
    acceleration_std_deg_s2: float = 35.0
    measurement_std_deg: float = 2.0

    @classmethod
    def initialize(
        cls,
        bearing_deg: float,
        elevation_deg: float,
        timestamp_s: float = 0.0,
        position_std_deg: float = 4.0,
        velocity_std_deg_s: float = 30.0,
    ) -> "SphericalKalmanState":
        vector = np.array([bearing_deg, elevation_deg, 0.0, 0.0], dtype=np.float64)
        covariance = np.diag(
            [position_std_deg**2, position_std_deg**2, velocity_std_deg_s**2, velocity_std_deg_s**2]
        )
        return cls(vector, covariance, timestamp_s)

    @property
    def bearing_deg(self) -> float:
        return wrap_degrees(float(self.vector[0]))

    @property
    def elevation_deg(self) -> float:
        return float(np.clip(self.vector[1], -90.0, 90.0))

    @property
    def bearing_velocity_deg_s(self) -> float:
        return float(self.vector[2])

    @property
    def elevation_velocity_deg_s(self) -> float:
        return float(self.vector[3])

    @property
    def bearing_sigma_deg(self) -> float:
        return float(math.sqrt(max(self.covariance[0, 0], 0.0)))

    @property
    def elevation_sigma_deg(self) -> float:
        return float(math.sqrt(max(self.covariance[1, 1], 0.0)))

    def predict(self, timestamp_s: float) -> "SphericalKalmanState":
        dt = max(float(timestamp_s) - self.timestamp_s, 0.0)
        transition = np.array(
            [[1.0, 0.0, dt, 0.0], [0.0, 1.0, 0.0, dt], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]],
            dtype=np.float64,
        )
        q = self.acceleration_std_deg_s2**2
        process = q * np.array(
            [
                [dt**4 / 4.0, 0.0, dt**3 / 2.0, 0.0],
                [0.0, dt**4 / 4.0, 0.0, dt**3 / 2.0],
                [dt**3 / 2.0, 0.0, dt**2, 0.0],
                [0.0, dt**3 / 2.0, 0.0, dt**2],
            ],
            dtype=np.float64,
        )
        return SphericalKalmanState(
            transition @ self.vector,
            transition @ self.covariance @ transition.T + process,
            float(timestamp_s),
            self.confidence,
            self.acceleration_std_deg_s2,
            self.measurement_std_deg,
        )

    def update(
        self,
        bearing_deg: float,
        elevation_deg: float,
        timestamp_s: float,
        confidence: float,
    ) -> "SphericalKalmanState":
        predicted = self.predict(timestamp_s)
        horizontal = np.array(
            [[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0]], dtype=np.float64
        )
        unwrapped_bearing = predicted.vector[0] + circular_delta_degrees(
            bearing_deg, predicted.bearing_deg
        )
        measurement = np.array([unwrapped_bearing, elevation_deg], dtype=np.float64)
        confidence = float(np.clip(confidence, 0.05, 1.0))
        measurement_variance = (predicted.measurement_std_deg / confidence) ** 2
        noise = np.eye(2, dtype=np.float64) * measurement_variance
        innovation = measurement - horizontal @ predicted.vector
        innovation_covariance = horizontal @ predicted.covariance @ horizontal.T + noise
        gain = predicted.covariance @ horizontal.T @ np.linalg.inv(innovation_covariance)
        vector = predicted.vector + gain @ innovation
        identity = np.eye(4, dtype=np.float64)
        residual = identity - gain @ horizontal
        covariance = residual @ predicted.covariance @ residual.T + gain @ noise @ gain.T
        return SphericalKalmanState(
            vector,
            covariance,
            float(timestamp_s),
            confidence,
            predicted.acceleration_std_deg_s2,
            predicted.measurement_std_deg,
        )


@dataclass(frozen=True)
class DepthEstimate:
    depth: float
    uncertainty: float
    sample_count: int


def robust_target_depth(
    depth_map: np.ndarray,
    mask: np.ndarray,
    minimum_depth: float = 1e-4,
    trim_quantiles: tuple[float, float] = (0.2, 0.8),
) -> Optional[DepthEstimate]:
    """Estimate target depth while rejecting background and unstable edge pixels."""
    if depth_map.shape[:2] != mask.shape[:2]:
        raise ValueError("depth_map and mask must have matching height and width")
    values = np.asarray(depth_map, dtype=np.float32)[np.asarray(mask, dtype=bool)]
    values = values[np.isfinite(values) & (values > minimum_depth)]
    if values.size < 8:
        return None
    low, high = np.quantile(values, trim_quantiles)
    values = values[(values >= low) & (values <= high)]
    if values.size < 4:
        return None
    median = float(np.median(values))
    mad = float(np.median(np.abs(values - median)))
    return DepthEstimate(median, 1.4826 * mad, int(values.size))
