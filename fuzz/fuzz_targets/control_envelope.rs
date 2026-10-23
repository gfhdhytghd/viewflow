#![no_main]
//! Peer QUIC control stream: protobuf envelope, then domain validation.
use libfuzzer_sys::fuzz_target;
use prost::Message;
use viewflow_protocol::{DomainControl, wire};

fuzz_target!(|data: &[u8]| {
    if let Ok(envelope) = wire::ControlEnvelope::decode(data) {
        let _ = DomainControl::try_from(envelope);
    }
});
