#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = viewflowd::fuzz_api::cursor_feedback_roundtrip(data);
});
