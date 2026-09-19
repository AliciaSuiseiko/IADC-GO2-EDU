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
import torch
import yaml

from infer import infer_raw, load_model


def receive_exact(connection: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = connection.recv(size - len(chunks))
        if not chunk:
            raise ConnectionError("connection closed before payload completed")
        chunks.extend(chunk)
    return bytes(chunks)


def send_packet(connection: socket.socket, metadata: dict, payload: bytes) -> None:
    header = json.dumps(metadata, separators=(",", ":")).encode("utf-8")
    connection.sendall(struct.pack("!II", len(header), len(payload)))
    connection.sendall(header)
    connection.sendall(payload)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18761)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--metrics", required=True)
    parser.add_argument("--max-requests", type=int, default=3)
    parser.add_argument("--idle-timeout", type=float, default=600.0)
    args = parser.parse_args()

    config = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))
    load_started = time.perf_counter()
    model, device = load_model(config)
    load_ms = (time.perf_counter() - load_started) * 1000.0

    warmup_image = np.zeros((512, 1024, 3), dtype=np.uint8)
    warmup_started = time.perf_counter()
    infer_raw(model, device, warmup_image)
    torch.cuda.synchronize()
    warmup_ms = (time.perf_counter() - warmup_started) * 1000.0

    metrics_path = Path(args.metrics)
    metrics_path.parent.mkdir(parents=True, exist_ok=True)
    ready_path = Path(args.ready_file)
    ready_path.parent.mkdir(parents=True, exist_ok=True)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((args.host, args.port))
        server.listen(2)
        server.settimeout(args.idle_timeout)
        ready_path.write_text(
            json.dumps(
                {
                    "state": "READY",
                    "host": socket.gethostname(),
                    "port": args.port,
                    "model_load_ms": load_ms,
                    "warmup_ms": warmup_ms,
                    "gpu": torch.cuda.get_device_name(0),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        for request_index in range(1, args.max_requests + 1):
            try:
                connection, address = server.accept()
            except socket.timeout:
                break
            with connection:
                connection.settimeout(30.0)
                jpeg_size = struct.unpack("!I", receive_exact(connection, 4))[0]
                if jpeg_size <= 0 or jpeg_size > 16 * 1024 * 1024:
                    raise ValueError(f"invalid JPEG payload size: {jpeg_size}")
                jpeg = receive_exact(connection, jpeg_size)

                decode_started = time.perf_counter()
                image_bgr = cv2.imdecode(np.frombuffer(jpeg, dtype=np.uint8), cv2.IMREAD_COLOR)
                if image_bgr is None:
                    raise ValueError("failed to decode JPEG")
                image_rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
                decode_ms = (time.perf_counter() - decode_started) * 1000.0

                infer_started = time.perf_counter()
                depth = infer_raw(model, device, image_rgb)
                torch.cuda.synchronize()
                infer_ms = (time.perf_counter() - infer_started) * 1000.0

                encode_started = time.perf_counter()
                depth_fp16 = np.ascontiguousarray(depth, dtype=np.float16)
                compressed = zlib.compress(depth_fp16.tobytes(), level=1)
                encode_ms = (time.perf_counter() - encode_started) * 1000.0
                metadata = {
                    "request": request_index,
                    "shape": list(depth_fp16.shape),
                    "dtype": "float16",
                    "jpeg_bytes": jpeg_size,
                    "depth_raw_bytes": depth_fp16.nbytes,
                    "depth_compressed_bytes": len(compressed),
                    "server_decode_ms": decode_ms,
                    "server_infer_ms": infer_ms,
                    "server_encode_ms": encode_ms,
                }
                send_packet(connection, metadata, compressed)
                with metrics_path.open("a", encoding="utf-8") as stream:
                    stream.write(json.dumps({**metadata, "client": address[0]}) + "\n")

    ready_path.write_text(
        json.dumps({"state": "COMPLETE", "requests": request_index if "request_index" in locals() else 0}, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
