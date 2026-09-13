#include "window_shortcut_policy.hpp"
#include <cassert>
#include <stdexcept>

int main() {
    using namespace viewflow::macos;
    ShortcutPolicy policy;
    policy.add("Command+Q");
    policy.add("Ctrl+*");
    assert(policy.linux_first(shortcut_command, "q"));
    assert(policy.linux_first(shortcut_control, "x"));
    assert(policy.linux_first(shortcut_control | shortcut_shift, "x"));
    assert(!policy.linux_first(shortcut_command, "w"));
    try { policy.add("ctrl"); assert(false); } catch (const std::runtime_error&) {}
}
