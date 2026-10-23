#pragma once
#include <algorithm>
#include <cstdint>
#include <map>
#include <stdexcept>
#include <tuple>
#include <vector>

namespace viewflow::gpu {
// The classification is computed from prepared RGBA on the GPU, including
// repaired shadows. Unknown/mixed alpha never counts as opaque coverage.
enum class CellAlpha : uint32_t { Empty = 0, Mixed = 1, Opaque = 2 };
struct SparseCell {
  uint32_t source{}, sourceX{}, sourceY{}, width{}, height{};
  int64_t sceneX{}, sceneY{};
  uint32_t z{};
  CellAlpha alpha = CellAlpha::Mixed;
  // Different grids (fractional placement or different capture scale) must
  // never occlude one another.
  uint32_t grid{};
  bool preserveUnderlay = false;
};
// Clip before GPU alpha classification so fully off-screen cells cost no slots.
inline bool clipSparseCell(SparseCell& c, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
  const uint64_t left=std::max<uint64_t>(c.sourceX,x), top=std::max<uint64_t>(c.sourceY,y);
  const uint64_t right=std::min(uint64_t(c.sourceX)+c.width,uint64_t(x)+w);
  const uint64_t bottom=std::min(uint64_t(c.sourceY)+c.height,uint64_t(y)+h);
  if(left>=right || top>=bottom) return false;
  c.sceneX+=left-c.sourceX; c.sceneY+=top-c.sourceY;
  c.sourceX=uint32_t(left); c.sourceY=uint32_t(top);
  c.width=uint32_t(right-left); c.height=uint32_t(bottom-top);
  return true;
}
struct SparsePatch {
  uint32_t source{}, sourceX{}, sourceY{}, x{}, y{}, width{}, height{};
};
struct SparseDraw {
  SparsePatch patch;
  // Bottom-to-top sources for an optional precomposed patch.
  std::vector<SparseCell> layers;
};
struct SparsePlan {
  std::vector<SparseDraw> draws;
  uint64_t inputPixels{}, storedPixels{}, occludedPixels{}, emptyPixels{};
  uint32_t requiredWidth{}, requiredHeight{};
  bool fits = true;
};
inline bool containsCell(const SparseCell& a, const SparseCell& b) {
  return a.grid == b.grid && a.sceneX <= b.sceneX && a.sceneY <= b.sceneY &&
    a.sceneX + a.width >= b.sceneX + b.width &&
    a.sceneY + a.height >= b.sceneY + b.height;
}
inline bool intersectsCell(const SparseCell& a, const SparseCell& b) {
  return a.grid == b.grid && a.sceneX < b.sceneX + b.width &&
    b.sceneX < a.sceneX + a.width && a.sceneY < b.sceneY + b.height &&
    b.sceneY < a.sceneY + a.height;
}
// Grid-aligned 128px cells make the search local. Boundary cells are exact
// source bounds; uncertain partial coverage is retained, never guessed away.
inline SparsePlan planSparseAtlas(std::vector<SparseCell> cells, uint32_t width,
                                 uint32_t height, bool prerender, uint32_t blurHalo = 0) {
  constexpr uint32_t cellSize = 128;
  if (width < cellSize || height < cellSize || cells.size() > 262144)
    throw std::invalid_argument("invalid sparse atlas capacity");
  for (const auto& c : cells)
    if (!c.width || !c.height || c.width > cellSize || c.height > cellSize ||
        c.sceneX < INT64_MIN + cellSize || c.sceneX > INT64_MAX - cellSize ||
        c.sceneY < INT64_MIN + cellSize || c.sceneY > INT64_MAX - cellSize)
      throw std::invalid_argument("invalid sparse cell");
  std::stable_sort(cells.begin(), cells.end(), [](const auto& a, const auto& b) {
    return std::tie(a.z, a.source) > std::tie(b.z, b.source);
  });
  auto floorCell = [](int64_t x) { return x / 128 - (x % 128 < 0); };
  using Key = std::tuple<uint32_t, int64_t, int64_t>;
  std::map<Key, std::vector<SparseCell>> groups;
  SparsePlan plan;
  for (const auto& c : cells) {
    const uint64_t pixels = uint64_t(c.width) * c.height;
    plan.inputPixels += pixels;
    if (c.alpha == CellAlpha::Empty) { plan.emptyPixels += pixels; continue; }
    // Caller splits each source at global grid boundaries.
    if (floorCell(c.sceneX) != floorCell(c.sceneX + c.width - 1) ||
        floorCell(c.sceneY) != floorCell(c.sceneY + c.height - 1))
      throw std::invalid_argument("cell crosses scene grid boundary");
    groups[{c.grid, floorCell(c.sceneX), floorCell(c.sceneY)}].push_back(c);
  }
  if (blurHalo) {
    // Receiver backdrop blur can sample through a mixed-alpha edge. Preserve
    // lower residency in that edge's halo, including cells hidden by opaque
    // pixels immediately next to it. No color image is downloaded here.
    const int64_t radius=(int64_t(blurHalo)+127)/128;
    if(radius>16) throw std::invalid_argument("sparse blur halo too large");
    for(auto& [key,group]:groups) {
      const auto [grid,gx,gy]=key;
      for(auto& c:group) if(c.alpha==CellAlpha::Opaque) {
        for(int64_t dy=-radius;dy<=radius && !c.preserveUnderlay;++dy)
          for(int64_t dx=-radius;dx<=radius && !c.preserveUnderlay;++dx) {
            const auto found=groups.find({grid,gx+dx,gy+dy});
            if(found==groups.end()) continue;
            for(const auto& edge:found->second)
              if(edge.source==c.source && edge.alpha==CellAlpha::Mixed &&
                  c.sceneX<int64_t(blurHalo)+edge.sceneX+edge.width &&
                  edge.sceneX<int64_t(blurHalo)+c.sceneX+c.width &&
                  c.sceneY<int64_t(blurHalo)+edge.sceneY+edge.height &&
                  edge.sceneY<int64_t(blurHalo)+c.sceneY+c.height) { c.preserveUnderlay=true;break; }
          }
      }
    }
  }
  for (auto& [key, group] : groups) {
    (void)key;
    std::vector<SparseCell> visible;
    for (const auto& cell : group) {
      const bool hidden = std::any_of(visible.begin(), visible.end(), [&](const auto& front) {
        return front.alpha == CellAlpha::Opaque && !front.preserveUnderlay && containsCell(front, cell);
      });
      if (hidden) plan.occludedPixels += uint64_t(cell.width) * cell.height;
      else visible.push_back(cell);
    }
    // Flatten only an exact common region. Boundary intersections with a
    // different footprint retain independent composition, even in this mode.
    const bool flatten = prerender && visible.size() > 1 &&
      std::all_of(visible.begin(), visible.end(), [&](const auto& c) {
        return containsCell(c, visible.front()) && containsCell(visible.front(), c);
      });
    if (flatten) {
      const auto& top = visible.front();
      SparseDraw draw{{top.source, top.sourceX, top.sourceY, 0, 0, top.width, top.height}, {}};
      draw.layers.assign(visible.rbegin(), visible.rend());
      plan.occludedPixels += uint64_t(top.width) * top.height * (visible.size() - 1);
      plan.draws.push_back(std::move(draw));
    } else {
      for (const auto& c : visible)
        plan.draws.push_back({{c.source, c.sourceX, c.sourceY, 0, 0, c.width, c.height}, {c}});
    }
  }
  // A deterministic plan gives unchanged scenes unchanged mappings.
  std::sort(plan.draws.begin(), plan.draws.end(), [](const auto& a, const auto& b) {
    return std::tie(a.patch.source, a.patch.sourceY, a.patch.sourceX) <
           std::tie(b.patch.source, b.patch.sourceY, b.patch.sourceX);
  });
  const uint32_t columns = width / cellSize;
  const uint32_t rows = (uint32_t(plan.draws.size()) + columns - 1) / columns;
  plan.requiredWidth = plan.draws.empty() ? cellSize : std::min(columns, uint32_t(plan.draws.size())) * cellSize;
  plan.requiredHeight = std::max(1u, rows) * cellSize;
  plan.fits = plan.requiredHeight <= height;
  for (size_t i = 0; i < plan.draws.size(); ++i) {
    auto& p = plan.draws[i].patch;
    p.x = uint32_t(i % columns) * cellSize;
    p.y = uint32_t(i / columns) * cellSize;
    plan.storedPixels += uint64_t(p.width) * p.height;
  }
  return plan;
}
}
