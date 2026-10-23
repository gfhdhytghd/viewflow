#pragma once
#include "activity_priority.hpp"
#include "wire.hpp"
#include <chrono>
#include <cstdlib>
#include <string_view>

namespace viewflow::activity {
inline std::uint64_t now_us() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
// Set by the bridge only after both the peer and the native backend advertise
// support. Standalone legacy invocation keeps its original byte stream.
inline bool negotiated() {
    const auto value = std::getenv("VIEWFLOW_ACTIVITY_PRIORITY");
    return value && std::string_view(value) == "1";
}
inline void observe(Priority<std::uint64_t>& state, const reverse::Input& event, std::uint64_t now) {
    using reverse::InputKind;
    switch (event.kind) {
    case InputKind::focus: state.focus(event.id); break;
    case InputKind::button: state.hold(event.id, 1, std::uint32_t(event.a), event.b != 0, now); break;
    case InputKind::key: state.hold(event.id, 2, std::uint32_t(event.a), event.b != 0, now); break;
    case InputKind::wheel: if (event.b) state.impulse(event.id, now); break;
    case InputKind::release: state.release(event.id, now); break;
    // Native gesture assemblies and native drag lifetimes are observed by the
    // caller after decoding their complete frame, not individual byte chunks.
    default: break;
    }
}
} // namespace viewflow::activity
