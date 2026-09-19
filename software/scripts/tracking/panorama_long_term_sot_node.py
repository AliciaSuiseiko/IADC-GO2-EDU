#!/usr/bin/env python3
"""ROS 2 panoramic single-target tracker for stitched ERP camera images."""

from __future__ import annotations

import json
import math
from pathlib import Path
import threading
import time
from typing import Optional

import cv2
import numpy as np
import rclpy
from cv_bridge import CvBridge
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import CompressedImage, Image
from std_msgs.msg import String
from ultralytics import YOLO

from panorama_reid import OSNetIdentityEncoder, crop_box
from panorama_sot_core import (
    AngularTargetState,
    SphericalKalmanState,
    angles_to_erp_pixel,
    centered_viewport_bbox,
    erp_bbox_to_spherical,
    extract_perspective_viewport,
    robust_target_depth,
    viewport_bbox_to_spherical,
    wrap_degrees,
)
from run_panorama_odtrack import draw_spherical_box, load_odtrack


UNINITIALIZED = "UNINITIALIZED"
VISIBLE = "VISIBLE"
OCCLUDED = "OCCLUDED"
LOST = "LOST"
REACQUIRED = "REACQUIRED"


def box_iou(first, second) -> float:
    ax, ay, aw, ah = [float(value) for value in first]
    bx, by, bw, bh = [float(value) for value in second]
    x1, y1 = max(ax, bx), max(ay, by)
    x2, y2 = min(ax + aw, bx + bw), min(ay + ah, by + bh)
    intersection = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    union = aw * ah + bw * bh - intersection
    return intersection / union if union > 0.0 else 0.0


def normalized_center_distance(box, width: int, height: int) -> float:
    x, y, box_width, box_height = [float(value) for value in box]
    return math.hypot(
        (x + box_width * 0.5 - width * 0.5) / width,
        (y + box_height * 0.5 - height * 0.5) / height,
    )


def erp_box_from_spherical(
    spherical: tuple[float, float, float, float], width: int, height: int
) -> tuple[list[float], bool]:
    bearing, elevation, horizontal_extent, vertical_extent = spherical
    center_x, center_y = angles_to_erp_pixel(bearing, elevation, width, height)
    box_width = horizontal_extent / 360.0 * width
    box_height = vertical_extent / 180.0 * height
    x = (center_x - box_width * 0.5) % width
    y = max(0.0, center_y - box_height * 0.5)
    box_height = min(box_height, height - y)
    wraps_seam = x + box_width > width
    return [x, y, box_width, box_height], wraps_seam


