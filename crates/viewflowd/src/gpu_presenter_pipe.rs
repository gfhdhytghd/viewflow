//! Local VFGP v1/v2/v3 presenter pipe framing; not the network VFCD descriptor.
use anyhow::{Result, bail};

pub const HEADER_BYTES: usize = 40;

/// Encode a v5 or desktop-aware v7 atlas record for an explicitly atlas-capable
/// native presenter. The entire canonical layout is bound to the admitted
/// media and the original same-host QPC deadline. Ordinary single-window
/// presenters must reject these records.
/// # Errors
/// Rejects mismatched media identity, invalid tiles, alpha or resource limits.
pub fn encode_atlas_record(
    admitted: &crate::atlas_runtime::AdmittedAtlas,
    deadline: NativePresentationDeadline,
    max_record_bytes: usize,
) -> Result<Vec<u8>> {
    let layout = &admitted.layout;
    layout
        .validate()
        .map_err(|error| anyhow::anyhow!("invalid VFGP atlas: {error:?}"))?;
    let media = &admitted.media;
    if media.manifest.window_id != layout.stream_id
        || media.manifest.frame_id != layout.frame_id
        || media.manifest.geometry_epoch != layout.geometry_epoch
        || media.manifest.source_submitted_ns != layout.source_submitted_ns
    {
        bail!("VFGP atlas/media identity mismatch");
    }
    let alpha = media
        .alpha
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("VFGP atlas alpha missing"))?;
    let mut record = encode_deadline_alpha_record(
        layout.frame_id,
        layout.width,
        layout.height,
        &media.color,
        alpha,
        deadline,
        max_record_bytes,
    )?;
    let desktop = layout.desktop.as_ref();
    let desktop_bytes = desktop.map_or(0, |desktop| 48 + desktop.windows.len() * 56);
    let mut extension = Vec::with_capacity(56 + layout.tiles.len() * 64 + desktop_bytes);
    extension.extend_from_slice(&layout.stream_id.0.to_be_bytes());
    for value in [
        layout.geometry_epoch,
        layout.config_generation,
        layout.layout_revision,
        layout.source_submitted_ns,
    ] {
        extension.extend_from_slice(&value.to_be_bytes());
    }
    extension.extend_from_slice(&u32::try_from(layout.tiles.len())?.to_be_bytes());
    let flags = u32::from(layout.color_keyframe)
        | (u32::from(layout.alpha_keyframe) << 1)
        | (u32::from(layout.patches.is_some() && desktop.is_some()) << 2);
    extension.extend_from_slice(&flags.to_be_bytes());
    for tile in &layout.tiles {
        extension.extend_from_slice(&tile.window_id.0.to_be_bytes());
        for value in [
            tile.placement_generation,
            tile.geometry_epoch,
            tile.source_frame_id,
            tile.source_submitted_ns,
        ] {
            extension.extend_from_slice(&value.to_be_bytes());
        }
        for value in [tile.x, tile.y, tile.width, tile.height] {
            extension.extend_from_slice(&value.to_be_bytes());
        }
    }
    if let Some(desktop) = desktop {
        extension.extend_from_slice(&desktop.topology_generation.to_be_bytes());
        for value in [desktop.viewport.x_millidip, desktop.viewport.y_millidip] {
            extension.extend_from_slice(&value.to_be_bytes());
        }
        for value in [
            desktop.viewport.width_millidip,
            desktop.viewport.height_millidip,
        ] {
            extension.extend_from_slice(&value.to_be_bytes());
        }
        extension.extend_from_slice(&u32::try_from(desktop.windows.len())?.to_be_bytes());
        extension.extend_from_slice(&0_u32.to_be_bytes());
        for placement in &desktop.windows {
            extension.extend_from_slice(&placement.window_id.0.to_be_bytes());
            for value in [placement.bounds.x_millidip, placement.bounds.y_millidip] {
                extension.extend_from_slice(&value.to_be_bytes());
            }
            for value in [
                placement.bounds.width_millidip,
                placement.bounds.height_millidip,
            ] {
                extension.extend_from_slice(&value.to_be_bytes());
            }
            extension.extend_from_slice(
                &(u32::from(placement.movable) | (placement.raise_serial << 1)).to_be_bytes(),
            );
            extension.extend_from_slice(&placement.z_order.to_be_bytes());
        }
    }
    if let Some(patches) = &layout.patches {
        extension.extend_from_slice(&u32::try_from(patches.len())?.to_be_bytes());
        extension.extend_from_slice(&0u32.to_be_bytes());
        for p in patches {
            for value in [
                p.tile_index,
                p.source_x,
                p.source_y,
                p.x,
                p.y,
                p.width,
                p.height,
            ] {
                extension.extend_from_slice(&value.to_be_bytes());
            }
        }
    }
    if record
        .len()
        .checked_add(extension.len())
        .is_none_or(|size| size > max_record_bytes)
    {
        bail!("VFGP atlas header exceeds record limit");
    }
    record[4] = if layout.patches.is_some() {
        8
    } else if desktop.is_some() {
        7
    } else {
        5
    };
    record[8..12].copy_from_slice(&u32::try_from(56 + extension.len())?.to_be_bytes());
    record.splice(56..56, extension);
    Ok(record)
}

