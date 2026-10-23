#![no_main]
//! HCSF headers from the local capture socket, as a sequence through one
//! per-connection lineage cursor.
use libfuzzer_sys::fuzz_target;
use viewflowd::hyprcapture_stream::{FrameCursor, FrameHeader, HEADER_BYTES};

fuzz_target!(|data: &[u8]| {
    let Some((limit, rest)) = data.split_first_chunk::<8>() else {
        return;
    };
    let max_pixel_bytes = u64::from_le_bytes(*limit);
    let mut cursor = FrameCursor::default();
    // A short final record still exercises the length check.
    for record in rest.chunks(HEADER_BYTES) {
        if let Ok(header) = FrameHeader::decode(record, max_pixel_bytes) {
            let _ = cursor.accept(&header);
        }
    }
});
