#pragma once
#include <algorithm>
#include <vector>
namespace viewflow::windows_preview {
// Clicks and captured stacking snapshots arrive independently. A newly raised
// source replaces an older local activation, and stays first until a snapshot
// acknowledges it. A subsequent local activation can take ownership again.
template<class Handle>
struct DesktopRaiseOrder {
  Handle pending_source{};
  void source_raised(Handle source, Handle& local) {
    local = Handle{};
    pending_source = source;
  }
  void reconcile(std::vector<Handle>& desired, Handle& local) {
    if (local != Handle{}) pending_source = Handle{};
    auto& requested = local != Handle{} ? local : pending_source;
    if (requested == Handle{}) return;
    const auto found = std::find(desired.begin(), desired.end(), requested);
    if (found == desired.end()) { requested = Handle{}; return; }
    if (found == desired.begin()) { requested = Handle{}; return; }
    const auto handle = *found;
    desired.erase(found);
    desired.insert(desired.begin(), handle);
  }
};
// Window handles are opaque. Only slots occupied by remote windows are replaced.
template<class Handle>
std::vector<Handle> InterleaveDesktopOrder(std::vector<Handle> actual, const std::vector<Handle>& desired) {
  size_t next = 0;
  for (auto& handle : actual)
    if (std::find(desired.begin(), desired.end(), handle) != desired.end()) handle = desired.at(next++);
  return actual;
}
}
