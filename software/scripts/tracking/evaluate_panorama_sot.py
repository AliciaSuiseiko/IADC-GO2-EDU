#!/usr/bin/env python3
"""Evaluate spherical SOT predictions against MOT-style ERP annotations."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


def circular_delta(value: float, reference: float, period: float) -> float:
    return (value - reference + period * 0.5) % period - period * 0.5


def split_circular_interval(start: float, length: float, period: float):
    if length >= period:
        return [(0.0, period)]
    start %= period
    end = start + length
    if end <= period:
        return [(start, end)]
    return [(start, period), (0.0, end - period)]


def interval_overlap(first, second) -> float:
    return sum(
        max(0.0, min(a1, b1) - max(a0, b0))
        for a0, a1 in first
        for b0, b1 in second
    )


def circular_iou(pred, truth, width: float, height: float) -> float:
    pred_x, pred_y, pred_w, pred_h = pred
    true_x, true_y, true_w, true_h = truth
    overlap_x = interval_overlap(
        split_circular_interval(pred_x, pred_w, width),
        split_circular_interval(true_x, true_w, width),
    )
    overlap_y = max(0.0, min(pred_y + pred_h, true_y + true_h) - max(pred_y, true_y))
    intersection = overlap_x * overlap_y
    union = pred_w * pred_h + true_w * true_h - intersection
    return intersection / union if union > 0.0 else 0.0


def prediction_box(item, width: float, height: float):
    center_x = (item["bearing_deg"] + 180.0) / 360.0 * width
    center_y = (90.0 - item["elevation_deg"]) / 180.0 * height
    box_width = item["horizontal_extent_deg"] / 360.0 * width
    box_height = item["vertical_extent_deg"] / 180.0 * height
    return center_x - box_width * 0.5, center_y - box_height * 0.5, box_width, box_height


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--ground-truth", type=Path, required=True)
    parser.add_argument("--target-id", type=int, required=True)
    parser.add_argument("--erp-width", type=float, required=True)
    parser.add_argument("--erp-height", type=float, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    prediction_data = json.loads(args.predictions.read_text())
    truth = {}
    for line in args.ground_truth.read_text().splitlines():
        fields = [float(value) for value in line.split(",")]
        if int(fields[1]) == args.target_id:
            truth[int(fields[0])] = tuple(fields[2:6])

    samples = []
    for item in prediction_data["predictions"]:
        frame = int(Path(item["source"]).stem)
        if frame not in truth:
            continue
        predicted = prediction_box(item, args.erp_width, args.erp_height)
        expected = truth[frame]
        pred_center_x = predicted[0] + predicted[2] * 0.5
        pred_center_y = predicted[1] + predicted[3] * 0.5
        true_center_x = expected[0] + expected[2] * 0.5
        true_center_y = expected[1] + expected[3] * 0.5
        dx = circular_delta(pred_center_x, true_center_x, args.erp_width)
        dy = pred_center_y - true_center_y
        samples.append(
            {
                "frame": frame,
                "circular_iou": circular_iou(
                    predicted, expected, args.erp_width, args.erp_height
                ),
                "center_error_px": math.hypot(dx, dy),
                "bearing_error_deg": abs(dx) / args.erp_width * 360.0,
            }
        )

    if not samples:
        raise RuntimeError("No overlapping prediction and ground-truth frames")
    metrics = {
        "frames": len(samples),
        "mean_circular_iou": sum(item["circular_iou"] for item in samples) / len(samples),
        "success_at_iou_0_5": sum(item["circular_iou"] >= 0.5 for item in samples) / len(samples),
        "mean_center_error_px": sum(item["center_error_px"] for item in samples) / len(samples),
        "precision_at_20_px": sum(item["center_error_px"] <= 20.0 for item in samples) / len(samples),
        "mean_bearing_error_deg": sum(item["bearing_error_deg"] for item in samples) / len(samples),
        "samples": samples,
    }
    destination = args.output or args.predictions.with_name("metrics.json")
    destination.write_text(json.dumps(metrics, indent=2))
    print(json.dumps({key: value for key, value in metrics.items() if key != "samples"}))


if __name__ == "__main__":
    main()
