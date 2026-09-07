// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
namespace viewflow::hyprland {
// Metadata-only reason codes; no input contents or recipient identity.
enum class KeyboardRouteFailure : std::uint32_t {
  None = 0, SeatManagerMissing = 1, InputManagerMissing = 2,
  SeatProtocolMissing = 3, KeyboardCapabilityMissing = 4, InputMethodGrab = 5,
};
// Seat selection can outlive text-input activation. This is compatibility with
// the registered IME device, not authority to deliver its keys to an app.
constexpr bool compatibleImeSeatKeyboard(bool virtualKeyboard, bool registeredImeGood,
    const void* keyboardClient, const void* imeClient) {
  return virtualKeyboard && registeredImeGood && keyboardClient && keyboardClient == imeClient;
}
constexpr bool mayDeferEmptySeatFocus(bool admitted, bool currentSeatPresent,
    std::uint32_t bindingFailure, bool routeAvailable, bool leaseLive) {
  return admitted && !currentSeatPresent && bindingFailure == (1U << 16U) && routeAvailable && leaseLive;
}
constexpr bool restoredSeatFocus(std::uint32_t bindingFailure, bool routeAvailable, bool leaseLive) {
  return bindingFailure == 0 && routeAvailable && leaseLive;
}
constexpr bool keyboardAdmissionCandidateReady(bool present, bool virtualKeyboard, bool allowWait) {
  return present && (!allowWait || !virtualKeyboard);
}
constexpr bool keyboardRouteMayStartAdmission(KeyboardRouteFailure failure, bool allowWait) {
  return failure == KeyboardRouteFailure::None || (allowWait && failure == KeyboardRouteFailure::InputMethodGrab);
}
constexpr KeyboardRouteFailure keyboardRouteFailure(bool seatManager, bool inputManager,
    bool seatProtocol, bool keyboardCapability, bool inputMethodGrab) {
  if (!seatManager) return KeyboardRouteFailure::SeatManagerMissing;
  if (!inputManager) return KeyboardRouteFailure::InputManagerMissing;
  if (!seatProtocol) return KeyboardRouteFailure::SeatProtocolMissing;
  if (!keyboardCapability) return KeyboardRouteFailure::KeyboardCapabilityMissing;
  if (inputMethodGrab) return KeyboardRouteFailure::InputMethodGrab;
  return KeyboardRouteFailure::None;
}
}
