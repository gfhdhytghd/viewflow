#include "window_keys.hpp"
#include <cassert>
#include <set>
int main() {
    using namespace viewflow::macos;
    std::set<unsigned> native, remote;
    for (auto [mac, evdev] : key_pairs) {
        assert(native.insert(mac).second && remote.insert(evdev).second);
        assert(mac_key(evdev) == mac && evdev_key(mac) == evdev);
    }
    assert(evdev_key(0) == 30); // Apple ANSI A -> Linux KEY_A / Windows scan 0x1e.
    assert(evdev_key(54) == 126 && evdev_key(55) == 125); // Separate right/left GUI.
    assert(evdev_key(60) == 54 && evdev_key(56) == 42); // Separate shifts.
    assert(mac_key(103) == 126 && mac_key(190) == 90); // Arrow up and F20.
    assert(!mac_key(255) && !evdev_key(255));
}
