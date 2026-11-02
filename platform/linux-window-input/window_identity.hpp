#pragma once
#include <string>

namespace viewflow::linux_input {
// IPC and current Lua expose stable IDs as hexadecimal strings. Older Lua
// builds exposed an integer. Keep both representations pinned to the same ID.
inline std::string window_guard(const std::string& address, unsigned pid,
                                const std::string& stable_id, bool require_mapped = true) {
    return "local w=hl.get_window('address:" + address + "');assert(w and " +
        (require_mapped ? std::string("w.mapped and ") : std::string()) + "w.pid==" +
        std::to_string(pid) + " and (w.stable_id=='" + stable_id +
        "' or w.stable_id==0x" + stable_id + "),'window target changed');";
}
inline std::string close_window_command(const std::string& address, unsigned pid,
                                        const std::string& stable_id) {
    // An unmapped but still-existing application window can still be closed.
    return window_guard(address, pid, stable_id, false) +
        "hl.dispatch(hl.dsp.window.close({window=w}));";
}
}