/// Same-Windows-host absolute QPC deadline, never a cross-host timestamp.
#[derive(Clone, Copy, Debug)]
pub struct NativePresentationDeadline {
    pub ticks: u64,
    pub frequency: u64,
}

impl NativePresentationDeadline {
    /// Derive one fixed same-host QPC deadline. Sample QPC before computing
    /// `remaining_ns` from the original source deadline, never after it.
    /// Fractional ticks are discarded so conversion cannot extend admission.
    ///
    /// # Errors
    /// Rejects zero frequency/budget, sub-tick budget, and arithmetic overflow.
    pub fn from_remaining_budget(
        sample_ticks: u64,
        frequency: u64,
        remaining_ns: u64,
    ) -> Result<Self> {
        if frequency == 0 || remaining_ns == 0 {
            bail!("native deadline requires a nonzero frequency and budget");
        }
        let budget = remaining_ns
            .checked_mul(frequency)
            .ok_or_else(|| anyhow::anyhow!("native deadline conversion overflow"))?
            / 1_000_000_000;
        if budget == 0 {
            bail!("native deadline budget is below one QPC tick");
        }
        let ticks = sample_ticks
            .checked_add(budget)
            .ok_or_else(|| anyhow::anyhow!("native absolute deadline overflow"))?;
        Ok(Self { ticks, frequency })
    }
}

/// Encode an explicitly deadline-protected v4 live record. This is not used
/// by the live writer until the native presenter opts into expiry enforcement.
/// The caller must derive the fixed deadline from the original source budget.
///
/// # Errors
/// Rejects zero deadline/frequency, invalid planes, or total/decoded size limits.
pub fn encode_deadline_alpha_record(
    identity: u64,
    width: u32,
    height: u32,
    color_annex_b: &[u8],
    alpha_vfar: &bytes::Bytes,
    deadline: NativePresentationDeadline,
    max_record_bytes: usize,
) -> Result<Vec<u8>> {
    if deadline.ticks == 0 || deadline.frequency == 0 {
        bail!("VFGP native deadline and frequency must be nonzero");
    }
    let mut record = encode_compressed_alpha_record(
        identity,
        width,
        height,
        color_annex_b,
        alpha_vfar,
        max_record_bytes,
    )?;
    if record
        .len()
        .checked_add(16)
        .is_none_or(|size| size > max_record_bytes)
    {
        bail!("VFGP deadline header exceeds record limit");
    }
    record[4] = 4;
    record[8..12].copy_from_slice(&56_u32.to_be_bytes());
    record.splice(
        HEADER_BYTES..HEADER_BYTES,
        deadline
            .ticks
            .to_be_bytes()
            .into_iter()
            .chain(deadline.frequency.to_be_bytes()),
    );
    Ok(record)
}

