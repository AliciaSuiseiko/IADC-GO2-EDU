#include <iostream>
#include <string>
#include <vector>

#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/go2/robot_state/robot_state_client.hpp>

int main(int argc, char** argv) {
  const std::string interface_name = argc > 1 ? argv[1] : "eth0";
  unitree::robot::ChannelFactory::Instance()->Init(0, interface_name);

  unitree::robot::go2::RobotStateClient client;
  client.SetTimeout(5.0F);
  client.Init();

  std::vector<unitree::robot::go2::ServiceState> services;
  const int32_t result = client.ServiceList(services);
  if (result != 0) {
    std::cerr << "ServiceList failed: " << result << '\n';
    unitree::robot::ChannelFactory::Instance()->Release();
    return 1;
  }

  for (const auto& service : services) {
    std::cout << service.name << " status=" << service.status
              << " protect=" << service.protect << '\n';
  }

  unitree::robot::ChannelFactory::Instance()->Release();
  return 0;
}
