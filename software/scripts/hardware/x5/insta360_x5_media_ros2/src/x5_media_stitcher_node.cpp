#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <ins_realtime_stitcher.h>
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/image.hpp>

#include "insta360_x5_media_ros2/x5_stitch_protocol.hpp"

namespace
{
ins::STITCH_TYPE parse_stitch_type(const std::string & value)
{
  if (value == "template") {
    return ins::STITCH_TYPE::TEMPLATE;
  }
  if (value == "dynamic") {
    return ins::STITCH_TYPE::DYNAMICSTITCH;
  }
  if (value == "optflow") {
    return ins::STITCH_TYPE::OPTFLOW;
  }
  if (value == "aiflow") {
    return ins::STITCH_TYPE::AIFLOW;
  }
  throw std::invalid_argument("stitch_type must be template, dynamic, optflow, or aiflow");
}
}  // namespace

class X5MediaStitcherNode final : public rclcpp::Node
{
public:
  X5MediaStitcherNode() : Node("x5_media_stitcher_node")
  {
    port_ = declare_parameter<int>("port", 42101);
    output_width_ = declare_parameter<int>("output_width", 1920);
    output_height_ = declare_parameter<int>("output_height", 960);
    crop_top_ = declare_parameter<int>("crop_top", 160);
    crop_bottom_ = declare_parameter<int>("crop_bottom", 160);
    publish_fps_ = declare_parameter<double>("publish_fps", 5.0);
    stitch_type_name_ = declare_parameter<std::string>("stitch_type", "dynamic");
    stitch_type_ = parse_stitch_type(stitch_type_name_);
    image_latency_ms_ = declare_parameter<double>("image_latency_ms", 0.0);
    frame_id_ = declare_parameter<std::string>("frame_id", "camera");
    image_topic_ = declare_parameter<std::string>("image_topic", "/camera/image");
    full_topic_ =
      declare_parameter<std::string>("full_topic", "/camera/panorama_full");

    if (port_ <= 0 || port_ > 65535 || output_width_ <= 0 || output_height_ <= 0 ||
      publish_fps_ <= 0.0 || crop_top_ < 0 || crop_bottom_ < 0 ||
      crop_top_ + crop_bottom_ >= output_height_)
    {
      throw std::invalid_argument("invalid X5 MediaSDK stitcher parameters");
    }

    image_publisher_ = create_publisher<sensor_msgs::msg::Image>(image_topic_, 2);
    full_publisher_ = create_publisher<sensor_msgs::msg::Image>(full_topic_, 2);
    server_thread_ = std::thread(&X5MediaStitcherNode::serve, this);
  }

  ~X5MediaStitcherNode() override
  {
    stopping_.store(true);
    close_sockets();
    if (server_thread_.joinable()) {
      server_thread_.join();
    }
    stop_stitcher();
  }

private:
  void close_sockets()
  {
    std::lock_guard<std::mutex> lock(socket_mutex_);
    if (client_fd_ >= 0) {
      shutdown(client_fd_, SHUT_RDWR);
      close(client_fd_);
      client_fd_ = -1;
    }
    if (server_fd_ >= 0) {
      shutdown(server_fd_, SHUT_RDWR);
      close(server_fd_);
      server_fd_ = -1;
    }
  }

  void serve()
  {
    const int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) {
      RCLCPP_FATAL(get_logger(), "Failed to create X5 MediaSDK TCP socket");
      return;
    }
    {
      std::lock_guard<std::mutex> lock(socket_mutex_);
      server_fd_ = server;
    }
    const int enabled = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons(static_cast<std::uint16_t>(port_));
    if (bind(server, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 ||
      listen(server, 1) != 0)
    {
      RCLCPP_FATAL(get_logger(), "Failed to listen for X5 CameraSDK stream on port %d", port_);
      close_sockets();
      return;
    }
    RCLCPP_INFO(get_logger(), "Listening for official X5 CameraSDK stream on port %d", port_);

    while (!stopping_.load()) {
      sockaddr_in peer{};
      socklen_t peer_size = sizeof(peer);
      const int client = accept(server, reinterpret_cast<sockaddr *>(&peer), &peer_size);
      if (client < 0) {
        if (!stopping_.load()) {
          RCLCPP_WARN(get_logger(), "X5 CameraSDK accept failed; retrying");
          std::this_thread::sleep_for(std::chrono::seconds(1));
        }
        continue;
      }
      {
        std::lock_guard<std::mutex> lock(socket_mutex_);
        client_fd_ = client;
      }
      RCLCPP_INFO(
        get_logger(), "Accepted X5 CameraSDK stream from %s", inet_ntoa(peer.sin_addr));
      try {
        receive_connection(client);
      } catch (const std::exception & error) {
        if (!stopping_.load()) {
          RCLCPP_ERROR(get_logger(), "X5 stitch stream error: %s", error.what());
        }
      }
      {
        std::lock_guard<std::mutex> lock(socket_mutex_);
        if (client_fd_ == client) {
          close(client_fd_);
          client_fd_ = -1;
        }
      }
      RCLCPP_WARN(get_logger(), "X5 CameraSDK stream disconnected");
    }
  }

