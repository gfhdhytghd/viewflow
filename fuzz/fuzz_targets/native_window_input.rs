#![no_main]
//! Length-prefixed VFRV input records read from the native window helper.
use libfuzzer_sys::fuzz_target;
use viewflowd::native_window_wire::{Input, read_input};

fuzz_target!(|data: &[u8]| {
    if let Ok(input) = Input::decode(data) {
        assert_eq!(input.encode(), data);
    }
    let mut reader = data;
    while let Ok(Some(input)) = read_input(&mut reader) {
        assert_eq!(
            Input::decode(&input.encode()).expect("input re-decodes"),
            input
        );
    }
});
