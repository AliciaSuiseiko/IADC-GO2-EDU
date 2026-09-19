#!/usr/bin/env python3
"""Wait for and print one complete tracking state containing depth."""

from __future__ import annotations

import argparse
import json
import time

import rclpy
from rclpy.node import Node
from std_msgs.msg import String


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--topic", default="/tracking/target_state")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    rclpy.init()
    node = Node("wait_for_tracking_depth")
    result: list[dict] = []

    def callback(message: String) -> None:
        payload = json.loads(message.data)
        if "target_depth" in payload:
            result.append(payload)

    subscription = node.create_subscription(String, args.topic, callback, 10)
    deadline = time.monotonic() + args.timeout
    try:
        while not result and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.2)
    finally:
        node.destroy_subscription(subscription)
        node.destroy_node()
        rclpy.shutdown()
    if not result:
        raise TimeoutError(f"no depth-bearing tracking state on {args.topic}")
    print(json.dumps(result[0], indent=2))


if __name__ == "__main__":
    main()
