#!/usr/bin/env python3
"""ROS 2 panoramic person tracker with seam-aware stable IDs."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

import cv2
from cv_bridge import CvBridge
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image
from std_msgs.msg import String

from panorama_tracking_core import (
    StableIdMapper,
    bearing_from_x,
    center_body_forward,
    elevation_from_y,
)


class PanoramaPersonTracker(Node):
    def __init__(self) -> None:
        super().__init__("panorama_person_tracker")
        self.declare_parameter("input_topic", "/camera/image")
        self.declare_parameter("annotated_topic", "/tracking/annotated_image")
        self.declare_parameter("tracks_topic", "/tracking/person_tracks")
        self.declare_parameter("target_topic", "/tracking/target_state")
        self.declare_parameter("select_target_topic", "/tracking/select_target")
        self.declare_parameter("model_path", "yolo11n.pt")
        self.declare_parameter("tracker_config", "botsort.yaml")
        self.declare_parameter("fallback_tracker_config", "bytetrack.yaml")
        self.declare_parameter("device", "0")
        self.declare_parameter("confidence", 0.25)
        self.declare_parameter("image_size", 960)
        self.declare_parameter("process_every_n", 1)
        self.declare_parameter("target_lost_frames", 30)
        self.declare_parameter("body_forward_offset_deg", 0.0)

        from ultralytics import YOLO

        model_path = str(self.get_parameter("model_path").value)
        self.model = YOLO(model_path)
        self.tracker_config = str(self.get_parameter("tracker_config").value)
        self.fallback_tracker_config = str(
            self.get_parameter("fallback_tracker_config").value
        )
        self.device = str(self.get_parameter("device").value)
        self.confidence = float(self.get_parameter("confidence").value)
        self.image_size = int(self.get_parameter("image_size").value)
        self.process_every_n = max(int(self.get_parameter("process_every_n").value), 1)
        self.target_lost_frames = max(
            int(self.get_parameter("target_lost_frames").value), 1
        )
        self.body_forward_offset_deg = float(
            self.get_parameter("body_forward_offset_deg").value
        )
        self.person_class_id = self._find_person_class(self.model.names)
        self.bridge = CvBridge()
        self.mapper = StableIdMapper(max_age_frames=self.target_lost_frames)
        self.frame_index = 0
        self.target_stable_id: Optional[int] = None
        self.tracker_fallback_used = False

        self.annotated_pub = self.create_publisher(
            Image, str(self.get_parameter("annotated_topic").value), 2
        )
        self.tracks_pub = self.create_publisher(
            String, str(self.get_parameter("tracks_topic").value), 5
        )
        self.target_pub = self.create_publisher(
            String, str(self.get_parameter("target_topic").value), 5
        )
        self.subscription = self.create_subscription(
            Image,
            str(self.get_parameter("input_topic").value),
            self.on_image,
            2,
        )
        self.target_selection_subscription = self.create_subscription(
            String,
            str(self.get_parameter("select_target_topic").value),
            self.on_target_selection,
            5,
        )
        self.get_logger().info(
            f"Loaded {Path(model_path).name}; person_class_id={self.person_class_id}; "
            f"tracker={self.tracker_config}; "
            f"body_forward_offset_deg={self.body_forward_offset_deg:.1f}"
        )

    def on_target_selection(self, message: String) -> None:
        command = message.data.strip().lower()
        if command in {"", "auto", "largest", "reset"}:
            self.target_stable_id = None
            self.get_logger().info("Target lock reset; largest visible person will be selected")
            return
        try:
            self.target_stable_id = int(command)
            self.get_logger().info(f"Target locked to stable_id={self.target_stable_id}")
        except ValueError:
            self.get_logger().warning(
                f"Invalid target selection {message.data!r}; use an integer ID or reset"
            )

    @staticmethod
    def _find_person_class(names) -> Optional[int]:
        items = names.items() if isinstance(names, dict) else enumerate(names)
        for class_id, name in items:
            if str(name).strip().lower() in {"person", "pedestrian", "human"}:
                return int(class_id)
        return None

    def _run_tracker(self, frame):
        kwargs = {
            "source": frame,
            "persist": True,
            "tracker": self.tracker_config,
            "conf": self.confidence,
            "imgsz": self.image_size,
            "device": self.device,
            "verbose": False,
        }
        if self.person_class_id is not None:
            kwargs["classes"] = [self.person_class_id]
        try:
            return self.model.track(**kwargs)[0]
        except Exception as exc:
            if self.tracker_fallback_used:
                raise
            self.get_logger().warning(
                f"Primary tracker failed ({exc}); retrying with "
                f"{self.fallback_tracker_config}"
            )
            self.tracker_fallback_used = True
            self.tracker_config = self.fallback_tracker_config
            self.model.predictor = None
            kwargs["tracker"] = self.tracker_config
            return self.model.track(**kwargs)[0]

    def _extract_people(self, result, width: int, height: int) -> list[dict]:
        if result.boxes is None or result.boxes.id is None:
            return []
        boxes = result.boxes.xyxy.detach().cpu().tolist()
        raw_ids = result.boxes.id.detach().cpu().int().tolist()
        confidences = result.boxes.conf.detach().cpu().tolist()
        classes = result.boxes.cls.detach().cpu().int().tolist()
        detections = []
        for bbox_values, raw_id, confidence, class_id in zip(
            boxes, raw_ids, confidences, classes
        ):
            class_name = str(result.names[int(class_id)])
            if self.person_class_id is None and class_name.lower() not in {
                "person",
                "pedestrian",
                "human",
            }:
                continue
            x1, y1, x2, y2 = map(float, bbox_values)
            center_x = (x1 + x2) * 0.5
            center_y = (y1 + y2) * 0.5
            area_ratio = max((x2 - x1) * (y2 - y1), 0.0) / (width * height)
            detections.append(
                {
                    "raw_id": int(raw_id),
                    "class": class_name,
                    "confidence": round(float(confidence), 4),
                    "bbox": (x1, y1, x2, y2),
                    "bearing_deg": bearing_from_x(center_x, width),
                    "elevation_deg": elevation_from_y(center_y, height),
                    "area_ratio": area_ratio,
                }
            )
        return detections

    def _select_or_read_target(self, tracks: list[dict]) -> Optional[dict]:
        if self.target_stable_id is None and tracks:
            selected = max(tracks, key=lambda track: track["area_ratio"])
            self.target_stable_id = int(selected["stable_id"])
            self.get_logger().info(
                f"Locked target stable_id={self.target_stable_id} (largest person)"
            )
        return next(
            (
                track
                for track in tracks
                if int(track["stable_id"]) == self.target_stable_id
            ),
            None,
        )

    def _target_payload(self, visible_target: Optional[dict]) -> dict:
        if self.target_stable_id is None:
            return {"state": "UNINITIALIZED", "frame": self.frame_index}
        if visible_target is not None:
            return {
                "state": "VISIBLE",
                "frame": self.frame_index,
                **visible_target,
            }
        memory = self.mapper.memories.get(self.target_stable_id)
        if memory is None:
            return {
                "state": "LOST",
                "frame": self.frame_index,
                "stable_id": self.target_stable_id,
            }
        age = self.frame_index - memory.last_frame
        if age > self.target_lost_frames:
            state = "LOST"
        else:
            state = "PREDICTED"
        predicted_bearing = (
            memory.bearing_deg + memory.angular_velocity_deg_frame * age + 180.0
        ) % 360.0 - 180.0
        return {
            "state": state,
            "frame": self.frame_index,
            "stable_id": self.target_stable_id,
            "last_seen_frames": age,
            "bearing_deg": predicted_bearing,
            "elevation_deg": memory.elevation_deg,
            "angular_velocity_deg_frame": memory.angular_velocity_deg_frame,
        }

    def on_image(self, message: Image) -> None:
        self.frame_index += 1
        if self.frame_index % self.process_every_n:
            return
        try:
            raw_frame = self.bridge.imgmsg_to_cv2(message, desired_encoding="bgr8")
            frame, _ = center_body_forward(
                raw_frame, self.body_forward_offset_deg
            )
            height, width = frame.shape[:2]
            result = self._run_tracker(frame)
            raw_people = self._extract_people(result, width, height)
            tracks = self.mapper.update(self.frame_index, raw_people, width)
            visible_target = self._select_or_read_target(tracks)
            target = self._target_payload(visible_target)

            public_tracks = []
            annotated = frame.copy()
            center_x = width // 2
            cv2.line(annotated, (center_x, 0), (center_x, height - 1), (255, 180, 0), 2)
            cv2.putText(
                annotated,
                "BODY FORWARD 0 deg",
                (min(center_x + 8, max(width - 230, 0)), 24),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.6,
                (255, 180, 0),
                2,
                cv2.LINE_AA,
            )
            for track in tracks:
                public = dict(track)
                public["bbox"] = [round(value, 1) for value in track["bbox"]]
                public["bearing_deg"] = round(track["bearing_deg"], 2)
                public["elevation_deg"] = round(track["elevation_deg"], 2)
                public["area_ratio"] = round(track["area_ratio"], 6)
                public["angular_velocity_deg_frame"] = round(
                    track["angular_velocity_deg_frame"], 3
                )
                public_tracks.append(public)

                x1, y1, x2, y2 = map(int, track["bbox"])
                is_target = int(track["stable_id"]) == self.target_stable_id
                color = (0, 220, 255) if is_target else (60, 220, 60)
                cv2.rectangle(annotated, (x1, y1), (x2, y2), color, 2)
                label = (
                    f"{'TARGET ' if is_target else ''}ID {track['stable_id']} "
                    f"az {track['bearing_deg']:.1f} conf {track['confidence']:.2f}"
                )
                cv2.putText(
                    annotated,
                    label,
                    (x1, max(y1 - 8, 20)),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.55,
                    color,
                    2,
                    cv2.LINE_AA,
                )

            tracks_message = String()
            tracks_message.data = json.dumps(
                {
                    "frame": self.frame_index,
                    "bearing_reference": "base_forward",
                    "body_forward_centered": True,
                    "tracks": public_tracks,
                },
                separators=(",", ":"),
            )
            self.tracks_pub.publish(tracks_message)
            target_message = String()
            target_message.data = json.dumps(target, separators=(",", ":"))
            self.target_pub.publish(target_message)

            annotated_message = self.bridge.cv2_to_imgmsg(annotated, encoding="bgr8")
            annotated_message.header = message.header
            self.annotated_pub.publish(annotated_message)
        except Exception as exc:
            self.get_logger().error(f"Tracking frame failed: {exc}")


def main(args=None) -> None:
    rclpy.init(args=args)
    node = PanoramaPersonTracker()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
