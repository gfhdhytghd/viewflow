#pragma once
#include <string>

namespace viewflow::linux_input {
// IPC and current Lua expose stable IDs as hexadecimal strings. Older Lua
// builds exposed an integer. Keep both representations pinned to the same ID.
inline std::string window_guard(const std::string& address, unsigned pid,
                                const std::string& stable_id) {
    return "local w=hl.get_window('address:" + address + "');assert(w and w.mapped and w.pid==" +
        std::to_string(pid) + " and (w.stable_id=='" + stable_id +
        "' or w.stable_id==0x" + stable_id + "),'window target changed');";
}
}
