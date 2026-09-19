#!/usr/bin/env python3
"""Geometry and stable-ID helpers shared by ROS and offline evaluation."""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Dict, Iterable, Optional

import numpy as np


def circular_delta_deg(current: float, previous: float) -> float:
    return (current - previous + 180.0) % 360.0 - 180.0


def bearing_from_x(center_x: float, width: int) -> float:
    return ((center_x / width) * 360.0) % 360.0 - 180.0


def elevation_from_y(center_y: float, height: int) -> float:
    return 90.0 - (center_y / height) * 180.0


def body_forward_shift_pixels(width: int, body_forward_offset_deg: float) -> int:
    return int(round(-body_forward_offset_deg * width / 360.0))


def center_body_forward(frame, body_forward_offset_deg: float):
    shift_pixels = body_forward_shift_pixels(
        frame.shape[1], body_forward_offset_deg
    )
    if shift_pixels == 0:
        return frame, 0
    return np.roll(frame, shift_pixels, axis=1), shift_pixels


@dataclass
class TrackMemory:
    stable_id: int
    raw_id: int
    bearing_deg: float
    elevation_deg: float
    area_ratio: float
    bbox: tuple[float, float, float, float]
    last_frame: int
    angular_velocity_deg_frame: float = 0.0


class StableIdMapper:
    """Preserve public IDs when a planar tracker switches IDs at the ERP seam."""

    def __init__(
        self,
        max_age_frames: int = 12,
        seam_bridge_max_age_frames: int = 6,
        seam_width_ratio: float = 0.15,
        max_angle_deg: float = 30.0,
        max_elevation_deg: float = 18.0,
        max_log_area_delta: float = 0.9,
    ) -> None:
        self.max_age_frames = max_age_frames
        self.seam_bridge_max_age_frames = min(
            seam_bridge_max_age_frames, max_age_frames
        )
        self.seam_width_ratio = seam_width_ratio
        self.max_angle_deg = max_angle_deg
        self.max_elevation_deg = max_elevation_deg
        self.max_log_area_delta = max_log_area_delta
        self.next_stable_id = 1
        self.raw_to_stable: Dict[int, int] = {}
        self.memories: Dict[int, TrackMemory] = {}

    def _near_opposite_seams(self, old_x: float, new_x: float, width: int) -> bool:
        edge = width * self.seam_width_ratio
        return (old_x < edge and new_x > width - edge) or (
            old_x > width - edge and new_x < edge
        )

    def _candidate(
        self,
        frame_index: int,
        bbox: tuple[float, float, float, float],
        bearing_deg: float,
        elevation_deg: float,
        area_ratio: float,
        width: int,
        already_used: set[int],
    ) -> Optional[int]:
        center_x = (bbox[0] + bbox[2]) * 0.5
        best: tuple[float, int] | None = None
        for stable_id, memory in self.memories.items():
            if stable_id in already_used:
                continue
            age = frame_index - memory.last_frame
            if age < 1 or age > self.seam_bridge_max_age_frames:
                continue
            old_x = (memory.bbox[0] + memory.bbox[2]) * 0.5
            if not self._near_opposite_seams(old_x, center_x, width):
                continue
            angle_error = abs(circular_delta_deg(bearing_deg, memory.bearing_deg))
            elevation_error = abs(elevation_deg - memory.elevation_deg)
            area_error = abs(
                math.log(max(area_ratio, 1e-8) / max(memory.area_ratio, 1e-8))
            )
            if (
                angle_error > self.max_angle_deg
                or elevation_error > self.max_elevation_deg
                or area_error > self.max_log_area_delta
            ):
                continue
            score = angle_error + 0.5 * elevation_error + 6.0 * area_error + age
            if best is None or score < best[0]:
                best = (score, stable_id)
        return None if best is None else best[1]

    def update(
        self,
        frame_index: int,
        detections: Iterable[dict],
        width: int,
    ) -> list[dict]:
        output: list[dict] = []
        used: set[int] = set()
        for detection in detections:
            raw_id = int(detection["raw_id"])
            stable_id = self.raw_to_stable.get(raw_id)
            if stable_id is None:
                stable_id = self._candidate(
                    frame_index,
                    detection["bbox"],
                    detection["bearing_deg"],
                    detection["elevation_deg"],
                    detection["area_ratio"],
                    width,
                    used,
                )
                if stable_id is None:
                    stable_id = self.next_stable_id
                    self.next_stable_id += 1
                self.raw_to_stable[raw_id] = stable_id

            previous = self.memories.get(stable_id)
            velocity = 0.0
            if previous is not None:
                elapsed = max(frame_index - previous.last_frame, 1)
                measured = circular_delta_deg(
                    detection["bearing_deg"], previous.bearing_deg
                ) / elapsed
                velocity = 0.7 * previous.angular_velocity_deg_frame + 0.3 * measured

            self.memories[stable_id] = TrackMemory(
                stable_id=stable_id,
                raw_id=raw_id,
                bearing_deg=detection["bearing_deg"],
                elevation_deg=detection["elevation_deg"],
                area_ratio=detection["area_ratio"],
                bbox=detection["bbox"],
                last_frame=frame_index,
                angular_velocity_deg_frame=velocity,
            )
            used.add(stable_id)
            public_detection = dict(detection)
            public_detection["stable_id"] = stable_id
            public_detection["angular_velocity_deg_frame"] = velocity
            output.append(public_detection)

        live_ids = {
            memory.raw_id
            for memory in self.memories.values()
            if frame_index - memory.last_frame <= self.max_age_frames
        }
        self.raw_to_stable = {
            raw_id: stable_id
            for raw_id, stable_id in self.raw_to_stable.items()
            if raw_id in live_ids
        }
        self.memories = {
            stable_id: memory
            for stable_id, memory in self.memories.items()
            if frame_index - memory.last_frame <= self.max_age_frames
        }
        return output
