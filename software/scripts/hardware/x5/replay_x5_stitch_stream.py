#!/usr/bin/env python3
"""Replay an X5 transport capture into the MediaSDK TCP stitcher."""

from __future__ import annotations

import argparse
import socket
import struct
import time
from pathlib import Path


MAGIC = b"X5S1"
HEADER = struct.Struct("!4sHHIq")
MAX_PAYLOAD = 32 * 1024 * 1024
VIDEO_MESSAGE = 2


def read_exact(file_handle, size: int) -> bytes:
    data = file_handle.read(size)
    if len(data) != size:
        raise ValueError("truncated X5 capture")
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=42101)
    parser.add_argument("--video-fps", type=float, default=30000.0 / 1001.0)
    parser.add_argument("--pause-after-video-count", type=int, default=0)
    parser.add_argument("--pause-seconds", type=float, default=0.0)
    args = parser.parse_args()
    if args.video_fps <= 0:
        parser.error("--video-fps must be positive")
    if args.pause_after_video_count < 0 or args.pause_seconds < 0:
        parser.error("pause values must be non-negative")

    packet_count = 0
    video_count = 0
    with args.capture.open("rb") as capture, socket.create_connection(
        (args.host, args.port), timeout=10
    ) as connection:
        connection.settimeout(10)
        while True:
            header = capture.read(HEADER.size)
            if not header:
                break
            if len(header) != HEADER.size:
                raise ValueError("truncated X5 capture header")
            magic, message_type, reserved, payload_size, _ = HEADER.unpack(header)
            if magic != MAGIC or reserved != 0 or payload_size > MAX_PAYLOAD:
                raise ValueError("invalid X5 capture header")
            payload = read_exact(capture, payload_size)
            connection.sendall(header)
            connection.sendall(payload)
            packet_count += 1
            if message_type == VIDEO_MESSAGE:
                video_count += 1
                if (
                    args.pause_after_video_count
                    and video_count == args.pause_after_video_count
                ):
                    time.sleep(args.pause_seconds)
                time.sleep(1.0 / args.video_fps)

    print(f"REPLAY_COMPLETE packets={packet_count} video_packets={video_count}")
    return 0 if video_count else 2


if __name__ == "__main__":
    raise SystemExit(main())
