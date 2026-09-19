#!/usr/bin/env python3
"""Dependency-light checks for spherical coordinates and seam ID bridging."""

import importlib.util
import sys
import types
from pathlib import Path


def load_tracker_module():
    sys.modules["numpy"] = types.ModuleType("numpy")
    path = Path(__file__).with_name("panorama_tracking_core.py")
    spec = importlib.util.spec_from_file_location("panorama_tracking_core", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


module = load_tracker_module()

assert module.bearing_from_x(0, 1920) == -180.0
assert module.bearing_from_x(960, 1920) == 0.0
assert module.circular_delta_deg(-179.0, 179.0) == 2.0
assert module.circular_delta_deg(179.0, -179.0) == -2.0
assert module.body_forward_shift_pixels(1920, 90.0) == -480
assert module.body_forward_shift_pixels(1920, -90.0) == 480

mapper = module.StableIdMapper(max_age_frames=10, seam_bridge_max_age_frames=4)
first = mapper.update(
    1,
    [{
        "raw_id": 7,
        "bbox": (1850.0, 150.0, 1910.0, 450.0),
        "bearing_deg": 172.5,
        "elevation_deg": 5.0,
        "area_ratio": 0.015,
    }],
    1920,
)
second = mapper.update(
    2,
    [{
        "raw_id": 19,
        "bbox": (5.0, 150.0, 65.0, 450.0),
        "bearing_deg": -173.5,
        "elevation_deg": 5.0,
        "area_ratio": 0.015,
    }],
    1920,
)
assert first[0]["stable_id"] == second[0]["stable_id"]

third = mapper.update(
    3,
    [{
        "raw_id": 23,
        "bbox": (700.0, 150.0, 760.0, 450.0),
        "bearing_deg": -43.0,
        "elevation_deg": 5.0,
        "area_ratio": 0.015,
    }],
    1920,
)
assert third[0]["stable_id"] != first[0]["stable_id"]

mapper.update(20, [], 1920)
assert not mapper.memories
assert not mapper.raw_to_stable

print("panorama_person_tracker helpers: PASS")
