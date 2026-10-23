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
}
