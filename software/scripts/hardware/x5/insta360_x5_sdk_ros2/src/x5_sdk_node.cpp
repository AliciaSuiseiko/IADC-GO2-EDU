#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <ctime>
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <netdb.h>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <camera/camera.h>
#include <camera/device_discovery.h>
#include <camera/photography_settings.h>
#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/gst.h>
#include <gst/video/video.h>
#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>
#include <sensor_msgs/msg/image.hpp>

#include "insta360_x5_sdk_ros2/x5_stitch_protocol.hpp"

namespace
{
class StreamDelegate final : public ins_camera::StreamDelegate
{
public:
  using VideoCallback =
    std::function<void(const uint8_t *, size_t, int64_t, uint8_t, int)>;
  using GyroCallback = std::function<void(const std::vector<ins_camera::GyroData> &)>;
  using ExposureCallback = std::function<void(const ins_camera::ExposureData &)>;

  StreamDelegate(
    VideoCallback video_callback, GyroCallback gyro_callback,
    ExposureCallback exposure_callback)
  : video_callback_(std::move(video_callback)),
    gyro_callback_(std::move(gyro_callback)),
    exposure_callback_(std::move(exposure_callback)) {}

  void OnAudioData(const uint8_t *, size_t, int64_t) override {}

  void OnVideoData(
    const uint8_t * data, size_t size, int64_t timestamp,
    uint8_t stream_type, int stream_index) override
  {
    video_callback_(data, size, timestamp, stream_type, stream_index);
  }

  void OnGyroData(const std::vector<ins_camera::GyroData> & data) override
  {
    gyro_callback_(data);
  }

  void OnExposureData(const ins_camera::ExposureData & data) override
  {
    exposure_callback_(data);
  }

private:
  VideoCallback video_callback_;
  GyroCallback gyro_callback_;
  ExposureCallback exposure_callback_;
};

class StitchTransport final
{
public:
  StitchTransport(std::string host, int port, rclcpp::Logger logger)
  : host_(std::move(host)), port_(port), logger_(std::move(logger)) {}

  ~StitchTransport() {stop();}

  bool start(
    std::vector<std::uint8_t> camera_info_packet,
    std::chrono::seconds timeout = std::chrono::seconds(15))
  {
    camera_info_packet_ = std::move(camera_info_packet);
    stopping_.store(false);
    worker_ = std::thread(&StitchTransport::run, this);
    std::unique_lock<std::mutex> lock(ready_mutex_);
    return ready_condition_.wait_for(
      lock, timeout, [this]() {return ready_ || stopping_.load();}) && ready_;
  }

  void enqueue(std::vector<std::uint8_t> packet)
  {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.push_back(std::move(packet));
    condition_.notify_one();
  }

  void stop()
  {
    if (stopping_.exchange(true)) {
      return;
    }
    condition_.notify_all();
    ready_condition_.notify_all();
    close_socket();
    if (worker_.joinable()) {
      worker_.join();
    }
  }

private:
  int connect_socket()
  {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo * result = nullptr;
    const auto port = std::to_string(port_);
    if (getaddrinfo(host_.c_str(), port.c_str(), &hints, &result) != 0) {
      return -1;
    }
    int connected = -1;
    for (auto * address = result; address != nullptr; address = address->ai_next) {
      const int candidate = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
      if (candidate < 0) {
        continue;
      }
      const int enabled = 1;
      setsockopt(candidate, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled));
      if (connect(candidate, address->ai_addr, address->ai_addrlen) == 0) {
        connected = candidate;
        break;
      }
      close(candidate);
    }
    freeaddrinfo(result);
    return connected;
  }

  void close_socket()
  {
    std::lock_guard<std::mutex> lock(socket_mutex_);
    if (socket_fd_ >= 0) {
      shutdown(socket_fd_, SHUT_RDWR);
      close(socket_fd_);
      socket_fd_ = -1;
    }
  }

