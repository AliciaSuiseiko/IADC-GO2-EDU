#!/usr/bin/env python3
"""Event-triggered SAM2 bbox-to-mask refinement for panoramic tracking."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import threading
import time
from typing import Optional

import cv2
import numpy as np
import rclpy
from rclpy.executors import ExternalShutdownException
from cv_bridge import CvBridge
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import CompressedImage, Image
from std_msgs.msg import String
import torch


def load_predictor(sam2_repo: Path, checkpoint: Path, device: str):
    if not sam2_repo.is_dir() or not checkpoint.is_file():
        raise RuntimeError(f"SAM2 assets missing: repo={sam2_repo}, checkpoint={checkpoint}")
    sys.path.insert(0, str(sam2_repo))
    from sam2.build_sam import build_sam2
    from sam2.sam2_image_predictor import SAM2ImagePredictor

    model = build_sam2(
        "configs/sam2.1/sam2.1_hiera_b+.yaml",
        str(checkpoint),
        device=device,
    )
    return SAM2ImagePredictor(model)


def seam_safe_prompt(
    frame: np.ndarray, bbox: list[float], wraps_seam: bool
) -> tuple[np.ndarray, np.ndarray, int]:
    """Roll a seam-crossing ERP target to the image center before prompting SAM2."""
    height, width = frame.shape[:2]
    x, y, box_width, box_height = bbox
    shift = 0
    if wraps_seam or x + box_width > width:
        center = (x + box_width * 0.5) % width
        shift = int(round(width * 0.5 - center))
        frame = np.roll(frame, shift, axis=1)
        x = width * 0.5 - box_width * 0.5
    x1 = np.clip(x, 0, width - 1)
    y1 = np.clip(y, 0, height - 1)
    x2 = np.clip(x + box_width, x1 + 1, width)
    y2 = np.clip(y + box_height, y1 + 1, height)
    return frame, np.asarray([x1, y1, x2, y2], dtype=np.float32), shift


class Sam2TrackingMaskNode(Node):
    def __init__(self) -> None:
        super().__init__("sam2_tracking_mask")
        defaults = {
            "image_topic": "/camera/image/compressed",
            "compressed_input": True,
            "state_topic": "/tracking/target_state",
            "output_topic": "/tracking/target_mask_refined",
            "sam2_repo": "",
            "checkpoint": "",
            "device": "cuda",
            "minimum_interval_sec": 0.5,
        }
        for name, value in defaults.items():
            self.declare_parameter(name, value)
        self.bridge = CvBridge()
        self.lock = threading.Lock()
        self.latest_frame: Optional[tuple[np.ndarray, object]] = None
        self.pending_state: Optional[dict] = None
        self.busy = False
        self.last_trigger_s = 0.0
        self.last_signature = ""

        self.get_logger().info("Loading event-triggered SAM2 mask refiner")
        self.predictor = load_predictor(
            Path(self._param("sam2_repo")),
            Path(self._param("checkpoint")),
            str(self._param("device")),
        )
        qos = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
        )
        message_type = CompressedImage if self._param("compressed_input") else Image
        self.create_subscription(message_type, self._param("image_topic"), self._image, qos)
        self.create_subscription(String, self._param("state_topic"), self._state, 5)
        self.publisher = self.create_publisher(Image, self._param("output_topic"), qos)
        self.create_timer(0.05, self._dispatch)
        self.get_logger().info("SAM2 mask refiner ready")

    def _param(self, name: str):
        return self.get_parameter(name).value

    def _image(self, message) -> None:
        try:
            if self._param("compressed_input"):
                frame = cv2.imdecode(np.frombuffer(message.data, np.uint8), cv2.IMREAD_COLOR)
            else:
                frame = self.bridge.imgmsg_to_cv2(message, desired_encoding="bgr8")
            if frame is None:
                raise ValueError("empty image")
            with self.lock:
                self.latest_frame = (frame, message.header)
        except Exception as error:
            self.get_logger().error(f"Cannot decode image: {error}")

    def _state(self, message: String) -> None:
        try:
            state = json.loads(message.data)
            if "bbox_erp_xywh" not in state:
                return
            source = str(state.get("recovery_source", ""))
            mode = str(state.get("state", ""))
            if mode not in {"VISIBLE", "REACQUIRED"}:
                return
            signature = f"{mode}:{source}"
            trigger_sources = {
                "bbox_init",
                "reference_init",
                "panorama_detector_reid",
                "remote_detector_reid",
            }
            if mode != "REACQUIRED" and source not in trigger_sources:
                return
            now = time.monotonic()
            if signature == self.last_signature and now - self.last_trigger_s < float(
                self._param("minimum_interval_sec")
            ):
                return
            with self.lock:
                self.pending_state = state
            self.last_signature = signature
            self.last_trigger_s = now
        except Exception as error:
            self.get_logger().warning(f"Ignoring invalid target state: {error}")

    def _dispatch(self) -> None:
        with self.lock:
            if self.busy or self.pending_state is None or self.latest_frame is None:
                return
            state = self.pending_state
            frame, header = self.latest_frame
            self.pending_state = None
            self.busy = True
        threading.Thread(
            target=self._refine,
            args=(frame.copy(), header, state),
            daemon=True,
        ).start()

    def _refine(self, frame: np.ndarray, header, state: dict) -> None:
        started = time.perf_counter()
        try:
            rolled, prompt, shift = seam_safe_prompt(
                frame,
                [float(value) for value in state["bbox_erp_xywh"]],
                bool(state.get("wraps_seam", False)),
            )
            with torch.inference_mode(), torch.autocast("cuda", dtype=torch.bfloat16):
                self.predictor.set_image(cv2.cvtColor(rolled, cv2.COLOR_BGR2RGB))
                masks, scores, _ = self.predictor.predict(
                    point_coords=None,
                    point_labels=None,
                    box=prompt,
                    multimask_output=False,
                )
            mask = np.asarray(masks[0] > 0, dtype=np.uint8) * 255
            if shift:
                mask = np.roll(mask, -shift, axis=1)
            output = self.bridge.cv2_to_imgmsg(mask, encoding="mono8")
            output.header = header
            self.publisher.publish(output)
            self.get_logger().info(
                f"Published refined mask score={float(scores[0]):.3f} "
                f"latency_ms={(time.perf_counter() - started) * 1000.0:.1f}"
            )
        except Exception as error:
            self.get_logger().error(f"SAM2 refinement failed: {error}")
        finally:
            with self.lock:
                self.busy = False


def main() -> None:
    rclpy.init()
    node = Sam2TrackingMaskNode()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
