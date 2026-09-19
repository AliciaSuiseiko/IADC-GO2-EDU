cmake_minimum_required(VERSION 3.8)
project(insta360_x5_media_ros2)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(OpenCV REQUIRED)

set(INSTA360_MEDIA_SDK_ROOT "$ENV{INSTA360_MEDIA_SDK_ROOT}"
  CACHE PATH "Extracted Insta360 MediaSDK root")
if(NOT INSTA360_MEDIA_SDK_ROOT)
  message(FATAL_ERROR "INSTA360_MEDIA_SDK_ROOT must point to the extracted MediaSDK usr directory")
endif()
find_path(INSTA360_MEDIA_SDK_INCLUDE_DIR ins_realtime_stitcher.h
  PATHS "${INSTA360_MEDIA_SDK_ROOT}/include" NO_DEFAULT_PATH REQUIRED)
find_library(INSTA360_MEDIA_SDK_LIBRARY MediaSDK
  PATHS "${INSTA360_MEDIA_SDK_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)

add_executable(x5_media_stitcher_node src/x5_media_stitcher_node.cpp)
target_compile_features(x5_media_stitcher_node PUBLIC cxx_std_17)
target_include_directories(x5_media_stitcher_node PRIVATE
  include
  "${INSTA360_MEDIA_SDK_INCLUDE_DIR}"
  ${OpenCV_INCLUDE_DIRS})
ament_target_dependencies(x5_media_stitcher_node rclcpp sensor_msgs)
target_link_libraries(x5_media_stitcher_node
  "${INSTA360_MEDIA_SDK_LIBRARY}"
  ${OpenCV_LIBS}
  pthread)
target_link_options(x5_media_stitcher_node PRIVATE
  "-Wl,--enable-new-dtags"
  "-Wl,-rpath-link,${INSTA360_MEDIA_SDK_ROOT}/lib")
set_target_properties(x5_media_stitcher_node PROPERTIES
  INSTALL_RPATH "")

install(TARGETS x5_media_stitcher_node DESTINATION lib/${PROJECT_NAME})
install(DIRECTORY include/ DESTINATION include)

ament_package()