  bool send_packet(const std::vector<std::uint8_t> & packet)
  {
    std::lock_guard<std::mutex> lock(socket_mutex_);
    return socket_fd_ >= 0 && x5_stitch_protocol::send_all(socket_fd_, packet);
  }

  void run()
  {
    auto next_warning = std::chrono::steady_clock::time_point::min();
    while (!stopping_.load()) {
      {
        std::lock_guard<std::mutex> lock(socket_mutex_);
        if (socket_fd_ < 0) {
          socket_fd_ = connect_socket();
        }
      }
      if (socket_fd_ < 0) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= next_warning) {
          RCLCPP_WARN(
            logger_, "Official X5 stitch receiver unavailable at %s:%d",
            host_.c_str(), port_);
          next_warning = now + std::chrono::seconds(60);
        }
        std::this_thread::sleep_for(std::chrono::seconds(2));
        continue;
      }

      if (!send_packet(camera_info_packet_)) {
        close_socket();
        continue;
      }
      {
        std::lock_guard<std::mutex> lock(ready_mutex_);
        ready_ = true;
      }
      ready_condition_.notify_all();
      RCLCPP_INFO(logger_, "Streaming X5 CameraSDK data to %s:%d", host_.c_str(), port_);

      while (!stopping_.load()) {
        std::vector<std::uint8_t> packet;
        {
          std::unique_lock<std::mutex> lock(mutex_);
          condition_.wait_for(
            lock, std::chrono::seconds(1),
            [this]() {return stopping_.load() || !queue_.empty();});
          if (stopping_.load()) {
            break;
          }
          if (queue_.empty()) {
            continue;
          }
          packet = std::move(queue_.front());
          queue_.pop_front();
        }
        if (!send_packet(packet)) {
          close_socket();
          std::lock_guard<std::mutex> lock(mutex_);
          queue_.push_front(std::move(packet));
          break;
        }
      }
    }
    close_socket();
  }

  std::string host_;
  int port_{};
  rclcpp::Logger logger_;
  std::atomic<bool> stopping_{true};
  std::thread worker_;
  std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<std::vector<std::uint8_t>> queue_;
  std::vector<std::uint8_t> camera_info_packet_;
  std::mutex ready_mutex_;
  std::condition_variable ready_condition_;
  bool ready_{false};
  std::mutex socket_mutex_;
  int socket_fd_{-1};
};

ins_camera::VideoResolution parse_resolution(const std::string & value)
{
  if (value == "1440x720") {
    return ins_camera::VideoResolution::RES_1440_720P30;
  }
  if (value == "3840x1920") {
    return ins_camera::VideoResolution::RES_3840_1920P30;
  }
  if (value == "2560x1280") {
    return ins_camera::VideoResolution::RES_2560_1280P30;
  }
  if (value == "1920x960") {
    return ins_camera::VideoResolution::RES_1920_960P30;
  }
  throw std::invalid_argument(
          "source_resolution must be 3840x1920, 2560x1280, 1920x960, or 1440x720");
}
}  // namespace

