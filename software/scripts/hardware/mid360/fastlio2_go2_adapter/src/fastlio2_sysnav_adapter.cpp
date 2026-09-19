#include <cmath>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include <Eigen/Geometry>
#include <nav_msgs/msg/odometry.hpp>
#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/imu.hpp>
#include <sensor_msgs/msg/point_cloud2.hpp>
#include <sensor_msgs/point_cloud2_iterator.hpp>
#include <std_msgs/msg/bool.hpp>

class Fastlio2SysnavAdapter : public rclcpp::Node {
 public:
  Fastlio2SysnavAdapter() : Node("fastlio2_sysnav_adapter") {
    const auto imu_topic = declare_parameter("imu_topic", "/livox/imu");
    const auto odom_topic = declare_parameter("odom_topic", "/Odometry");
    const auto cloud_topic = declare_parameter("cloud_topic", "/cloud_registered");
    const auto output_odom_topic =
        declare_parameter("output_odom_topic", "/state_estimation");
    const auto output_scan_odom_topic = declare_parameter(
        "output_scan_odom_topic", "/aft_mapped_to_init_incremental");
    const auto output_cloud_topic =
        declare_parameter("output_cloud_topic", "/registered_scan");
    world_frame_ = declare_parameter("world_frame", "map");
    sensor_frame_ = declare_parameter("sensor_frame", "sensor");
    initialization_samples_ = declare_parameter("initialization_samples", 200);
    max_initial_gyro_ = declare_parameter("max_initial_gyro_rad_s", 0.03);

    t_i_l_ = vector3_parameter("imu_t_lidar");
    r_i_l_ = matrix3_parameter("imu_R_lidar");
    r_i_b_ = r_i_l_ * matrix3_parameter("lidar_R_body");

    const auto qos = rclcpp::QoS(rclcpp::KeepLast(20)).reliable();
    odom_pub_ = create_publisher<nav_msgs::msg::Odometry>(output_odom_topic, qos);
    scan_odom_pub_ =
        create_publisher<nav_msgs::msg::Odometry>(output_scan_odom_topic, qos);
    cloud_pub_ =
        create_publisher<sensor_msgs::msg::PointCloud2>(output_cloud_topic, qos);
    health_pub_ =
        create_publisher<std_msgs::msg::Bool>("/state_estimation_health", qos);

    imu_sub_ = create_subscription<sensor_msgs::msg::Imu>(
        imu_topic, rclcpp::SensorDataQoS(),
        std::bind(&Fastlio2SysnavAdapter::imu_callback, this,
                  std::placeholders::_1));
    odom_sub_ = create_subscription<nav_msgs::msg::Odometry>(
        odom_topic, rclcpp::SensorDataQoS(),
        std::bind(&Fastlio2SysnavAdapter::odom_callback, this,
                  std::placeholders::_1));
    cloud_sub_ = create_subscription<sensor_msgs::msg::PointCloud2>(
        cloud_topic, rclcpp::SensorDataQoS(),
        std::bind(&Fastlio2SysnavAdapter::cloud_callback, this,
                  std::placeholders::_1));
  }

 private:
  Eigen::Vector3d vector3_parameter(const std::string &name) {
    const auto values = declare_parameter<std::vector<double>>(name);
    if (values.size() != 3) {
      throw std::runtime_error(name + " must contain 3 values");
    }
    return {values[0], values[1], values[2]};
  }

  Eigen::Matrix3d matrix3_parameter(const std::string &name) {
    const auto values = declare_parameter<std::vector<double>>(name);
    if (values.size() != 9) {
      throw std::runtime_error(name + " must contain 9 values");
    }
    Eigen::Matrix3d matrix;
    for (int row = 0; row < 3; ++row) {
      for (int col = 0; col < 3; ++col) {
        matrix(row, col) = values[row * 3 + col];
      }
    }
    return matrix;
  }

