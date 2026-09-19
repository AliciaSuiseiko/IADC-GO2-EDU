cmake_minimum_required(VERSION 3.8)
project(insta360_x5_sdk_ros2)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(OpenCV REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(GSTREAMER REQUIRED IMPORTED_TARGET
  gstreamer-1.0
  gstreamer-app-1.0
  gstreamer-video-1.0)

set(INSTA360_CAMERA_SDK_ROOT
  "$ENV{HOME}/lianaiwei/downloads/insta360/camerasdk-jetson-2.1.1"
  CACHE PATH "Extracted Insta360 CameraSDK root")
find_path(INSTA360_CAMERA_SDK_INCLUDE_DIR camera/camera.h
  PATHS "${INSTA360_CAMERA_SDK_ROOT}/include"
  NO_DEFAULT_PATH REQUIRED)
find_library(INSTA360_CAMERA_SDK_LIBRARY CameraSDK
  PATHS "${INSTA360_CAMERA_SDK_ROOT}/lib"
  NO_DEFAULT_PATH REQUIRED)

add_executable(x5_sdk_node src/x5_sdk_node.cpp)
target_compile_features(x5_sdk_node PUBLIC cxx_std_17)
target_include_directories(x5_sdk_node PRIVATE
  include
  "${INSTA360_CAMERA_SDK_INCLUDE_DIR}"
  ${OpenCV_INCLUDE_DIRS})
ament_target_dependencies(x5_sdk_node rclcpp sensor_msgs)
target_link_libraries(x5_sdk_node
  "${INSTA360_CAMERA_SDK_LIBRARY}"
  ${OpenCV_LIBS}
  PkgConfig::GSTREAMER)
set_target_properties(x5_sdk_node PROPERTIES INSTALL_RPATH "$ORIGIN/..")

install(TARGETS x5_sdk_node DESTINATION lib/${PROJECT_NAME})
install(FILES "${INSTA360_CAMERA_SDK_LIBRARY}" DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)
install(DIRECTORY config launch DESTINATION share/${PROJECT_NAME})

ament_package()
