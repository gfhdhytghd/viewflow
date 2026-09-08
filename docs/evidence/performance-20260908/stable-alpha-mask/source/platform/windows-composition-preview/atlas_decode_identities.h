#pragma once
#include <cstdint>
#include <map>
#include <optional>
#include <utility>

namespace viewflow::windows_preview {
struct AtlasDecodeIdentity {
  uint64_t source_identity{};
  uint32_t width{}, height{};
  bool warmup{};
};

// Codec-local monotonic IDs never collide with either warmup IDs or the
// independently numbered live atlas stream. Mapping is consumed exactly once.
class AtlasDecodeIdentities {
 public:
  std::optional<uint64_t> Stage(uint64_t source, uint32_t width, uint32_t height, bool warmup) {
    if (!source || !width || !height || pending_.size() >= 8 || next_ == UINT64_MAX) return {};
    const uint64_t local = ++next_;
    pending_.emplace(local, AtlasDecodeIdentity{source,width,height,warmup});
    return local;
  }
  std::optional<AtlasDecodeIdentity> Take(uint64_t local, uint32_t width, uint32_t height) {
    const auto found = pending_.find(local);
    if (found == pending_.end() || found->second.width != width || found->second.height != height) return {};
    auto result = found->second;
    pending_.erase(found);
    return result;
  }
  bool Empty() const { return pending_.empty(); }
 private:
  uint64_t next_{};
  std::map<uint64_t, AtlasDecodeIdentity> pending_;
};
} // namespace viewflow::windows_preview
