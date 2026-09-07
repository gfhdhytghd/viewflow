//! V3 stop-and-wait feedback on a dedicated reliable stream. This reports only
//! native API disposition, never physical scanout or fresh-input authority.
use anyhow::{Result, ensure};
use viewflow_protocol::AtlasFrame;

pub const RECORD_BYTES: usize = 73;

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
