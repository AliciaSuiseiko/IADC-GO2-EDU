#!/usr/bin/env python3

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

import rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message


def message_stamp(message):
    return float(message.header.stamp.sec) + float(message.header.stamp.nanosec) * 1e-9


def vector_norm(vector):
    return math.sqrt(vector.x**2 + vector.y**2 + vector.z**2)


def new_bin():
    return {
        "imu_count": 0,
        "lidar_count": 0,
        "odom_count": 0,
        "command_count": 0,
        "accel_norm_min_g": math.inf,
        "accel_norm_max_g": -math.inf,
        "gyro_norm_max_rad_s": 0.0,
        "lidar_points_min": math.inf,
        "lidar_points_max": 0,
        "odom_first_m": None,
        "odom_last_m": None,
        "command_linear_max_mps": 0.0,
        "command_yaw_max_rad_s": 0.0,
    }


def clean_bin(bucket):
    result = dict(bucket)
    for key in ("accel_norm_min_g", "accel_norm_max_g", "lidar_points_min"):
        if not math.isfinite(result[key]):
            result[key] = None
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bag")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=args.bag, storage_id="sqlite3"),
        rosbag2_py.ConverterOptions("cdr", "cdr"),
    )
    selected = {
        "/livox/imu",
        "/livox/lidar",
        "/Odometry",
        "/sysnav_exploration/cmd_vel_stamped",
    }
    topic_types = {
        item.name: get_message(item.type)
        for item in reader.get_all_topics_and_types()
        if item.name in selected
    }
    bins = defaultdict(new_bin)
    counts = defaultdict(int)
    top_accel = []
    top_gyro = []
    top_odom_steps = []
    last_odom = None
    last_odom_stamp = None
    last_stamps = {}
    timing = defaultdict(lambda: {"nonmonotonic": 0, "min_dt": math.inf, "max_dt": 0.0})

    def keep_top(container, sample, key, limit=20):
        container.append(sample)
        container.sort(key=lambda item: item[key], reverse=True)
        del container[limit:]

    while reader.has_next():
        topic, data, receive_ns = reader.read_next()
        if topic not in selected:
            continue
        message = deserialize_message(data, topic_types[topic])
        stamp = message_stamp(message)
        second = int(math.floor(stamp))
        bucket = bins[second]
        counts[topic] += 1

        previous_stamp = last_stamps.get(topic)
        if previous_stamp is not None:
            dt = stamp - previous_stamp
            timing[topic]["min_dt"] = min(timing[topic]["min_dt"], dt)
            timing[topic]["max_dt"] = max(timing[topic]["max_dt"], dt)
            if dt <= 0.0:
                timing[topic]["nonmonotonic"] += 1
        last_stamps[topic] = stamp

        if topic == "/livox/imu":
            accel = vector_norm(message.linear_acceleration)
            gyro = vector_norm(message.angular_velocity)
            bucket["imu_count"] += 1
            bucket["accel_norm_min_g"] = min(bucket["accel_norm_min_g"], accel)
            bucket["accel_norm_max_g"] = max(bucket["accel_norm_max_g"], accel)
            bucket["gyro_norm_max_rad_s"] = max(bucket["gyro_norm_max_rad_s"], gyro)
            keep_top(top_accel, {"stamp": stamp, "norm_g": accel}, "norm_g")
            keep_top(top_gyro, {"stamp": stamp, "norm_rad_s": gyro}, "norm_rad_s")
        elif topic == "/livox/lidar":
            points = int(message.point_num)
            bucket["lidar_count"] += 1
            bucket["lidar_points_min"] = min(bucket["lidar_points_min"], points)
            bucket["lidar_points_max"] = max(bucket["lidar_points_max"], points)
        elif topic == "/Odometry":
            point = message.pose.pose.position
            current = [point.x, point.y, point.z]
            bucket["odom_count"] += 1
            if bucket["odom_first_m"] is None:
                bucket["odom_first_m"] = current
            bucket["odom_last_m"] = current
            if last_odom is not None:
                step = math.dist(last_odom, current)
                dt = stamp - last_odom_stamp
                speed = step / dt if dt > 1e-9 else math.inf
                keep_top(
                    top_odom_steps,
                    {
                        "stamp": stamp,
                        "step_m": step,
                        "dt_sec": dt,
                        "speed_mps": speed,
                        "position_m": current,
                    },
                    "step_m",
                )
            last_odom = current
            last_odom_stamp = stamp
        else:
            bucket["command_count"] += 1
            bucket["command_linear_max_mps"] = max(
                bucket["command_linear_max_mps"],
                math.hypot(message.twist.linear.x, message.twist.linear.y),
            )
            bucket["command_yaw_max_rad_s"] = max(
                bucket["command_yaw_max_rad_s"], abs(message.twist.angular.z)
            )

    clean_timing = {}
    for topic, stats in timing.items():
        clean_timing[topic] = dict(stats)
        if not math.isfinite(clean_timing[topic]["min_dt"]):
            clean_timing[topic]["min_dt"] = None
    report = {
        "counts": dict(counts),
        "timing": clean_timing,
        "top_accel": top_accel,
        "top_gyro": top_gyro,
        "top_odom_steps": top_odom_steps,
        "per_header_second": {
            str(second): clean_bin(bucket) for second, bucket in sorted(bins.items())
        },
    }
    Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
