#include <chrono>
#include <iostream>
#include <string>
#include <thread>

#include <unitree/idl/ros2/String_.hpp>
#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/channel/channel_publisher.hpp>

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "Usage: go2_lidar_switch <interface> <OFF|ON>\n";
    return 2;
  }

  const std::string interface_name = argv[1];
  const std::string command = argv[2];
  if (command != "OFF" && command != "ON") {
    std::cerr << "Command must be OFF or ON.\n";
    return 2;
  }

  unitree::robot::ChannelFactory::Instance()->Init(0, interface_name);
  unitree::robot::ChannelPublisher<std_msgs::msg::dds_::String_> publisher(
      "rt/utlidar/switch");
  publisher.InitChannel();
  std::this_thread::sleep_for(std::chrono::seconds(1));

  std_msgs::msg::dds_::String_ message;
  message.data(command);
  int successful_writes = 0;
  for (int i = 0; i < 5; ++i) {
    successful_writes += publisher.Write(message, 1000000) ? 1 : 0;
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
  }

  publisher.CloseChannel();
  unitree::robot::ChannelFactory::Instance()->Release();
  std::cout << "command=" << command
            << " successful_writes=" << successful_writes << "/5\n";
  return successful_writes > 0 ? 0 : 1;
}
