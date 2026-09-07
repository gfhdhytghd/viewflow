// SPDX-License-Identifier: GPL-3.0-only
#include "ime_popup_scope.hpp"
#include <cassert>

int main() {
    int surface, otherSurface, ime, otherIme;
    using viewflow_capture::ownsImePopup;
    assert(ownsImePopup(&surface, &surface, &ime, &ime, true, true, true));
    assert(!ownsImePopup(&surface, &otherSurface, &ime, &ime, true, true, true));
    assert(!ownsImePopup(&surface, &surface, &ime, &otherIme, true, true, true));
    assert(!ownsImePopup(nullptr, nullptr, &ime, &ime, true, true, true));
    assert(!ownsImePopup(&surface, &surface, nullptr, nullptr, true, true, true));
    assert(!ownsImePopup(&surface, &surface, &ime, &ime, false, true, true));
    assert(!ownsImePopup(&surface, &surface, &ime, &ime, true, false, true));
    assert(!ownsImePopup(&surface, &surface, &ime, &ime, true, true, false));
}
