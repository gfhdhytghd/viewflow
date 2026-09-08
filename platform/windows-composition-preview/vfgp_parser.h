#pragma once
#include "atlas_record.h"
#include "input_recovery_record.h"
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <utility>
#include <vector>
namespace viewflow::vfgp {
struct DeadlineQpc {
  uint64_t deadline{}, frequency{};
  constexpr bool operator==(const DeadlineQpc &) const = default;
};
struct Frame {
  uint64_t identity{};
  uint32_t width{}, height{};
  bool decode_only{};
  std::vector<uint8_t> color_au, alpha;
  std::optional<DeadlineQpc> deadline_qpc{};
  std::optional<AtlasLayout> atlas{};
  std::optional<InputRecoveryConfirmation> input_recovery{};
  // Shared only after exact encoded bytes and geometry match. Each frame keeps
  // its own metadata while delayed consumers retain immutable pixel storage.
  std::shared_ptr<const std::vector<uint8_t>> shared_alpha{};
  bool alpha_reused{};
  std::span<const uint8_t> Alpha() const {
    return shared_alpha ? std::span<const uint8_t>(*shared_alpha)
                        : std::span<const uint8_t>(alpha);
  }
};
// Append pipe bytes, extract complete VFGP v1/v2/v3 records. V3 is reserved
// for a decode-only startup picture and is never a presentable frame. Returns
// false on a terminal contract violation; no recovery scan is ever attempted.
// V4 deadline records remain opt-in until native live admission is explicitly
// wired. V6 input recovery controls are separately opt-in, returned as an
// explicit input_recovery kind with no picture fields and an independent replay
// ledger. V7 desktop records retain the v5 picture payload but append an
// explicit per-tile desktop placement; they are never accepted without the
// desktop capability negotiated on argv. V9 rejected-input cancel/resume controls
// require the same recovery opt-in, have explicit cause/kind, and share V6
// control sequencing without weakening its advancing-geometry contract.
class Parser {
public:
  explicit Parser(size_t max_frame_bytes = 16u * 1024u * 1024u,
                  bool allow_deadline_v4 = false, bool allow_atlas_v5 = false,
                  bool allow_input_recovery_v6 = false,
                  bool allow_desktop_v7 = false, bool reuse_alpha = false)
      : max_(max_frame_bytes), allow_deadline_v4_(allow_deadline_v4),
        allow_atlas_v5_(allow_atlas_v5),
        allow_input_recovery_v6_(allow_input_recovery_v6),
        allow_desktop_v7_(allow_desktop_v7), reuse_alpha_(reuse_alpha) {}
  bool Push(std::span<const uint8_t> input, std::vector<Frame> *output);
  bool Finish() const { return !error_ && bytes_.empty() && wanted_ == 40; }
  const char *error() const { return error_; }
  // After synchronous consumption, retain at most one bounded alpha buffer.
  // This transfers ownership; callers must not retain spans into it.
  void RecycleAlpha(std::vector<uint8_t> alpha) {
    if (alpha.capacity() <= max_ &&
        alpha.capacity() >= alpha_scratch_.capacity()) {
      alpha.clear();
      alpha_scratch_ = std::move(alpha);
    }
  }

private:
  std::vector<uint8_t> alpha_scratch_;
  size_t max_;
  bool allow_deadline_v4_{};
  bool allow_atlas_v5_{};
  bool allow_input_recovery_v6_{};
  bool allow_desktop_v7_{};
  bool reuse_alpha_{};
  uint32_t alpha_width_{}, alpha_height_{};
  uint8_t alpha_version_{};
  std::vector<uint8_t> encoded_alpha_;
  std::shared_ptr<const std::vector<uint8_t>> decoded_alpha_;
  size_t wanted_{40};
  size_t header_bytes_{40};
  uint8_t version_{};
  uint64_t previous_{}, previous_atlas_{}, previous_recovery_{};
  std::vector<uint8_t> bytes_;
  const char *error_{};
};
} // namespace viewflow::vfgp
