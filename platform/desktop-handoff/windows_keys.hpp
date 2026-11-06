#pragma once
#include "../reverse-common/windows_keys.hpp"
namespace viewflow::handoff {
// Shared with the window path; imported from samesys-review e477a06b.
inline unsigned evdev_scan(unsigned scan,bool extended) {
    return reverse::windows_keys::from_scan(scan|(extended?0xe000:0)).value_or(0);
}
inline unsigned evdev_key(unsigned vk,unsigned scan,bool extended) {
    return reverse::windows_keys::from_message(vk,(scan<<16)|(extended?1u<<24:0)).value_or(0);
}
inline auto windows_scan(unsigned evdev) {return reverse::windows_keys::to_windows(evdev);}
}
