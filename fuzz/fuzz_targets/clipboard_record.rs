#![no_main]
//! One clipboard-lane record from the peer, including PNG validation.
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Some((&role, record)) = data.split_first() else {
        return;
    };
    let _ = viewflowd::fuzz_api::clipboard_record(record, role & 1);
});
