// SPDX-License-Identifier: GPL-3.0-only
#include "pointer_timing_ring.hpp"
#include <cstdlib>
#include <limits>
using namespace viewflow::hyprland;
void require(bool value) { if (!value) std::abort(); }
struct GroupedNumbers : std::numpunct<char> {
  char do_thousands_sep() const override { return ','; }
  std::string do_grouping() const override { return "\3"; }
};
int main() {
  PointerTimingRing ring;
  require(ring.json() == "[]");
  const auto previous = std::locale::global(std::locale(std::locale::classic(), new GroupedNumbers));
  ring.push({std::numeric_limits<std::uint64_t>::max(), 2, 1234567, 4, 5, 6, 55, 0, false, 7, 8, InputDispatchOrigin::Readable});
  require(ring.json() == "[{\"sequence\":18446744073709551615,\"generation\":2,\"type\":55,\"received_ns\":1234567,\"applied_ns\":4,\"replied_ns\":5,\"deadline_ns\":6,\"result\":0,\"sent\":false,\"tick_ns\":7,\"read_ns\":8,\"dispatch_origin\":1,\"previous_dispatch_started_ns\":0,\"previous_dispatch_ended_ns\":0}]");
  std::locale::global(previous);
  for (std::uint64_t i = 1; i <= 100; ++i)
    ring.push({i, 2, 3, 4, 5, 6, 55, 4, true});
  std::string expected = "[";
  for (int i = 69; i <= 100; ++i) {
    if (i != 69) expected += ",";
    expected += "{\"sequence\":" + std::to_string(i) + ",\"generation\":2,\"type\":55,\"received_ns\":3,\"applied_ns\":4,\"replied_ns\":5,\"deadline_ns\":6,\"result\":4,\"sent\":true,\"tick_ns\":0,\"read_ns\":0,\"dispatch_origin\":0,\"previous_dispatch_started_ns\":0,\"previous_dispatch_ended_ns\":0}";
  }
  expected += "]";
  require(ring.json() == expected);
  require(ring.json() == expected); // reading must not consume evidence
  ring.push({101, 2, 3, 4, 5, 6, 55, 4, true, 7, 8, InputDispatchOrigin::Watchdog, 9, 10});
  require(ring.json().ends_with("\"dispatch_origin\":2,\"previous_dispatch_started_ns\":9,\"previous_dispatch_ended_ns\":10}]"));
  ring.push({102, 2, 3, 4, 5, 6, 55, 4, true, 7, 8, InputDispatchOrigin::RenderPre, 9, 10});
  require(ring.json().ends_with("\"dispatch_origin\":3,\"previous_dispatch_started_ns\":9,\"previous_dispatch_ended_ns\":10}]"));
  ring.push({103, 2, 3, 4, 5, 6, 59, 0, true, 7, 8, InputDispatchOrigin::Readable, 9, 10, 8, 5});
  require(ring.json().ends_with("\"begin_stage\":8,\"keyboard_startup_failure\":5}]"));
  ring.recordFocusDiagnostic(367);
  require(ring.json().ends_with("\"keyboard_startup_failure\":5,\"pointer_focus_diagnostic\":367}]"));
  ring.recordFocusDiagnostic(0);
  require(ring.json().ends_with("\"pointer_focus_diagnostic\":367}]"));
  PointerTimingRing empty;
  empty.recordFocusDiagnostic(367);
  require(empty.json() == "[]");
  ring.recordKeyboardDiagnostic(805322752);
  require(ring.json().ends_with("\"pointer_focus_diagnostic\":367,\"keyboard_runtime_diagnostic\":805322752}]"));
  ring.recordKeyboardDiagnostic(0);
  require(ring.json().ends_with("\"keyboard_runtime_diagnostic\":805322752}]"));
  PointerFocusTrace trace;
  trace.count = 2;
  trace.roles = 3;
  trace.observedNs = 12345;
  ring.recordFocusTrace(trace);
  require(ring.json().ends_with("\"pointer_focus_actor\":{\"observed_ns\":12345,\"roles\":3,\"stack\":[\"unresolved\",\"unresolved\"]}}]"));
  empty.recordFocusTrace(trace);
  require(empty.json() == "[]");
  // Corrupt diagnostic counts cannot cause an out-of-bounds query read.
  trace.count = 1000;
  std::ostringstream bounded;
  writePointerFocusTrace(bounded, trace);
  const auto text = bounded.str();
  std::size_t symbols = 0, offset = 0;
  while ((offset = text.find("unresolved", offset)) != std::string::npos) { ++symbols; offset += 10; }
  require(symbols == trace.frames.size());

}
