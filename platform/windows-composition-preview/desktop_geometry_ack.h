#pragma once
#include <array>
#include <cstdint>
#include <optional>
#include <span>
#include <utility>
namespace viewflow::vfgp {
struct DesktopGeometryAck {
  std::pair<uint64_t,uint64_t> stream, window;
  uint64_t drag{}, sequence{}, config{};
  int64_t x{}, y{}; uint64_t width{}, height{};
  bool rejected{};
};
inline std::optional<DesktopGeometryAck> DecodeDesktopGeometryAck(std::span<const uint8_t> b) {
  if(b.size()!=128 || b[0]!='V' || b[1]!='F' || b[2]!='G' || b[3]!='P' || b[4]!=10 || b[5]>1 || b[6] || b[7])return {};
  const auto u64=[&](size_t o){uint64_t n=0;for(size_t i=0;i<8;++i)n=(n<<8)|b[o+i];return n;};
  if(u64(8)!=uint64_t(128)<<32 || u64(24) || u64(32) || u64(120))return {};
  DesktopGeometryAck a{{u64(40),u64(48)},{u64(56),u64(64)},u64(72),u64(16),u64(80),int64_t(u64(88)),int64_t(u64(96)),u64(104),u64(112),bool(b[5])};
  if(!a.sequence || !a.drag || !a.config || !(a.stream.first|a.stream.second) || !(a.window.first|a.window.second) || !a.width || !a.height)return {};
  return a;
}
}
