#include "desktop_stacking.h"
#include <cassert>
int main() {
  using viewflow::windows_preview::InterleaveDesktopOrder;
  // Native windows above, between and below the two proxies retain their slots.
  assert((InterleaveDesktopOrder<int>({10,1,20,2,30}, {2,1}) == std::vector<int>{10,2,20,1,30}));
  assert((InterleaveDesktopOrder<int>({10,2,20,1,30}, {2,1}) == std::vector<int>{10,2,20,1,30}));
  // Source activation raises only the newly active proxy before reconciliation.
  assert((InterleaveDesktopOrder<int>({2,10,1,20,30}, {2,1}) == std::vector<int>{2,10,1,20,30}));
  assert((InterleaveDesktopOrder<int>({1,10,2}, {2,1}) == std::vector<int>{2,10,1}));

  viewflow::windows_preview::DesktopRaiseOrder<int> raises;
  int local = 1;
  raises.source_raised(2, local);
  assert(local == 0);
  auto stale = std::vector<int>{1, 2};
  raises.reconcile(stale, local);
  assert((stale == std::vector<int>{2, 1}));
  // Repeated old snapshots cannot undo the new Linux click.
  stale = {1, 2};
  raises.reconcile(stale, local);
  assert((stale == std::vector<int>{2, 1}));
  auto acknowledged = std::vector<int>{2, 1};
  raises.reconcile(acknowledged, local);
  assert(raises.pending_source == 0);
  // A later Windows click owns the order until its snapshot arrives.
  local = 1;
  raises.reconcile(acknowledged, local);
  assert((acknowledged == std::vector<int>{1, 2}));
}
