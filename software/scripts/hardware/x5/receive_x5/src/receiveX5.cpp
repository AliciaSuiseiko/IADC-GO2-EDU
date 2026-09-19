#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <opencv2/highgui.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/videoio.hpp>

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>
#include <sensor_msgs/msg/image.hpp>
#include <sensor_msgs/msg/imu.hpp>

class ReceiveX5 : public rclcpp::Node
{
public:
  ReceiveX5()
  : Node("receiveX5")
  {
    device_ = declare_parameter<std::string>("device", "/dev/video0");
    imu_topic_ = declare_parameter<std::string>("imu_topic", "/imu/data");
    image_topic_ = declare_parameter<std::string>("image_topic", "/camera/image");
    compressed_topic_ = declare_parameter<std::string>(
      "compressed_topic", "/camera/image/compressed");
    frame_id_ = declare_parameter<std::string>("frame_id", "camera");
    input_width_ = declare_parameter<int>("input_width", 2880);
    input_height_ = declare_parameter<int>("input_height", 1440);
    input_fps_ = declare_parameter<int>("input_fps", 30);
    output_fps_ = declare_parameter<int>("output_fps", 10);
    full_output_width_ = declare_parameter<int>("full_output_width", 1920);
    full_output_height_ = declare_parameter<int>("full_output_height", 960);
    crop_top_ = declare_parameter<int>("crop_top", 160);
    crop_bottom_ = declare_parameter<int>("crop_bottom", 160);
    image_latency_ = declare_parameter<double>("image_latency", 0.05);
    compressed_quality_ = declare_parameter<int>("compressed_quality", 50);
    always_publish_compressed_ = declare_parameter<bool>(
      "always_publish_compressed", true);
    always_publish_image_ = declare_parameter<bool>("always_publish_image", true);
    show_image_ = declare_parameter<bool>("show_image", false);

    validate_parameters();

    image_pub_ = create_publisher<sensor_msgs::msg::Image>(image_topic_, 2);
    compressed_pub_ = create_publisher<sensor_msgs::msg::CompressedImage>(compressed_topic_, 2);
    imu_sub_ = create_subscription<sensor_msgs::msg::Imu>(
      imu_topic_, 50,
      [this](sensor_msgs::msg::Imu::ConstSharedPtr msg) {
        system_to_imu_time_ = rclcpp::Time(msg->header.stamp).seconds() - now().seconds();
      });

    const std::string pipeline = build_pipeline();
    RCLCPP_INFO(get_logger(), "Opening X5 on %s", device_.c_str());
    RCLCPP_INFO(get_logger(), "GStreamer pipeline: %s", pipeline.c_str());
    if (!capture_.open(pipeline, cv::CAP_GSTREAMER)) {
      throw std::runtime_error("Cannot open Insta360 X5 UVC stream");
    }

    compression_params_ = {cv::IMWRITE_JPEG_QUALITY, compressed_quality_};
    RCLCPP_INFO(
      get_logger(),
      "Publishing %dx%d BGR8 panorama at %d FPS to %s (compressed: %s)",
      full_output_width_, output_height(), output_fps_, image_topic_.c_str(),
      compressed_topic_.c_str());
  }

