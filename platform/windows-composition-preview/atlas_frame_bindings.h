#pragma once
#include "vfgp_parser.h"
#include <map>

namespace viewflow::windows_preview {
struct AtlasFrameBinding {
  uint64_t identity{};
  uint32_t width{}, height{};
  vfgp::DeadlineQpc deadline;
  vfgp::AtlasLayout layout;
};

// Decoder output may be delayed. Retain each complete immutable layout by its
// submitted identity, never attach the newest layout to whichever pixels
// arrive.
class AtlasFrameBindings {
public:
  bool Stage(const vfgp::Frame &frame) {
    if (!frame.atlas || !frame.deadline_qpc || frame.decode_only ||
        !frame.identity || !frame.deadline_qpc->deadline ||
        !frame.deadline_qpc->frequency || pending_.size() >= 8 ||
        pending_.contains(frame.identity))
      return false;
    const auto &layout = *frame.atlas;
    const bool keyframe = layout.color_keyframe && layout.alpha_keyframe;
    if (needs_keyframe_ && !keyframe)
      return false;
    if (!latest_) {
      if (!keyframe)
        return false;
    } else {
      const auto &old = latest_->layout;
      if (frame.identity <= latest_->identity ||
          frame.width != latest_->width || frame.height != latest_->height ||
          layout.stream != old.stream ||
          layout.geometry_epoch != old.geometry_epoch ||
          layout.config_generation != old.config_generation ||
          layout.revision < old.revision || layout.source_ns <= old.source_ns)
        return false;
      if (layout.desktop && old.desktop &&
          layout.desktop->topology_generation <
              old.desktop->topology_generation)
        return false;
      const bool changed = !SamePlacement(layout.tiles, old.tiles) ||
                           !SameDesktopPlacement(layout.desktop, old.desktop);
      if ((changed && layout.revision == old.revision) ||
          ((changed || layout.revision != old.revision ||
            frame.identity - latest_->identity != 1) &&
           !keyframe))
        return false;
      size_t previous_index = 0;
      for (const auto &tile : layout.tiles) {
        while (previous_index < old.tiles.size() &&
               old.tiles[previous_index].window < tile.window)
          ++previous_index;
        if (previous_index == old.tiles.size() ||
            old.tiles[previous_index].window != tile.window)
          continue;
        const auto &previous = old.tiles[previous_index];
        if (tile.source_frame <= previous.source_frame ||
            tile.source_ns <= previous.source_ns ||
            tile.geometry_epoch < previous.geometry_epoch ||
            tile.placement_generation < previous.placement_generation)
          return false;
      }
    }
    AtlasFrameBinding binding{frame.identity, frame.width, frame.height,
                              *frame.deadline_qpc, layout};
    pending_.emplace(frame.identity, binding);
    latest_ = std::move(binding);
    needs_keyframe_ = false;
    return true;
  }

  const AtlasFrameBinding *Find(uint64_t identity, uint32_t width,
                                uint32_t height) const {
    const auto it = pending_.find(identity);
    if (identity <= resolved_ || it == pending_.end() ||
        it->second.width != width || it->second.height != height)
      return nullptr;
    return &it->second;
  }
  bool Commit(uint64_t identity) {
    if (identity <= resolved_ || !pending_.contains(identity))
      return false;
    resolved_ = identity;
    pending_.erase(pending_.begin(), pending_.upper_bound(identity));
    return true;
  }
  // Caller must independently prove no visual was bound for this frame.
  // Only a single resolved handoff is recoverable: queued decoder outputs
  // would make reference-chain disposition ambiguous and remain terminal.
  // Keep latest_ intact so rejection cannot reset layout/source replay floors.
  bool DiscardUnbound(uint64_t identity) {
    if (identity <= resolved_ || pending_.size() != 1 ||
        !pending_.contains(identity))
      return false;
    resolved_ = identity;
    pending_.erase(identity);
    needs_keyframe_ = true;
    return true;
  }
  bool Empty() const { return pending_.empty(); }

private:
  static bool SamePlacement(const std::vector<vfgp::AtlasTile> &a,
                            const std::vector<vfgp::AtlasTile> &b) {
    if (a.size() != b.size())
      return false;
    for (size_t i = 0; i < a.size(); ++i) {
      if (a[i].window != b[i].window ||
          a[i].placement_generation != b[i].placement_generation ||
          a[i].geometry_epoch != b[i].geometry_epoch || a[i].x != b[i].x ||
          a[i].y != b[i].y || a[i].width != b[i].width ||
          a[i].height != b[i].height)
        return false;
    }
    return true;
  }
  static bool
  SameDesktopPlacement(const std::optional<vfgp::DesktopLayout> &a,
                       const std::optional<vfgp::DesktopLayout> &b) {
    if (a.has_value() != b.has_value())
      return false;
    if (!a)
      return true;
    if (a->topology_generation != b->topology_generation ||
        a->viewport.x_millidip != b->viewport.x_millidip ||
        a->viewport.y_millidip != b->viewport.y_millidip ||
        a->viewport.width_millidip != b->viewport.width_millidip ||
        a->viewport.height_millidip != b->viewport.height_millidip ||
        a->windows.size() != b->windows.size())
      return false;
    for (size_t i = 0; i < a->windows.size(); ++i) {
      const auto &x = a->windows[i];
      const auto &y = b->windows[i];
      if (x.window != y.window || x.movable != y.movable ||
          x.bounds.x_millidip != y.bounds.x_millidip ||
          x.bounds.y_millidip != y.bounds.y_millidip ||
          x.bounds.width_millidip != y.bounds.width_millidip ||
          x.bounds.height_millidip != y.bounds.height_millidip)
        return false;
    }
    return true;
  }
  std::map<uint64_t, AtlasFrameBinding> pending_;
  std::optional<AtlasFrameBinding> latest_;
  uint64_t resolved_{};
  bool needs_keyframe_{};
};
} // namespace viewflow::windows_preview
