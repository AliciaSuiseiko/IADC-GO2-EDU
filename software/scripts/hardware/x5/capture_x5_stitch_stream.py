#!/usr/bin/env python3
"""Capture the exact X5 CameraSDK-to-MediaSDK transport stream.

This diagnostic server intentionally does not decode or stitch frames. It stores
the framed transport byte-for-byte and extracts each encoded video stream so the
input can be inspected and replayed without requiring a live camera.
"""

from __future__ import annotations

import argparse
import json
import socket
import struct
import time
from collections import Counter
from pathlib import Path


MAGIC = b"X5S1"
HEADER = struct.Struct("!4sHHIq")
VIDEO_PREFIX = struct.Struct("!qBi")
MAX_PAYLOAD = 32 * 1024 * 1024


def receive_exact(connection: socket.socket, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise EOFError("X5 transport disconnected")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def annex_b_nal_type(data: bytes) -> int | None:
    for index in range(max(0, len(data) - 4)):
        if data[index : index + 3] == b"\x00\x00\x01":
            return data[index + 3] & 0x1F
        if data[index : index + 4] == b"\x00\x00\x00\x01":
            return data[index + 4] & 0x1F
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=42101)
    parser.add_argument("--duration", type=float, default=10.0)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    packet_counts: Counter[int] = Counter()
    packet_bytes: Counter[int] = Counter()
    stream_counts: Counter[int] = Counter()
    stream_bytes: Counter[int] = Counter()
    first_video: dict[str, object] = {}
    stream_files: dict[int, object] = {}
    started_at = time.time()

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind((args.host, args.port))
            server.listen(1)
            print(f"READY {args.host}:{args.port}", flush=True)
            connection, peer = server.accept()
            with connection, (args.output_dir / "transport.x5cap").open("wb") as capture:
                print(f"CONNECTED {peer[0]}:{peer[1]}", flush=True)
                capture_started = time.monotonic()
                while time.monotonic() - capture_started < args.duration:
                    header_bytes = receive_exact(connection, HEADER.size)
                    magic, message_type, reserved, payload_size, timestamp = HEADER.unpack(
                        header_bytes
                    )
                    if magic != MAGIC or reserved != 0 or payload_size > MAX_PAYLOAD:
                        raise ValueError("invalid X5 transport header")
                    payload = receive_exact(connection, payload_size)
                    capture.write(header_bytes)
                    capture.write(payload)
                    packet_counts[message_type] += 1
                    packet_bytes[message_type] += payload_size

                    if message_type == 1:
                        (args.output_dir / "camera_info.bin").write_bytes(payload)
                    elif message_type == 2:
                        if len(payload) < VIDEO_PREFIX.size:
                            raise ValueError("truncated X5 video packet")
                        ros_timestamp, stream_type, stream_index = VIDEO_PREFIX.unpack_from(payload)
                        encoded = payload[VIDEO_PREFIX.size :]
                        if stream_index not in stream_files:
                            stream_files[stream_index] = (
                                args.output_dir / f"video_stream_{stream_index}.h264"
                            ).open("wb")
                        stream_files[stream_index].write(encoded)
                        stream_counts[stream_index] += 1
                        stream_bytes[stream_index] += len(encoded)
                        if str(stream_index) not in first_video:
                            first_video[str(stream_index)] = {
                                "sdk_timestamp": timestamp,
                                "ros_timestamp": ros_timestamp,
                                "stream_type": stream_type,
                                "encoded_bytes": len(encoded),
                                "prefix_hex": encoded[:16].hex(),
                                "first_annex_b_nal_type": annex_b_nal_type(encoded),
                            }
    except EOFError as error:
        print(str(error), flush=True)
    finally:
        for file_handle in stream_files.values():
            file_handle.close()

    manifest = {
        "capture_started_unix": started_at,
        "requested_duration_sec": args.duration,
        "packet_counts": {str(key): value for key, value in sorted(packet_counts.items())},
        "packet_payload_bytes": {
            str(key): value for key, value in sorted(packet_bytes.items())
        },
        "video_stream_packet_counts": {
            str(key): value for key, value in sorted(stream_counts.items())
        },
        "video_stream_bytes": {str(key): value for key, value in sorted(stream_bytes.items())},
        "first_video_packet": first_video,
    }
    (args.output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(manifest, sort_keys=True), flush=True)
    return 0 if packet_counts[2] else 2


if __name__ == "__main__":
    raise SystemExit(main())
