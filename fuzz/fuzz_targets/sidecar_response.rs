#![no_main]
use libfuzzer_sys::fuzz_target;
use viewflow_platform::sidecar::{read_response, write_response};

fuzz_target!(|data: &[u8]| {
    let mut reader = data;
    while let Ok(Some(response)) = read_response(&mut reader) {
        let mut encoded = Vec::new();
        write_response(&mut encoded, response).expect("decoded response must re-encode");
        let again = read_response(&mut encoded.as_slice())
            .expect("re-encoded response must decode")
            .expect("re-encoded response is not EOF");
        assert_eq!(again, response);
    }
});
