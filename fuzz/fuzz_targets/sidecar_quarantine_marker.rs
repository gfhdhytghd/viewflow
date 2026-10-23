#![no_main]
use libfuzzer_sys::fuzz_target;
use viewflow_platform::sidecar::DurableQuarantineMarker;

fuzz_target!(|data: &[u8]| {
    if let Ok(marker) = DurableQuarantineMarker::decode(data) {
        let encoded = marker.encode().expect("decoded marker must re-encode");
        assert_eq!(&encoded[..], data, "marker decoding is not canonical");
    }
});