  void receive_connection(int client)
  {
    while (!stopping_.load()) {
      x5_stitch_protocol::Header header;
      if (!x5_stitch_protocol::receive_header(client, header)) {
        return;
      }
      std::vector<std::uint8_t> payload(header.payload_size);
      if (!payload.empty() &&
        !x5_stitch_protocol::receive_exact(client, payload.data(), payload.size()))
      {
        return;
      }
      switch (header.type) {
        case x5_stitch_protocol::MessageType::kCameraInfo:
          configure_stitcher(payload);
          break;
        case x5_stitch_protocol::MessageType::kVideo:
          handle_video(header.timestamp, std::move(payload));
          break;
        case x5_stitch_protocol::MessageType::kGyro:
          handle_gyro(payload);
          break;
        case x5_stitch_protocol::MessageType::kExposure:
          handle_exposure(payload);
          break;
        default:
          throw std::runtime_error("unknown X5 stitch message type");
      }
    }
  }

  void configure_stitcher(const std::vector<std::uint8_t> & payload)
  {
    x5_stitch_protocol::Reader reader(payload);
    ins::CameraInfo info;
    info.cameraName = reader.string();
    const auto encode_type = reader.u8();
    info.decode_type = encode_type == 0 ?
      ins::VideoDecodeType::kH264 : ins::VideoDecodeType::kH265;
    info.window_crop_info_.src_width = reader.u32();
    info.window_crop_info_.src_height = reader.u32();
    info.window_crop_info_.dst_width = reader.u32();
    info.window_crop_info_.dst_height = reader.u32();
    info.window_crop_info_.crop_offset_x = reader.i32();
    info.window_crop_info_.crop_offset_y = reader.i32();
    reader.i64();
    reader.i64();
    // Insta360's official real-time demo leaves both initial offsets unset.
    info.gyro_timestamp = 0;
    info.sweep_timestamp = 0;
    const auto offset_count = reader.u32();
    if (offset_count > 128) {
      throw std::runtime_error("invalid X5 lens-offset count");
    }
    info.offset.reserve(offset_count);
    for (std::uint32_t index = 0; index < offset_count; ++index) {
      info.offset.push_back(reader.string());
    }
    if (reader.remaining_size() != 0) {
      throw std::runtime_error("unexpected trailing X5 camera-info data");
    }

    stop_stitcher();
    retained_video_packets_.clear();
    {
      std::lock_guard<std::mutex> lock(timestamp_mutex_);
      frame_timestamps_.clear();
    }
    stitcher_ = std::make_shared<ins::RealTimeStitcher>();
    stitcher_->SetCameraInfo(info);
    stitcher_->SetStitchType(stitch_type_);
    stitcher_->EnableFlowState(true);
    stitcher_->SetOutputSize(output_width_, output_height_);
    stitcher_->SetStitchStateCallback(
      [this](int error, const char * message) {
        RCLCPP_ERROR(
          get_logger(), "MediaSDK stitch error %d: %s", error,
          message == nullptr ? "unknown" : message);
      });
    stitcher_->SetStitchRealTimeDataCallback(
      [this](
        std::uint8_t * data[4], int linesize[4], int width, int height,
        int format, std::int64_t timestamp)
      {
        on_stitched(data, linesize, width, height, format, timestamp);
      });
    stitch_started_ = false;
    RCLCPP_INFO(
      get_logger(),
      "MediaSDK configured for %s (%ux%u lens input, %zu calibration offsets, %s stitch); "
      "waiting for the first CameraSDK video packet",
      info.cameraName.c_str(), info.window_crop_info_.src_width,
      info.window_crop_info_.src_height, info.offset.size(), stitch_type_name_.c_str());
  }

