// SPDX-License-Identifier: GPL-3.0-only
#pragma once
namespace viewflow::hyprland {
// A gesture that began remotely must not deliver orphan updates to Linux when
// the pointer returns mid-gesture. The next gesture restores normal local use.
struct GestureRoute {
  struct Decision { bool suppress{}, cancelLocal{}; };
  bool localStarted{}, remoteStarted{};
  Decision begin(bool remote) {
    const bool cancel = localStarted;
    localStarted = !remote; remoteStarted = remote;
    return {remote, cancel};
  }
  Decision update(bool remote) {
    const bool cancel = remote && localStarted;
    if (remote) { localStarted = false; remoteStarted = true; }
    return {remoteStarted, cancel};
  }
  Decision end(bool remote) {
    const auto result = update(remote);
    localStarted = remoteStarted = false;
    return result;
  }
};
}
