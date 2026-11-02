// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <memory>
#include <string>
namespace viewflow::hyprland {
void requestOutputFloatFit();
class OutputFloat {
public:
    OutputFloat();
    ~OutputFloat();
    void refresh();
    void workarea(std::string selector,std::string snapshot);
    void add(std::string output, std::string special, std::string underlay);
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
}
