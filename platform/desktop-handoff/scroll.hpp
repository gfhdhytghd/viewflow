#pragma once
#include <array>
#include <cmath>
#include <cstdint>
#include <stdexcept>
namespace viewflow::handoff {
// Wire: signed 120 units/detent, or signed 1000 units/logical point.
// Native integer APIs retain subunit remainder per axis, including across end
// markers. End markers carry zero delta and never manufacture a detent.
struct ScrollAccumulator {
    std::array<double,2> remainder{};
    int convert(int axis,int amount,bool precise,bool windows) {
        if(axis<0 || axis>1)throw std::runtime_error("invalid scroll axis");
        const double scale=windows?(precise?120.0/40000:1.0):(precise?1.0/1000:1.0/120);
        const double total=amount*scale+remainder[axis];
        const auto value=std::lround(total);
        if(value<INT32_MIN || value>INT32_MAX)throw std::runtime_error("scroll amount out of range");
        remainder[axis]=total-static_cast<double>(value);return static_cast<int>(value);
    }
};
}
