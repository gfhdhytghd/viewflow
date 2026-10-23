#![no_main]
//! Hyprland IPC JSON replies and VFHY window-pointer completion packets.
use libfuzzer_sys::fuzz_target;
use viewflow_hyprland::window_pointer_wire::Request;
use viewflow_hyprland::{parse_monitors, parse_windows};

fuzz_target!(|data: &[u8]| {
    if let Ok(json) = std::str::from_utf8(data) {
        let _ = parse_monitors(json);
        let _ = parse_windows(json);
    }
    // Fixed request identity; the packet must match it to complete.
    if let Ok(request) = Request::end(1, 1) {
        let _ = request.complete(data);
    }
});
