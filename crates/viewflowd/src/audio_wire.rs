//! Versioned PCM datagrams. A packet is one whole 5 ms block so congestion
//! can discard a packet without splitting samples or building a stale backlog.
use anyhow::{Result, ensure};

pub const SAMPLE_RATE: u32 = 48_000;
pub const CHANNELS: usize = 2;
pub const FRAMES: usize = 240;
pub const PCM_BYTES: usize = FRAMES * CHANNELS * 2;
pub const HEADER_BYTES: usize = 24;
pub const PACKET_BYTES: usize = HEADER_BYTES + PCM_BYTES;
const MAGIC: &[u8; 8] = b"VFAU\0\0\0\x01";

pub fn encode(generation: u64, sequence: u64, pcm: &[u8]) -> Result<Vec<u8>> {
    ensure!(
        pcm.len() == PCM_BYTES,
        "audio block must contain 240 stereo s16le frames"
    );
    let mut packet = Vec::with_capacity(PACKET_BYTES);
    packet.extend_from_slice(MAGIC);
    packet.extend_from_slice(&generation.to_le_bytes());
    packet.extend_from_slice(&sequence.to_le_bytes());
    packet.extend_from_slice(pcm);
    Ok(packet)
}

pub fn decode(packet: &[u8]) -> Result<(u64, u64, &[u8])> {
    ensure!(
        packet.len() == PACKET_BYTES && &packet[..8] == MAGIC,
        "invalid audio datagram"
    );
    Ok((
        u64::from_le_bytes(packet[8..16].try_into()?),
        u64::from_le_bytes(packet[16..24].try_into()?),
        &packet[HEADER_BYTES..],
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn whole_frames_fit_default_quic_datagram() {
        let pcm: Vec<_> = (0..PCM_BYTES).map(|n| n as u8).collect();
        let packet = encode(7, 42, &pcm).unwrap();
        assert!(packet.len() < 1200);
        assert_eq!(decode(&packet).unwrap(), (7, 42, pcm.as_slice()));
        for length in [0, 7, 23, PACKET_BYTES - 1] {
            assert!(decode(&packet[..length]).is_err());
        }
        let mut corrupt = packet;
        corrupt[7] = 2;
        assert!(decode(&corrupt).is_err());
        assert!(encode(1, 0, &[0; PCM_BYTES - 1]).is_err());
    }
}
