// SPDX-License-Identifier: GPL-3.0-only
#include "ime_popup_scope.hpp"
#include <cstdlib>

static void require(bool value) { if (!value) std::abort(); }
int main() {
  using namespace viewflow::hyprland;
  int main = 1, other = 2, ime = 3, mainClient = 4, imeClient = 5;
  const ImePopupScope exact{&main,&main,&ime,&ime,&mainClient,&mainClient,&imeClient,&imeClient,true,true,true};
  require(ownsImePopup(exact));
  for (unsigned field = 0; field != 11; ++field) {
    auto changed = exact;
    switch (field) {
      case 0: changed.mainSurface = nullptr; break;
      case 1: changed.focusedSurface = &other; break;
      case 2: changed.activeIme = nullptr; break;
      case 3: changed.popupOwner = &other; break;
      case 4: changed.mainClient = nullptr; break;
      case 5: changed.inputClient = &other; break;
      case 6: changed.imeClient = nullptr; break;
      case 7: changed.popupClient = &other; break;
      case 8: changed.inputEnabled = false; break;
      case 9: changed.imeActive = false; break;
      case 10: changed.mapped = false; break;
    }
    require(!ownsImePopup(changed));
  }
  // Unmapping a candidate or changing focus/IME cannot preserve admission.
  auto live = exact;
  live.mapped = false; require(!ownsImePopup(live));
  live.mapped = true; live.focusedSurface = &other; require(!ownsImePopup(live));
  live.focusedSurface = &main; live.popupOwner = &other; require(!ownsImePopup(live));
  // A candidate disappearing after moving to the main surface cannot clear
  // the new pointer target. Expired weak references still clean old records.
  require(retiresImePointerRecipient(false,true,&ime,&ime));
  require(retiresImePointerRecipient(false,true,nullptr,nullptr));
  require(!retiresImePointerRecipient(false,true,&main,&ime));
  require(!retiresImePointerRecipient(false,false,nullptr,nullptr));
  require(!retiresImePointerRecipient(true,true,&ime,&ime));
  for (unsigned mask = 0; mask != 8; ++mask) {
    const bool surfaceLive = mask & 1;
    const bool same = mask & 2;
    const bool pressed = mask & 4;
    unsigned releases = 0, clearSerials = 0;
    bool held = pressed;
    cleanupRecordedPointerButton(surfaceLive,same,pressed,
        [&] { ++releases; }, [&] { ++clearSerials; held = false; });
    require(releases == (mask == 7 ? 1U : 0U));
    require(clearSerials == 1 && !held);
  }
}
