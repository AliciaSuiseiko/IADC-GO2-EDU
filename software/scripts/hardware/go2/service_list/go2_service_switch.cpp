#include <algorithm>
#include <array>
#include <iostream>
#include <string>

#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/go2/robot_state/robot_state_client.hpp>

int main(int argc, char** argv) {
  if (argc != 6) {
    std::cerr << "Usage: go2_service_switch <interface> <service> <off|on> "
                 "--confirm <service>\n";
    return 2;
  }

  const std::string interface_name = argv[1];
  const std::string service_name = argv[2];
  const std::string action = argv[3];
  const std::string confirm_flag = argv[4];
  const std::string confirm_service = argv[5];
  constexpr std::array<const char*, 4> allowed_services{
      "unitree_lidar", "unitree_lidar_slam", "obstacles_avoid",
      "voxel_height_mapping"};

  const bool allowed = std::any_of(
      allowed_services.begin(), allowed_services.end(),
      [&](const char* candidate) { return service_name == candidate; });
  if (!allowed || (action != "off" && action != "on") ||
      confirm_flag != "--confirm" || confirm_service != service_name) {
    std::cerr << "Refusing request: service/action/confirmation is invalid.\n";
    return 2;
  }

  unitree::robot::ChannelFactory::Instance()->Init(0, interface_name);
  unitree::robot::go2::RobotStateClient client;
  client.SetTimeout(5.0F);
  client.Init();

  int32_t resulting_status = -1;
  const int32_t request = action == "on" ? 1 : 0;
  const int32_t result =
      client.ServiceSwitch(service_name, request, resulting_status);
  std::cout << "service=" << service_name << " action=" << action
            << " result=" << result << " status=" << resulting_status << '\n';

  unitree::robot::ChannelFactory::Instance()->Release();
  return result == 0 ? 0 : 1;
}