  void run()
  {
    cv::Mat input;
    cv::Mat resized;
    std::size_t failed_reads = 0;
    std::size_t published_frames = 0;
    auto rate_window_start = std::chrono::steady_clock::now();

    while (rclcpp::ok()) {
      if (!capture_.read(input) || input.empty()) {
        ++failed_reads;
        RCLCPP_WARN_THROTTLE(
          get_logger(), *get_clock(), 2000,
          "Failed to read X5 frame (%zu consecutive failures)", failed_reads);
        rclcpp::spin_some(shared_from_this());
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        continue;
      }
      failed_reads = 0;

      const int64_t capture_time_ns = now().nanoseconds() +
        static_cast<int64_t>((system_to_imu_time_ - image_latency_) * 1e9);

      if (input.cols != input_width_ || input.rows != input_height_) {
        RCLCPP_WARN_THROTTLE(
          get_logger(), *get_clock(), 5000,
          "X5 returned %dx%d, expected %dx%d",
          input.cols, input.rows, input_width_, input_height_);
      }

      cv::resize(
        input, resized, cv::Size(full_output_width_, full_output_height_),
        0.0, 0.0, cv::INTER_AREA);
      const cv::Rect roi(
        0, crop_top_, full_output_width_,
        full_output_height_ - crop_top_ - crop_bottom_);
      const cv::Mat panorama = resized(roi);

      std_msgs::msg::Header header;
      header.frame_id = frame_id_;
      header.stamp = rclcpp::Time(capture_time_ns);
      if (always_publish_image_ || image_pub_->get_subscription_count() > 0) {
        sensor_msgs::msg::Image image_message;
        image_message.header = header;
        image_message.height = static_cast<uint32_t>(panorama.rows);
        image_message.width = static_cast<uint32_t>(panorama.cols);
        image_message.encoding = "bgr8";
        image_message.is_bigendian = false;
        image_message.step = static_cast<sensor_msgs::msg::Image::_step_type>(
          panorama.cols * panorama.elemSize());
        image_message.data.resize(
          static_cast<std::size_t>(image_message.step) * image_message.height);
        if (panorama.isContinuous()) {
          std::memcpy(image_message.data.data(), panorama.data, image_message.data.size());
        } else {
          for (int row = 0; row < panorama.rows; ++row) {
            std::memcpy(
              image_message.data.data() + static_cast<std::size_t>(row) * image_message.step,
              panorama.ptr(row), image_message.step);
          }
        }
        image_pub_->publish(image_message);
      }

      ++published_frames;
      const auto rate_now = std::chrono::steady_clock::now();
      const double rate_seconds = std::chrono::duration<double>(rate_now - rate_window_start).count();
      if (rate_seconds >= 5.0) {
        RCLCPP_INFO(
          get_logger(), "Published %.2f FPS over %.1f seconds",
          static_cast<double>(published_frames) / rate_seconds, rate_seconds);
        published_frames = 0;
        rate_window_start = rate_now;
      }

      if (always_publish_compressed_ || compressed_pub_->get_subscription_count() > 0) {
        sensor_msgs::msg::CompressedImage compressed;
        compressed.header = header;
        compressed.format = "jpeg";
        cv::imencode(".jpg", panorama, compressed.data, compression_params_);
        compressed_pub_->publish(compressed);
      }

      if (show_image_) {
        cv::Mat preview;
        cv::resize(panorama, preview, cv::Size(), 0.5, 0.5, cv::INTER_AREA);
        cv::imshow("Insta360 X5 (SysNav input)", preview);
        cv::waitKey(1);
      }

      rclcpp::spin_some(shared_from_this());
    }
  }

private:
  int output_height() const
  {
    return full_output_height_ - crop_top_ - crop_bottom_;
  }

  void validate_parameters()
  {
    if (input_width_ <= 0 || input_height_ <= 0 || input_fps_ <= 0 || output_fps_ <= 0 ||
      full_output_width_ <= 0 || full_output_height_ <= 0)
    {
      throw std::invalid_argument("Image dimensions and FPS must be positive");
    }
    if (crop_top_ < 0 || crop_bottom_ < 0 || output_height() <= 0) {
      throw std::invalid_argument("Invalid top/bottom crop for requested output height");
    }
    output_fps_ = std::min(output_fps_, input_fps_);
    compressed_quality_ = std::clamp(compressed_quality_, 1, 100);
  }

  std::string build_pipeline() const
  {
    std::ostringstream pipeline;
    pipeline << "v4l2src device=" << device_
             << " ! image/jpeg,width=" << input_width_
             << ",height=" << input_height_
             << ",framerate=" << input_fps_ << "/1"
             << " ! videorate drop-only=true max-rate=" << output_fps_
             << " ! image/jpeg,width=" << input_width_
             << ",height=" << input_height_
             << ",framerate=" << output_fps_ << "/1"
             << " ! jpegparse ! jpegdec ! videoconvert ! video/x-raw,format=BGR"
             << " ! appsink drop=true max-buffers=1 sync=false";
    return pipeline.str();
  }

  std::string device_;
  std::string imu_topic_;
  std::string image_topic_;
  std::string compressed_topic_;
  std::string frame_id_;
  int input_width_;
  int input_height_;
  int input_fps_;
  int output_fps_;
  int full_output_width_;
  int full_output_height_;
  int crop_top_;
  int crop_bottom_;
  double image_latency_;
  int compressed_quality_;
  bool always_publish_compressed_;
  bool always_publish_image_;
  bool show_image_;
  double system_to_imu_time_{0.0};

  cv::VideoCapture capture_;
  std::vector<int> compression_params_;
  rclcpp::Publisher<sensor_msgs::msg::Image>::SharedPtr image_pub_;
  rclcpp::Publisher<sensor_msgs::msg::CompressedImage>::SharedPtr compressed_pub_;
  rclcpp::Subscription<sensor_msgs::msg::Imu>::SharedPtr imu_sub_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  try {
    auto node = std::make_shared<ReceiveX5>();
    node->run();
  } catch (const std::exception & error) {
    RCLCPP_FATAL(rclcpp::get_logger("receiveX5"), "%s", error.what());
    rclcpp::shutdown();
    return 1;
  }
  rclcpp::shutdown();
  return 0;
}
