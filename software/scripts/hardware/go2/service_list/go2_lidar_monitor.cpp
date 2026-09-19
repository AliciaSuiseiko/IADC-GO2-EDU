#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>

#include <unitree/idl/go2/LidarState_.hpp>
#include <unitree/idl/ros2/String_.hpp>
#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/channel/channel_subscriber.hpp>

namespace {
std::mutex output_mutex;
std::atomic<int64_t> last_state_print_ms{0};

int64_t NowMilliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

void PrintTimestamp(std::ostream& output, int64_t milliseconds) {
  const auto seconds = static_cast<std::time_t>(milliseconds / 1000);
  const auto remainder = milliseconds % 1000;
  output << std::put_time(std::localtime(&seconds), "%F %T") << '.'
         << std::setfill('0') << std::setw(3) << remainder << std::setfill(' ');
}

void SwitchHandler(const void* raw_message) {
  const auto* message =
      static_cast<const std_msgs::msg::dds_::String_*>(raw_message);
  std::lock_guard<std::mutex> lock(output_mutex);
  PrintTimestamp(std::cout, NowMilliseconds());
  std::cout << " switch data='" << message->data() << "'\n" << std::flush;
}

void StateHandler(const void* raw_message) {
  const int64_t now_ms = NowMilliseconds();
  int64_t previous_ms = last_state_print_ms.load();
  if (now_ms - previous_ms < 500 ||
      !last_state_print_ms.compare_exchange_strong(
          previous_ms, now_ms)) {
    return;
  }

  const auto* state =
      static_cast<const unitree_go::msg::dds_::LidarState_*>(raw_message);
  std::lock_guard<std::mutex> lock(output_mutex);
  PrintTimestamp(std::cout, now_ms);
  std::cout << " state sys_rpm=" << state->sys_rotation_speed()
            << " com_rpm=" << state->com_rotation_speed()
            << " cloud_hz=" << state->cloud_frequency()
            << " cloud_size=" << state->cloud_size()
            << " imu_hz=" << state->imu_frequency()
            << " error=" << static_cast<int>(state->error_state()) << '\n'
            << std::flush;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc < 2 || argc > 3) {
    std::cerr << "Usage: go2_lidar_monitor <interface> [seconds]\n";
    return 2;
  }

  const std::string interface_name = argv[1];
  const int duration_seconds = argc == 3 ? std::atoi(argv[2]) : 120;
  if (duration_seconds <= 0) {
    std::cerr << "Duration must be positive.\n";
    return 2;
  }

  unitree::robot::ChannelFactory::Instance()->Init(0, interface_name);
  unitree::robot::ChannelSubscriber<std_msgs::msg::dds_::String_>
      switch_subscriber("rt/utlidar/switch");
  unitree::robot::ChannelSubscriber<unitree_go::msg::dds_::LidarState_>
      state_subscriber("rt/utlidar/lidar_state");
  switch_subscriber.InitChannel(SwitchHandler, 64);
  state_subscriber.InitChannel(StateHandler, 64);

  {
    std::lock_guard<std::mutex> lock(output_mutex);
    PrintTimestamp(std::cout, NowMilliseconds());
    std::cout << " monitor_started duration_s=" << duration_seconds << '\n'
              << std::flush;
  }
  std::this_thread::sleep_for(std::chrono::seconds(duration_seconds));

  state_subscriber.CloseChannel();
  switch_subscriber.CloseChannel();
  unitree::robot::ChannelFactory::Instance()->Release();
  return 0;
}
