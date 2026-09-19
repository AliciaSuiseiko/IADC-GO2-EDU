#include <algorithm>
#include <cmath>
#include <cstring>
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

class Fastlio2Go2Adapter : public rclcpp::Node {
 public:
  Fastlio2Go2Adapter() : Node("fastlio2_go2_adapter") {
    const auto imu_topic = declare_parameter("imu_topic", "/imu/data");
    const auto odom_topic = declare_parameter("odom_topic", "/Odometry");
    const auto cloud_topic = declare_parameter("cloud_topic", "/cloud_registered_body");
    const auto output_odom_topic = declare_parameter("output_odom_topic", "/Odometry_go2");
    const auto output_cloud_topic =
        declare_parameter("output_cloud_topic", "/cloud_registered_go2_body");
    initialization_samples_ = declare_parameter("initialization_samples", 200);
    max_initial_gyro_ = declare_parameter("max_initial_gyro_rad_s", 0.03);

    const auto t_i_l = vector3_parameter("imu_t_lidar");
    const auto r_i_l = matrix3_parameter("imu_R_lidar");
    const auto t_l_b = vector3_parameter("lidar_t_body");
    const auto r_l_b = matrix3_parameter("lidar_R_body");
    t_i_b_ = t_i_l + r_i_l * t_l_b;
    r_i_b_ = r_i_l * r_l_b;

    odom_pub_ = create_publisher<nav_msgs::msg::Odometry>(output_odom_topic, 20);
    cloud_pub_ = create_publisher<sensor_msgs::msg::PointCloud2>(output_cloud_topic, 10);
    imu_sub_ = create_subscription<sensor_msgs::msg::Imu>(
        imu_topic, rclcpp::SensorDataQoS(),
        std::bind(&Fastlio2Go2Adapter::imu_callback, this, std::placeholders::_1));
    odom_sub_ = create_subscription<nav_msgs::msg::Odometry>(
        odom_topic, rclcpp::SensorDataQoS(),
        std::bind(&Fastlio2Go2Adapter::odom_callback, this, std::placeholders::_1));
    cloud_sub_ = create_subscription<sensor_msgs::msg::PointCloud2>(
        cloud_topic, rclcpp::SensorDataQoS(),
        std::bind(&Fastlio2Go2Adapter::cloud_callback, this, std::placeholders::_1));
  }

 private:
  Eigen::Vector3d vector3_parameter(const std::string &name) {
    const auto values = declare_parameter<std::vector<double>>(name);
    if (values.size() != 3) throw std::runtime_error(name + " must contain 3 values");
    return {values[0], values[1], values[2]};
  }

  Eigen::Matrix3d matrix3_parameter(const std::string &name) {
    const auto values = declare_parameter<std::vector<double>>(name);
    if (values.size() != 9) throw std::runtime_error(name + " must contain 9 values");
    Eigen::Matrix3d matrix;
    for (int row = 0; row < 3; ++row)
      for (int col = 0; col < 3; ++col) matrix(row, col) = values[row * 3 + col];
    return matrix;
  }

  void imu_callback(const sensor_msgs::msg::Imu::SharedPtr msg) {
    if (gravity_ready_) return;
    const Eigen::Vector3d gyro(msg->angular_velocity.x, msg->angular_velocity.y,
                               msg->angular_velocity.z);
    if (gyro.norm() > max_initial_gyro_) return;
    gravity_sum_ += Eigen::Vector3d(msg->linear_acceleration.x, msg->linear_acceleration.y,
                                    msg->linear_acceleration.z);
    ++gravity_samples_;
    if (gravity_samples_ < initialization_samples_) return;

    up_i_ = gravity_sum_.normalized();
    Eigen::Vector3d x_i = r_i_b_.col(0);
    x_i -= up_i_ * up_i_.dot(x_i);
    if (x_i.norm() < 1e-6) throw std::runtime_error("body X axis is parallel to gravity");
    x_i.normalize();
    Eigen::Vector3d y_i = up_i_.cross(x_i).normalized();
    x_i = y_i.cross(up_i_).normalized();
    Eigen::Matrix3d r_i_n;
    r_i_n.col(0) = x_i;
    r_i_n.col(1) = y_i;
    r_i_n.col(2) = up_i_;
    r_n_w_ = r_i_n.transpose();
    gravity_ready_ = true;
    RCLCPP_INFO(get_logger(), "gravity initialized from %d static IMU samples", gravity_samples_);
  }

