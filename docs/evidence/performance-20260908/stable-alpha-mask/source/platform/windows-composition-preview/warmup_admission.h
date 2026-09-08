#pragma once
#include <cstdint>

namespace viewflow::windows_preview {
// Default preserves the legacy optional, single-picture warmup. Three-picture
// mode is explicit and must finish every unbound copy before accepting live.
class WarmupAdmission {
 public:
  explicit WarmupAdmission(uint32_t count = 1) : limit_(count) {}
  static constexpr bool valid_count(uint32_t count) {
    return count == 1 || count == 3;
  }
  bool admit(bool decode_only, uint64_t identity) {
    if (failed_ || !valid_count(limit_) || !identity) return fail();
    if (!decode_only) {
      if (limit_ == 3 && (pending_ || completed_ != limit_)) return fail();
      live_ = true;
      return true;
    }
    if (live_ || pending_ || admitted_ >= limit_ || identity <= previous_)
      return fail();
    ++admitted_;
    pending_ = identity;
    previous_ = identity;
    return true;
  }
  // Call only after the decoded picture has been copied to an unbound surface.
  bool complete(uint64_t identity) {
    if (failed_ || !pending_ || pending_ != identity) return fail();
    pending_ = 0;
    ++completed_;
    return true;
  }
  bool finish() const {
    return !failed_ && !pending_ && valid_count(limit_) &&
           (limit_ == 1 || completed_ == limit_);
  }
 private:
  bool fail() { failed_ = true; return false; }
  uint32_t limit_, admitted_{}, completed_{};
  uint64_t pending_{}, previous_{};
  bool live_{}, failed_{};
};
}  // namespace viewflow::windows_preview
