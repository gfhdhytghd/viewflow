#![no_main]
use bytes::Bytes;
use libfuzzer_sys::fuzz_target;
use viewflow_transport::ReliablePayload;
use viewflow_transport::fuzz_api::{decode_reliable, encode_blob_chunk, encode_control};

fuzz_target!(|data: &[u8]| {
    let bytes = Bytes::copy_from_slice(data);
    match decode_reliable(&bytes) {
        Ok(ReliablePayload::Control(payload)) => {
            assert_eq!(encode_control(&payload), bytes);
        }
        Ok(ReliablePayload::BlobChunk(chunk)) => {
            assert_eq!(encode_blob_chunk(&chunk).expect("chunk re-encodes"), bytes);
        }
        Err(_) => {}
    }
});