  void odom_callback(const nav_msgs::msg::Odometry::SharedPtr msg) {
    if (!gravity_ready_) return;
    const auto &p = msg->pose.pose.position;
    const auto &q = msg->pose.pose.orientation;
    const Eigen::Quaterniond q_w_i(q.w, q.x, q.y, q.z);
    const Eigen::Vector3d p_w_i(p.x, p.y, p.z);
    const Eigen::Matrix3d r_w_b = q_w_i.normalized().toRotationMatrix() * r_i_b_;
    const Eigen::Vector3d p_w_b = p_w_i + q_w_i * t_i_b_;
    if (!origin_ready_) {
      origin_n_ = r_n_w_ * p_w_b;
      origin_ready_ = true;
    }

    const Eigen::Matrix3d r_n_b = r_n_w_ * r_w_b;
    const Eigen::Vector3d p_n_b = r_n_w_ * p_w_b - origin_n_;
    const Eigen::Quaterniond q_n_b(r_n_b);
    auto output = *msg;
    output.header.frame_id = "go2_odom";
    output.child_frame_id = "go2_body";
    output.pose.pose.position.x = p_n_b.x();
    output.pose.pose.position.y = p_n_b.y();
    output.pose.pose.position.z = p_n_b.z();
    output.pose.pose.orientation.x = q_n_b.x();
    output.pose.pose.orientation.y = q_n_b.y();
    output.pose.pose.orientation.z = q_n_b.z();
    output.pose.pose.orientation.w = q_n_b.w();
    const Eigen::Matrix3d r_b_i = r_i_b_.transpose();
    const Eigen::Vector3d linear_i(msg->twist.twist.linear.x, msg->twist.twist.linear.y,
                                   msg->twist.twist.linear.z);
    const Eigen::Vector3d angular_i(msg->twist.twist.angular.x, msg->twist.twist.angular.y,
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
  }

  void cloud_callback(const sensor_msgs::msg::PointCloud2::SharedPtr msg) {
    if (!gravity_ready_) return;
    auto output = *msg;
    output.header.frame_id = "go2_body";
    const Eigen::Matrix3d r_b_i = r_i_b_.transpose();
    const Eigen::Vector3d t_b_i = -r_b_i * t_i_b_;
    sensor_msgs::PointCloud2Iterator<float> x(output, "x");
    sensor_msgs::PointCloud2Iterator<float> y(output, "y");
    sensor_msgs::PointCloud2Iterator<float> z(output, "z");
    for (; x != x.end(); ++x, ++y, ++z) {
      if (!std::isfinite(*x) || !std::isfinite(*y) || !std::isfinite(*z)) continue;
      const Eigen::Vector3d point = r_b_i * Eigen::Vector3d(*x, *y, *z) + t_b_i;
      *x = static_cast<float>(point.x());
      *y = static_cast<float>(point.y());
      *z = static_cast<float>(point.z());
    }
    cloud_pub_->publish(output);
  }

  int initialization_samples_{200};
  int gravity_samples_{0};
  double max_initial_gyro_{0.03};
  bool gravity_ready_{false};
  bool origin_ready_{false};
  Eigen::Vector3d gravity_sum_{Eigen::Vector3d::Zero()};
  Eigen::Vector3d up_i_{Eigen::Vector3d::UnitZ()};
  Eigen::Vector3d t_i_b_{Eigen::Vector3d::Zero()};
  Eigen::Matrix3d r_i_b_{Eigen::Matrix3d::Identity()};
  Eigen::Matrix3d r_n_w_{Eigen::Matrix3d::Identity()};
  Eigen::Vector3d origin_n_{Eigen::Vector3d::Zero()};
  rclcpp::Subscription<sensor_msgs::msg::Imu>::SharedPtr imu_sub_;
  rclcpp::Subscription<nav_msgs::msg::Odometry>::SharedPtr odom_sub_;
  rclcpp::Subscription<sensor_msgs::msg::PointCloud2>::SharedPtr cloud_sub_;
  rclcpp::Publisher<nav_msgs::msg::Odometry>::SharedPtr odom_pub_;
  rclcpp::Publisher<sensor_msgs::msg::PointCloud2>::SharedPtr cloud_pub_;
};

int main(int argc, char **argv) {
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<Fastlio2Go2Adapter>());
  rclcpp::shutdown();
  return 0;
}
