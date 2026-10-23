#![no_main]
//! Local sidecar IPC request frames, possibly several back to back.
use libfuzzer_sys::fuzz_target;
use viewflow_platform::sidecar::{read_request, write_request};

fuzz_target!(|data: &[u8]| {
    let mut reader = data;
    // Stop on the first error, as the service loop does.
    while let Ok(Some(request)) = read_request(&mut reader) {
        let mut encoded = Vec::new();
        write_request(&mut encoded, &request).expect("decoded request must re-encode");
        let again = read_request(&mut encoded.as_slice())
            .expect("re-encoded request must decode")
            .expect("re-encoded request is not EOF");
        assert_eq!(again, request);
    }
});
