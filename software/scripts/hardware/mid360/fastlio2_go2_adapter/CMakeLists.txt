cmake_minimum_required(VERSION 3.8)
project(fastlio2_go2_adapter)

find_package(ament_cmake REQUIRED)
find_package(Eigen3 REQUIRED)
find_package(geometry_msgs REQUIRED)
find_package(nav_msgs REQUIRED)
find_package(rclcpp REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(std_msgs REQUIRED)

add_executable(fastlio2_go2_adapter src/fastlio2_go2_adapter.cpp)
target_compile_features(fastlio2_go2_adapter PUBLIC cxx_std_17)
target_link_libraries(fastlio2_go2_adapter Eigen3::Eigen)
ament_target_dependencies(
  fastlio2_go2_adapter geometry_msgs nav_msgs rclcpp sensor_msgs
)

add_executable(fastlio2_sysnav_adapter src/fastlio2_sysnav_adapter.cpp)
target_compile_features(fastlio2_sysnav_adapter PUBLIC cxx_std_17)
target_link_libraries(fastlio2_sysnav_adapter Eigen3::Eigen)
ament_target_dependencies(
  fastlio2_sysnav_adapter geometry_msgs nav_msgs rclcpp sensor_msgs std_msgs
)

install(
  TARGETS fastlio2_go2_adapter fastlio2_sysnav_adapter
  DESTINATION lib/${PROJECT_NAME}
)
install(DIRECTORY config launch DESTINATION share/${PROJECT_NAME})

ament_package()