  void stop_stitcher()
  {
    if (stitcher_) {
      stitcher_->CancelStitch();
      stitcher_.reset();
    }
    stitch_started_ = false;
  }

  void handle_video(
    std::int64_t sdk_timestamp, std::vector<std::uint8_t> payload)
  {
    if (!stitcher_) {
      return;
    }
    received_video_packets_.fetch_add(1);
    retained_video_packets_.push_back(std::move(payload));
    while (retained_video_packets_.size() > 600) {
      retained_video_packets_.pop_front();
    }
    x5_stitch_protocol::Reader reader(retained_video_packets_.back());
    const auto ros_timestamp = reader.i64();
    const auto stream_type = reader.u8();
    const auto stream_index = reader.i32();
    {
      std::lock_guard<std::mutex> lock(timestamp_mutex_);
      frame_timestamps_.emplace_back(sdk_timestamp, ros_timestamp);
      while (frame_timestamps_.size() > 512) {
        frame_timestamps_.pop_front();
      }
    }
    if (!stitch_started_) {
      stitcher_->StartStitch();
      stitch_started_ = true;
      RCLCPP_INFO(get_logger(), "MediaSDK stitching started on the first video packet");
    }
    stitcher_->HandleVideoData(
      reader.remaining_data(), reader.remaining_size(), sdk_timestamp,
      stream_type, stream_index);
  }

  void handle_gyro(const std::vector<std::uint8_t> & payload)
  {
    if (!stitcher_) {
      return;
    }
    x5_stitch_protocol::Reader reader(payload);
    const auto count = reader.u32();
    if (count > 10000 || reader.remaining_size() != count * 56ULL) {
      throw std::runtime_error("invalid X5 gyro packet");
    }
    std::vector<ins::GyroData> samples(count);
    for (auto & sample : samples) {
      sample.timestamp = reader.i64();
      sample.ax = reader.f64();
      sample.ay = reader.f64();
      sample.az = reader.f64();
      sample.gx = reader.f64();
      sample.gy = reader.f64();
      sample.gz = reader.f64();
    }
    stitcher_->HandleGyroData(samples);
  }

  void handle_exposure(const std::vector<std::uint8_t> & payload)
  {
    if (!stitcher_) {
      return;
    }
    x5_stitch_protocol::Reader reader(payload);
    ins::ExposureData exposure{};
    exposure.timestamp = reader.f64();
    exposure.exposure_time = reader.f64();
    if (reader.remaining_size() != 0) {
      throw std::runtime_error("invalid X5 exposure packet");
    }
    stitcher_->HandleExposureData(exposure);
  }

  std::int64_t ros_timestamp_for(std::int64_t sdk_timestamp)
  {
    std::lock_guard<std::mutex> lock(timestamp_mutex_);
    if (frame_timestamps_.empty()) {
      return get_clock()->now().nanoseconds();
    }
    auto best = frame_timestamps_.begin();
    auto best_delta = std::llabs(best->first - sdk_timestamp);
    for (auto iterator = std::next(best); iterator != frame_timestamps_.end(); ++iterator) {
      const auto delta = std::llabs(iterator->first - sdk_timestamp);
      if (delta < best_delta) {
        best = iterator;
        best_delta = delta;
      }
    }
    const auto stamp = best->second;
    while (!frame_timestamps_.empty() && frame_timestamps_.front().first <= best->first) {
      frame_timestamps_.pop_front();
    }
    return stamp - static_cast<std::int64_t>(image_latency_ms_ * 1.0e6);
  }

  sensor_msgs::msg::Image make_image(
    const cv::Mat & image, std::int64_t ros_timestamp) const
  {
    sensor_msgs::msg::Image message;
    message.header.stamp = rclcpp::Time(ros_timestamp);
    message.header.frame_id = frame_id_;
    message.height = static_cast<std::uint32_t>(image.rows);
    message.width = static_cast<std::uint32_t>(image.cols);
    message.encoding = "bgr8";
    message.is_bigendian = false;
    message.step = static_cast<std::uint32_t>(image.cols * image.elemSize());
    message.data.resize(static_cast<std::size_t>(message.height) * message.step);
    for (int row = 0; row < image.rows; ++row) {
      std::memcpy(
        message.data.data() + static_cast<std::size_t>(row) * message.step,
        image.ptr(row), message.step);
    }
    return message;
  }

