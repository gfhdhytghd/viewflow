// SPDX-License-Identifier: GPL-3.0-only
#pragma once

namespace viewflow_capture {
// IME clients are compositor-wide. Only exact surface and live IME ownership
// establish membership in this capture; a common client or PID is insufficient.
inline bool ownsImePopup(const void* capturedSurface, const void* focusedSurface,
                         const void* activeIme, const void* popupOwner,
                         bool inputEnabled, bool imeActive, bool mapped) {
    return capturedSurface && capturedSurface == focusedSurface && activeIme &&
        activeIme == popupOwner && inputEnabled && imeActive && mapped;
}
}
