import time

import cv2
from cv_bridge import CvBridge
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import CompressedImage


class X5CameraNode(Node):
    def __init__(self):
        super().__init__("x5_camera")
        self.declare_parameter("device", 0)
        self.declare_parameter("gstreamer_pipeline", "")
        self.declare_parameter("width", 1920)
        self.declare_parameter("height", 960)
        self.declare_parameter("fps", 10.0)
        self.declare_parameter("frame_id", "camera_link")
        self.declare_parameter("publish_raw", True)
        self.declare_parameter("jpeg_quality", 90)

        self._frame_id = self.get_parameter("frame_id").value
        self._publish_raw = self.get_parameter("publish_raw").value
        self._jpeg_quality = int(self.get_parameter("jpeg_quality").value)
        self._bridge = CvBridge()
        self._raw_pub = None
        if self._publish_raw:
            from sensor_msgs.msg import Image

            self._raw_pub = self.create_publisher(Image, "/camera/image", 2)
        self._compressed_pub = self.create_publisher(
            CompressedImage, "/camera/image/compressed", 2
        )

        pipeline = self.get_parameter("gstreamer_pipeline").value
        if pipeline:
            self._capture = cv2.VideoCapture(pipeline, cv2.CAP_GSTREAMER)
        else:
            device = int(self.get_parameter("device").value)
            self._capture = cv2.VideoCapture(device, cv2.CAP_V4L2)
            self._capture.set(
                cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG")
            )
            self._capture.set(cv2.CAP_PROP_FRAME_WIDTH, self.get_parameter("width").value)
            self._capture.set(cv2.CAP_PROP_FRAME_HEIGHT, self.get_parameter("height").value)
            self._capture.set(cv2.CAP_PROP_FPS, self.get_parameter("fps").value)

        if not self._capture.isOpened():
            raise RuntimeError("Unable to open the configured X5/UVC video source")

        fps = float(self.get_parameter("fps").value)
        self._last_frame = time.monotonic()
        self._timer = self.create_timer(1.0 / max(fps, 1.0), self._publish_frame)

    def _publish_frame(self):
        try:
            ok, frame = self._capture.read()
        except cv2.error as exc:
            self.get_logger().warning(f"Camera capture error: {exc}")
            return
        if not ok or frame is None or frame.size == 0:
            if time.monotonic() - self._last_frame > 2.0:
                self.get_logger().error("No camera frame received for more than 2 seconds")
            return

        self._last_frame = time.monotonic()
        stamp = self.get_clock().now().to_msg()
        if self._raw_pub is not None:
            raw = self._bridge.cv2_to_imgmsg(frame, encoding="bgr8")
            raw.header.stamp = stamp
            raw.header.frame_id = self._frame_id
            self._raw_pub.publish(raw)

        ok, encoded = cv2.imencode(
            ".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, self._jpeg_quality]
        )
        if ok:
            compressed = CompressedImage()
            compressed.header.stamp = stamp
            compressed.header.frame_id = self._frame_id
            compressed.format = "jpeg"
            compressed.data = encoded.tobytes()
            self._compressed_pub.publish(compressed)

    def destroy_node(self):
        self._capture.release()
        super().destroy_node()


def main(args=None):
    rclpy.init(args=args)
    node = X5CameraNode()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()