class X5SdkNode final : public rclcpp::Node
{
public:
  X5SdkNode() : Node("x5_sdk_node")
  {
    source_resolution_name_ = declare_parameter<std::string>("source_resolution", "1920x960");
    source_bitrate_ = declare_parameter<int>("source_bitrate", 8 * 1024 * 1024);
    using_lrv_ = declare_parameter<bool>("using_lrv", false);
    output_width_ = declare_parameter<int>("output_width", 1920);
    output_height_ = declare_parameter<int>("output_height", 960);
    crop_top_ = declare_parameter<int>("crop_top", 0);
    crop_bottom_ = declare_parameter<int>("crop_bottom", 0);
    output_fps_ = declare_parameter<double>("output_fps", 10.0);
    frame_id_ = declare_parameter<std::string>("frame_id", "camera");
    raw_topic_ = declare_parameter<std::string>("raw_topic", "/camera/image");
    compressed_topic_ =
      declare_parameter<std::string>("compressed_topic", "/camera/image/compressed");
    publish_raw_ = declare_parameter<bool>("publish_raw", true);
    jpeg_quality_ = declare_parameter<int>("jpeg_quality", 75);
    enable_stitching_ = declare_parameter<bool>("enable_in_camera_stitching", true);
    stitch_transport_enabled_ = declare_parameter<bool>("stitch_transport_enabled", false);
    stitch_server_host_ =
      declare_parameter<std::string>("stitch_server_host", "127.0.0.1");
    stitch_server_port_ = declare_parameter<int>("stitch_server_port", 42101);
    self_mask_rectangles_ =
      declare_parameter<std::vector<int64_t>>(
        "self_mask_rectangles", std::vector<int64_t>{});

    if (source_bitrate_ <= 0 || output_width_ <= 0 || output_height_ <= 0 || output_fps_ <= 0.0) {
      throw std::invalid_argument("bitrate, output dimensions, and FPS must be positive");
    }
    if (stitch_server_port_ <= 0 || stitch_server_port_ > 65535) {
      throw std::invalid_argument("stitch_server_port must be between 1 and 65535");
    }
    if (crop_top_ < 0 || crop_bottom_ < 0 || crop_top_ + crop_bottom_ >= output_height_) {
      throw std::invalid_argument("crop_top and crop_bottom must preserve a positive image height");
    }
    if (self_mask_rectangles_.size() % 4 != 0) {
      throw std::invalid_argument(
              "self_mask_rectangles must contain x_min,y_min,x_max,y_max groups");
    }
    jpeg_quality_ = std::clamp(jpeg_quality_, 1, 100);
    source_resolution_ = parse_resolution(source_resolution_name_);

    if (publish_raw_) {
      raw_pub_ = create_publisher<sensor_msgs::msg::Image>(raw_topic_, 2);
    }
    compressed_pub_ =
      create_publisher<sensor_msgs::msg::CompressedImage>(compressed_topic_, 2);
  }

  ~X5SdkNode() override {stop();}

