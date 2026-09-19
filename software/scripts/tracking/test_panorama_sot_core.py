#!/usr/bin/env python3
"""Dependency-light tests for panoramic SOT geometry and state estimation."""

import math
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from panorama_sot_core import (  # noqa: E402
    AngularTargetState,
    SearchPolicy,
    TrackingMode,
    angles_to_erp_pixel,
    build_cylindrical_viewport_map,
    build_erp_viewport_map,
    centered_cylindrical_bbox,
    centered_viewport_bbox,
    circular_delta_degrees,
    cylindrical_bbox_to_spherical,
    erp_bbox_to_spherical,
    erp_pixel_to_angles,
    perspective_pixel_to_angles,
    robust_target_depth,
    SphericalKalmanState,
    viewport_bbox_to_spherical,
)


assert circular_delta_degrees(-179.0, 179.0) == 2.0
assert circular_delta_degrees(179.0, -179.0) == -2.0

for bearing, elevation in [(-179.0, 0.0), (0.0, 0.0), (93.0, -25.0)]:
    x, y = angles_to_erp_pixel(bearing, elevation, 1920, 960)
    recovered_bearing, recovered_elevation = erp_pixel_to_angles(x, y, 1920, 960)
    assert abs(circular_delta_degrees(recovered_bearing, bearing)) < 1e-5
    assert abs(recovered_elevation - elevation) < 1e-5

bearing, elevation = perspective_pixel_to_angles(
    320.0, 320.0, 640, 640, 179.0, 7.0, 90.0
)
assert abs(circular_delta_degrees(bearing, 179.0)) < 0.2
assert abs(elevation - 7.0) < 0.2

map_x, map_y = build_erp_viewport_map(1920, 960, 321, 241, 179.0, 0.0, 100.0)
assert map_x.shape == (241, 321)
assert map_y.shape == (241, 321)
assert np.all((map_x >= 0.0) & (map_x < 1920.0))
assert np.all((map_y >= 0.0) & (map_y <= 959.0))
assert np.any(map_x < 100.0) and np.any(map_x > 1800.0)

spherical = erp_bbox_to_spherical((1870.0, 400.0, 100.0, 200.0), 1920, 960)
assert abs(circular_delta_degrees(spherical[0], -180.0)) < 1e-3
local_bbox = centered_viewport_bbox(spherical[2], spherical[3], 640, 640, 90.0)
recovered = viewport_bbox_to_spherical(
    tuple(local_bbox), 640, 640, spherical[0], spherical[1], 90.0
)
assert abs(circular_delta_degrees(recovered[0], spherical[0])) < 0.2
assert abs(recovered[1] - spherical[1]) < 0.2
assert abs(recovered[2] - spherical[2]) < 1e-5

cylindrical_x, cylindrical_y = build_cylindrical_viewport_map(
    200, 48, -180.0, 72.0, (80, 48)
)
assert cylindrical_x.shape == (48, 80)
assert cylindrical_y.shape == (48, 80)
assert cylindrical_x[24, 40] < 2.0 or cylindrical_x[24, 40] > 198.0
assert np.any(cylindrical_x < 10.0) and np.any(cylindrical_x > 190.0)
cylindrical_box = centered_cylindrical_bbox(18.0, 90.0, 80, 48, 72.0)
cylindrical_recovered = cylindrical_bbox_to_spherical(
    tuple(cylindrical_box), 80, 48, 179.0, 72.0
)
assert abs(circular_delta_degrees(cylindrical_recovered[0], 179.0)) < 1e-6
assert abs(cylindrical_recovered[1]) < 1e-6
assert abs(cylindrical_recovered[2] - 18.0) < 1e-6
assert abs(cylindrical_recovered[3] - 90.0) < 1e-6

state = AngularTargetState(179.0, 0.0, timestamp_s=0.0)
state = state.update(-179.0, 0.0, timestamp_s=1.0, confidence=0.9)
assert abs(circular_delta_degrees(state.bearing_deg, 179.0)) < 2.0
assert state.bearing_velocity_deg_s > 0.0
predicted = state.predict(2.0)
assert -180.0 <= predicted.bearing_deg < 180.0

policy = SearchPolicy(uncertain_frames=5)
assert policy.mode(0.9, 0) == TrackingMode.VISIBLE
assert policy.mode(0.2, 2) == TrackingMode.UNCERTAIN
assert policy.mode(None, 8) == TrackingMode.LOST
assert policy.search_fov(TrackingMode.LOST) == 360.0

depth = np.full((10, 10), 4.0, dtype=np.float32)
depth[0, 0] = 100.0
mask = np.ones((10, 10), dtype=np.uint8)
estimate = robust_target_depth(depth, mask)
assert estimate is not None
assert math.isclose(estimate.depth, 4.0)

kalman = SphericalKalmanState.initialize(179.0, 0.0, 0.0)
kalman = kalman.update(-179.0, 1.0, 0.1, confidence=0.9)
assert abs(circular_delta_degrees(kalman.bearing_deg, -179.0)) < 2.0
visible_sigma = kalman.bearing_sigma_deg
predicted_kalman = kalman.predict(1.1)
assert predicted_kalman.bearing_sigma_deg > visible_sigma
corrected_kalman = predicted_kalman.update(-170.0, 1.5, 1.1, confidence=0.9)
assert corrected_kalman.bearing_sigma_deg < predicted_kalman.bearing_sigma_deg
assert estimate.uncertainty < 1e-5

print("panorama_sot_core: PASS")
