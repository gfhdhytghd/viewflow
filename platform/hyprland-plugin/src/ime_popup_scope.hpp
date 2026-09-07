// SPDX-License-Identifier: GPL-3.0-only
#pragma once

namespace viewflow::hyprland {
struct ImePopupScope {
  const void* mainSurface = nullptr;
  const void* focusedSurface = nullptr;
  const void* activeIme = nullptr;
  const void* popupOwner = nullptr;
  const void* mainClient = nullptr;
  const void* inputClient = nullptr;
  const void* imeClient = nullptr;
  const void* popupClient = nullptr;
  bool inputEnabled = false;
  bool imeActive = false;
  bool mapped = false;
};
// A shared PID/client is insufficient: the relay's enabled TextInput must
// name the exact captured main surface and the popup the exact live IME.
inline bool ownsImePopup(const ImePopupScope& scope) {
  return scope.mainSurface && scope.mainSurface == scope.focusedSurface &&
      scope.activeIme && scope.activeIme == scope.popupOwner &&
      scope.mainClient && scope.mainClient == scope.inputClient &&
      scope.imeClient && scope.imeClient == scope.popupClient &&
      scope.inputEnabled && scope.imeActive && scope.mapped;
}
inline bool retiresImePointerRecipient(bool ended, bool started, const void* current, const void* retired) {
  return !ended && started && current == retired;
}

// Cleanup may send a release only into its original recipient's surface.
// Retained bookkeeping must still be removed when focus cleared or changed.
inline bool maySendRecordedPointerRelease(bool recipientLive, bool ownedSurfaceLive,
                                          bool sameSurface, bool recordedPressed) {
  return recipientLive && ownedSurfaceLive && sameSurface && recordedPressed;
}
template<class SendRelease, class ClearRecord>
inline void cleanupRecordedPointerButton(bool ownedSurfaceLive, bool sameSurface, bool pressed,
                                        SendRelease sendRelease, ClearRecord clearRecord) {
  if (maySendRecordedPointerRelease(true, ownedSurfaceLive, sameSurface, pressed)) sendRelease();
  clearRecord();
}
}