  void start()
  {
    if (streaming_.load()) {
      return;
    }

    ins_camera::SetLogLevel(ins_camera::LogLevel::ERR);
    ins_camera::DeviceDiscovery discovery;
    auto devices = discovery.GetAvailableDevices();
    if (devices.empty()) {
      throw std::runtime_error(
              "No X5 found by CameraSDK; set the camera USB mode to Android control");
    }

    camera_ = std::make_shared<ins_camera::Camera>(devices.front().info);
    if (!camera_->Open()) {
      discovery.FreeDeviceDescriptors(devices);
      throw std::runtime_error("CameraSDK failed to open X5");
    }
    const auto camera_name = devices.front().camera_name;
    const auto firmware = devices.front().fw_version;
    discovery.FreeDeviceDescriptors(devices);

    const auto encode_type = camera_->GetVideoEncodeType();
    const bool is_h265 = encode_type == ins_camera::VideoEncodeType::H265;
    create_pipeline(is_h265);

    delegate_ = std::make_shared<StreamDelegate>(
      [this](const uint8_t * data, size_t size, int64_t timestamp, uint8_t type, int index) {
        push_video(data, size, timestamp, type, index);
      },
      [this](const std::vector<ins_camera::GyroData> & data) {
        push_gyro(data);
      },
      [this](const ins_camera::ExposureData & data) {
        push_exposure(data);
      });
    std::shared_ptr<ins_camera::StreamDelegate> sdk_delegate = delegate_;
    camera_->SetStreamDelegate(sdk_delegate);

    const auto now_seconds = static_cast<uint64_t>(std::time(nullptr));
    camera_->SyncLocalTimeToCamera(now_seconds, 0);
    if (!camera_->SetVideoSubMode(ins_camera::SubVideoMode::VIDEO_LIVEVIEW)) {
      throw std::runtime_error("Failed to switch X5 to live-view mode");
    }

    ins_camera::RecordParams record_params;
    record_params.resolution = source_resolution_;
    record_params.bitrate = source_bitrate_;
    if (!camera_->SetVideoCaptureParams(
        record_params, ins_camera::CameraFunctionMode::FUNCTION_MODE_LIVE_STREAM))
    {
      throw std::runtime_error("Failed to set X5 live-view parameters");
    }
    if (enable_stitching_) {
      if (!camera_->EnableInCameraStitching(true)) {
        RCLCPP_WARN(get_logger(), "X5 rejected in-camera stitching; publishing decoded lens stream");
      } else {
        RCLCPP_INFO(get_logger(), "X5 in-camera stitching enabled");
      }
    }

    if (stitch_transport_enabled_) {
      const auto preview = camera_->GetPreviewParam();
      stitch_transport_ = std::make_unique<StitchTransport>(
        stitch_server_host_, stitch_server_port_, get_logger());
      if (!stitch_transport_->start(make_camera_info_packet(preview))) {
        throw std::runtime_error(
                "X5 MediaSDK transport was not ready before live streaming");
      }
    }

    ins_camera::LiveStreamParam stream_params;
    stream_params.video_resolution = source_resolution_;
    stream_params.lrv_video_resulution = source_resolution_;
    stream_params.video_bitrate = static_cast<uint32_t>(source_bitrate_);
    stream_params.enable_audio = false;
    stream_params.enable_gyro = stitch_transport_enabled_;
    stream_params.using_lrv = using_lrv_;

    streaming_.store(true);
    if (!camera_->StartLiveStreaming(stream_params)) {
      streaming_.store(false);
      throw std::runtime_error("CameraSDK failed to start X5 preview stream");
    }

    frame_timer_ = create_wall_timer(
      std::chrono::duration<double>(1.0 / output_fps_),
      std::bind(&X5SdkNode::publish_latest_frame, this));
    RCLCPP_INFO(
      get_logger(), "Opened %s (%s), %s preview (using_lrv=%s) -> %dx%d at %.1f Hz",
      camera_name.c_str(), firmware.c_str(), source_resolution_name_.c_str(),
      using_lrv_ ? "true" : "false",
      output_width_, output_height_ - crop_top_ - crop_bottom_, output_fps_);
  }

