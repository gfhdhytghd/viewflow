// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <dlfcn.h>
#include <iomanip>
#include <ostream>

namespace viewflow::hyprland {
// Captured once on the compositor thread; symbol resolution occurs only when
// the local diagnostic is queried. Raw program addresses never leave this type.
struct PointerFocusTrace {
  std::array<std::uintptr_t, 24> frames{};
  std::uint32_t count = 0, roles = 0;
  std::uint64_t observedNs = 0;
};

inline void writePointerFocusTrace(std::ostream& out, const PointerFocusTrace& trace) {
  if (!trace.count) return;
  out << ",\"pointer_focus_actor\":{\"observed_ns\":" << trace.observedNs
      << ",\"roles\":" << trace.roles << ",\"stack\":[";
  const auto count = std::min<std::size_t>(trace.count, trace.frames.size());
  for (std::size_t i = 0; i < count; ++i) {
    if (i) out << ',';
    Dl_info symbol{};
    const auto ip = trace.frames[i];
    const bool resolved = ip && dladdr(reinterpret_cast<const void*>(ip - 1), &symbol) && symbol.dli_sname;
    out << std::quoted(resolved ? symbol.dli_sname : "unresolved");
  }
  out << "]}";
}
}
