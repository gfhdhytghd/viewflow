#pragma once
#include "../reverse-common/wire.hpp"
namespace viewflow::reverse {
inline bool desktop_output(const Tile& tile) {return (tile.flags&windows_desktop_output_flag)!=0;}
inline bool desktop_output_only(const Frame& frame) {
    return !frame.tiles.empty() && std::all_of(frame.tiles.begin(),frame.tiles.end(),desktop_output);
}
}
