#![no_main]
//! A sequence of media datagrams through one reassembler. Each record is a
//! u16 length, a u16 receive-time delta, then the datagram bytes.
use bytes::Bytes;
use libfuzzer_sys::fuzz_target;
use viewflow_transport::{MediaAssembler, MediaAssemblerConfig, MediaDatagram};

const MAX_PLANE_BYTES: usize = 1 << 16;

fuzz_target!(|data: &[u8]| {
    let mut assembler = MediaAssembler::new(MediaAssemblerConfig {
        deadline_ns: 33_333_333,
        max_chunks_per_plane: 64,
        max_plane_bytes: MAX_PLANE_BYTES,
    });
    let mut rest = data;
    let mut now = 0_u64;
    let mut mode = 0_u8;
    while let Some((head, tail)) = rest.split_first_chunk::<4>() {
        let len = usize::from(u16::from_le_bytes([head[0], head[1]]));
        now = now.saturating_add(u64::from(u16::from_le_bytes([head[2], head[3]])));
        let (packet, tail) = tail.split_at(len.min(tail.len()));
        rest = tail;
        let Ok(datagram) = MediaDatagram::decode(Bytes::copy_from_slice(packet)) else {
            continue;
        };
        mode = mode.wrapping_add(1);
        let payload = match mode % 3 {
            0 => assembler
                .push(datagram, now)
                .map(|plane| plane.map(|p| p.payload)),
            1 => assembler
                .push_latest(datagram, now)
                .map(|plane| plane.map(|p| p.payload)),
            _ => assembler
                .push_any(datagram, now)
                .map(|media| media.map(|m| m.payload)),
        };
        if let Ok(Some(payload)) = payload {
            assert!(payload.len() <= MAX_PLANE_BYTES);
        }
    }
});
