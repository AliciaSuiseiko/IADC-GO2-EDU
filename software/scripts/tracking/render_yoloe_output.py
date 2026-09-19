#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import cv2
import numpy as np


COCO_NAMES = (
    "person,bicycle,car,motorcycle,airplane,bus,train,truck,boat,traffic light,"
    "fire hydrant,stop sign,parking meter,bench,bird,cat,dog,horse,sheep,cow,"
    "elephant,bear,zebra,giraffe,backpack,umbrella,handbag,tie,suitcase,frisbee,"
    "skis,snowboard,sports ball,kite,baseball bat,baseball glove,skateboard,"
    "surfboard,tennis racket,bottle,wine glass,cup,fork,knife,spoon,bowl,banana,"
    "apple,sandwich,orange,broccoli,carrot,hot dog,pizza,donut,cake,chair,couch,"
    "potted plant,bed,dining table,toilet,tv,laptop,mouse,remote,keyboard,cell phone,"
    "microwave,oven,toaster,sink,refrigerator,book,clock,vase,scissors,teddy bear,"
    "hair drier,toothbrush"
).split(",")


def sigmoid(value: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-np.clip(value, -30.0, 30.0)))


def load_labels(path: str | None) -> tuple[list[str], str]:
    if path is None:
        return COCO_NAMES, "coco-default"

    labels_path = Path(path)
    if labels_path.suffix.lower() in {".yaml", ".yml"}:
        try:
            import yaml
        except ImportError as exc:
            raise SystemExit("PyYAML is required to read YAML labels") from exc
        payload = yaml.safe_load(labels_path.read_text(encoding="utf-8"))
        labels = []
        for group in payload.get("prompts", {}).values():
            labels.extend(group.get("prompts", []))
    else:
        labels = [line.strip() for line in labels_path.read_text(encoding="utf-8").splitlines() if line.strip()]

    if not labels:
        raise SystemExit(f"no labels found in: {labels_path}")
    return labels, str(labels_path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--tensors", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--labels")
    parser.add_argument("--depth")
    parser.add_argument("--depth-scale", type=float, default=100.0)
    parser.add_argument("--confidence", type=float, default=0.25)
    parser.add_argument("--max-detections", type=int, default=40)
    args = parser.parse_args()
    label_names, labels_source = load_labels(args.labels)
    depth = np.load(args.depth) if args.depth else None
    if depth is not None and depth.ndim != 2:
        raise SystemExit(f"expected a 2D depth map, got shape {depth.shape}")

    image = cv2.imread(args.image, cv2.IMREAD_COLOR)
    if image is None:
        raise SystemExit(f"failed to read image: {args.image}")
    canvas = cv2.resize(image, (1920, 640), interpolation=cv2.INTER_LINEAR)

    payload = json.loads(Path(args.tensors).read_text(encoding="utf-8"))
    tensors = {entry["name"]: entry for entry in payload}
    detections = np.asarray(tensors["output0"]["values"], dtype=np.float32).reshape(300, 38)
    prototypes = np.asarray(tensors["output1"]["values"], dtype=np.float32).reshape(32, 160, 480)

    selected = detections[detections[:, 4] >= args.confidence]
    selected = selected[np.argsort(selected[:, 4])[::-1]][: args.max_detections]
    overlay = canvas.copy()
    rendered = []

    for index, row in enumerate(selected):
        x1, y1, x2, y2, confidence, class_id = row[:6]
        class_id = int(class_id)
        x1i, y1i = max(0, int(round(x1))), max(0, int(round(y1)))
        x2i, y2i = min(1919, int(round(x2))), min(639, int(round(y2)))
        if x2i <= x1i or y2i <= y1i:
            continue

        mask = sigmoid(row[6:] @ prototypes.reshape(32, -1)).reshape(160, 480)
        low_x1, low_y1 = max(0, x1i // 4), max(0, y1i // 4)
        low_x2, low_y2 = min(480, (x2i + 3) // 4), min(160, (y2i + 3) // 4)
        cropped = np.zeros_like(mask)
        cropped[low_y1:low_y2, low_x1:low_x2] = mask[low_y1:low_y2, low_x1:low_x2]
        full_mask = cv2.resize(cropped, (1920, 640), interpolation=cv2.INTER_LINEAR) > 0.5

        color = np.array(
            ((37 * class_id + 31) % 220 + 25, (17 * class_id + 89) % 220 + 25, (29 * class_id + 151) % 220 + 25),
            dtype=np.uint8,
        )
        overlay[full_mask] = color
        label_name = label_names[class_id] if 0 <= class_id < len(label_names) else f"class-{class_id}"
        depth_summary = None
        if depth is not None:
            depth_mask = cv2.resize(
                full_mask.astype(np.uint8),
                (depth.shape[1], depth.shape[0]),
                interpolation=cv2.INTER_NEAREST,
            ).astype(bool)
            samples = depth[depth_mask]
            samples = samples[np.isfinite(samples) & (samples > 0)] * args.depth_scale
            if samples.size:
                depth_summary = {
                    "median_m": float(np.median(samples)),
                    "p10_m": float(np.percentile(samples, 10)),
                    "p90_m": float(np.percentile(samples, 90)),
                    "sample_pixels": int(samples.size),
                }
        label = f"{label_name} {confidence:.2f}"
        if depth_summary is not None:
            label += f"  {depth_summary['median_m']:.1f}m"
        cv2.rectangle(canvas, (x1i, y1i), (x2i, y2i), color.tolist(), 2)
        cv2.putText(canvas, label, (x1i, max(18, y1i - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color.tolist(), 2, cv2.LINE_AA)
        rendered.append(
            {
                "rank": index + 1,
                "class_id": class_id,
                "class_name": label_name,
                "confidence": float(confidence),
                "box_xyxy": [float(x1), float(y1), float(x2), float(y2)],
                "mask_pixels": int(full_mask.sum()),
                "depth": depth_summary,
            }
        )

    canvas = cv2.addWeighted(canvas, 0.72, overlay, 0.28, 0.0)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(output), canvas):
        raise SystemExit(f"failed to write output: {output}")
    Path(args.summary).write_text(
        json.dumps(
            {
                "confidence_threshold": args.confidence,
                "labels_source": labels_source,
                "depth_source": args.depth,
                "depth_scale_to_meters": args.depth_scale if depth is not None else None,
                "detections_above_threshold": len(rendered),
                "detections": rendered,
                "output_image": str(output),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
