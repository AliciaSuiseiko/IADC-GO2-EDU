#!/usr/bin/env python3
"""Evaluate an Ultralytics tracking-by-detection pipeline on MOT-format panoramas."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import cv2

from panorama_tracking_core import StableIdMapper, bearing_from_x, elevation_from_y


def natural_key(path: Path):
    return [int(part) if part.isdigit() else part for part in __import__("re").split(r"(\d+)", path.name)]


def find_sequences(root: Path) -> list[tuple[Path, Path]]:
    sequences = []
    for gt_path in sorted(root.rglob("gt.txt")):
        image_dir = gt_path.parent.parent / "img1"
        if image_dir.is_dir():
            sequences.append((image_dir, gt_path))
    if not sequences:
        raise FileNotFoundError(f"No MOT sequence containing img1/ and gt/gt.txt under {root}")
    return sequences


def person_class_id(names) -> int | None:
    items = names.items() if isinstance(names, dict) else enumerate(names)
    for class_id, name in items:
        if str(name).strip().lower() in {"person", "pedestrian", "human"}:
            return int(class_id)
    return None


def draw_frame(frame, tracks: list[dict], backend: str):
    height, width = frame.shape[:2]
    center_x = width // 2
    cv2.line(frame, (center_x, 0), (center_x, height - 1), (255, 180, 0), 3)
    cv2.putText(frame, "BODY FORWARD 0 deg", (center_x + 10, 32),
                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 180, 0), 2, cv2.LINE_AA)
    cv2.putText(frame, backend, (20, 32), cv2.FONT_HERSHEY_SIMPLEX,
                0.8, (255, 255, 255), 2, cv2.LINE_AA)
    for track in tracks:
        x1, y1, x2, y2 = map(int, track["bbox"])
        cv2.rectangle(frame, (x1, y1), (x2, y2), (40, 220, 60), 2)
        cv2.putText(
            frame,
            f"ID {track['stable_id']} az {track['bearing_deg']:.1f}",
            (x1, max(y1 - 7, 20)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (40, 220, 60),
            2,
            cv2.LINE_AA,
        )
    return frame


def evaluate_mot(gt_path: Path, prediction_path: Path) -> dict:
    import motmetrics as mm

    gt = mm.io.loadtxt(str(gt_path), fmt="mot15-2D", min_confidence=1)
    prediction = mm.io.loadtxt(str(prediction_path), fmt="mot15-2D")
    accumulator = mm.utils.compare_to_groundtruth(gt, prediction, "iou", distth=0.5)
    metrics = [
        "num_frames", "mota", "idf1", "precision", "recall", "num_switches",
        "num_fragmentations", "mostly_tracked", "mostly_lost", "num_false_positives",
        "num_misses",
    ]
    row = mm.metrics.create().compute(accumulator, metrics=metrics, name="overall").loc["overall"]
    return {key: float(row[key]) for key in metrics}


def run_sequence(model, tracker_config: str, image_dir: Path, gt_path: Path,
                 output_dir: Path, args) -> dict:
    image_paths = sorted(
        [p for p in image_dir.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"}],
        key=natural_key,
    )
    if args.max_frames > 0:
        image_paths = image_paths[: args.max_frames]
    mapper = StableIdMapper(max_age_frames=args.track_buffer)
    class_id = person_class_id(model.names)
    rows = []
    writer = None
    prediction_path = output_dir / f"{image_dir.parent.name}.txt"
    video_path = output_dir / f"{image_dir.parent.name}.mp4"
    started = time.perf_counter()

    for index, image_path in enumerate(image_paths, start=1):
        frame = cv2.imread(str(image_path))
        if frame is None:
            continue
        height, width = frame.shape[:2]
        kwargs = dict(source=frame, persist=True, tracker=tracker_config,
                      conf=args.confidence, imgsz=args.image_size,
                      device=args.device, verbose=False)
        if class_id is not None:
            kwargs["classes"] = [class_id]
        result = model.track(**kwargs)[0]
        detections = []
        if result.boxes is not None and result.boxes.id is not None:
            for bbox, raw_id, confidence, detected_class in zip(
                result.boxes.xyxy.detach().cpu().tolist(),
                result.boxes.id.detach().cpu().int().tolist(),
                result.boxes.conf.detach().cpu().tolist(),
                result.boxes.cls.detach().cpu().int().tolist(),
            ):
                class_name = str(result.names[int(detected_class)]).lower()
                if class_id is None and class_name not in {"person", "pedestrian", "human"}:
                    continue
                x1, y1, x2, y2 = map(float, bbox)
                cx, cy = (x1 + x2) * 0.5, (y1 + y2) * 0.5
                detections.append({
                    "raw_id": int(raw_id),
                    "bbox": (x1, y1, x2, y2),
                    "confidence": float(confidence),
                    "bearing_deg": bearing_from_x(cx, width),
                    "elevation_deg": elevation_from_y(cy, height),
                    "area_ratio": max((x2 - x1) * (y2 - y1), 0.0) / (width * height),
                })
        tracks = mapper.update(index, detections, width)
        for track in tracks:
            x1, y1, x2, y2 = track["bbox"]
            rows.append(
                f"{index},{track['stable_id']},{x1:.3f},{y1:.3f},"
                f"{x2-x1:.3f},{y2-y1:.3f},{track['confidence']:.5f},-1,-1,-1"
            )
        if index <= args.video_frames:
            if writer is None:
                writer = cv2.VideoWriter(
                    str(video_path), cv2.VideoWriter_fourcc(*"mp4v"),
                    args.video_fps, (width, height)
                )
            writer.write(draw_frame(frame.copy(), tracks, Path(tracker_config).stem))

    if writer is not None:
        writer.release()
    elapsed = time.perf_counter() - started
    prediction_path.write_text("\n".join(rows) + ("\n" if rows else ""))
    metrics = evaluate_mot(gt_path, prediction_path)
    metrics.update({
        "sequence": image_dir.parent.name,
        "frames_processed": len(image_paths),
        "elapsed_seconds": elapsed,
        "pipeline_fps": len(image_paths) / elapsed if elapsed else 0.0,
        "prediction_file": str(prediction_path),
        "visualization": str(video_path) if video_path.exists() else None,
    })
    return metrics


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--tracker", required=True)
    parser.add_argument("--device", default="0")
    parser.add_argument("--image-size", type=int, default=960)
    parser.add_argument("--confidence", type=float, default=0.25)
    parser.add_argument("--track-buffer", type=int, default=30)
    parser.add_argument("--max-sequences", type=int, default=0)
    parser.add_argument("--max-frames", type=int, default=0)
    parser.add_argument("--video-frames", type=int, default=500)
    parser.add_argument("--video-fps", type=float, default=10.0)
    args = parser.parse_args()

    from ultralytics import YOLO

    args.output_dir.mkdir(parents=True, exist_ok=True)
    sequences = find_sequences(args.data_root)
    if args.max_sequences > 0:
        sequences = sequences[: args.max_sequences]
    results = []
    for image_dir, gt_path in sequences:
        model = YOLO(args.model)
        results.append(
            run_sequence(
                model, args.tracker, image_dir, gt_path, args.output_dir, args
            )
        )
    summary = {"model": args.model, "tracker": args.tracker, "results": results}
    (args.output_dir / "metrics.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
