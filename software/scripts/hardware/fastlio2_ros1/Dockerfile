FROM ros:noetic-ros-base-focal

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    git \
    libapr1-dev \
    libboost-chrono-dev \
    libboost-system-dev \
    libboost-thread-dev \
    libeigen3-dev \
    libpcl-dev \
    python3-catkin-tools \
    python3-pip \
    ros-noetic-eigen-conversions \
    ros-noetic-message-generation \
    ros-noetic-message-runtime \
    ros-noetic-pcl-conversions \
    ros-noetic-pcl-ros \
    ros-noetic-rviz \
    ros-noetic-tf \
    ros-noetic-tf2-ros \
    ros-noetic-rosbag \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch master https://github.com/Livox-SDK/Livox-SDK2.git /tmp/Livox-SDK2 \
    && cmake -S /tmp/Livox-SDK2 -B /tmp/Livox-SDK2/build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /tmp/Livox-SDK2/build --parallel 2 \
    && cmake --install /tmp/Livox-SDK2/build \
    && rm -rf /tmp/Livox-SDK2

WORKDIR /work/fastlio2_ros1_ws

CMD ["bash"]