  static bool finite_odometry(const nav_msgs::msg::Odometry &msg) {
    const auto &p = msg.pose.pose.position;
    const auto &q = msg.pose.pose.orientation;
    return std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z) &&
           std::isfinite(q.x) && std::isfinite(q.y) && std::isfinite(q.z) &&
           std::isfinite(q.w) &&
           (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w) > 1e-12;
  }

  void publish_health(bool healthy) {
    std_msgs::msg::Bool message;
    message.data = healthy;
    health_pub_->publish(message);
  }

  void imu_callback(const sensor_msgs::msg::Imu::SharedPtr msg) {
    if (gravity_ready_) {
      return;
    }
    const Eigen::Vector3d gyro(msg->angular_velocity.x, msg->angular_velocity.y,
                               msg->angular_velocity.z);
    if (gyro.norm() > max_initial_gyro_) {
      return;
    }
    gravity_sum_ += Eigen::Vector3d(msg->linear_acceleration.x,
                                    msg->linear_acceleration.y,
                                    msg->linear_acceleration.z);
    ++gravity_samples_;
    if (gravity_samples_ < initialization_samples_) {
      return;
    }

    const Eigen::Vector3d up_i = gravity_sum_.normalized();
    Eigen::Vector3d x_i = r_i_b_.col(0);
    x_i -= up_i * up_i.dot(x_i);
    if (x_i.norm() < 1e-6) {
      throw std::runtime_error("body X axis is parallel to gravity");
    }
    x_i.normalize();
    Eigen::Vector3d y_i = up_i.cross(x_i).normalized();
    x_i = y_i.cross(up_i).normalized();
    Eigen::Matrix3d r_i_n;
    r_i_n.col(0) = x_i;
    r_i_n.col(1) = y_i;
    r_i_n.col(2) = up_i;
    r_n_w_ = r_i_n.transpose();
    gravity_ready_ = true;
    RCLCPP_INFO(get_logger(), "gravity aligned from %d static IMU samples",
                gravity_samples_);
  }

  void odom_callback(const nav_msgs::msg::Odometry::SharedPtr msg) {
    if (!gravity_ready_) {
      publish_health(false);
      return;
    }
    const auto stamp = rclcpp::Time(msg->header.stamp);
    if (last_odom_stamp_.nanoseconds() != 0 && stamp <= last_odom_stamp_) {
      RCLCPP_WARN_THROTTLE(get_logger(), *get_clock(), 2000,
                           "dropping non-monotonic FAST-LIO2 odometry");
      publish_health(false);
      return;
    }
    if (!finite_odometry(*msg)) {
      RCLCPP_WARN_THROTTLE(get_logger(), *get_clock(), 2000,
                           "dropping invalid FAST-LIO2 odometry");
      publish_health(false);
      return;
    }

    const auto &p = msg->pose.pose.position;
    const auto &q = msg->pose.pose.orientation;
    const Eigen::Vector3d p_w_i(p.x, p.y, p.z);
    const Eigen::Quaterniond q_w_i(q.w, q.x, q.y, q.z);
    const Eigen::Quaterniond q_w_i_normalized = q_w_i.normalized();
    const Eigen::Vector3d p_w_l = p_w_i + q_w_i_normalized * t_i_l_;
    if (!origin_ready_) {
      origin_n_ = r_n_w_ * p_w_l;
      origin_ready_ = true;
    }
    const Eigen::Vector3d p_n_l = r_n_w_ * p_w_l - origin_n_;
    const Eigen::Matrix3d r_n_b = r_n_w_ *
        q_w_i_normalized.toRotationMatrix() * r_i_b_;
    const Eigen::Quaterniond q_n_b(r_n_b);

    auto output = *msg;
    output.header.frame_id = world_frame_;
    output.child_frame_id = sensor_frame_;
    output.pose.pose.position.x = p_n_l.x();
    output.pose.pose.position.y = p_n_l.y();
    output.pose.pose.position.z = p_n_l.z();
    output.pose.pose.orientation.x = q_n_b.x();
    output.pose.pose.orientation.y = q_n_b.y();
    output.pose.pose.orientation.z = q_n_b.z();
    output.pose.pose.orientation.w = q_n_b.w();

    const Eigen::Matrix3d r_b_i = r_i_b_.transpose();
    const Eigen::Vector3d linear_i(msg->twist.twist.linear.x,
                                   msg->twist.twist.linear.y,
                                   msg->twist.twist.linear.z);
    const Eigen::Vector3d angular_i(msg->twist.twist.angular.x,
                                    msg->twist.twist.angular.y,
                                    msg->twist.twist.angular.z);
    const Eigen::Vector3d linear_b = r_b_i * linear_i;
    const Eigen::Vector3d angular_b = r_b_i * angular_i;
    output.twist.twist.linear.x = linear_b.x();
    output.twist.twist.linear.y = linear_b.y();
    output.twist.twist.linear.z = linear_b.z();
    output.twist.twist.angular.x = angular_b.x();
    output.twist.twist.angular.y = angular_b.y();
    output.twist.twist.angular.z = angular_b.z();

    odom_pub_->publish(output);
    scan_odom_pub_->publish(output);
    publish_health(true);
    last_odom_stamp_ = stamp;
  }

  void cloud_callback(const sensor_msgs::msg::PointCloud2::SharedPtr msg) {
    if (!origin_ready_) {
      return;
    }
    const auto stamp = rclcpp::Time(msg->header.stamp);
    if (last_cloud_stamp_.nanoseconds() != 0 && stamp <= last_cloud_stamp_) {
      RCLCPP_WARN_THROTTLE(get_logger(), *get_clock(), 2000,
                           "dropping non-monotonic FAST-LIO2 registered scan");
      return;
    }
    auto output = *msg;
    output.header.frame_id = world_frame_;
    sensor_msgs::PointCloud2Iterator<float> x(output, "x");
    sensor_msgs::PointCloud2Iterator<float> y(output, "y");
    sensor_msgs::PointCloud2Iterator<float> z(output, "z");
    for (; x != x.end(); ++x, ++y, ++z) {
      if (!std::isfinite(*x) || !std::isfinite(*y) || !std::isfinite(*z)) {
        continue;
      }
      const Eigen::Vector3d p_n =
          r_n_w_ * Eigen::Vector3d(*x, *y, *z) - origin_n_;
      *x = static_cast<float>(p_n.x());
      *y = static_cast<float>(p_n.y());
      *z = static_cast<float>(p_n.z());
    }
    cloud_pub_->publish(output);
    last_cloud_stamp_ = stamp;
  }

  std::string world_frame_;
  std::string sensor_frame_;
  int initialization_samples_{200};
  int gravity_samples_{0};
  double max_initial_gyro_{0.03};
  bool gravity_ready_{false};
  bool origin_ready_{false};
  Eigen::Vector3d gravity_sum_{Eigen::Vector3d::Zero()};
  Eigen::Vector3d origin_n_{Eigen::Vector3d::Zero()};
  Eigen::Vector3d t_i_l_{Eigen::Vector3d::Zero()};
  Eigen::Matrix3d r_i_l_{Eigen::Matrix3d::Identity()};
  Eigen::Matrix3d r_i_b_{Eigen::Matrix3d::Identity()};
  Eigen::Matrix3d r_n_w_{Eigen::Matrix3d::Identity()};
  rclcpp::Time last_odom_stamp_{0, 0, RCL_ROS_TIME};
  rclcpp::Time last_cloud_stamp_{0, 0, RCL_ROS_TIME};
  rclcpp::Subscription<sensor_msgs::msg::Imu>::SharedPtr imu_sub_;
  rclcpp::Subscription<nav_msgs::msg::Odometry>::SharedPtr odom_sub_;
  rclcpp::Subscription<sensor_msgs::msg::PointCloud2>::SharedPtr cloud_sub_;
  rclcpp::Publisher<nav_msgs::msg::Odometry>::SharedPtr odom_pub_;
  rclcpp::Publisher<nav_msgs::msg::Odometry>::SharedPtr scan_odom_pub_;
  rclcpp::Publisher<sensor_msgs::msg::PointCloud2>::SharedPtr cloud_pub_;
  rclcpp::Publisher<std_msgs::msg::Bool>::SharedPtr health_pub_;
};

int main(int argc, char **argv) {
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<Fastlio2SysnavAdapter>());
  rclcpp::shutdown();
  return 0;
}