  void stop()
  {
    if (!camera_ && !pipeline_) {
      return;
    }
    frame_timer_.reset();
    streaming_.store(false);
    if (camera_) {
      camera_->StopLiveStreaming();
      camera_->Close();
      camera_.reset();
    }
    if (stitch_transport_) {
      stitch_transport_->stop();
      stitch_transport_.reset();
    }
    delegate_.reset();
    if (appsrc_) {
      gst_app_src_end_of_stream(GST_APP_SRC(appsrc_));
    }
    if (pipeline_) {
      gst_element_set_state(pipeline_, GST_STATE_NULL);
    }
    if (appsink_) {
      gst_object_unref(appsink_);
      appsink_ = nullptr;
    }
    if (appsrc_) {
      gst_object_unref(appsrc_);
      appsrc_ = nullptr;
    }
    if (pipeline_) {
      gst_object_unref(pipeline_);
      pipeline_ = nullptr;
    }
  }

private:
  void create_pipeline(bool is_h265)
  {
    gst_init(nullptr, nullptr);
    const std::string parser = is_h265 ? "h265parse" : "h264parse";
    const std::string crop = crop_top_ > 0 || crop_bottom_ > 0 ?
      "! videocrop top=" + std::to_string(crop_top_) +
      " bottom=" + std::to_string(crop_bottom_) + " " : "";
    const std::string pipeline_description =
      "appsrc name=source is-live=true format=time block=false do-timestamp=true "
      "! queue leaky=downstream max-size-buffers=8 "
      "! " + parser + " config-interval=-1 "
      "! nvv4l2decoder enable-max-performance=true "
      "! nvvidconv "
      "! video/x-raw,format=BGRx,width=" + std::to_string(output_width_) +
      ",height=" + std::to_string(output_height_) +
      " " + crop + "! videoconvert ! video/x-raw,format=BGR "
      "! appsink name=sink sync=false max-buffers=1 drop=true";

    GError * error = nullptr;
    pipeline_ = gst_parse_launch(pipeline_description.c_str(), &error);
    if (!pipeline_) {
      const std::string message = error ? error->message : "unknown GStreamer error";
      if (error) {
        g_error_free(error);
      }
      throw std::runtime_error("Failed to create X5 decoder pipeline: " + message);
    }
    appsrc_ = gst_bin_get_by_name(GST_BIN(pipeline_), "source");
    appsink_ = gst_bin_get_by_name(GST_BIN(pipeline_), "sink");
    if (!appsrc_ || !appsink_) {
      throw std::runtime_error("X5 decoder pipeline is missing appsrc or appsink");
    }
    gst_app_sink_set_emit_signals(GST_APP_SINK(appsink_), false);
    if (gst_element_set_state(pipeline_, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
      throw std::runtime_error("Failed to start X5 decoder pipeline");
    }
  }

  void push_video(
    const uint8_t * data, size_t size, int64_t timestamp, uint8_t stream_type,
    int stream_index)
  {
    if (!streaming_.load() || !data || size == 0) {
      return;
    }
    const auto video_packets = received_video_packets_.fetch_add(1) + 1;
    received_video_bytes_.fetch_add(size);
    const auto now_time = std::chrono::steady_clock::now();
    if (now_time - last_video_report_ >= std::chrono::seconds(5)) {
      const auto previous_packets = last_reported_video_packets_.exchange(video_packets);
      const auto total_bytes = received_video_bytes_.load();
      const auto previous_bytes = last_reported_video_bytes_.exchange(total_bytes);
      const auto elapsed = std::chrono::duration<double>(now_time - last_video_report_).count();
      RCLCPP_INFO(
        get_logger(), "CameraSDK video input: %.2f packets/s, %.2f Mbit/s",
        static_cast<double>(video_packets - previous_packets) / elapsed,
        static_cast<double>(total_bytes - previous_bytes) * 8.0 / elapsed / 1.0e6);
      last_video_report_ = now_time;
    }
    if (stitch_transport_) {
      std::vector<std::uint8_t> payload;
      payload.reserve(13 + size);
      x5_stitch_protocol::append_i64(payload, now().nanoseconds());
      payload.push_back(stream_type);
      x5_stitch_protocol::append_i32(payload, stream_index);
      payload.insert(payload.end(), data, data + size);
      stitch_transport_->enqueue(x5_stitch_protocol::make_packet(
        x5_stitch_protocol::MessageType::kVideo, timestamp, payload));
    }
    if (!appsrc_ || stream_index != 0) {
      return;
    }
    GstBuffer * buffer = gst_buffer_new_allocate(nullptr, size, nullptr);
    if (!buffer) {
      return;
    }
    gst_buffer_fill(buffer, 0, data, size);
    const GstFlowReturn result = gst_app_src_push_buffer(GST_APP_SRC(appsrc_), buffer);
    if (result != GST_FLOW_OK && result != GST_FLOW_FLUSHING) {
      RCLCPP_WARN_THROTTLE(
        get_logger(), *get_clock(), 2000, "GStreamer rejected X5 video data: %d", result);
    }
  }

  void push_gyro(const std::vector<ins_camera::GyroData> & data)
  {
    if (!streaming_.load() || !stitch_transport_ || data.empty()) {
      return;
    }
    std::vector<std::uint8_t> payload;
    payload.reserve(4 + data.size() * 56);
    x5_stitch_protocol::append_u32(payload, static_cast<std::uint32_t>(data.size()));
    for (const auto & sample : data) {
      x5_stitch_protocol::append_i64(payload, sample.timestamp);
      x5_stitch_protocol::append_double(payload, sample.ax);
      x5_stitch_protocol::append_double(payload, sample.ay);
      x5_stitch_protocol::append_double(payload, sample.az);
      x5_stitch_protocol::append_double(payload, sample.gx);
      x5_stitch_protocol::append_double(payload, sample.gy);
      x5_stitch_protocol::append_double(payload, sample.gz);
    }
    stitch_transport_->enqueue(x5_stitch_protocol::make_packet(
      x5_stitch_protocol::MessageType::kGyro, data.back().timestamp, payload));
  }

  void push_exposure(const ins_camera::ExposureData & data)
  {
    if (!streaming_.load() || !stitch_transport_) {
      return;
    }
    std::vector<std::uint8_t> payload;
    payload.reserve(16);
    x5_stitch_protocol::append_double(payload, data.timestamp);
    x5_stitch_protocol::append_double(payload, data.exposure_time);
    stitch_transport_->enqueue(x5_stitch_protocol::make_packet(
      x5_stitch_protocol::MessageType::kExposure,
      static_cast<std::int64_t>(data.timestamp), payload));
  }

  std::vector<std::uint8_t> make_camera_info_packet(
    const ins_camera::PreviewParam & preview) const
  {
    std::vector<std::uint8_t> payload;
    x5_stitch_protocol::append_string(payload, preview.camera_name);
    payload.push_back(static_cast<std::uint8_t>(preview.encode_type));
    x5_stitch_protocol::append_u32(payload, preview.crop_info.src_width);
    x5_stitch_protocol::append_u32(payload, preview.crop_info.src_height);
    x5_stitch_protocol::append_u32(payload, preview.crop_info.dst_width);
    x5_stitch_protocol::append_u32(payload, preview.crop_info.dst_height);
    x5_stitch_protocol::append_i32(payload, preview.crop_info.crop_offset_x);
    x5_stitch_protocol::append_i32(payload, preview.crop_info.crop_offset_y);
    x5_stitch_protocol::append_i64(payload, preview.delay_timestamp);
    x5_stitch_protocol::append_i64(payload, preview.sweep_time);
    x5_stitch_protocol::append_u32(
      payload, static_cast<std::uint32_t>(preview.offset.size()));
    for (const auto & offset : preview.offset) {
      x5_stitch_protocol::append_string(payload, offset);
    }
    return x5_stitch_protocol::make_packet(
      x5_stitch_protocol::MessageType::kCameraInfo, 0, payload);
  }

  void publish_latest_frame()
  {
    if (!appsink_) {
      return;
    }
    GstSample * sample = gst_app_sink_try_pull_sample(GST_APP_SINK(appsink_), 0);
    if (!sample) {
      return;
    }

    GstCaps * caps = gst_sample_get_caps(sample);
    GstBuffer * buffer = gst_sample_get_buffer(sample);
    GstVideoInfo info;
    GstMapInfo map;
    if (!caps || !buffer || !gst_video_info_from_caps(&info, caps) ||
      !gst_buffer_map(buffer, &map, GST_MAP_READ))
    {
      gst_sample_unref(sample);
      return;
    }

    const int width = static_cast<int>(GST_VIDEO_INFO_WIDTH(&info));
    const int height = static_cast<int>(GST_VIDEO_INFO_HEIGHT(&info));
    const int stride = GST_VIDEO_INFO_PLANE_STRIDE(&info, 0);
    const auto stamp = now();
    cv::Mat frame(height, width, CV_8UC3, map.data, stride);
    cv::Mat output_frame = frame.clone();
    for (size_t index = 0; index < self_mask_rectangles_.size(); index += 4) {
      const int x_min = std::clamp<int>(self_mask_rectangles_[index], 0, width);
      const int y_min = std::clamp<int>(self_mask_rectangles_[index + 1], 0, height);
      const int x_max = std::clamp<int>(self_mask_rectangles_[index + 2], 0, width);
      const int y_max = std::clamp<int>(self_mask_rectangles_[index + 3], 0, height);
      if (x_max > x_min && y_max > y_min) {
        cv::rectangle(
          output_frame, cv::Rect(x_min, y_min, x_max - x_min, y_max - y_min),
          cv::Scalar(0, 0, 0), cv::FILLED);
      }
    }

    if (raw_pub_) {
      sensor_msgs::msg::Image message;
      message.header.stamp = stamp;
      message.header.frame_id = frame_id_;
      message.height = static_cast<uint32_t>(height);
      message.width = static_cast<uint32_t>(width);
      message.encoding = "bgr8";
      message.is_bigendian = false;
      message.step = static_cast<uint32_t>(output_frame.step);
      message.data.assign(output_frame.datastart, output_frame.dataend);
      raw_pub_->publish(message);
    }

    std::vector<uint8_t> jpeg;
    const std::vector<int> options = {cv::IMWRITE_JPEG_QUALITY, jpeg_quality_};
    if (cv::imencode(".jpg", output_frame, jpeg, options)) {
      sensor_msgs::msg::CompressedImage message;
      message.header.stamp = stamp;
      message.header.frame_id = frame_id_;
      message.format = "jpeg";
      message.data = std::move(jpeg);
      compressed_pub_->publish(message);
    }

    gst_buffer_unmap(buffer, &map);
    gst_sample_unref(sample);
    ++published_frames_;
    if (published_frames_ == 1) {
      RCLCPP_INFO(get_logger(), "Publishing decoded X5 frames on %s", raw_topic_.c_str());
    }
  }

  std::string source_resolution_name_;
  std::string frame_id_;
  std::string raw_topic_;
  std::string compressed_topic_;
  int source_bitrate_{};
  bool using_lrv_{};
  int output_width_{};
  int output_height_{};
  int crop_top_{};
  int crop_bottom_{};
  double output_fps_{};
  bool publish_raw_{};
  int jpeg_quality_{};
  bool enable_stitching_{};
  bool stitch_transport_enabled_{};
  std::string stitch_server_host_;
  int stitch_server_port_{};
  std::vector<int64_t> self_mask_rectangles_;
  ins_camera::VideoResolution source_resolution_{};

  std::atomic<bool> streaming_{false};
  std::atomic<std::uint64_t> received_video_packets_{0};
  std::atomic<std::uint64_t> received_video_bytes_{0};
  std::atomic<std::uint64_t> last_reported_video_packets_{0};
  std::atomic<std::uint64_t> last_reported_video_bytes_{0};
  std::chrono::steady_clock::time_point last_video_report_{std::chrono::steady_clock::now()};
  uint64_t published_frames_{0};
  std::shared_ptr<ins_camera::Camera> camera_;
  std::shared_ptr<StreamDelegate> delegate_;
  std::unique_ptr<StitchTransport> stitch_transport_;
  GstElement * pipeline_{nullptr};
  GstElement * appsrc_{nullptr};
  GstElement * appsink_{nullptr};
  rclcpp::TimerBase::SharedPtr frame_timer_;
  rclcpp::Publisher<sensor_msgs::msg::Image>::SharedPtr raw_pub_;
  rclcpp::Publisher<sensor_msgs::msg::CompressedImage>::SharedPtr compressed_pub_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  try {
    auto node = std::make_shared<X5SdkNode>();
    node->start();
    rclcpp::spin(node);
    node->stop();
  } catch (const std::exception & error) {
    RCLCPP_FATAL(rclcpp::get_logger("x5_sdk_node"), "%s", error.what());
    rclcpp::shutdown();
    return 1;
  }
  rclcpp::shutdown();
  return 0;
}
