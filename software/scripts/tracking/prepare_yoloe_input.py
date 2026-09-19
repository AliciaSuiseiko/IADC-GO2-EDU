#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=640)
    args = parser.parse_args()

    image = cv2.imread(args.image, cv2.IMREAD_COLOR)
    if image is None:
        raise SystemExit(f"failed to read image: {args.image}")

    original_height, original_width = image.shape[:2]
    resized = cv2.resize(image, (args.width, args.height), interpolation=cv2.INTER_LINEAR)
    tensor = resized[:, :, ::-1].transpose(2, 0, 1)
    tensor = np.ascontiguousarray(tensor, dtype=np.float32) / 255.0
    tensor = tensor[np.newaxis, ...]

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    tensor.tofile(output)
    Path(args.metadata).write_text(
        json.dumps(
            {
                "source": str(Path(args.image).resolve()),
                "original_shape_hwc": [original_height, original_width, 3],
                "tensor_shape_nchw": list(tensor.shape),
                "dtype": str(tensor.dtype),
                "normalization": "RGB float32 / 255",
                "min": float(tensor.min()),
                "max": float(tensor.max()),
                "mean": float(tensor.mean()),
                "bytes": output.stat().st_size,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
