#!/usr/bin/env python3
import argparse
import json
import socket
import struct
import time
import zlib
from pathlib import Path

import cv2
import numpy as np


def receive_exact(connection: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = connection.recv(size - len(chunks))
        if not chunk:
            raise ConnectionError("connection closed before payload completed")
        chunks.extend(chunk)
    return bytes(chunks)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=18761)
    parser.add_argument("--image", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--jpeg-quality", type=int, default=85)
    args = parser.parse_args()

    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    image = cv2.imread(args.image, cv2.IMREAD_COLOR)
    if image is None:
        raise SystemExit(f"failed to read image: {args.image}")
    image = cv2.resize(image, (1024, 512), interpolation=cv2.INTER_AREA)

    total_started = time.perf_counter()
    encode_started = time.perf_counter()
    ok, encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, args.jpeg_quality])
    if not ok:
        raise SystemExit("failed to encode JPEG")
    jpeg = encoded.tobytes()
    client_encode_ms = (time.perf_counter() - encode_started) * 1000.0

    network_started = time.perf_counter()
    with socket.create_connection((args.host, args.port), timeout=10.0) as connection:
        connection.settimeout(30.0)
        connection.sendall(struct.pack("!I", len(jpeg)))
        connection.sendall(jpeg)
        header_size, payload_size = struct.unpack("!II", receive_exact(connection, 8))
        metadata = json.loads(receive_exact(connection, header_size))
        compressed = receive_exact(connection, payload_size)
    network_roundtrip_ms = (time.perf_counter() - network_started) * 1000.0

    decode_started = time.perf_counter()
    raw = zlib.decompress(compressed)
    depth = np.frombuffer(raw, dtype=np.float16).reshape(metadata["shape"]).astype(np.float32)
    client_decode_ms = (time.perf_counter() - decode_started) * 1000.0
    total_ms = (time.perf_counter() - total_started) * 1000.0

    np.save(output / "depth.npy", depth)
    normalized = np.clip(depth, 0.0, 0.1) * 10.0
    gray = np.asarray(normalized * 255.0, dtype=np.uint8)
    color = cv2.applyColorMap(gray, cv2.COLORMAP_TURBO)
    cv2.imwrite(str(output / "depth-color.png"), color)

    result = {
        **metadata,
        "server_host": args.host,
        "jpeg_quality": args.jpeg_quality,
        "client_encode_ms": client_encode_ms,
        "network_roundtrip_ms": network_roundtrip_ms,
        "client_decode_ms": client_decode_ms,
        "client_total_ms": total_ms,
        "depth_min": float(depth.min()),
        "depth_max": float(depth.max()),
        "depth_mean": float(depth.mean()),
    }
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
