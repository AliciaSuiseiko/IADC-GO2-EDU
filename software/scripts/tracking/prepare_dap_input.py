#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import cv2


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--width", type=int, default=1024)
    parser.add_argument("--height", type=int, default=512)
    args = parser.parse_args()

    image = cv2.imread(args.image, cv2.IMREAD_COLOR)
    if image is None:
        raise SystemExit(f"failed to read image: {args.image}")
    original_shape = list(image.shape)
    resized = cv2.resize(image, (args.width, args.height), interpolation=cv2.INTER_AREA)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(output), resized):
        raise SystemExit(f"failed to write image: {output}")
    Path(args.metadata).write_text(
        json.dumps(
            {
                "source": str(Path(args.image).resolve()),
                "original_shape_hwc": original_shape,
                "resized_shape_hwc": list(resized.shape),
                "output_bytes": output.stat().st_size,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
