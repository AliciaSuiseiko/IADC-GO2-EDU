#!/usr/bin/env python3

import math
import sys
import time

import rclpy
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.executors import ExternalShutdownException
from std_msgs.msg import Bool


class RuntimeGuard(Node):
    def __init__(self):
        super().__init__("sysnav_runtime_guard")
        self.started = time.monotonic()
        self.last_received = None
        self.last_stamp = None
        self.last_position = None
        self.origin = None
        self.failure = None
        self.stale_warning_active = False
        self.health_false_since = None
        self.declare_parameter("initial_timeout_sec", 12.0)
        self.declare_parameter("stale_warning_sec", 5.0)
        self.declare_parameter("stale_failure_sec", 15.0)
        self.declare_parameter("unhealthy_failure_sec", 3.0)
        self.initial_timeout = float(self.get_parameter("initial_timeout_sec").value)
        self.stale_warning = float(self.get_parameter("stale_warning_sec").value)
        self.stale_failure = float(self.get_parameter("stale_failure_sec").value)
        self.unhealthy_failure = float(
            self.get_parameter("unhealthy_failure_sec").value
        )
        self.create_subscription(Odometry, "/state_estimation", self.on_odom, 20)
        self.create_subscription(Bool, "/state_estimation_health", self.on_health, 10)

    def fail(self, reason):
        if self.failure is None:
            self.failure = reason
            print(f"RUNTIME_GUARD_FAILURE: {reason}", file=sys.stderr, flush=True)

    def on_odom(self, message):
        now = time.monotonic()
        if self.stale_warning_active:
            print("RUNTIME_GUARD_RECOVERED: state_estimation resumed", flush=True)
            self.stale_warning_active = False
        position = message.pose.pose.position
        quaternion = message.pose.pose.orientation
        current = (position.x, position.y, position.z)
        values = current + (
            quaternion.x,
            quaternion.y,
            quaternion.z,
            quaternion.w,
        )
        if not all(math.isfinite(value) for value in values):
            self.fail("state_estimation contains a non-finite pose")
            return

        quaternion_norm = math.sqrt(
            quaternion.x * quaternion.x
            + quaternion.y * quaternion.y
            + quaternion.z * quaternion.z
            + quaternion.w * quaternion.w
        )
        if not 0.9 <= quaternion_norm <= 1.1:
            self.fail(f"invalid orientation norm {quaternion_norm:.3f}")
            return

        stamp = float(message.header.stamp.sec) + float(message.header.stamp.nanosec) * 1e-9
        if self.origin is None:
            self.origin = current
        if abs(current[2] - self.origin[2]) > 2.0:
            self.fail(
                "vertical localization drift exceeded 2.0 m "
                f"(origin_z={self.origin[2]:.3f}, current_z={current[2]:.3f})"
            )
            return

        if self.last_position is not None and self.last_stamp is not None:
            dt = stamp - self.last_stamp
            step = math.dist(self.last_position, current)
            if dt > 1e-3 and step > 0.10 and step / dt > 2.0:
                self.fail(
                    "physically implausible localization jump "
                    f"(step={step:.3f} m, dt={dt:.3f} s, speed={step / dt:.3f} m/s)"
                )
                return

        self.last_received = now
        self.last_stamp = stamp
        self.last_position = current

    def on_health(self, message):
        now = time.monotonic()
        if message.data:
            self.health_false_since = None
        elif self.health_false_since is None:
            self.health_false_since = now

    def check_freshness(self):
        now = time.monotonic()
        if self.last_received is None:
            if now - self.started > self.initial_timeout:
                self.fail(
                    "state_estimation did not arrive within "
                    f"{self.initial_timeout:.0f} seconds"
                )
            return

        stale_for = now - self.last_received
        if stale_for > self.stale_failure:
            self.fail(
                "state_estimation stopped publishing for more than "
                f"{self.stale_failure:.0f} seconds"
            )
        elif stale_for > self.stale_warning and not self.stale_warning_active:
            print(
                "RUNTIME_GUARD_WARNING: state_estimation is stale "
                f"({stale_for:.1f} seconds); waiting for recovery",
                file=sys.stderr,
                flush=True,
            )
            self.stale_warning_active = True

        if (
            self.health_false_since is not None
            and now - self.health_false_since > self.unhealthy_failure
        ):
            self.fail(
                "state_estimation_health remained false for more than "
                f"{self.unhealthy_failure:.0f} seconds"
            )


def main():
    rclpy.init()
    node = RuntimeGuard()
    try:
        while rclpy.ok() and node.failure is None:
            rclpy.spin_once(node, timeout_sec=0.2)
            node.check_freshness()
        return 2 if node.failure else 0
    except (KeyboardInterrupt, ExternalShutdownException):
        return 0
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
