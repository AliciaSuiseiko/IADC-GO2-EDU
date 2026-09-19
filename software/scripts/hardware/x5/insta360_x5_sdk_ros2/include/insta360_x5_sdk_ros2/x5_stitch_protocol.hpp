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

inline std::uint64_t host_to_network_u64(std::uint64_t value)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  return (static_cast<std::uint64_t>(htonl(static_cast<std::uint32_t>(value))) << 32) |
         htonl(static_cast<std::uint32_t>(value >> 32));
#else
  return value;
#endif
}

inline std::uint64_t network_to_host_u64(std::uint64_t value)
{
  return host_to_network_u64(value);
}

inline void append_u16(std::vector<std::uint8_t> & output, std::uint16_t value)
{
  const auto network = htons(value);
  const auto * bytes = reinterpret_cast<const std::uint8_t *>(&network);
  output.insert(output.end(), bytes, bytes + sizeof(network));
}

inline void append_u32(std::vector<std::uint8_t> & output, std::uint32_t value)
{
  const auto network = htonl(value);
  const auto * bytes = reinterpret_cast<const std::uint8_t *>(&network);
  output.insert(output.end(), bytes, bytes + sizeof(network));
}

inline void append_u64(std::vector<std::uint8_t> & output, std::uint64_t value)
{
  const auto network = host_to_network_u64(value);
  const auto * bytes = reinterpret_cast<const std::uint8_t *>(&network);
  output.insert(output.end(), bytes, bytes + sizeof(network));
}

inline void append_i32(std::vector<std::uint8_t> & output, std::int32_t value)
{
  append_u32(output, static_cast<std::uint32_t>(value));
}

inline void append_i64(std::vector<std::uint8_t> & output, std::int64_t value)
{
  append_u64(output, static_cast<std::uint64_t>(value));
}

inline void append_double(std::vector<std::uint8_t> & output, double value)
{
  static_assert(sizeof(double) == sizeof(std::uint64_t));
  std::uint64_t bits = 0;
  std::memcpy(&bits, &value, sizeof(bits));
  append_u64(output, bits);
}

inline void append_string(std::vector<std::uint8_t> & output, const std::string & value)
{
  if (value.size() > UINT16_MAX) {
    throw std::length_error("X5 protocol string exceeds 65535 bytes");
  }
  append_u16(output, static_cast<std::uint16_t>(value.size()));
  output.insert(output.end(), value.begin(), value.end());
}

inline std::vector<std::uint8_t> make_packet(
  MessageType type, std::int64_t timestamp, const std::vector<std::uint8_t> & payload)
{
  if (payload.size() > kMaxPayloadSize) {
    throw std::length_error("X5 protocol payload is too large");
  }
  std::vector<std::uint8_t> packet;
  packet.reserve(kHeaderSize + payload.size());
  for (const char byte : kMagic) {
    packet.push_back(static_cast<std::uint8_t>(byte));
  }
  append_u16(packet, static_cast<std::uint16_t>(type));
  append_u16(packet, 0);
  append_u32(packet, static_cast<std::uint32_t>(payload.size()));
  append_i64(packet, timestamp);
  packet.insert(packet.end(), payload.begin(), payload.end());
  return packet;
}

inline bool send_all(int socket_fd, const std::vector<std::uint8_t> & packet)
{
  std::size_t sent = 0;
  while (sent < packet.size()) {
    const auto result = send(
      socket_fd, packet.data() + sent, packet.size() - sent, MSG_NOSIGNAL);
    if (result <= 0) {
      return false;
    }
    sent += static_cast<std::size_t>(result);
  }
  return true;
}
}  // namespace x5_stitch_protocol
