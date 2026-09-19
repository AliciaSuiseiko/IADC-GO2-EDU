cmake_minimum_required(VERSION 3.16)
project(go2_service_list LANGUAGES CXX)

find_package(unitree_sdk2 2.0.0 EXACT REQUIRED)

add_executable(go2_service_list go2_service_list.cpp)
target_compile_features(go2_service_list PRIVATE cxx_std_17)
target_link_libraries(go2_service_list PRIVATE unitree_sdk2)

add_executable(go2_service_switch go2_service_switch.cpp)
target_compile_features(go2_service_switch PRIVATE cxx_std_17)
target_link_libraries(go2_service_switch PRIVATE unitree_sdk2)

add_executable(go2_lidar_switch go2_lidar_switch.cpp)
target_compile_features(go2_lidar_switch PRIVATE cxx_std_17)
target_link_libraries(go2_lidar_switch PRIVATE unitree_sdk2)

add_executable(go2_lidar_monitor go2_lidar_monitor.cpp)
target_compile_features(go2_lidar_monitor PRIVATE cxx_std_17)
target_link_libraries(go2_lidar_monitor PRIVATE unitree_sdk2)

add_executable(go2_obstacles_avoid go2_obstacles_avoid.cpp)
target_compile_features(go2_obstacles_avoid PRIVATE cxx_std_17)
target_link_libraries(go2_obstacles_avoid PRIVATE unitree_sdk2)

install(
  TARGETS go2_service_list go2_service_switch go2_lidar_switch
          go2_lidar_monitor go2_obstacles_avoid
  RUNTIME DESTINATION bin
)
