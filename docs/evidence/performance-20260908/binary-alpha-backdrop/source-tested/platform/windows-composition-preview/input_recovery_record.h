#pragma once
#include "atlas_record.h"

namespace viewflow::vfgp {
// VFGP v6 is trusted-local input control, never a picture or remote authority.
// Only a receiver that has validated the source's post-cleanup authorization
// may write it. Native resume additionally requires an exact cancelled target,
// physical release drain, matching history and a live same-host QPC deadline.
struct InputRecoveryConfirmation {
  uint64_t sequence{};
  AtlasId stream, window;
  uint64_t atlas_epoch{}, config_generation{}, previous_epoch{}, geometry_epoch{};
  uint64_t grant_generation{}, atlas_frame{}, source_frame{}, placement_generation{};
  uint64_t deadline_qpc{}, frequency{};
  uint64_t cancel_sequence{}, previous_atlas_frame{}, previous_source_frame{};
  uint8_t rejection_kind{}; // V9 only: 1 cancel, 2 source-authorized resume.

};
inline constexpr size_t input_recovery_bytes = 152;

inline std::optional<InputRecoveryConfirmation> DecodeInputRecovery(std::span<const uint8_t> b) {
  if (b.size() != input_recovery_bytes || b[0] != 'V' || b[1] != 'F' || b[2] != 'G' || b[3] != 'P' ||
      b[4] != 6 || b[5] || b[6] || b[7]) return {};
  const auto u32 = [&](size_t at) { return (uint32_t(b[at]) << 24) | (uint32_t(b[at+1]) << 16) |
      (uint32_t(b[at+2]) << 8) | b[at+3]; };
  const auto u64 = [&](size_t at) { return (uint64_t(u32(at)) << 32) | u32(at+4); };
  if (u32(8) != input_recovery_bytes || u32(12) || u64(24) || u64(32)) return {};
  InputRecoveryConfirmation result{u64(16), {u64(40), u64(48)}, {u64(56), u64(64)},
      u64(72), u64(80), u64(88), u64(96), u64(104), u64(112), u64(120), u64(128), u64(136), u64(144)};
  if (!result.sequence || result.stream == AtlasId{} || result.window == AtlasId{} ||
      result.stream == result.window || !result.atlas_epoch || !result.config_generation ||
      !result.previous_epoch || result.geometry_epoch <= result.previous_epoch ||
      !result.grant_generation || !result.atlas_frame || !result.source_frame ||
      !result.placement_generation || !result.deadline_qpc || !result.frequency) return {};
  return result;
}
inline constexpr size_t rejected_input_bytes = 176;
inline std::optional<InputRecoveryConfirmation> DecodeRejectedInput(std::span<const uint8_t> b) {
  if (b.size() != rejected_input_bytes || b[0] != 'V' || b[1] != 'F' || b[2] != 'G' || b[3] != 'P' ||
      b[4] != 9 || (b[5] != 1 && b[5] != 2) || b[6] != 1 || b[7]) return {};
  const auto u32 = [&](size_t at) { return (uint32_t(b[at]) << 24) | (uint32_t(b[at+1]) << 16) |
      (uint32_t(b[at+2]) << 8) | b[at+3]; };
  const auto u64 = [&](size_t at) { return (uint64_t(u32(at)) << 32) | u32(at+4); };
  if (u32(8) != rejected_input_bytes || u32(12) || u64(24) || u64(32)) return {};
  InputRecoveryConfirmation c{u64(16), {u64(40), u64(48)}, {u64(56), u64(64)},
      u64(72), u64(80), u64(88), u64(96), u64(104), u64(112), u64(120), u64(128), u64(136), u64(144),
      u64(152), u64(160), u64(168), b[5]};
  if (!c.sequence || c.stream == AtlasId{} || c.window == AtlasId{} || c.stream == c.window ||
      !c.atlas_epoch || !c.config_generation || !c.previous_epoch || c.geometry_epoch < c.previous_epoch ||
      !c.atlas_frame || !c.source_frame || !c.placement_generation || !c.deadline_qpc || !c.frequency ||
      !c.cancel_sequence || !c.previous_atlas_frame || !c.previous_source_frame ||
      c.atlas_frame < c.previous_atlas_frame || c.source_frame < c.previous_source_frame) return {};
  if (c.rejection_kind == 1 ?
      (c.sequence != c.cancel_sequence || c.grant_generation || c.geometry_epoch != c.previous_epoch ||
       c.atlas_frame != c.previous_atlas_frame || c.source_frame != c.previous_source_frame) :
      (!c.grant_generation || c.sequence <= c.cancel_sequence)) return {};
  return c;
}
} // namespace viewflow::vfgp
