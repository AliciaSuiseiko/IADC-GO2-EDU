#!/usr/bin/env python3
import argparse
import json
import math

import numpy as np
import rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message


def rotation_from_vectors(source, target):
    source = source / np.linalg.norm(source)
    target = target / np.linalg.norm(target)
    cross = np.cross(source, target)
    dot = float(np.clip(np.dot(source, target), -1.0, 1.0))
    norm = np.linalg.norm(cross)
    if norm < 1e-12:
        return np.eye(3) if dot > 0.0 else np.diag([1.0, -1.0, -1.0])
    skew = np.array(
        [[0.0, -cross[2], cross[1]],
         [cross[2], 0.0, -cross[0]],
         [-cross[1], cross[0], 0.0]]
    )
    return np.eye(3) + skew + skew @ skew * ((1.0 - dot) / (norm * norm))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bag", nargs="+")
    parser.add_argument("--topic", default="/imu/data")
    parser.add_argument("--gyro-threshold", type=float, default=0.03)
    args = parser.parse_args()

    accelerations = []
    gyros = []
    bag_samples = {}
    for bag in args.bag:
        reader = rosbag2_py.SequentialReader()
        reader.open(
            rosbag2_py.StorageOptions(uri=bag, storage_id="sqlite3"),
            rosbag2_py.ConverterOptions("", ""),
        )
        types = {item.name: item.type for item in reader.get_all_topics_and_types()}
        message_type = get_message(types[args.topic])
        count = 0
        while reader.has_next():
            topic, raw, _ = reader.read_next()
            if topic != args.topic:
                continue
            msg = deserialize_message(raw, message_type)
            accelerations.append(
                [msg.linear_acceleration.x, msg.linear_acceleration.y, msg.linear_acceleration.z]
            )
            gyros.append([msg.angular_velocity.x, msg.angular_velocity.y, msg.angular_velocity.z])
            count += 1
        bag_samples[bag] = count

    acc = np.asarray(accelerations, dtype=float)
    gyro = np.asarray(gyros, dtype=float)
    gyro_norm = np.linalg.norm(gyro, axis=1)
    static = gyro_norm < args.gyro_threshold
    if static.sum() < 100:
        raise SystemExit(f"not enough static IMU samples: {int(static.sum())}")

    static_acc = acc[static]
    median = np.median(static_acc, axis=0)
    residual = np.linalg.norm(static_acc - median, axis=1)
    cutoff = np.quantile(residual, 0.8)
    selected = static_acc[residual <= cutoff]
    mean = selected.mean(axis=0)
    std = selected.std(axis=0)
    up_imu = mean / np.linalg.norm(mean)

    # Minimal roll/pitch rotation mapping the IMU/LiDAR up direction into body +Z.
    r_body_imu = rotation_from_vectors(up_imu, np.array([0.0, 0.0, 1.0]))
    x_tilt_deg = math.degrees(math.atan2(up_imu[1], up_imu[2]))
    total_tilt_deg = math.degrees(math.acos(float(np.clip(up_imu[2], -1.0, 1.0))))

    result = {
        "bags": bag_samples,
        "samples": len(acc),
        "static_samples": int(static.sum()),
        "selected_samples": len(selected),
        "gyro_threshold_rad_s": args.gyro_threshold,
        "mean_acc_m_s2": mean.tolist(),
        "std_acc_m_s2": std.tolist(),
        "mean_acc_norm_m_s2": float(np.linalg.norm(mean)),
        "up_in_imu": up_imu.tolist(),
        "total_tilt_deg": total_tilt_deg,
        "x_axis_tilt_deg": x_tilt_deg,
        "R_body_imu_minimal": r_body_imu.tolist(),
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
