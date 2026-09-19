#!/usr/bin/env python3
"""Measure OSNet identity separation on one annotated QuadTrack sequence."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np

from panorama_reid import OSNetIdentityEncoder, cosine_similarity, crop_box


def load_tracks(path: Path):
    tracks = {}
    for line in path.read_text().splitlines():
        fields = [float(value) for value in line.split(",")]
        frame, target_id = int(fields[0]), int(fields[1])
        tracks.setdefault(frame, {})[target_id] = tuple(fields[2:6])
    return tracks


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--torchreid-repo", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--frames", type=Path, required=True)
    parser.add_argument("--ground-truth", type=Path, required=True)
    parser.add_argument("--target-id", type=int, required=True)
    parser.add_argument("--stride", type=int, default=10)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    tracks = load_tracks(args.ground_truth)
    initial_frame = min(frame for frame, boxes in tracks.items() if args.target_id in boxes)
    initial_image = cv2.imread(str(args.frames / f"{initial_frame:06d}.jpg"))
    encoder = OSNetIdentityEncoder(args.torchreid_repo, args.checkpoint)
    anchor = encoder.encode([crop_box(initial_image, tracks[initial_frame][args.target_id])])[0]

    rows = []
    correct = 0
    tested = 0
    margins = []
    for frame in sorted(tracks):
        if frame < initial_frame or (frame - initial_frame) % args.stride:
            continue
        boxes = tracks[frame]
        if args.target_id not in boxes:
            continue
        image = cv2.imread(str(args.frames / f"{frame:06d}.jpg"))
        identities = sorted(boxes)
        features = encoder.encode([crop_box(image, boxes[identity]) for identity in identities])
        scores = {identity: cosine_similarity(anchor, feature) for identity, feature in zip(identities, features)}
        ranked = sorted(scores, key=scores.get, reverse=True)
        best_distractor = max((score for identity, score in scores.items() if identity != args.target_id), default=-1.0)
        margin = scores[args.target_id] - best_distractor
        rows.append({"frame": frame, "scores": scores, "margin": margin, "winner": ranked[0]})
        correct += ranked[0] == args.target_id
        tested += 1
        margins.append(margin)

    result = {
        "frames": tested,
        "rank1": correct / tested,
        "mean_target_margin": float(np.mean(margins)),
        "positive_margin_rate": float(np.mean(np.asarray(margins) > 0.0)),
        "samples": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2))
    print(json.dumps({key: value for key, value in result.items() if key != "samples"}))


if __name__ == "__main__":
    main()
