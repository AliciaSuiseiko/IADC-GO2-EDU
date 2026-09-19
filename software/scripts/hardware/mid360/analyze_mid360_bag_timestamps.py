#!/usr/bin/env python3
import argparse
import bisect
import json
import math

import rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message


def stamp_seconds(stamp) -> float:
    return stamp.sec + stamp.nanosec * 1e-9


def stats(values: list[float]) -> dict:
    if not values:
        return {"count": 0}
    ordered = sorted(values)
    return {
        "count": len(values),
        "min": ordered[0],
        "median": ordered[len(ordered) // 2],
        "max": ordered[-1],
        "mean": sum(values) / len(values),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bag")
    parser.add_argument("--lidar-topic", default="/lidar/scan")
    parser.add_argument("--imu-topic", default="/imu/data")
    args = parser.parse_args()

    reader = rosbag2_py.SequentialReader()
    storage = rosbag2_py.StorageOptions(uri=args.bag, storage_id="sqlite3")
    converter = rosbag2_py.ConverterOptions("", "")
    reader.open(storage, converter)
    types = {item.name: item.type for item in reader.get_all_topics_and_types()}
    lidar_type = get_message(types[args.lidar_topic])
    imu_type = get_message(types[args.imu_topic])

    lidar = []
    imu = []
    while reader.has_next():
        topic, raw, storage_ns = reader.read_next()
        if topic == args.lidar_topic:
            msg = deserialize_message(raw, lidar_type)
            last_offset = msg.points[-1].offset_time * 1e-9 if msg.points else math.nan
            lidar.append((stamp_seconds(msg.header.stamp), storage_ns * 1e-9, last_offset))
        elif topic == args.imu_topic:
            msg = deserialize_message(raw, imu_type)
            imu.append((stamp_seconds(msg.header.stamp), storage_ns * 1e-9))

    imu_headers = [item[0] for item in imu]
    nearest_imu = []
    for lidar_header, _, _ in lidar:
        index = bisect.bisect_left(imu_headers, lidar_header)
        candidates = []
        if index < len(imu_headers):
            candidates.append(imu_headers[index])
        if index:
            candidates.append(imu_headers[index - 1])
        if candidates:
            nearest_imu.append(min(candidates, key=lambda value: abs(value - lidar_header)) - lidar_header)

    result = {
        "lidar_messages": len(lidar),
        "imu_messages": len(imu),
        "lidar_header_interval_s": stats([
            lidar[index][0] - lidar[index - 1][0] for index in range(1, len(lidar))
        ]),
        "imu_header_interval_s": stats([
            imu[index][0] - imu[index - 1][0] for index in range(1, len(imu))
        ]),
        "lidar_storage_minus_header_s": stats([storage - header for header, storage, _ in lidar]),
        "imu_storage_minus_header_s": stats([storage - header for header, storage in imu]),
        "nearest_imu_minus_lidar_header_s": stats(nearest_imu),
        "lidar_last_point_offset_s": stats([
            offset for _, _, offset in lidar if not math.isnan(offset)
        ]),
        "lidar_header_nonmonotonic": sum(
            lidar[index][0] <= lidar[index - 1][0] for index in range(1, len(lidar))
        ),
        "imu_header_nonmonotonic": sum(
            imu[index][0] <= imu[index - 1][0] for index in range(1, len(imu))
        ),
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
