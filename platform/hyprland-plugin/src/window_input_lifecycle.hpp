// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "window_pointer_authority.hpp"

namespace viewflow::hyprland {
inline WindowPointerRevocation retirementReason(WindowPointerRevocation reason) {
  return reason == WindowPointerRevocation::None ? WindowPointerRevocation::Cancelled : reason;
}

// Resize is still a revocation, never permission to resume. Preserve later
// fatal observations while the exact target's listeners remain alive, so a
// future explicit resize rebind cannot mistake local takeover for resize-only.
// All other revocations are terminal; no event can downgrade them to Resized.
inline WindowPointerRevocation observedRevocation(WindowPointerRevocation current,
                                                 WindowPointerRevocation incoming) {
  if (incoming == WindowPointerRevocation::None)
    return current;
  if (current == WindowPointerRevocation::None || current == WindowPointerRevocation::Resized)
    return incoming;
  return current;
}

// Restoration is an ordinary, still-owned END operation, never a response to
// losing a route, focus, capability, target or lease.
inline bool mayRestoreInputFocus(WindowPointerRevocation reason, bool targetRevoked, bool preserveFocus = false) {
  return !preserveFocus && reason == WindowPointerRevocation::Cancelled && !targetRevoked;
}

// A stationary compositor recheck may clear pointer focus during composition.
// It cannot revoke an independent exact keyboard binding when no pointer
// buttons are held. This grants no authority over a replacement pointer surface.
inline bool mayRetainKeyboardWithoutPointer(bool keyboardActive, bool ownedPointerPresent,
    bool seatAvailable, bool currentPointerPresent, bool heldButtons) {
  return keyboardActive && ownedPointerPresent && seatAvailable && !currentPointerPresent && !heldButtons;
}

// Hover does not own keyboard focus or a pressed grab. Compositor pointer
// focus changes are normal; the next remote motion may resolve its target and
// enter it again. Real local input and target destruction revoke separately.
inline bool mayResumeHover(bool keyboardSession, bool seatAvailable, bool heldButtons) {
  return !keyboardSession && seatAvailable && !heldButtons;
}
}
