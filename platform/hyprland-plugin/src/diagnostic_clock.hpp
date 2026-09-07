// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
#include <time.h>

namespace viewflow::hyprland {
// Diagnostic-only: zero means unavailable and must never authorize input.
inline std::uint64_t diagnosticMonotonicNs() noexcept {
  timespec now{};
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0) return 0;
  return std::uint64_t(now.tv_sec) * 1'000'000'000ULL + std::uint64_t(now.tv_nsec);
}
}
