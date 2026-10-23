#![no_main]
use bytes::Bytes;
use libfuzzer_sys::fuzz_target;
use viewflow_transport::RawBgraPayload;

fuzz_target!(|data: &[u8]| {
    let Some((head, payload)) = data.split_first_chunk::<2>() else {
        return;
    };
    let max_bytes = usize::from(u16::from_le_bytes(*head)) * 64;
    let bytes = Bytes::copy_from_slice(payload);
    if let Ok(frame) = RawBgraPayload::decode(bytes.clone(), max_bytes) {
        assert_eq!(frame.encode(max_bytes).expect("frame re-encodes"), bytes);
    }
});
