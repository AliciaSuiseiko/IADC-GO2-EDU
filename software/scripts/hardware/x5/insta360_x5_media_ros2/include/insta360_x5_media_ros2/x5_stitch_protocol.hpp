#pragma once

#include <arpa/inet.h>
#include <sys/socket.h>

#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace x5_stitch_protocol
{
constexpr char kMagic[4] = {'X', '5', 'S', '1'};
constexpr std::size_t kHeaderSize = 20;
constexpr std::uint32_t kMaxPayloadSize = 32U * 1024U * 1024U;

enum class MessageType : std::uint16_t
{
  kCameraInfo = 1,
  kVideo = 2,
  kGyro = 3,
  kExposure = 4,
};

inline std::uint64_t network_to_host_u64(std::uint64_t value)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  return (static_cast<std::uint64_t>(ntohl(static_cast<std::uint32_t>(value))) << 32) |
         ntohl(static_cast<std::uint32_t>(value >> 32));
#else
  return value;
#endif
}

inline bool receive_exact(int socket_fd, void * destination, std::size_t size)
{
  auto * output = static_cast<std::uint8_t *>(destination);
  std::size_t received = 0;
  while (received < size) {
    const auto result = recv(socket_fd, output + received, size - received, 0);
    if (result <= 0) {
      return false;
    }
    received += static_cast<std::size_t>(result);
  }
  return true;
}

struct Header
{
  MessageType type{};
  std::uint32_t payload_size{};
  std::int64_t timestamp{};
};

inline bool receive_header(int socket_fd, Header & header)
{
  std::uint8_t bytes[kHeaderSize]{};
  if (!receive_exact(socket_fd, bytes, sizeof(bytes)) ||
    std::memcmp(bytes, kMagic, sizeof(kMagic)) != 0)
  {
    return false;
  }
  std::uint16_t type = 0;
  std::uint32_t payload_size = 0;
  std::uint64_t timestamp = 0;
  std::memcpy(&type, bytes + 4, sizeof(type));
  std::memcpy(&payload_size, bytes + 8, sizeof(payload_size));
  std::memcpy(&timestamp, bytes + 12, sizeof(timestamp));
  header.type = static_cast<MessageType>(ntohs(type));
  header.payload_size = ntohl(payload_size);
  header.timestamp = static_cast<std::int64_t>(network_to_host_u64(timestamp));
  return header.payload_size <= kMaxPayloadSize;
}

class Reader final
{
public:
  explicit Reader(const std::vector<std::uint8_t> & data) : data_(data) {}

  std::uint8_t u8()
  {
    require(1);
    return data_[position_++];
  }

  std::uint16_t u16()
  {
    require(2);
    std::uint16_t value = 0;
    std::memcpy(&value, data_.data() + position_, sizeof(value));
    position_ += sizeof(value);
    return ntohs(value);
  }

  std::uint32_t u32()
  {
    require(4);
    std::uint32_t value = 0;
    std::memcpy(&value, data_.data() + position_, sizeof(value));
    position_ += sizeof(value);
    return ntohl(value);
  }

  std::uint64_t u64()
  {
    require(8);
    std::uint64_t value = 0;
    std::memcpy(&value, data_.data() + position_, sizeof(value));
    position_ += sizeof(value);
    return network_to_host_u64(value);
  }

  std::int32_t i32() {return static_cast<std::int32_t>(u32());}
  std::int64_t i64() {return static_cast<std::int64_t>(u64());}

  double f64()
  {
    const auto bits = u64();
    double value = 0.0;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
  }

  std::string string()
  {
    const auto size = u16();
    require(size);
    std::string value(
      reinterpret_cast<const char *>(data_.data() + position_), size);
    position_ += size;
    return value;
  }

  const std::uint8_t * remaining_data() const {return data_.data() + position_;}
  std::size_t remaining_size() const {return data_.size() - position_;}

private:
  void require(std::size_t size) const
  {
    if (position_ + size > data_.size()) {
      throw std::runtime_error("truncated X5 stitch packet");
    }
  }

  const std::vector<std::uint8_t> & data_;
  std::size_t position_{0};
};
}  // namespace x5_stitch_protocol
