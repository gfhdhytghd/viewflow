// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <memory>
namespace viewflow::hyprland {
class MacOsShadows {
public:
  explicit MacOsShadows(void* handle);
  ~MacOsShadows();
private:
  struct Impl;
  std::unique_ptr<Impl> m_impl;
};
}
