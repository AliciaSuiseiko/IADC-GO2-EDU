#include <iostream>
#include <string>

#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/go2/obstacles_avoid/obstacles_avoid_client.hpp>

int main(int argc, char** argv) {
  if (argc != 3 || std::string(argv[2]) != "off") {
    std::cerr << "Usage: go2_obstacles_avoid <interface> off\n";
    return 2;
  }

  unitree::robot::ChannelFactory::Instance()->Init(0, argv[1]);
  unitree::robot::go2::ObstaclesAvoidClient client;
  client.SetTimeout(5.0F);
  client.Init();

  const int32_t set_result = client.SwitchSet(false);
  bool enabled = true;
  const int32_t get_result = client.SwitchGet(enabled);
  std::cout << "set_result=" << set_result << " get_result=" << get_result
            << " enabled=" << std::boolalpha << enabled << '\n';

  unitree::robot::ChannelFactory::Instance()->Release();
  return set_result == 0 && get_result == 0 && !enabled ? 0 : 1;
}
