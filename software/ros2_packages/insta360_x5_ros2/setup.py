from setuptools import find_packages, setup


package_name = "insta360_x5_ros2"

setup(
    name=package_name,
    version="0.1.0",
    packages=find_packages(),
    data_files=[
        ("share/ament_index/resource_index/packages", ["resource/" + package_name]),
        ("share/" + package_name, ["package.xml"]),
        ("share/" + package_name + "/launch", ["launch/x5_camera.launch.py"]),
        ("share/" + package_name + "/config", ["config/x5_camera.yaml"]),
    ],
    install_requires=["setuptools"],
    zip_safe=True,
    maintainer="aiwei",
    maintainer_email="aiwei@example.com",
    description="UVC or GStreamer ROS 2 bridge for Insta360 X5 live video.",
    license="MIT",
    entry_points={
        "console_scripts": [
            "x5_camera_node = insta360_x5_ros2.x5_camera_node:main",
        ],
    },
)