/// Forward checked VFAR to a v2 presenter without expanding it on this side.
/// Identity and source freshness must already be admitted by the caller.
///
/// # Errors
/// Rejects malformed VFAR, mismatched geometry, and encoded/decoded overruns.
pub fn encode_compressed_alpha_record(
    identity: u64,
    width: u32,
    height: u32,
    color_annex_b: &[u8],
    alpha_vfar: &bytes::Bytes,
    max_record_bytes: usize,
) -> Result<Vec<u8>> {
    let dimensions = viewflow_transport::validate_alpha_rle(
        alpha_vfar.clone(),
        viewflow_transport::AlphaRleLimits {
            max_coded_width: width,
            max_coded_height: height,
            max_luma_samples: u64::from(width) * u64::from(height),
            max_decoded_bytes: u64::try_from(max_record_bytes)?,
            max_encoded_bytes: max_record_bytes,
        },
    )?;
    if dimensions != (width, height) {
        bail!("VFGP alpha geometry differs from admitted color");
    }
    encode_planes(
        2,
        identity,
        width,
        height,
        color_annex_b,
        alpha_vfar,
        max_record_bytes,
    )
}

/// Encode one startup-only H.264/VFAR pair. VFGP v3 is an explicit native
/// decode-only contract: its output may warm decoder state but cannot be
/// composed or counted as a presenter submission.
///
/// # Errors
///
/// Rejects invalid or over-budget VFAR/color input and geometry mismatch.
pub fn encode_compressed_alpha_decode_only_record(
    identity: u64,
    width: u32,
    height: u32,
    color_annex_b: &[u8],
    alpha_vfar: &bytes::Bytes,
    max_record_bytes: usize,
) -> Result<Vec<u8>> {
    let dimensions = viewflow_transport::validate_alpha_rle(
        alpha_vfar.clone(),
        viewflow_transport::AlphaRleLimits {
            max_coded_width: width,
            max_coded_height: height,
            max_luma_samples: u64::from(width) * u64::from(height),
            max_decoded_bytes: u64::try_from(max_record_bytes)?,
            max_encoded_bytes: max_record_bytes,
        },
    )?;
    if dimensions != (width, height) {
        bail!("VFGP alpha geometry differs from warmup color");
    }
    encode_planes(
        3,
        identity,
        width,
        height,
        color_annex_b,
        alpha_vfar,
        max_record_bytes,
    )
}

/// Convert an already matched, admitted H.264/VFAR pair to the local pipe.
/// The transport caller must validate window/frame/epoch identity and freshness
/// before calling; this function additionally checks decoded alpha geometry.
///
/// # Errors
/// Rejects malformed or over-budget VFAR, geometry mismatch, and invalid VFGP.
pub fn encode_lossless_alpha_record(
    identity: u64,
    width: u32,
    height: u32,
    color_annex_b: &[u8],
    alpha_vfar: bytes::Bytes,
    max_record_bytes: usize,
) -> Result<Vec<u8>> {
    let samples = u64::from(width) * u64::from(height);
    let decoded = viewflow_transport::decode_alpha_rle(
        alpha_vfar,
        viewflow_transport::AlphaRleLimits {
            max_coded_width: width,
            max_coded_height: height,
            max_luma_samples: samples,
            max_decoded_bytes: u64::try_from(max_record_bytes)?,
            max_encoded_bytes: max_record_bytes,
        },
    )?;
    if decoded.width != width || decoded.height != height {
        bail!("VFGP alpha geometry differs from admitted color");
    }
    encode_record(
        identity,
        width,
        height,
        color_annex_b,
        &decoded.samples,
        max_record_bytes,
    )
}

