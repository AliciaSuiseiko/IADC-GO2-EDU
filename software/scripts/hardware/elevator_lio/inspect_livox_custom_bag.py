#!/usr/bin/env python3
import argparse
import collections
import json

import rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message


def stamp_seconds(stamp) -> float:
    return stamp.sec + stamp.nanosec * 1e-9


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bag")
    parser.add_argument("--topic", default="/lidar/scan")
    parser.add_argument("--max-frames", type=int, default=0)
    args = parser.parse_args()

    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=args.bag, storage_id="sqlite3"),
        rosbag2_py.ConverterOptions("", ""),
    )
    types = {item.name: item.type for item in reader.get_all_topics_and_types()}
    message_type = get_message(types[args.topic])

    frames = []
    while reader.has_next():
        topic, raw, storage_ns = reader.read_next()
        if topic != args.topic:
            continue
        message = deserialize_message(raw, message_type)
        points = message.points
        offsets = [int(point.offset_time) for point in points]
        valid = [
            point
            for point in points
            if point.line < 6 and (point.tag & 0x30) in (0x00, 0x10)
        ]
        frames.append(
            {
                "header_s": stamp_seconds(message.header.stamp),
                "storage_s": storage_ns * 1e-9,
                "points": len(points),
                "valid_line_tag": len(valid),
                "lines": collections.Counter(int(point.line) for point in points),
                "tags": collections.Counter(int(point.tag) for point in points),
                "offset_min_ns": min(offsets) if offsets else None,
                "offset_max_ns": max(offsets) if offsets else None,
                "offset_last_ns": offsets[-1] if offsets else None,
                "offset_nonmonotonic": sum(
                    offsets[index] < offsets[index - 1]
                    for index in range(1, len(offsets))
                ),
            }
        )
        if args.max_frames and len(frames) >= args.max_frames:
            break

    selected = []
    for index in (0, 1, 2, 3, 4, 5, 10, 50, 100, 200, 300, 400):
        if index >= len(frames):
            continue
        frame = dict(frames[index])
        frame["index"] = index
        frame["storage_minus_header_s"] = frame.pop("storage_s") - frame["header_s"]
        frame["lines"] = dict(sorted(frame["lines"].items()))
        frame["tags"] = dict(sorted(frame["tags"].items()))
        selected.append(frame)

    result = {
        "frame_count": len(frames),
        "point_count_range": [
            min(frame["points"] for frame in frames),
            max(frame["points"] for frame in frames),
        ],
        "valid_line_tag_range": [
            min(frame["valid_line_tag"] for frame in frames),
            max(frame["valid_line_tag"] for frame in frames),
        ],
        "frames_with_nonmonotonic_offsets": sum(
            frame["offset_nonmonotonic"] > 0 for frame in frames
        ),
        "header_interval_s_range": [
            min(
                frames[index]["header_s"] - frames[index - 1]["header_s"]
                for index in range(1, len(frames))
            ),
            max(
                frames[index]["header_s"] - frames[index - 1]["header_s"]
                for index in range(1, len(frames))
            ),
        ],
        "selected_frames": selected,
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
