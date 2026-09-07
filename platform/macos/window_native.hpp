#pragma once
#include "../reverse-common/wire.hpp"
#include <vector>

namespace viewflow::macos {
struct Options {
    bool source{};
    bool validate{};
    unsigned codec{1}, fps{60};
    double scale{1};
    int origin_x{}, origin_y{};
    std::vector<unsigned> windows;
};
int run_source(const Options&);
int run_presenter(const Options&);
}
