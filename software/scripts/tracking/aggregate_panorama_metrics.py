#!/usr/bin/env python3
"""Aggregate existing MOT prediction files without rerunning inference."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import motmetrics as mm


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    args = parser.parse_args()

    metrics = [
        "num_frames", "num_objects", "mota", "idf1", "precision", "recall",
        "num_switches", "num_fragmentations", "mostly_tracked", "mostly_lost",
        "num_false_positives", "num_misses", "idtp", "idfp", "idfn",
    ]
    output = {}
    for tracker in ("botsort", "bytetrack"):
        accumulators, names = [], []
        for prediction_path in sorted((args.run_dir / tracker).glob("*.txt")):
            sequence = prediction_path.stem
            gt_path = args.data_root / "train" / sequence / "gt" / "gt.txt"
            gt = mm.io.loadtxt(str(gt_path), fmt="mot15-2D", min_confidence=1)
            prediction = mm.io.loadtxt(str(prediction_path), fmt="mot15-2D")
            accumulators.append(
                mm.utils.compare_to_groundtruth(gt, prediction, "iou", distth=0.5)
            )
            names.append(sequence)
        table = mm.metrics.create().compute_many(
            accumulators,
            names=names,
            metrics=metrics,
            generate_overall=True,
        )
        output[tracker] = {
            index: {key: float(value) for key, value in row.items()}
            for index, row in table.to_dict(orient="index").items()
        }
    destination = args.run_dir / "aggregate_metrics.json"
    destination.write_text(json.dumps(output, indent=2))
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
