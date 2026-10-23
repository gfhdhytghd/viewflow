#pragma once
#include <algorithm>
#include <vector>
namespace viewflow::windows_preview {
// Window handles are opaque. Only slots occupied by remote windows are replaced.
template<class Handle>
std::vector<Handle> InterleaveDesktopOrder(std::vector<Handle> actual, const std::vector<Handle>& desired) {
  size_t next = 0;
  for (auto& handle : actual)
    if (std::find(desired.begin(), desired.end(), handle) != desired.end()) handle = desired.at(next++);
  return actual;
}
}
