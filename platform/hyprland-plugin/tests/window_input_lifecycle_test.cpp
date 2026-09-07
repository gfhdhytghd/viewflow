// SPDX-License-Identifier: GPL-3.0-only
#include "window_input_lifecycle.hpp"
#include <cstdlib>

static void require(bool condition) { if (!condition) std::abort(); }
int main() {
  using namespace viewflow::hyprland;
  using Reason = WindowPointerRevocation;
  require(retirementReason(Reason::None) == Reason::Cancelled);
  for (unsigned value = 1; value <= 15; ++value) {
    const auto reason = static_cast<Reason>(value);
    require(retirementReason(reason) == reason);
    require(mayRestoreInputFocus(reason, false) == (reason == Reason::Cancelled));
    require(!mayRestoreInputFocus(reason, true));
    require(!mayRestoreInputFocus(reason, false, true));
    require(!mayRestoreInputFocus(reason, true, true));
  }
  require(!mayRestoreInputFocus(Reason::None, false));
  // Exhaust all wire-defined observations: only resize may be superseded,
  // never by None, and all terminal reasons survive every later event.
  for (unsigned before = 0; before <= 15; ++before) {
    for (unsigned event = 0; event <= 15; ++event) {
      const auto current = static_cast<Reason>(before);
      const auto incoming = static_cast<Reason>(event);
      const auto expected = incoming != Reason::None &&
          (current == Reason::None || current == Reason::Resized) ? incoming : current;
      require(observedRevocation(current, incoming) == expected);
    }
  }
  for (unsigned value = 1; value <= 15; ++value) {
    const auto fatal = static_cast<Reason>(value);
    if (fatal == Reason::Resized) continue;
    auto reason = observedRevocation(Reason::None, Reason::Resized);
    reason = observedRevocation(reason, Reason::Resized); // repeated commits
    reason = observedRevocation(reason, fatal); // takeover/lock/unmap/expiry
    require(reason == fatal);
    require(observedRevocation(reason, Reason::Resized) == fatal);
    require(observedRevocation(reason, Reason::None) == fatal);
    require(!mayRestoreInputFocus(reason, true));
  }
  // Better observation must not relax connection-local renewal rejection.
  WindowPointerAuthority authority;
  require(authority.begin(1, true));
  authority.revoke();
  require(!authority.begin(2, true));
  // Trial 71: exact keyboard remains active, no pointer focus/held buttons.
  require(mayRetainKeyboardWithoutPointer(true, true, true, false, false));
  for (unsigned mask = 0; mask < 8; ++mask)
    require(mayResumeHover(mask & 1, mask & 2, mask & 4) == (mask == 2));
  for (unsigned mask = 0; mask < 32; ++mask) {
    const bool retained = mayRetainKeyboardWithoutPointer(
        (mask & 1) != 0, (mask & 2) != 0, (mask & 4) != 0,
        (mask & 8) != 0, (mask & 16) != 0);
    require(retained == (mask == 7));
  }
}
