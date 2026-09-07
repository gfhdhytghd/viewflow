// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "input_dispatch_origin.hpp"
#include "pointer_focus_trace.hpp"
#include <array>
#include <cstdint>
#include <locale>
#include <sstream>
#include <string>

namespace viewflow::hyprland {
// Compositor-thread-owned diagnostics: recording does not allocate or perform I/O.
class PointerTimingRing {
public:
  struct Timing {
    std::uint64_t sequence{}, generation{}, received{}, applied{}, replied{}, deadline{};
    std::uint32_t type{}, result{};
    bool sent{};
    std::uint64_t tickStarted{}, readStarted{};
    InputDispatchOrigin origin = InputDispatchOrigin::Tick;
    std::uint64_t previousDispatchStarted{}, previousDispatchEnded{};
    std::uint32_t beginStage{}, keyboardStartupFailure{};
    std::uint32_t pointerFocusDiagnostic{};
    std::uint32_t keyboardRuntimeDiagnostic{};
    PointerFocusTrace pointerFocusTrace{};
  };
  void push(Timing timing) noexcept {
    m_timings[m_next] = timing;
    m_next = (m_next + 1) % m_timings.size();
    if (m_count < m_timings.size()) ++m_count;
  }
  // A tick can retire the session without another incoming command. Preserve
  // that observation on the latest command rather than requiring stderr access.
  void recordFocusDiagnostic(std::uint32_t diagnostic) noexcept {
    if (m_count && diagnostic)
      m_timings[(m_next + m_timings.size() - 1) % m_timings.size()].pointerFocusDiagnostic = diagnostic;
  }
  void recordKeyboardDiagnostic(std::uint32_t diagnostic) noexcept {
    if (m_count && diagnostic)
      m_timings[(m_next + m_timings.size() - 1) % m_timings.size()].keyboardRuntimeDiagnostic = diagnostic;
  }
  void recordFocusTrace(const PointerFocusTrace& trace) noexcept {
    if (m_count && trace.count)
      m_timings[(m_next + m_timings.size() - 1) % m_timings.size()].pointerFocusTrace = trace;
  }
  [[nodiscard]] std::string json() const {
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << "[";
    for (std::size_t i = 0; i < m_count; ++i) {
      const auto &t = m_timings[(m_next + m_timings.size() - m_count + i) % m_timings.size()];
      if (i) out << ",";
      out << "{\"sequence\":" << t.sequence << ",\"generation\":" << t.generation
          << ",\"type\":" << t.type << ",\"received_ns\":" << t.received
          << ",\"applied_ns\":" << t.applied << ",\"replied_ns\":" << t.replied
          << ",\"deadline_ns\":" << t.deadline << ",\"result\":" << t.result
          << ",\"sent\":" << (t.sent ? "true" : "false")
          << ",\"tick_ns\":" << t.tickStarted << ",\"read_ns\":" << t.readStarted
          << ",\"dispatch_origin\":" << static_cast<std::uint32_t>(t.origin)
          << ",\"previous_dispatch_started_ns\":" << t.previousDispatchStarted
          << ",\"previous_dispatch_ended_ns\":" << t.previousDispatchEnded;
      if (t.beginStage || t.keyboardStartupFailure)
        out << ",\"begin_stage\":" << t.beginStage << ",\"keyboard_startup_failure\":" << t.keyboardStartupFailure;
      if (t.pointerFocusDiagnostic)
        out << ",\"pointer_focus_diagnostic\":" << t.pointerFocusDiagnostic;
      if (t.keyboardRuntimeDiagnostic)
        out << ",\"keyboard_runtime_diagnostic\":" << t.keyboardRuntimeDiagnostic;
      writePointerFocusTrace(out, t.pointerFocusTrace);
      out << "}";
    }
    out << "]";
    return out.str();
  }
private:
  std::array<Timing, 32> m_timings{};
  std::size_t m_next = 0, m_count = 0;
};
}
