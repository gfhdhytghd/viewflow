// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
namespace viewflow::hyprland {
struct FloatRect { double x,y,width,height; };
inline FloatRect fitFloat(FloatRect current, FloatRect work) {
    const double width=std::min(current.width,work.width),height=std::min(current.height,work.height);
    return {std::clamp(current.x,work.x,work.x+work.width-width),
            std::clamp(current.y,work.y,work.y+work.height-height),width,height};
}
}
