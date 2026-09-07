#pragma once
#include <cstdint>
#include <optional>
#include <span>
#include <utility>
#include <vector>

namespace viewflow::vfgp {
using AtlasId = std::pair<uint64_t, uint64_t>;
// VFGP v7 coordinates are signed global milli-DIPs. They must never be
// confused with HWND coordinates on a particular receiver.
struct DesktopRect {
  int64_t x_millidip{}, y_millidip{};
  uint64_t width_millidip{}, height_millidip{};
};
struct AtlasTile {
  AtlasId window;
  uint64_t placement_generation{}, geometry_epoch{}, source_frame{},
      source_ns{};
  uint32_t x{}, y{}, width{}, height{};
};
struct DesktopWindow {
  AtlasId window;
  DesktopRect bounds;
  bool movable{};
  uint32_t z_order{};
  uint32_t raise_serial{};
};
struct DesktopLayout {
  uint64_t topology_generation{};
  DesktopRect viewport;
  std::vector<DesktopWindow>
      windows; // Exact, canonical AtlasLayout::tiles order.
};
struct AtlasLayout {
  AtlasId stream;
  uint64_t geometry_epoch{}, config_generation{}, revision{}, source_ns{};
  bool color_keyframe{}, alpha_keyframe{};
  std::vector<AtlasTile> tiles;
  std::optional<DesktopLayout> desktop;
};

inline std::optional<AtlasLayout>
DecodeAtlasLayout(std::span<const uint8_t> bytes, uint32_t width,
                  uint32_t height) {
  auto u32 = [&](size_t at) {
    return (uint32_t(bytes[at]) << 24) | (uint32_t(bytes[at + 1]) << 16) |
           (uint32_t(bytes[at + 2]) << 8) | bytes[at + 3];
  };
  auto u64 = [&](size_t at) { return (uint64_t(u32(at)) << 32) | u32(at + 4); };
  auto id = [&](size_t at) { return AtlasId{u64(at), u64(at + 8)}; };
  if (bytes.size() < 112 || !width || !height || (width | height) & 1u)
    return {};
  const auto count = u32(104), flags = u32(108);
  if (count > 4096 || bytes.size() != 112 + size_t(count) * 64 || flags > 3)
    return {};
  AtlasLayout layout{id(56),  u64(72),         u64(80),         u64(88),
                     u64(96), bool(flags & 1), bool(flags & 2), {}};
  if (layout.stream == AtlasId{} || !layout.geometry_epoch ||
      !layout.config_generation || !layout.source_ns)
    return {};
  uint64_t oldest = UINT64_MAX;
  for (uint32_t i = 0; i < count; ++i) {
    const size_t at = 112 + size_t(i) * 64;
    AtlasTile tile{id(at),       u64(at + 16), u64(at + 24),
                   u64(at + 32), u64(at + 40), u32(at + 48),
                   u32(at + 52), u32(at + 56), u32(at + 60)};
    if (tile.window == AtlasId{} || tile.window == layout.stream ||
        (!layout.tiles.empty() && layout.tiles.back().window >= tile.window) ||
        !tile.placement_generation ||
        tile.placement_generation > layout.revision || !tile.geometry_epoch ||
        !tile.source_frame || tile.source_ns < layout.source_ns ||
        !tile.width || !tile.height || uint64_t(tile.x) + tile.width > width ||
        uint64_t(tile.y) + tile.height > height)
      return {};
    for (const auto &other : layout.tiles) {
      if (tile.x < uint64_t(other.x) + other.width &&
          other.x < uint64_t(tile.x) + tile.width &&
          tile.y < uint64_t(other.y) + other.height &&
          other.y < uint64_t(tile.y) + tile.height)
        return {};
    }
    if (tile.source_ns < oldest)
      oldest = tile.source_ns;
    layout.tiles.push_back(tile);
  }
  if (count && oldest != layout.source_ns)
    return {};
  return layout;
}

inline std::optional<DesktopLayout>
DecodeDesktopLayout(std::span<const uint8_t> bytes, const AtlasLayout &atlas) {
  // bytes begins at the first desktop extension byte: topology + viewport +
  // count/reserved, followed by one ordered 56-byte window record per tile.
  constexpr size_t fixed = 48, record = 56;
  auto u32 = [&](size_t at) {
    return (uint32_t(bytes[at]) << 24) | (uint32_t(bytes[at + 1]) << 16) |
           (uint32_t(bytes[at + 2]) << 8) | bytes[at + 3];
  };
  auto u64 = [&](size_t at) { return (uint64_t(u32(at)) << 32) | u32(at + 4); };
  auto i64 = [&](size_t at) { return static_cast<int64_t>(u64(at)); };
  auto id = [&](size_t at) { return AtlasId{u64(at), u64(at + 8)}; };
  if (atlas.tiles.size() > 4096 ||
      bytes.size() != fixed + atlas.tiles.size() * record)
    return {};
  DesktopLayout layout{u64(0), {i64(8), i64(16), u64(24), u64(32)}, {}};
  if (!layout.topology_generation || !layout.viewport.width_millidip ||
      !layout.viewport.height_millidip ||
      layout.viewport.width_millidip > uint64_t(INT64_MAX) ||
      layout.viewport.height_millidip > uint64_t(INT64_MAX) ||
      layout.viewport.x_millidip >
          INT64_MAX - static_cast<int64_t>(layout.viewport.width_millidip) ||
      layout.viewport.y_millidip >
          INT64_MAX - static_cast<int64_t>(layout.viewport.height_millidip) ||
      u32(40) != atlas.tiles.size() || u32(44) != 0)
    return {};
  layout.windows.reserve(atlas.tiles.size());
  for (size_t index = 0; index < atlas.tiles.size(); ++index) {
    const size_t at = fixed + index * record;
    DesktopWindow window{
        id(at),
        {i64(at + 16), i64(at + 24), u64(at + 32), u64(at + 40)},
        bool(u32(at + 48) & 1), u32(at + 52), u32(at + 48) >> 1};
    if (window.window != atlas.tiles[index].window ||
        !window.bounds.width_millidip || !window.bounds.height_millidip)
      return {};
    // Endpoints must be representable. This catches wrapping rectangles before
    // any native placement calculation can turn them into a different window.
    if ((window.bounds.width_millidip > uint64_t(INT64_MAX) ||
         window.bounds.x_millidip >
             INT64_MAX - static_cast<int64_t>(window.bounds.width_millidip)) ||
        (window.bounds.height_millidip > uint64_t(INT64_MAX) ||
         window.bounds.y_millidip >
             INT64_MAX - static_cast<int64_t>(window.bounds.height_millidip)))
      return {};
    layout.windows.push_back(window);
  }
  return layout;
}
} // namespace viewflow::vfgp
