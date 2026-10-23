#![no_main]
//! Atlas V3 feedback records checked against a pending frame. The pending
//! frame comes from a length-prefixed protobuf `AtlasFrame` in the input.
use libfuzzer_sys::fuzz_target;
use prost::Message;
use viewflow_protocol::{AtlasFrame, wire};
use viewflowd::atlas_feedback::{decode, encode};

fuzz_target!(|data: &[u8]| {
    let Some((&len, rest)) = data.split_first() else {
        return;
    };
    let (frame, record) = rest.split_at(usize::from(len).min(rest.len()));
    let Ok(message) = wire::AtlasFrame::decode(frame) else {
        return;
    };
    let Ok(pending) = AtlasFrame::try_from(message) else {
        return;
    };
    if let Ok(result) = decode(record, &pending) {
        assert_eq!(
            &encode(&pending, result).expect("feedback re-encodes")[..],
            record
        );
    }
});