  void on_stitched(
    std::uint8_t * data[4], int linesize[4], int width, int height,
    int, std::int64_t sdk_timestamp)
  {
    if (data == nullptr || data[0] == nullptr || width <= 0 || height <= 0) {
      return;
    }
    const auto now = std::chrono::steady_clock::now();
    {
      std::lock_guard<std::mutex> lock(publish_mutex_);
      if (last_publish_.time_since_epoch().count() != 0 &&
        now - last_publish_ < std::chrono::duration<double>(1.0 / publish_fps_))
      {
        return;
      }
      last_publish_ = now;
    }

    cv::Mat rgba(height, width, CV_8UC4, data[0], linesize[0]);
    cv::Mat bgr;
    cv::cvtColor(rgba, bgr, cv::COLOR_RGBA2BGR);
    const auto ros_timestamp = ros_timestamp_for(sdk_timestamp);
    full_publisher_->publish(make_image(bgr, ros_timestamp));

    const int top = std::clamp(crop_top_, 0, bgr.rows - 1);
    const int bottom = std::clamp(crop_bottom_, 0, bgr.rows - top - 1);
    const cv::Mat cropped = bgr(cv::Rect(0, top, bgr.cols, bgr.rows - top - bottom));
    image_publisher_->publish(make_image(cropped, ros_timestamp));
    const auto published = published_frames_.fetch_add(1) + 1;
    if (published == 1) {
      RCLCPP_INFO(
        get_logger(), "Publishing official stitched X5 panorama at %dx%d on %s",
        cropped.cols, cropped.rows, image_topic_.c_str());
    }
    if (now - last_rate_report_ >= std::chrono::seconds(5)) {
      const auto received = received_video_packets_.load();
      const auto previous_received = last_reported_video_packets_.exchange(received);
      const auto previous_published = last_reported_published_frames_.exchange(published);
      const auto elapsed = std::chrono::duration<double>(now - last_rate_report_).count();
      RCLCPP_INFO(
        get_logger(), "MediaSDK throughput: input %.2f packets/s, output %.2f frames/s",
        static_cast<double>(received - previous_received) / elapsed,
        static_cast<double>(published - previous_published) / elapsed);
      last_rate_report_ = now;
    }
  }

  int port_{};
  int output_width_{};
  int output_height_{};
  int crop_top_{};
  int crop_bottom_{};
  double publish_fps_{};
  std::string stitch_type_name_;
  ins::STITCH_TYPE stitch_type_{ins::STITCH_TYPE::DYNAMICSTITCH};
  double image_latency_ms_{};
  std::string frame_id_;
  std::string image_topic_;
  std::string full_topic_;

  std::atomic<bool> stopping_{false};
  std::atomic<std::uint64_t> published_frames_{0};
  std::atomic<std::uint64_t> received_video_packets_{0};
  std::atomic<std::uint64_t> last_reported_video_packets_{0};
  std::atomic<std::uint64_t> last_reported_published_frames_{0};
  std::chrono::steady_clock::time_point last_rate_report_{std::chrono::steady_clock::now()};
  std::thread server_thread_;
  std::mutex socket_mutex_;
  int server_fd_{-1};
  int client_fd_{-1};
  std::shared_ptr<ins::RealTimeStitcher> stitcher_;
  std::deque<std::vector<std::uint8_t>> retained_video_packets_;
  bool stitch_started_{false};
  std::mutex timestamp_mutex_;
  std::deque<std::pair<std::int64_t, std::int64_t>> frame_timestamps_;
  std::mutex publish_mutex_;
  std::chrono::steady_clock::time_point last_publish_{};
  rclcpp::Publisher<sensor_msgs::msg::Image>::SharedPtr image_publisher_;
  rclcpp::Publisher<sensor_msgs::msg::Image>::SharedPtr full_publisher_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  try {
    ins::InitEnv();
    ins::SetLogLevel(ins::InsLogLevel::WARNING);
    auto node = std::make_shared<X5MediaStitcherNode>();
    rclcpp::spin(node);
  } catch (const std::exception & error) {
    RCLCPP_FATAL(rclcpp::get_logger("x5_media_stitcher_node"), "%s", error.what());
    rclcpp::shutdown();
    return 1;
  }
  rclcpp::shutdown();
  return 0;
}