/// Validate lengths before allocating a local GPU-presenter record.
/// The resource limit covers the header and payload, not a resolution ceiling.
///
/// # Errors
/// Rejects zero identities, empty color, invalid alpha geometry, overflow, or
/// records exceeding the caller's resource limit. Stream identity ordering is
/// the caller's responsibility; the native reader also enforces it.
pub fn encode_record(
    identity: u64,
    width: u32,
    height: u32,
    color_annex_b: &[u8],
    alpha_gray8: &[u8],
    max_record_bytes: usize,
) -> Result<Vec<u8>> {
    let alpha_size = u64::from(width) * u64::from(height);
    if identity == 0
        || width == 0
        || height == 0
        || color_annex_b.is_empty()
        || u64::try_from(alpha_gray8.len())? != alpha_size
    {
        bail!("invalid VFGP identity, geometry, or plane length");
    }
    encode_planes(
        1,
        identity,
        width,
        height,
        color_annex_b,
        alpha_gray8,
        max_record_bytes,
    )
}

fn encode_planes(
    version: u8,
    identity: u64,
    width: u32,
    height: u32,
    color_annex_b: &[u8],
    alpha: &[u8],
    max_record_bytes: usize,
) -> Result<Vec<u8>> {
    if identity == 0 || width == 0 || height == 0 || color_annex_b.is_empty() {
        bail!("invalid VFGP identity, geometry, or color length");
    }
    let color_len = u32::try_from(color_annex_b.len())?;
    let alpha_len = u32::try_from(alpha.len())?;
    let payload_len = color_len
        .checked_add(alpha_len)
        .ok_or_else(|| anyhow::anyhow!("VFGP payload overflow"))?;
    let total = usize::try_from(payload_len)?
        .checked_add(HEADER_BYTES)
        .ok_or_else(|| anyhow::anyhow!("VFGP record overflow"))?;
    if total > max_record_bytes {
        bail!("VFGP record exceeds resource limit");
    }
    let mut record = Vec::with_capacity(total);
    record.extend_from_slice(&[
        b'V',
        b'F',
        b'G',
        b'P',
        version,
        u8::from(version == 3),
        0,
        0,
    ]);
    record.extend_from_slice(&40_u32.to_be_bytes());
    record.extend_from_slice(&payload_len.to_be_bytes());
    record.extend_from_slice(&identity.to_be_bytes());
    for field in [width, height, color_len, alpha_len] {
        record.extend_from_slice(&field.to_be_bytes());
    }
    record.extend_from_slice(color_annex_b);
    record.extend_from_slice(alpha);
    Ok(record)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atlas_record_preserves_identity_tiles_and_deadline() {
        use viewflow_protocol::{AtlasFrame, AtlasTile, FrameManifest, Id128};
        let mut admitted = crate::atlas_runtime::AdmittedAtlas {
            layout: AtlasFrame {
                patches: None,
                stream_id: Id128(99),
                frame_id: 9,
                geometry_epoch: 3,
                config_generation: 4,
                layout_revision: 5,
                width: 4,
                height: 2,
                source_submitted_ns: 100,
                color_keyframe: true,
                alpha_keyframe: true,
                desktop: None,
                tiles: (0..2)
                    .map(|i| AtlasTile {
                        window_id: Id128(u128::from(i + 1)),
                        placement_generation: 5,
                        geometry_epoch: 3,
                        source_frame_id: u64::from(i + 7),
                        source_submitted_ns: u64::from(i + 100),
                        x: i * 2,
                        y: 0,
                        width: 2,
                        height: 2,
                    })
                    .collect(),
            },
            media: crate::media_runtime::EncodedFrame {
                manifest: FrameManifest {
                    window_id: Id128(99),
                    frame_id: 9,
                    geometry_epoch: 3,
                    source_submitted_ns: 100,
                    received_ns: 110,
                },
                color: bytes::Bytes::from_static(&[0, 0, 1, 0x65]),
                alpha: Some(viewflow_transport::encode_alpha_rle(4, 2, &[7; 8]).unwrap()),
            },
        };
        let deadline = NativePresentationDeadline {
            ticks: 1000,
            frequency: 10_000_000,
        };
        let record = encode_atlas_record(&admitted, deadline, 4096).unwrap();
        assert_eq!(record[4], 5);
        assert_eq!(&record[8..12], &240_u32.to_be_bytes());
        assert_eq!(&record[40..48], &1000_u64.to_be_bytes());
        assert_eq!(&record[56..72], &99_u128.to_be_bytes());
        assert_eq!(&record[104..108], &2_u32.to_be_bytes());
        assert_eq!(&record[112..128], &1_u128.to_be_bytes());
        assert_eq!(&record[176..192], &2_u128.to_be_bytes());
        assert_eq!(&record[240..244], &[0, 0, 1, 0x65]);
        assert!(encode_atlas_record(&admitted, deadline, record.len() - 1).is_err());
        if let Some(path) = std::env::var_os("VIEWFLOW_ATLAS_TEST_FIXTURE") {
            std::fs::write(path, &record).unwrap();
        }
        admitted.media.manifest.frame_id += 1;
        assert!(encode_atlas_record(&admitted, deadline, 4096).is_err());
        admitted.media.manifest.frame_id -= 1;
        admitted.layout.tiles[1].x = 1;
        assert!(encode_atlas_record(&admitted, deadline, 4096).is_err());
    }

    #[test]
    fn desktop_layout_selects_v7_and_keeps_v5_byte_exact_when_absent() {
        use viewflow_protocol::{
            AtlasDesktopLayout, AtlasFrame, AtlasTile, AtlasWindowPlacement, DesktopRect,
            FrameManifest, Id128,
        };

        let mut admitted = crate::atlas_runtime::AdmittedAtlas {
            layout: AtlasFrame {
                patches: None,
                stream_id: Id128(99),
                frame_id: 9,
                geometry_epoch: 3,
                config_generation: 4,
                layout_revision: 5,
                width: 4,
                height: 2,
                source_submitted_ns: 100,
                color_keyframe: true,
                alpha_keyframe: true,
                desktop: None,
                tiles: (0..2)
                    .map(|i| AtlasTile {
                        window_id: Id128(u128::from(i + 1)),
                        placement_generation: 5,
                        geometry_epoch: 3,
                        source_frame_id: u64::from(i + 7),
                        source_submitted_ns: u64::from(i + 100),
                        x: i * 2,
                        y: 0,
                        width: 2,
                        height: 2,
                    })
                    .collect(),
            },
            media: crate::media_runtime::EncodedFrame {
                manifest: FrameManifest {
                    window_id: Id128(99),
                    frame_id: 9,
                    geometry_epoch: 3,
                    source_submitted_ns: 100,
                    received_ns: 110,
                },
                color: bytes::Bytes::from_static(&[0, 0, 1, 0x65]),
                alpha: Some(viewflow_transport::encode_alpha_rle(4, 2, &[7; 8]).unwrap()),
            },
        };
        let deadline = NativePresentationDeadline {
            ticks: 1000,
            frequency: 10_000_000,
        };
        let v5 = encode_atlas_record(&admitted, deadline, 4096).unwrap();
        assert_eq!(v5[4], 5);
        assert_eq!(&v5[8..12], &240_u32.to_be_bytes());
        admitted.layout.desktop = Some(AtlasDesktopLayout {
            topology_generation: 6,
            viewport: DesktopRect {
                x_millidip: -100,
                y_millidip: 200,
                width_millidip: 400,
                height_millidip: 300,
            },
            windows: vec![
                AtlasWindowPlacement {
                    window_id: Id128(1),
                    bounds: DesktopRect {
                        x_millidip: -100,
                        y_millidip: 200,
                        width_millidip: 200,
                        height_millidip: 300,
                    },
                    movable: true,
                    z_order: 7,
                    raise_serial: 1,
                },
                AtlasWindowPlacement {
                    window_id: Id128(2),
                    bounds: DesktopRect {
                        x_millidip: 100,
                        y_millidip: 200,
                        width_millidip: 200,
                        height_millidip: 300,
                    },
                    movable: false,
                    z_order: 0,
                    raise_serial: 0,
                },
            ],
        });
        let v7 = encode_atlas_record(&admitted, deadline, 4096).unwrap();
        assert_eq!(v7[4], 7);
        assert_eq!(&v7[8..12], &400_u32.to_be_bytes());
        // V7 changes only the version/header-length declaration before the
        // unchanged V5 base and tile records.
        assert_eq!(&v7[..4], &v5[..4]);
        assert_eq!(&v7[5..8], &v5[5..8]);
        assert_eq!(&v7[12..112 + 2 * 64], &v5[12..112 + 2 * 64]);
        let desktop = 112 + 2 * 64;
        assert_eq!(&v7[desktop..desktop + 8], &6_u64.to_be_bytes());
        assert_eq!(&v7[desktop + 8..desktop + 16], &(-100_i64).to_be_bytes());
        assert_eq!(&v7[desktop + 16..desktop + 24], &200_i64.to_be_bytes());
        assert_eq!(&v7[desktop + 24..desktop + 32], &400_u64.to_be_bytes());
        assert_eq!(&v7[desktop + 32..desktop + 40], &300_u64.to_be_bytes());
        assert_eq!(&v7[desktop + 40..desktop + 44], &2_u32.to_be_bytes());
        assert_eq!(&v7[desktop + 44..desktop + 48], &[0; 4]);
        let first = desktop + 48;
        assert_eq!(&v7[first..first + 16], &1_u128.to_be_bytes());
        assert_eq!(&v7[first + 16..first + 24], &(-100_i64).to_be_bytes());
        assert_eq!(&v7[first + 48..first + 52], &3_u32.to_be_bytes());
        assert_eq!(&v7[first + 52..first + 56], &7_u32.to_be_bytes());
        let second = first + 56;
        assert_eq!(&v7[second..second + 16], &2_u128.to_be_bytes());
        assert_eq!(&v7[second + 48..second + 52], &[0; 4]);
        assert_eq!(&v7[400..], &v5[240..]);
        assert!(encode_atlas_record(&admitted, deadline, v7.len() - 1).is_err());
    }

    #[test]
    fn native_qpc_budget_matches_conservative_cpp_conversion() {
        let deadline =
            NativePresentationDeadline::from_remaining_budget(1_000, 10_000_000, 33_333_333)
                .unwrap();
        assert_eq!(deadline.ticks, 334_333);
        assert_eq!(deadline.frequency, 10_000_000);
        for (ticks, frequency, budget) in [
            (0, 0, 1),
            (0, 1, 0),
            (0, 10_000_000, 1),
            (u64::MAX, 10_000_000, 100),
            (0, 2, u64::MAX),
        ] {
            assert!(
                NativePresentationDeadline::from_remaining_budget(ticks, frequency, budget)
                    .is_err()
            );
        }
    }

    #[test]
    fn deadline_v4_has_exact_layout_and_cannot_omit_budget() {
        let alpha = viewflow_transport::encode_alpha_rle(2, 2, &[7; 4]).unwrap();
        let color = [0, 0, 1, 0x65];
        let deadline = NativePresentationDeadline {
            ticks: 0x0102_0304_0506_0708,
            frequency: 10_000_000,
        };
        let record = encode_deadline_alpha_record(9, 2, 2, &color, &alpha, deadline, 128).unwrap();
        assert_eq!(&record[..8], b"VFGP\x04\0\0\0");
        assert_eq!(&record[8..12], &56_u32.to_be_bytes());
        assert_eq!(&record[40..48], &deadline.ticks.to_be_bytes());
        assert_eq!(&record[48..56], &deadline.frequency.to_be_bytes());
        assert_eq!(&record[56..60], &color);
        assert_eq!(&record[60..], alpha.as_ref());
        assert!(
            encode_deadline_alpha_record(9, 2, 2, &color, &alpha, deadline, record.len()).is_ok()
        );
        assert!(
            encode_deadline_alpha_record(9, 2, 2, &color, &alpha, deadline, record.len() - 1)
                .is_err()
        );
        for invalid in [
            NativePresentationDeadline {
                ticks: 0,
                ..deadline
            },
            NativePresentationDeadline {
                frequency: 0,
                ..deadline
            },
        ] {
            assert!(encode_deadline_alpha_record(9, 2, 2, &color, &alpha, invalid, 128).is_err());
        }
    }

    #[test]
    fn compressed_v2_forwards_exact_vfar_and_bounds_decoded_size() {
        let alpha = viewflow_transport::encode_alpha_rle(64, 64, &[137; 4096]).unwrap();
        let color = [0, 0, 1, 0x65];
        let record = encode_compressed_alpha_record(7, 64, 64, &color, &alpha, 8192).unwrap();
        assert_eq!(&record[..8], b"VFGP\x02\0\0\0");
        assert_eq!(&record[44..], alpha.as_ref());
        assert!(record.len() < 256);
        assert!(encode_compressed_alpha_record(7, 64, 64, &color, &alpha, 256).is_err());
        assert!(encode_compressed_alpha_record(7, 32, 128, &color, &alpha, 8192).is_err());
        let mut bad = alpha.to_vec();
        bad.push(0);
        assert!(encode_compressed_alpha_record(7, 64, 64, &color, &bad.into(), 8192).is_err());
    }

    #[test]
    fn decode_only_v3_is_distinct_from_live_v2() {
        let alpha = viewflow_transport::encode_alpha_rle(2, 2, &[7; 4]).unwrap();
        let record =
            encode_compressed_alpha_decode_only_record(9, 2, 2, &[0, 0, 1, 0x65], &alpha, 128)
                .unwrap();
        assert_eq!(&record[..8], b"VFGP\x03\x01\0\0");
    }

    #[test]
    fn lossless_plane_reaches_pipe_unchanged_and_mismatch_is_rejected() {
        let alpha = viewflow_transport::encode_alpha_rle(8, 8, &[137; 64]).unwrap();
        let record =
            encode_lossless_alpha_record(1, 8, 8, &[0, 0, 1, 0x65], alpha.clone(), 108).unwrap();
        assert_eq!(&record[44..], &[137; 64]);
        assert!(encode_lossless_alpha_record(1, 9, 8, &[1], alpha.clone(), 1024).is_err());
        assert!(encode_lossless_alpha_record(1, 8, 8, &[1], alpha, 64).is_err());
    }

    #[test]
    fn exact_header_and_plane_order() {
        let color = [0, 0, 1, 0x65];
        let record = encode_record(0x0102, 2, 1, &color, &[0, 255], 46).unwrap();
        assert_eq!(&record[..8], b"VFGP\x01\0\0\0");
        assert_eq!(&record[8..16], &[0, 0, 0, 40, 0, 0, 0, 6]);
        assert_eq!(&record[16..24], &0x0102_u64.to_be_bytes());
        assert_eq!(
            &record[24..40],
            &[0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 2]
        );
        assert_eq!(&record[40..], &[0, 0, 1, 0x65, 0, 255]);
    }

    #[test]
    fn rejects_invalid_geometry_and_exact_resource_overrun() {
        assert!(encode_record(1, 2, 1, &[1], &[0, 255], 42).is_err());
        assert!(encode_record(0, 2, 1, &[1], &[0, 255], 43).is_err());
        assert!(encode_record(1, u32::MAX, u32::MAX, &[1], &[0], usize::MAX).is_err());
        assert!(encode_record(1, 2, 1, &[], &[0, 255], 43).is_err());
    }
}
