#!/usr/bin/env python3
import argparse
from collections import Counter
import json
from pathlib import Path

import cv2
import torch
from ultralytics import YOLOE


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    image_path = Path(args.image).resolve()
    model_path = Path(args.model).resolve()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    if not image_path.is_file():
        raise FileNotFoundError(image_path)
    if not model_path.is_file():
        raise FileNotFoundError(model_path)
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is unavailable")

    image = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
    if image is None:
        raise RuntimeError(f"Failed to decode {image_path}")

    prompts = [
        "person",
        "chair",
        "table",
        "computer monitor",
        "door",
        "backpack",
        "box",
    ]
    model = YOLOE(str(model_path), task="segment")
    model.set_classes(prompts)
    results = model.predict(
        source=image,
        imgsz=640,
        conf=0.25,
        device=0,
        half=False,
        verbose=False,
    )
    result = results[0]
    box_count = 0 if result.boxes is None else len(result.boxes)
    mask_count = 0 if result.masks is None else len(result.masks)
    class_counts = Counter()
    if result.boxes is not None:
        class_counts.update(result.names[int(index)] for index in result.boxes.cls.cpu().tolist())

    annotated_path = output_dir / "annotated.jpg"
    if not cv2.imwrite(str(annotated_path), result.plot()):
        raise RuntimeError(f"Failed to write {annotated_path}")

    summary = {
        "status": "COMPLETE",
        "cuda_device": torch.cuda.get_device_name(0),
        "input_shape": list(image.shape),
        "boxes": box_count,
        "masks": mask_count,
        "class_counts": dict(sorted(class_counts.items())),
        "annotated_image": str(annotated_path),
    }
    (output_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=True))


if __name__ == "__main__":
    main()