def likely_dual_fisheye(frame: np.ndarray) -> bool:
    """Detect the X5 dual-circle preview that can otherwise masquerade as 2:1 ERP."""
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    height, width = gray.shape
    h = max(height // 10, 1)
    w = max(width // 10, 1)
    corners = np.concatenate(
        [
            gray[:h, :w].ravel(),
            gray[:h, -w:].ravel(),
            gray[-h:, :w].ravel(),
            gray[-h:, -w:].ravel(),
        ]
    )
    return float(np.mean(corners < 12)) > 0.70


class IdentityGallery:
    """Immutable identity anchor plus a bounded high-confidence dynamic gallery."""

    def __init__(self, anchor: np.ndarray, capacity: int = 8) -> None:
        self.anchor = anchor / max(np.linalg.norm(anchor), 1e-12)
        self.dynamic: list[np.ndarray] = []
        self.capacity = max(int(capacity), 1)

    def similarity(self, features: np.ndarray) -> np.ndarray:
        gallery = np.stack([self.anchor, *self.dynamic])
        similarities = features @ gallery.T
        top_count = min(3, similarities.shape[1])
        return np.sort(similarities, axis=1)[:, -top_count:].mean(axis=1)

    def anchor_similarity(self, feature: np.ndarray) -> float:
        return float(np.dot(feature.reshape(-1), self.anchor.reshape(-1)))

    def update(self, feature: np.ndarray) -> None:
        feature = feature / max(np.linalg.norm(feature), 1e-12)
        self.dynamic.append(feature)
        self.dynamic = self.dynamic[-self.capacity :]


class PanoramaLongTermSotNode(Node):
    def __init__(self) -> None:
        super().__init__("panorama_long_term_sot")
        self._declare_parameters()
        self.bridge = CvBridge()
        self.lock = threading.Lock()
        self.latest_frame: Optional[tuple[np.ndarray, object, float]] = None
        self.last_processed_stamp_ns = -1
        self.pending_bbox: Optional[list[float]] = None
        self.reference_feature: Optional[np.ndarray] = None
        self.reference_pending = False
        self.input_validated = False
        self.input_rejection_logged = False

        self.mode = UNINITIALIZED
        self.tracker = None
        self.gallery: Optional[IdentityGallery] = None
        self.angular_state: Optional[SphericalKalmanState] = None
        self.spherical_box: Optional[tuple[float, float, float, float]] = None
        self.reference_area = 1.0
        self.frame_index = 0
        self.last_seen_s: Optional[float] = None
        self.last_identity_similarity = 0.0
        self.last_response_confidence = 0.0
        self.recovery_source = "none"
        self.gallery_updates = 0
        self.reacquisition_scan_index = 0
        self.processing_times: list[float] = []
        self.arrival_times: list[float] = []
        self.dropped_frames = 0
        self.latest_depth: Optional[tuple[np.ndarray, float]] = None
        self.latest_refined_mask: Optional[tuple[np.ndarray, float]] = None
        self.last_mask_source = "bbox_fallback"

        self.get_logger().info("Loading ODTrack, OSNet, and detector locally")
        self.identity_encoder = OSNetIdentityEncoder(
            Path(self._param("torchreid_repo")),
            Path(self._param("reid_checkpoint")),
            self._param("device"),
        )
        self.detector = YOLO(self._param("detector_model"))
        self._new_tracker()

        sensor_qos = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
        )
        image_message_type = CompressedImage if self._param("compressed_input") else Image
        self.create_subscription(
            image_message_type, self._param("image_topic"), self._image_callback, sensor_qos
        )
        self.create_subscription(
            String, "/tracking/initialize_target", self._initialize_callback, 5
        )
        self.create_subscription(Image, "/tracking/target_reference", self._reference_callback, 2)
        self.create_subscription(String, "/tracking/reset_target", self._reset_callback, 2)
        if self._param("depth_topic"):
            self.create_subscription(
                Image, self._param("depth_topic"), self._depth_callback, sensor_qos
            )
        if self._param("refined_mask_topic"):
            self.create_subscription(
                Image, self._param("refined_mask_topic"), self._refined_mask_callback, sensor_qos
            )
        self.state_pub = self.create_publisher(String, "/tracking/target_state", 5)
        self.mask_pub = self.create_publisher(Image, "/tracking/target_mask", sensor_qos)
        self.annotated_pub = self.create_publisher(Image, "/tracking/annotated_image", sensor_qos)
        self.diagnostics_pub = self.create_publisher(String, "/tracking/diagnostics", 5)
        self.create_timer(1.0 / float(self._param("max_processing_fps")), self._process_latest)
        self.create_timer(1.0, self._publish_diagnostics)
        self.get_logger().info(
            "Ready; initialize with bbox JSON on /tracking/initialize_target or an image on "
            "/tracking/target_reference"
        )

    def _declare_parameters(self) -> None:
        defaults = {
            "image_topic": "/camera/image",
            "compressed_input": False,
            "depth_topic": "",
            "refined_mask_topic": "",
            "depth_scale": 1.0,
            "depth_is_metric": False,
            "auxiliary_max_age_sec": 0.35,
            "odtrack_repo": "",
            "odtrack_checkpoint": "",
            "odtrack_config": "baseline",
            "torchreid_repo": "",
            "reid_checkpoint": "",
            "detector_model": "yolo11n.pt",
            "device": "cuda",
            "viewport_width": 640,
            "viewport_height": 640,
            "visible_fov_deg": 100.0,
            "recovery_fov_deg": 145.0,
            "detector_interval": 5,
            "identity_interval": 3,
            "gallery_update_interval": 15,
            "detector_confidence": 0.18,
            "identity_threshold": 0.48,
            "gallery_anchor_threshold": 0.60,
            "response_threshold": 0.20,
            "max_prediction_sec": 0.5,
            "max_processing_fps": 10.0,
            "body_forward_offset_deg": 0.0,
            "require_erp": True,
        }
        for name, value in defaults.items():
            self.declare_parameter(name, value)

    def _param(self, name: str):
        return self.get_parameter(name).value

    def _new_tracker(self) -> None:
        repo = Path(self._param("odtrack_repo"))
        checkpoint = Path(self._param("odtrack_checkpoint"))
        if not repo.is_dir() or not checkpoint.is_file():
            raise RuntimeError(f"ODTrack assets missing: repo={repo}, checkpoint={checkpoint}")
        self.tracker = load_odtrack(repo, checkpoint, self._param("odtrack_config"))

    def _image_callback(self, message) -> None:
        arrival = time.monotonic()
        try:
            if self._param("compressed_input"):
                frame = cv2.imdecode(np.frombuffer(message.data, dtype=np.uint8), cv2.IMREAD_COLOR)
                if frame is None:
                    raise ValueError("OpenCV returned an empty decoded frame")
            else:
                frame = self.bridge.imgmsg_to_cv2(message, desired_encoding="bgr8")
        except Exception as error:
            self.get_logger().error(f"Cannot decode camera image: {error}")
            return
        stamp_ns = int(message.header.stamp.sec) * 1_000_000_000 + int(
            message.header.stamp.nanosec
        )
        timestamp_s = stamp_ns / 1e9 if stamp_ns > 0 else time.time()
        with self.lock:
            if self.latest_frame is not None:
                self.dropped_frames += 1
            self.latest_frame = (frame, message.header, timestamp_s)
            self.arrival_times.append(arrival)
            self.arrival_times = self.arrival_times[-120:]

    def _initialize_callback(self, message: String) -> None:
        try:
            payload = json.loads(message.data)
            bbox = [float(value) for value in payload["bbox"]]
            if len(bbox) != 4 or bbox[2] <= 0 or bbox[3] <= 0:
                raise ValueError("bbox must be [x,y,width,height]")
            projection = payload.get("projection", "erp")
            if projection != "erp":
                raise ValueError("live node currently accepts stitched ERP coordinates only")
            with self.lock:
                self.pending_bbox = bbox
                self.reference_pending = False
            self.get_logger().info(f"Queued ERP bbox initialization: {bbox}")
        except Exception as error:
            self.get_logger().error(f"Invalid initialization request: {error}")

    def _reference_callback(self, message: Image) -> None:
        try:
            reference = self.bridge.imgmsg_to_cv2(message, desired_encoding="bgr8")
            feature = self.identity_encoder.encode([reference])[0]
            with self.lock:
                self.reference_feature = feature
                self.reference_pending = True
                self.pending_bbox = None
            self.get_logger().info("Reference identity accepted; scanning the next ERP frame")
        except Exception as error:
            self.get_logger().error(f"Cannot encode target reference: {error}")

    @staticmethod
    def _header_time(header) -> float:
        stamp_ns = int(header.stamp.sec) * 1_000_000_000 + int(header.stamp.nanosec)
        return stamp_ns / 1e9 if stamp_ns > 0 else time.time()

    @classmethod
    def _message_time(cls, message) -> float:
        return cls._header_time(message.header)

    def _depth_callback(self, message: Image) -> None:
        try:
            depth = np.asarray(self.bridge.imgmsg_to_cv2(message, desired_encoding="passthrough"))
            if depth.ndim != 2:
                raise ValueError(f"expected one-channel depth, received shape {depth.shape}")
            depth = depth.astype(np.float32) * float(self._param("depth_scale"))
            with self.lock:
                self.latest_depth = (depth, self._message_time(message))
        except Exception as error:
            self.get_logger().error(f"Cannot decode auxiliary depth: {error}")

    def _refined_mask_callback(self, message: Image) -> None:
        try:
            mask = np.asarray(self.bridge.imgmsg_to_cv2(message, desired_encoding="mono8")) > 0
            with self.lock:
                self.latest_refined_mask = (mask, self._message_time(message))
        except Exception as error:
            self.get_logger().error(f"Cannot decode refined target mask: {error}")

    def _reset_callback(self, _: String) -> None:
        with self.lock:
            self._reset_state()
        self.get_logger().info("Target reset")

    def _reset_state(self) -> None:
        self.mode = UNINITIALIZED
        self.gallery = None
        self.angular_state = None
        self.spherical_box = None
        self.pending_bbox = None
        self.reference_feature = None
        self.reference_pending = False
        self.last_seen_s = None
        self.last_identity_similarity = 0.0
        self.last_response_confidence = 0.0
        self.recovery_source = "none"
        self.reacquisition_scan_index = 0
        self.latest_refined_mask = None
        self.last_mask_source = "bbox_fallback"
        self._new_tracker()

    def _extract_view(self, frame: np.ndarray, bearing: float, elevation: float, fov: float):
        size = (int(self._param("viewport_width")), int(self._param("viewport_height")))
        return extract_perspective_viewport(frame, bearing, elevation, fov, size)

    def _detect_people(self, image: np.ndarray) -> list[list[float]]:
        result = self.detector.predict(
            image,
            imgsz=max(int(self._param("viewport_width")), int(self._param("viewport_height"))),
            classes=[0],
            conf=float(self._param("detector_confidence")),
            device=self._param("device"),
            verbose=False,
        )[0]
        if result.boxes is None:
            return []
        boxes = []
        for xyxy in result.boxes.xyxy.detach().cpu().numpy():
            x1, y1, x2, y2 = xyxy.tolist()
            if x2 - x1 >= 8 and y2 - y1 >= 16:
                boxes.append([x1, y1, x2 - x1, y2 - y1])
        return boxes

    def _initialize_from_bbox(self, frame: np.ndarray, bbox: list[float], timestamp_s: float) -> None:
        height, width = frame.shape[:2]
        bearing, elevation, angular_width, angular_height = erp_bbox_to_spherical(
            tuple(bbox), width, height
        )
        fov = float(self._param("visible_fov_deg"))
        view = self._extract_view(frame, bearing, elevation, fov)
        local_box = centered_viewport_bbox(
            angular_width,
            angular_height,
            int(self._param("viewport_width")),
            int(self._param("viewport_height")),
            fov,
        )
        self.tracker.initialize(cv2.cvtColor(view, cv2.COLOR_BGR2RGB), {"init_bbox": local_box})
        anchor = self.identity_encoder.encode([crop_box(view, local_box, padding=0.0)])[0]
        self.gallery = IdentityGallery(anchor)
        self.angular_state = SphericalKalmanState.initialize(bearing, elevation, timestamp_s)
        self.spherical_box = (bearing, elevation, angular_width, angular_height)
        self.reference_area = local_box[2] * local_box[3]
        self.mode = VISIBLE
        self.last_seen_s = timestamp_s
        self.last_identity_similarity = 1.0
        self.last_response_confidence = 1.0
        self.recovery_source = "bbox_init"

    def _scan_reference(self, frame: np.ndarray, timestamp_s: float) -> bool:
        if self.reference_feature is None:
            return False
        best = None
        view_width = int(self._param("viewport_width"))
        view_height = int(self._param("viewport_height"))
        scan_fov = 100.0
        for bearing in (-135.0, -45.0, 45.0, 135.0):
            view = self._extract_view(frame, bearing, 0.0, scan_fov)
            boxes = self._detect_people(view)
            if not boxes:
                continue
            features = self.identity_encoder.encode([crop_box(view, box) for box in boxes])
            similarities = features @ self.reference_feature.reshape(-1, 1)
            index = int(np.argmax(similarities[:, 0]))
            score = float(similarities[index, 0])
            if best is None or score > best[0]:
                spherical = viewport_bbox_to_spherical(
                    tuple(boxes[index]), view_width, view_height, bearing, 0.0, scan_fov
                )
                best = (score, spherical)
        if best is None or best[0] < float(self._param("identity_threshold")):
            return False
        erp_box, _ = erp_box_from_spherical(best[1], frame.shape[1], frame.shape[0])
        self._initialize_from_bbox(frame, erp_box, timestamp_s)
        assert self.gallery is not None
        self.gallery = IdentityGallery(self.reference_feature)
        self.recovery_source = "reference_init"
        self.reference_pending = False
        return True

    def _reacquire(self, frame: np.ndarray, timestamp_s: float) -> bool:
        if self.gallery is None or self.angular_state is None:
            return False
        predicted = self.angular_state.predict(timestamp_s)
        search_step = min(90.0, max(45.0, 2.0 * predicted.bearing_sigma_deg))
        offsets = (0.0, -search_step, search_step, 180.0)
        offset = offsets[self.reacquisition_scan_index % len(offsets)]
        self.reacquisition_scan_index += 1
        center_bearing = wrap_degrees(predicted.bearing_deg + offset)
        fov = float(self._param("recovery_fov_deg"))
        view = self._extract_view(frame, center_bearing, predicted.elevation_deg, fov)
        boxes = self._detect_people(view)
        if not boxes:
            return False
        features = self.identity_encoder.encode([crop_box(view, box) for box in boxes])
        similarities = self.gallery.similarity(features)
        anchor_similarities = features @ self.gallery.anchor.reshape(-1, 1)
        candidate_spherical = [
            viewport_bbox_to_spherical(
                tuple(box),
                int(self._param("viewport_width")),
                int(self._param("viewport_height")),
                center_bearing,
                predicted.elevation_deg,
                fov,
            )
            for box in boxes
        ]
        bearing_sigma = max(predicted.bearing_sigma_deg, 8.0)
        elevation_sigma = max(predicted.elevation_sigma_deg, 6.0)
        motion_scores = np.asarray(
            [
                math.exp(
                    -0.5
                    * (
                        (wrap_degrees(item[0] - predicted.bearing_deg) / bearing_sigma) ** 2
                        + ((item[1] - predicted.elevation_deg) / elevation_sigma) ** 2
                    )
                )
                for item in candidate_spherical
            ],
            dtype=np.float32,
        )
        size_scores = np.asarray(
            [
                math.exp(
                    -abs(
                        math.log(
                            max(box[2] * box[3], 1.0) / max(self.reference_area, 1.0)
                        )
                    )
                )
                for box in boxes
            ],
            dtype=np.float32,
        )
        scores = (
            0.50 * similarities
            + 0.25 * anchor_similarities[:, 0]
            + 0.15 * motion_scores
            + 0.10 * size_scores
        )
        index = int(np.argmax(scores))
        identity = float(similarities[index])
        anchor_identity = float(anchor_similarities[index, 0])
        if identity < float(self._param("identity_threshold")) or anchor_identity < 0.40:
            return False
        local_box = boxes[index]
        spherical = candidate_spherical[index]
        self.tracker.initialize(cv2.cvtColor(view, cv2.COLOR_BGR2RGB), {"init_bbox": local_box})
        self.angular_state = self.angular_state.update(
            spherical[0], spherical[1], timestamp_s, identity
        )
        self.spherical_box = spherical
        self.reference_area = local_box[2] * local_box[3]
        self.last_seen_s = timestamp_s
        self.last_identity_similarity = identity
        self.mode = REACQUIRED
        self.recovery_source = "panorama_detector_reid"
        return True

    def _track(self, frame: np.ndarray, timestamp_s: float) -> None:
        assert self.angular_state is not None and self.spherical_box is not None
        assert self.gallery is not None
        predicted = self.angular_state.predict(timestamp_s)
        fov = float(self._param("visible_fov_deg"))
        view = self._extract_view(frame, predicted.bearing_deg, predicted.elevation_deg, fov)
        _, _, angular_width, angular_height = self.spherical_box
        self.tracker.state = centered_viewport_bbox(
            angular_width,
            angular_height,
            int(self._param("viewport_width")),
            int(self._param("viewport_height")),
            fov,
        )
        result = self.tracker.track(cv2.cvtColor(view, cv2.COLOR_BGR2RGB))
        sot_box = [float(value) for value in result["target_bbox"]]
        response = float(self.tracker.last_response_confidence or 0.0)
        self.last_response_confidence = response
        chosen_box = sot_box
        source = "odtrack"
        chosen_feature = None
        identity = self.last_identity_similarity

        identity_due = self.frame_index % int(self._param("identity_interval")) == 0
        detector_due = self.frame_index % int(self._param("detector_interval")) == 0
        if identity_due:
            chosen_feature = self.identity_encoder.encode([crop_box(view, sot_box)])[0]
            identity = float(self.gallery.similarity(chosen_feature[None, :])[0])

        if detector_due:
            boxes = self._detect_people(view)
            if boxes:
                features = self.identity_encoder.encode([crop_box(view, box) for box in boxes])
                similarities = self.gallery.similarity(features)
                scores = []
                for box, similarity in zip(boxes, similarities):
                    motion = math.exp(-0.5 * (normalized_center_distance(
                        box, int(self._param("viewport_width")), int(self._param("viewport_height"))
                    ) / 0.28) ** 2)
                    scores.append(0.70 * float(similarity) + 0.18 * motion + 0.12 * box_iou(box, sot_box))
                best = int(np.argmax(scores))
                sot_score = 0.70 * identity + 0.18 + 0.12
                if (
                    similarities[best] >= float(self._param("identity_threshold"))
                    and scores[best] > sot_score + 0.02
                ):
                    chosen_box = boxes[best]
                    chosen_feature = features[best]
                    identity = float(similarities[best])
                    source = "local_detector_reid"
                    if box_iou(chosen_box, sot_box) < 0.55:
                        self.tracker.initialize(
                            cv2.cvtColor(view, cv2.COLOR_BGR2RGB), {"init_bbox": chosen_box}
                        )

        accepted = (
            response >= float(self._param("response_threshold"))
            and identity >= float(self._param("identity_threshold"))
        )
        if not accepted:
            elapsed = timestamp_s - (self.last_seen_s or timestamp_s)
            self.mode = OCCLUDED if elapsed <= float(self._param("max_prediction_sec")) else LOST
            self.angular_state = predicted
            self.recovery_source = "motion_prediction" if self.mode == OCCLUDED else "none"
            if self.mode == LOST:
                self._reacquire(frame, timestamp_s)
            return

        spherical = viewport_bbox_to_spherical(
            tuple(chosen_box),
            int(self._param("viewport_width")),
            int(self._param("viewport_height")),
            predicted.bearing_deg,
            predicted.elevation_deg,
            fov,
        )
        self.angular_state = self.angular_state.update(
            spherical[0], spherical[1], timestamp_s, identity
        )
        self.spherical_box = spherical
        self.last_seen_s = timestamp_s
        self.last_identity_similarity = identity
        self.mode = VISIBLE if self.mode != LOST else REACQUIRED
        self.recovery_source = source

        if (
            chosen_feature is not None
            and self.frame_index % int(self._param("gallery_update_interval")) == 0
            and self.gallery.anchor_similarity(chosen_feature)
            >= float(self._param("gallery_anchor_threshold"))
            and response >= float(self._param("response_threshold")) * 1.5
        ):
            self.gallery.update(chosen_feature)
            self.gallery_updates += 1

    def _process_latest(self) -> None:
        with self.lock:
            packet = self.latest_frame
            self.latest_frame = None
            pending_bbox = self.pending_bbox
            if pending_bbox is not None:
                self.pending_bbox = None
            reference_pending = self.reference_pending
        if packet is None:
            return
        frame, header, timestamp_s = packet
        stamp_ns = int(header.stamp.sec) * 1_000_000_000 + int(header.stamp.nanosec)
        if stamp_ns > 0 and stamp_ns == self.last_processed_stamp_ns:
            return
        self.last_processed_stamp_ns = stamp_ns
        start = time.perf_counter()

        if not self.input_validated:
            height, width = frame.shape[:2]
            if bool(self._param("require_erp")) and (
                abs(width / max(height, 1) - 2.0) > 0.08 or likely_dual_fisheye(frame)
            ):
                if not self.input_rejection_logged:
                    self.get_logger().error(
                        "Rejected /camera/image: expected stitched 2:1 ERP, received likely dual-fisheye preview"
                    )
                    self.input_rejection_logged = True
                self._publish_state(header, frame)
                return
            self.input_validated = True
            self.input_rejection_logged = False
            self.get_logger().info(f"Validated stitched ERP input: {width}x{height}")

        if pending_bbox is not None:
            try:
                self._initialize_from_bbox(frame, pending_bbox, timestamp_s)
            except Exception as error:
                self.get_logger().error(f"Target initialization failed: {error}")
                self._reset_state()
        elif reference_pending and self.mode == UNINITIALIZED:
            self._scan_reference(frame, timestamp_s)
        elif self.mode != UNINITIALIZED:
            self._track(frame, timestamp_s)

        self.frame_index += 1
        self.processing_times.append(time.perf_counter() - start)
        self.processing_times = self.processing_times[-120:]
        self._publish_state(header, frame)

    def _publish_state(self, header, frame: np.ndarray) -> None:
        if not rclpy.ok():
            return
        now_s = time.time()
        publish_mask = self.mask_pub.get_subscription_count() > 0
        publish_annotated = self.annotated_pub.get_subscription_count() > 0
        frame_time = self._header_time(header)
        maximum_age = float(self._param("auxiliary_max_age_sec"))
        with self.lock:
            depth_packet = self.latest_depth
            refined_packet = self.latest_refined_mask
        refined_is_fresh = (
            refined_packet is not None and abs(frame_time - refined_packet[1]) <= maximum_age
        )
        depth_is_fresh = depth_packet is not None and abs(frame_time - depth_packet[1]) <= maximum_age
        need_mask = publish_mask or depth_is_fresh
        payload = {
            "state": self.mode,
            "confidence": round(float(min(self.last_identity_similarity, self.last_response_confidence)), 4),
            "identity_similarity": round(float(self.last_identity_similarity), 4),
            "response_confidence": round(float(self.last_response_confidence), 4),
            "last_visible_age_sec": None if self.last_seen_s is None else round(max(0.0, now_s - self.last_seen_s), 3),
            "recovery_source": self.recovery_source,
        }
        if need_mask and refined_is_fresh:
            mask = cv2.resize(
                refined_packet[0].astype(np.uint8),
                (frame.shape[1], frame.shape[0]),
                interpolation=cv2.INTER_NEAREST,
            )
            mask = np.asarray(mask > 0, dtype=np.uint8) * 255
            self.last_mask_source = "refined_topic"
        else:
            mask = np.zeros(frame.shape[:2], dtype=np.uint8) if need_mask else None
            self.last_mask_source = "bbox_fallback"
        annotated = frame.copy() if publish_annotated else None
        if self.spherical_box is not None and self.angular_state is not None:
            box, wraps_seam = erp_box_from_spherical(
                self.spherical_box, frame.shape[1], frame.shape[0]
            )
            payload.update(
                {
                    "bbox_erp_xywh": [round(value, 2) for value in box],
                    "wraps_seam": wraps_seam,
                    "bearing_camera_deg": round(self.angular_state.bearing_deg, 3),
                    "bearing_body_deg": round(
                        wrap_degrees(
                            self.angular_state.bearing_deg
                            - float(self._param("body_forward_offset_deg"))
                        ),
                        3,
                    ),
                    "elevation_deg": round(self.angular_state.elevation_deg, 3),
                    "bearing_velocity_deg_s": round(
                        self.angular_state.bearing_velocity_deg_s, 3
                    ),
                    "elevation_velocity_deg_s": round(
                        self.angular_state.elevation_velocity_deg_s, 3
                    ),
                    "bearing_sigma_deg": round(self.angular_state.bearing_sigma_deg, 3),
                    "elevation_sigma_deg": round(self.angular_state.elevation_sigma_deg, 3),
                }
            )
            if annotated is not None:
                draw_spherical_box(annotated, *self.spherical_box)
            center_x, center_y = angles_to_erp_pixel(
                self.angular_state.bearing_deg,
                self.angular_state.elevation_deg,
                frame.shape[1],
                frame.shape[0],
            )
            box_width, box_height = box[2], box[3]
            x1 = int(round(center_x - box_width * 0.5))
            x2 = int(round(center_x + box_width * 0.5))
            y1 = max(0, int(round(center_y - box_height * 0.5)))
            y2 = min(frame.shape[0], int(round(center_y + box_height * 0.5)))
            for shift in (-frame.shape[1], 0, frame.shape[1]):
                left, right = x1 + shift, x2 + shift
                if right > 0 and left < frame.shape[1]:
                    if mask is not None and not refined_is_fresh:
                        mask[y1:y2, max(0, left) : min(frame.shape[1], right)] = 255

        if depth_is_fresh and mask is not None and np.any(mask):
            depth = depth_packet[0]
            if depth.shape != frame.shape[:2]:
                depth = cv2.resize(
                    depth, (frame.shape[1], frame.shape[0]), interpolation=cv2.INTER_LINEAR
                )
            estimate = robust_target_depth(depth, mask)
            if estimate is not None:
                payload.update(
                    {
                        "target_depth": round(estimate.depth, 4),
                        "target_depth_uncertainty": round(estimate.uncertainty, 4),
                        "target_depth_samples": estimate.sample_count,
                        "depth_is_metric": bool(self._param("depth_is_metric")),
                        "depth_age_sec": round(abs(frame_time - depth_packet[1]), 3),
                    }
                )
        payload["mask_source"] = self.last_mask_source

        if annotated is not None:
            cv2.putText(
                annotated,
                f"{self.mode} id={self.last_identity_similarity:.2f} sot={self.last_response_confidence:.2f}",
                (20, 38),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.85,
                (0, 220, 255),
                2,
                cv2.LINE_AA,
            )
        state_message = String()
        state_message.data = json.dumps(payload, separators=(",", ":"))
        self.state_pub.publish(state_message)
        if publish_mask and mask is not None:
            mask_message = self.bridge.cv2_to_imgmsg(mask, encoding="mono8")
            mask_message.header = header
            self.mask_pub.publish(mask_message)
        if annotated is not None:
            annotated_message = self.bridge.cv2_to_imgmsg(annotated, encoding="bgr8")
            annotated_message.header = header
            self.annotated_pub.publish(annotated_message)

    def _publish_diagnostics(self) -> None:
        processing_ms = np.asarray(self.processing_times, dtype=np.float64) * 1000.0
        if len(self.arrival_times) >= 2:
            input_fps = (len(self.arrival_times) - 1) / (
                self.arrival_times[-1] - self.arrival_times[0]
            )
        else:
            input_fps = 0.0
        payload = {
            "state": self.mode,
            "input_fps": round(float(input_fps), 3),
            "processing_fps": round(
                float(1000.0 / processing_ms.mean()) if processing_ms.size else 0.0, 3
            ),
            "latency_p50_ms": round(float(np.percentile(processing_ms, 50)), 3)
            if processing_ms.size
            else None,
            "latency_p95_ms": round(float(np.percentile(processing_ms, 95)), 3)
            if processing_ms.size
            else None,
            "dropped_input_frames": self.dropped_frames,
            "gallery_updates": self.gallery_updates,
            "gallery_size": 0 if self.gallery is None else 1 + len(self.gallery.dynamic),
            "mask_source": self.last_mask_source,
            "input_projection": "erp",
        }
        message = String()
        message.data = json.dumps(payload, separators=(",", ":"))
        self.diagnostics_pub.publish(message)


def main() -> None:
    rclpy.init()
    node = PanoramaLongTermSotNode()
    try:
        rclpy.spin(node)
    except rclpy.executors.ExternalShutdownException:
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
