#![no_main]
//! Fixed-size Windows input-service request and result records.
use libfuzzer_sys::fuzz_target;
use viewflow_platform::fuzz_api::{
    REQUEST_SIZE, decode_windows_input, decode_windows_result, encode_windows_input,
    encode_windows_result,
};

fuzz_target!(|data: &[u8]| {
    let Some((result, rest)) = data.split_first_chunk::<5>() else {
        return;
    };
    let decoded = decode_windows_result(*result);
    assert_eq!(
        decode_windows_result(encode_windows_result(decoded)),
        decoded
    );

    let Some(request) = rest.first_chunk::<REQUEST_SIZE>() else {
        return;
    };
    if let Ok((event, display)) = decode_windows_input(request) {
        // Decoding ignores some unused bytes, so compare canonical encodings.
        let canonical = encode_windows_input(Some(event), display);
        let (again, again_display) =
            decode_windows_input(&canonical).expect("canonical request must decode");
        assert_eq!(again, event);
        assert_eq!(encode_windows_input(Some(again), again_display), canonical);
    }
});
