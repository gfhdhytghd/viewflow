//! V3 stop-and-wait feedback on a dedicated reliable stream. This reports only
//! native API disposition, never physical scanout or fresh-input authority.
use anyhow::{Result, ensure};
use viewflow_protocol::AtlasFrame;

pub const RECORD_BYTES: usize = 73;

/// Keep one diagnostic record in one stderr write across Rust/C++ producers.
pub(crate) fn trace_line(args: std::fmt::Arguments<'_>) {
    use std::io::Write;
    let mut line = std::fmt::format(args);
    line.push('\n');
    let _ = std::io::stderr().lock().write_all(line.as_bytes());
}

/// Opt-in stage timing: `1` samples frames; `all` diagnoses periodic stalls.
pub(crate) fn trace_frame(frame: u64) -> bool {
    static MODE: std::sync::OnceLock<u8> = std::sync::OnceLock::new();
    let mode = *MODE.get_or_init(|| match std::env::var("VIEWFLOW_ATLAS_TIMINGS").as_deref() {
        Ok("1") => 1,
        Ok("all") => 2,
        _ => 0,
    });
    mode == 2 || (mode == 1 && (frame <= 8 || frame % 30 == 0))
}

/// Optional wall-clock sampling of QUIC counters, independent of frame work.
/// A delayed sample exposes runtime scheduling gaps. Counters describe QUIC
/// protocol processing; udp_tx is updated by poll_transmit before socket I/O.
/// They are neither socket completion nor NIC arrival/transmission timestamps.
pub(crate) struct ConnectionSampler(Option<tokio::task::JoinHandle<()>>);
impl Drop for ConnectionSampler {
    fn drop(&mut self) {
        if let Some(task) = &self.0 { task.abort(); }
    }
}
pub(crate) fn sample_connection(
    connection: &quinn::Connection,
    role: &'static str,
    now: impl Fn() -> Result<u64> + Send + 'static,
) -> ConnectionSampler {
    if std::env::var("VIEWFLOW_QUIC_POLL").as_deref() != Ok("1") {
        return ConnectionSampler(None);
    }
    let connection = connection.clone();
    ConnectionSampler(Some(tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_millis(5));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut previous = None;
        loop {
            tokio::select! {
                _ = connection.closed() => break,
                _ = interval.tick() => {}
            }
            let Ok(before_ns) = now() else { break; };
            let stats = connection.stats();
            let space = connection.datagram_send_buffer_space();
            let Ok(after_ns) = now() else { break; };
            let gap_ns = previous.map_or(0, |p| before_ns.saturating_sub(p));
            previous = Some(before_ns);
            trace_line(format_args!(
                "atlas-quic-sample role={role} before_ns={before_ns} after_ns={after_ns} gap_ns={gap_ns} rtt_us={} cwnd={} lost_packets={} congestion_events={} udp_tx={} udp_tx_bytes={} udp_rx={} udp_rx_bytes={} send_buffer_space={space}",
                stats.path.rtt.as_micros(), stats.path.cwnd, stats.path.lost_packets,
                stats.path.congestion_events, stats.udp_tx.datagrams, stats.udp_tx.bytes,
                stats.udp_rx.datagrams, stats.udp_rx.bytes));
        }
    })))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AtlasFrameDisposition {
    Committed,
    ExpiredUnbound,
}

/// Exact immutable identity of the pending frame is echoed, not a new timestamp.
/// # Errors
/// Invalid manifests are never eligible for recovery feedback.
pub fn encode(frame: &AtlasFrame, result: AtlasFrameDisposition) -> Result<[u8; RECORD_BYTES]> {
    frame
        .validate()
        .map_err(|error| anyhow::anyhow!("invalid feedback frame: {error:?}"))?;
    let mut bytes = [0; RECORD_BYTES];
    bytes[..4].copy_from_slice(b"VFD1");
    bytes[4..20].copy_from_slice(&frame.stream_id.0.to_be_bytes());
    for (index, value) in [
        frame.frame_id,
        frame.geometry_epoch,
        frame.config_generation,
        frame.layout_revision,
        frame.source_submitted_ns,
    ]
    .into_iter()
    .enumerate()
    {
        bytes[20 + index * 8..28 + index * 8].copy_from_slice(&value.to_be_bytes());
    }
    bytes[60..64].copy_from_slice(&u32::try_from(frame.tiles.len())?.to_be_bytes());
    // Bytes 64..72 are reserved and must remain zero in this version.
    bytes[72] = match result {
        AtlasFrameDisposition::Committed => 1,
        AtlasFrameDisposition::ExpiredUnbound => 2,
    };
    Ok(bytes)
}

/// # Errors
/// Rejects every mismatch, including unknown outcomes and nonzero reserved data.
pub fn decode(bytes: &[u8], pending: &AtlasFrame) -> Result<AtlasFrameDisposition> {
    ensure!(bytes.len() == RECORD_BYTES, "atlas feedback length");
    let result = match bytes[72] {
        1 => AtlasFrameDisposition::Committed,
        2 => AtlasFrameDisposition::ExpiredUnbound,
        _ => anyhow::bail!("unknown atlas feedback outcome"),
    };
    ensure!(
        bytes == encode(pending, result)?,
        "atlas feedback does not match pending frame"
    );
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_identity_and_reserved_bits_are_required() {
        let frame = AtlasFrame {
            patches: None,
            stream_id: viewflow_protocol::Id128(99),
            frame_id: 4,
            geometry_epoch: 1,
            config_generation: 1,
            layout_revision: 0,
            width: 2,
            height: 2,
            source_submitted_ns: 100,
            tiles: vec![],
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: None,
        };
        for outcome in [
            AtlasFrameDisposition::Committed,
            AtlasFrameDisposition::ExpiredUnbound,
        ] {
            let bytes = encode(&frame, outcome).unwrap();
            assert_eq!(decode(&bytes, &frame).unwrap(), outcome);
            for i in 0..RECORD_BYTES - 1 {
                let mut corrupted = bytes;
                corrupted[i] ^= 1;
                assert!(decode(&corrupted, &frame).is_err(), "byte {i}");
            }
            for invalid in [0, 3, 255] {
                let mut corrupted = bytes;
                corrupted[72] = invalid;
                assert!(decode(&corrupted, &frame).is_err());
            }
            assert!(decode(&bytes[..72], &frame).is_err());
        }
    }
}
