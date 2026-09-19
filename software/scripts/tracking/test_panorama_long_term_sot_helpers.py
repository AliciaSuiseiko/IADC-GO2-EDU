#!/usr/bin/env python3
"""Dependency-light checks for the ROS long-term SOT helper functions."""

import importlib.util
from pathlib import Path
import sys
import types

import numpy as np


for module_name in ("rclpy", "cv_bridge", "sensor_msgs", "sensor_msgs.msg", "std_msgs", "std_msgs.msg"):
    sys.modules[module_name] = types.ModuleType(module_name)
sys.modules["rclpy.node"] = types.SimpleNamespace(Node=object)
sys.modules["rclpy.qos"] = types.SimpleNamespace(
    HistoryPolicy=object, QoSProfile=object, ReliabilityPolicy=object
)
sys.modules["cv_bridge"].CvBridge = object
sys.modules["sensor_msgs.msg"].Image = object
sys.modules["std_msgs.msg"].String = object
sys.modules["ultralytics"] = types.SimpleNamespace(YOLO=object)
sys.modules["panorama_reid"] = types.SimpleNamespace(OSNetIdentityEncoder=object, crop_box=None)
sys.modules["run_panorama_odtrack"] = types.SimpleNamespace(draw_spherical_box=None, load_odtrack=None)

core_path = Path(__file__).with_name("panorama_sot_core.py")
core_spec = importlib.util.spec_from_file_location("panorama_sot_core", core_path)
core = importlib.util.module_from_spec(core_spec)
sys.modules["panorama_sot_core"] = core
core_spec.loader.exec_module(core)

path = Path(__file__).with_name("panorama_long_term_sot_node.py")
spec = importlib.util.spec_from_file_location("panorama_long_term_sot_node", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

box, wraps = module.erp_box_from_spherical((179.0, 0.0, 20.0, 40.0), 1920, 960)
assert wraps
assert 0.0 <= box[0] < 1920.0

dual = np.zeros((960, 1920, 3), dtype=np.uint8)
dual[100:860, 100:860] = 120
dual[100:860, 1060:1820] = 120
assert module.likely_dual_fisheye(dual)
assert not module.likely_dual_fisheye(np.full((960, 1920, 3), 120, dtype=np.uint8))

anchor = np.array([1.0, 0.0], dtype=np.float32)
gallery = module.IdentityGallery(anchor, capacity=2)
gallery.update(np.array([0.8, 0.6], dtype=np.float32))
gallery.update(np.array([0.6, 0.8], dtype=np.float32))
gallery.update(np.array([0.0, 1.0], dtype=np.float32))
assert np.allclose(gallery.anchor, anchor)
assert len(gallery.dynamic) == 2
assert gallery.similarity(anchor[None, :])[0] > 0.5

print("panorama long-term SOT helpers: PASS")
