#![no_main]
//! Line and JSON replies from local native helpers (presenter child, capture
//! plugin). The first byte picks the parser.
use libfuzzer_sys::fuzz_target;
use viewflowd::atlas_input_recovery::NativeRecoveryNotice;
use viewflowd::atlas_pointer::AtlasNativePointer;
use viewflowd::atlas_presenter::AtlasDisposition;
use viewflowd::desktop_pointer::AtlasDesktopMove;
use viewflowd::gpu_presenter_pipe::NativePresentationDeadline;
use viewflowd::hyprcapture_control::{GpuStreamRequest, StreamRequest};

fuzz_target!(|data: &[u8]| {
    let Some((&selector, rest)) = data.split_first() else {
        return;
    };
    match selector % 6 {
        0 => {
            if let Ok(line) = std::str::from_utf8(rest) {
                let deadline = NativePresentationDeadline {
                    ticks: 200,
                    frequency: 10_000_000,
                };
                let _ = AtlasDisposition::parse(line, 9, 2, 100, 250, deadline);
            }
        }
        1 => {
            if let Ok(line) = std::str::from_utf8(rest) {
                let _ = AtlasNativePointer::parse(line);
            }
        }
        2 => {
            if let Ok(line) = std::str::from_utf8(rest) {
                let _ = AtlasDesktopMove::parse(line);
            }
        }
        3 => {
            if let Ok(line) = std::str::from_utf8(rest) {
                let _ = NativeRecoveryNotice::parse(line);
            }
        }
        4 => {
            let request = StreamRequest {
                id: "fuzz-1",
                window_address: "0x123",
                socket_path: "/tmp/fuzz.sock",
                fps: 120,
            };
            let _ = request.validate_started(rest);
            let _ = request.validate_stopped(rest);
            let gpu = GpuStreamRequest {
                id: "fuzz-1",
                window_address: "0x123",
                socket_path: "/tmp/fuzz.sock",
                fps: 120,
            };
            let _ = gpu.validate_started(rest);
        }
        _ => {
            let _ = viewflowd::fuzz_api::hyprcapture_response(rest, "0x123", 1 << 24);
        }
    }
});
