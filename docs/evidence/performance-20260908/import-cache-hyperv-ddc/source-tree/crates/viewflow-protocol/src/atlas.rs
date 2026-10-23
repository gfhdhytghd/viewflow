//! Frame-bound layout metadata. Acceptance requires a negotiated atlas runtime;
//! parsing alone never creates a proxy, a media admission or input authorization.
use crate::{AtlasDesktopLayout, Id128, WindowId, WireError, required_id, wire};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AtlasTile {
    pub window_id: WindowId,
    pub placement_generation: u64,
    pub geometry_epoch: u64,
    pub source_frame_id: u64,
    /// Receiver-session clock, not the source machine's raw clock.
    pub source_submitted_ns: u64,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

/// A resident image region. Empty patch lists retain native window ownership
/// without allocating pixels for completely hidden or transparent windows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct AtlasPatch {
    pub tile_index: u32,
    pub source_x: u32,
    pub source_y: u32,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AtlasFrame {
    pub stream_id: Id128,
    pub frame_id: u64,
    pub geometry_epoch: u64,
    pub config_generation: u64,
    pub layout_revision: u64,
    pub width: u32,
    pub height: u32,
    /// Must equal the oldest tile timestamp for nonempty layouts.
    pub source_submitted_ns: u64,
    /// Canonical ascending window ID order, at most 4096 entries.
    pub tiles: Vec<AtlasTile>,
    pub color_keyframe: bool,
    pub alpha_keyframe: bool,
    /// Optional immutable logical desktop placement for every tile in this frame.
    pub desktop: Option<AtlasDesktopLayout>,
    /// None is the legacy whole-window allocation. Some is sparse v2.
    pub patches: Option<Vec<AtlasPatch>>,
}

impl AtlasFrame {
    /// # Errors
    /// Rejects invalid identities, noncanonical membership, overlaps, overflow,
    /// out-of-bounds pixels and attempts to renew an older tile's timestamp.
    pub fn validate(&self) -> Result<(), WireError> {
        let invalid = || WireError::InvalidField("atlas_frame");
        if self.stream_id.0 == 0
            || self.frame_id == 0
            || self.geometry_epoch == 0
            || self.config_generation == 0
            || self.source_submitted_ns == 0
            || self.width == 0
            || self.height == 0
            || self.width % 2 != 0
            || self.height % 2 != 0
            || self.tiles.len() > 4096
            || self.patches.as_ref().is_some_and(|p| p.len() > 32768)
        {
            return Err(invalid());
        }
        let mut previous = None;
        for tile in &self.tiles {
            if tile.window_id.0 == 0
                || tile.window_id == self.stream_id
                || previous.is_some_and(|id| id >= tile.window_id)
                || tile.placement_generation == 0
                || tile.placement_generation > self.layout_revision
                || tile.geometry_epoch == 0
                || tile.source_frame_id == 0
                || tile.width == 0
                || tile.height == 0
                || tile.source_submitted_ns < self.source_submitted_ns
                || (self.patches.is_none()
                    && (tile
                        .x
                        .checked_add(tile.width)
                        .is_none_or(|right| right > self.width)
                        || tile
                            .y
                            .checked_add(tile.height)
                            .is_none_or(|bottom| bottom > self.height)))
                || (self.patches.is_some()
                    && (tile.x != 0 || tile.y != 0 || tile.width > 8192 || tile.height > 4096))
            {
                return Err(invalid());
            }
            previous = Some(tile.window_id);
        }
        if self
            .tiles
            .iter()
            .map(|tile| tile.source_submitted_ns)
            .min()
            .is_some_and(|oldest| oldest != self.source_submitted_ns)
        {
            return Err(invalid());
        }
        if let Some(patches) = &self.patches {
            self.validate_patches(patches)?;
        } else {
            for (i, a) in self.tiles.iter().enumerate() {
                for b in &self.tiles[..i] {
                    if a.x < b.x + b.width
                        && b.x < a.x + a.width
                        && a.y < b.y + b.height
                        && b.y < a.y + a.height
                    {
                        return Err(invalid());
                    }
                }
            }
        }
        if let Some(desktop) = &self.desktop {
            desktop.validate_tiles(&self.tiles)?;
        }
        Ok(())
    }
    fn validate_patches(&self, patches: &[AtlasPatch]) -> Result<(), WireError> {
        let invalid = || WireError::InvalidField("atlas_frame.patches");
        let mut previous = None;
        let mut occupied = std::collections::BTreeSet::new();
        let mut active_x = std::collections::BTreeMap::<u32, u32>::new();
        let mut expiry_y = std::collections::BTreeSet::<(u32, u32)>::new();
        for (index, p) in patches.iter().enumerate() {
            let key = (p.tile_index, p.source_y, p.source_x);
            let Some(tile) = self.tiles.get(p.tile_index as usize) else {
                return Err(invalid());
            };
            if previous.is_some_and(|old| old >= key)
                || p.width == 0
                || p.height == 0
                || p.width > 128
                || p.height > 128
                || p.x % 128 != 0
                || p.y % 128 != 0
                || p.x.checked_add(p.width).is_none_or(|x| x > self.width)
                || p.y.checked_add(p.height).is_none_or(|y| y > self.height)
                || p.source_x
                    .checked_add(p.width)
                    .is_none_or(|x| x > tile.width)
                || p.source_y
                    .checked_add(p.height)
                    .is_none_or(|y| y > tile.height)
                || !occupied.insert((p.x, p.y))
            {
                return Err(invalid());
            }
            if patches.len() <= 128 {
                if patches[..index]
                    .iter()
                    .rev()
                    .take_while(|q| q.tile_index == p.tile_index)
                    .any(|q| {
                        p.source_x < q.source_x + q.width
                            && q.source_x < p.source_x + p.width
                            && p.source_y < q.source_y + q.height
                            && q.source_y < p.source_y + p.height
                    })
                {
                    return Err(invalid());
                }
            } else {
                // Accepted rectangles crossing this source-y scanline have
                // disjoint x intervals. Only the two neighbours can overlap.
                if previous.is_some_and(|old: (u32, u32, u32)| old.0 != p.tile_index) {
                    active_x.clear();
                    expiry_y.clear();
                }
                while let Some(&(bottom, x)) = expiry_y.first() {
                    if bottom > p.source_y {
                        break;
                    }
                    expiry_y.pop_first();
                    active_x.remove(&x);
                }
                let right = p.source_x + p.width; // checked above
                if active_x
                    .range(p.source_x..)
                    .next()
                    .is_some_and(|(&x, _)| x < right)
                    || active_x
                        .range(..p.source_x)
                        .next_back()
                        .is_some_and(|(_, &end)| end > p.source_x)
                {
                    return Err(invalid());
                }
                active_x.insert(p.source_x, right);
                expiry_y.insert((p.source_y + p.height, p.source_x));
            }
            previous = Some(key);
        }
        Ok(())
    }
}

impl TryFrom<wire::AtlasFrame> for AtlasFrame {
    type Error = WireError;
    fn try_from(value: wire::AtlasFrame) -> Result<Self, Self::Error> {
        if !matches!(value.version, 1 | 2)
            || (value.version == 2) != value.patches.is_some()
            || value.tiles.len() > 4096
        {
            return Err(WireError::InvalidField("atlas_frame.version_or_count"));
        }
        let frame = Self {
            stream_id: required_id(value.stream_id, "atlas_frame.stream_id")?,
            color_keyframe: value.color_keyframe,
            alpha_keyframe: value.alpha_keyframe,
            frame_id: value.frame_id,
            geometry_epoch: value.geometry_epoch,
            config_generation: value.config_generation,
            layout_revision: value.layout_revision,
            width: value.width,
            height: value.height,
            source_submitted_ns: value.source_submitted_ns,
            tiles: value
                .tiles
                .into_iter()
                .map(|tile| {
                    Ok(AtlasTile {
                        window_id: required_id(tile.window_id, "atlas_tile.window_id")?,
                        placement_generation: tile.placement_generation,
                        geometry_epoch: tile.geometry_epoch,
                        source_frame_id: tile.source_frame_id,
                        source_submitted_ns: tile.source_submitted_ns,
                        x: tile.x,
                        y: tile.y,
                        width: tile.width,
                        height: tile.height,
                    })
                })
                .collect::<Result<_, WireError>>()?,
            desktop: value.desktop.map(TryInto::try_into).transpose()?,
            patches: value.patches.map(|list| {
                list.patches
                    .into_iter()
                    .map(|p| AtlasPatch {
                        tile_index: p.tile_index,
                        source_x: p.source_x,
                        source_y: p.source_y,
                        x: p.x,
                        y: p.y,
                        width: p.width,
                        height: p.height,
                    })
                    .collect()
            }),
        };
        frame.validate()?;
        Ok(frame)
    }
}

impl From<AtlasFrame> for wire::AtlasFrame {
    #[allow(clippy::cast_possible_truncation)] // Split the exact high/low 64 bits.
    fn from(value: AtlasFrame) -> Self {
        let id = |value: Id128| wire::Id128 {
            high: (value.0 >> 64) as u64,
            low: value.0 as u64,
        };
        Self {
            version: if value.patches.is_some() { 2 } else { 1 },
            color_keyframe: value.color_keyframe,
            alpha_keyframe: value.alpha_keyframe,
            desktop: value.desktop.map(Into::into),
            patches: value.patches.map(|list| wire::AtlasPatches {
                patches: list
                    .into_iter()
                    .map(|p| wire::AtlasPatch {
                        tile_index: p.tile_index,
                        source_x: p.source_x,
                        source_y: p.source_y,
                        x: p.x,
                        y: p.y,
                        width: p.width,
                        height: p.height,
                    })
                    .collect(),
            }),
            stream_id: Some(id(value.stream_id)),
            frame_id: value.frame_id,
            geometry_epoch: value.geometry_epoch,
            config_generation: value.config_generation,
            layout_revision: value.layout_revision,
            width: value.width,
            height: value.height,
            source_submitted_ns: value.source_submitted_ns,
            tiles: value
                .tiles
                .into_iter()
                .map(|tile| wire::AtlasTile {
                    window_id: Some(id(tile.window_id)),
                    placement_generation: tile.placement_generation,
                    geometry_epoch: tile.geometry_epoch,
                    source_frame_id: tile.source_frame_id,
                    source_submitted_ns: tile.source_submitted_ns,
                    x: tile.x,
                    y: tile.y,
                    width: tile.width,
                    height: tile.height,
                })
                .collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn validate_patches_reference(
        frame: &AtlasFrame,
        patches: &[AtlasPatch],
    ) -> Result<(), WireError> {
        let invalid = || WireError::InvalidField("atlas_frame.patches");
        let mut previous = None;
        let mut occupied = std::collections::BTreeSet::new();
        let mut destinations: std::collections::BTreeMap<u32, Vec<&AtlasPatch>> =
            Default::default();
        for p in patches {
            let key = (p.tile_index, p.source_y, p.source_x);
            let Some(tile) = frame.tiles.get(p.tile_index as usize) else {
                return Err(invalid());
            };
            if previous.is_some_and(|old| old >= key)
                || p.width == 0
                || p.height == 0
                || p.width > 128
                || p.height > 128
                || p.x % 128 != 0
                || p.y % 128 != 0
                || p.x.checked_add(p.width).is_none_or(|x| x > frame.width)
                || p.y.checked_add(p.height).is_none_or(|y| y > frame.height)
                || p.source_x
                    .checked_add(p.width)
                    .is_none_or(|x| x > tile.width)
                || p.source_y
                    .checked_add(p.height)
                    .is_none_or(|y| y > tile.height)
                || !occupied.insert((p.x, p.y))
            {
                return Err(invalid());
            }
            let others = destinations.entry(p.tile_index).or_default();
            if others.iter().any(|q| {
                p.source_x < q.source_x + q.width
                    && q.source_x < p.source_x + p.width
                    && p.source_y < q.source_y + q.height
                    && q.source_y < p.source_y + p.height
            }) {
                return Err(invalid());
            }
            others.push(p);
            previous = Some(key);
        }
        Ok(())
    }
    #[test]
    fn sparse_windows_keep_full_geometry_and_only_resident_patches_use_capacity() {
        let mut f = frame();
        f.width = 256;
        f.height = 128;
        for t in &mut f.tiles {
            t.x = 0;
            t.y = 0;
            t.width = 1024;
            t.height = 768;
        }
        f.patches = Some(vec![
            AtlasPatch {
                tile_index: 0,
                source_x: 256,
                source_y: 128,
                x: 0,
                y: 0,
                width: 128,
                height: 128,
            },
            AtlasPatch {
                tile_index: 1,
                source_x: 0,
                source_y: 0,
                x: 128,
                y: 0,
                width: 128,
                height: 128,
            },
        ]);
        assert!(f.validate().is_ok());
        let wire: wire::AtlasFrame = f.clone().into();
        assert_eq!(wire.version, 2);
        assert_eq!(AtlasFrame::try_from(wire).unwrap(), f);
        let mut bad = f.clone();
        bad.patches.as_mut().unwrap()[1].x = 0;
        assert!(bad.validate().is_err());
        let mut bad = f.clone();
        bad.patches.as_mut().unwrap()[0].source_x = 1000;
        assert!(bad.validate().is_err());
        let mut bad = f.clone();
        bad.patches.as_mut().unwrap().reverse();
        assert!(bad.validate().is_err());
        f.patches = Some(vec![]);
        assert!(f.validate().is_ok()); // both HWNDs survive complete occlusion
        f.patches = None;
        assert!(f.validate().is_err()); // legacy full geometry cannot masquerade as sparse
    }

    #[test]
    fn sparse_sweep_matches_pairwise_reference() {
        let mut f = frame();
        f.width = 16384;
        f.height = 32768;
        for tile in &mut f.tiles {
            tile.width = u32::MAX;
            tile.height = u32::MAX;
        }
        let mut seed = 71231_u64;
        let mut random = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed as u32
        };
        for trial in 0..10000 {
            let count = (random() % 300) as usize;
            let mut patches = Vec::new();
            for i in 0..count {
                let grid = trial % 2 == 0;
                patches.push(AtlasPatch {
                    tile_index: random() % 2,
                    source_x: if grid {
                        (i as u32 % 10) * 128
                    } else {
                        random() % 512
                    },
                    source_y: if grid {
                        (i as u32 / 10) * 128
                    } else {
                        random() % 512
                    },
                    x: (i as u32 % 128) * 128,
                    y: (i as u32 / 128) * 128,
                    width: 1 + random() % 128,
                    height: 1 + random() % 128,
                });
            }
            patches.sort_by_key(|p| (p.tile_index, p.source_y, p.source_x));
            assert_eq!(
                f.validate_patches(&patches).is_ok(),
                validate_patches_reference(&f, &patches).is_ok(),
                "trial {trial}"
            );
        }
    }

    #[test]
    #[ignore = "offline performance comparison"]
    fn sparse_validation_profile() {
        let mut f = frame();
        f.width = 16384;
        f.height = 32768;
        for tile in &mut f.tiles {
            tile.width = 16384;
            tile.height = 32768;
        }
        for count in [128, 1024, 4096, 16384, 32768] {
            let patches: Vec<_> = (0..count)
                .map(|i| AtlasPatch {
                    tile_index: 0,
                    source_x: (i % 128) * 128,
                    source_y: (i / 128) * 128,
                    x: (i % 128) * 128,
                    y: (i / 128) * 128,
                    width: 128,
                    height: 128,
                })
                .collect();
            for optimized in [false, true] {
                let start = std::time::Instant::now();
                for _ in 0..5 {
                    let frame = std::hint::black_box(&f);
                    let patches = std::hint::black_box(&patches);
                    if optimized {
                        frame.validate_patches(patches)
                    } else {
                        validate_patches_reference(frame, patches)
                    }
                    .unwrap();
                }
                eprintln!(
                    "sparse-rust patches={count} optimized={optimized} mean_us={}",
                    start.elapsed().as_micros() / 5
                );
            }
        }
    }

    fn frame() -> AtlasFrame {
        AtlasFrame {
            patches: None,
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: None,
            stream_id: Id128(99),
            frame_id: 1,
            geometry_epoch: 1,
            config_generation: 1,
            layout_revision: 2,
            width: 64,
            height: 64,
            source_submitted_ns: 100,
            tiles: vec![
                AtlasTile {
                    window_id: Id128(1),
                    placement_generation: 1,
                    geometry_epoch: 7,
                    source_frame_id: 12,
                    source_submitted_ns: 100,
                    x: 0,
                    y: 0,
                    width: 8,
                    height: 8,
                },
                AtlasTile {
                    window_id: Id128(2),
                    placement_generation: 2,
                    geometry_epoch: 3,
                    source_frame_id: 20,
                    source_submitted_ns: 110,
                    x: 16,
                    y: 0,
                    width: 8,
                    height: 8,
                },
            ],
        }
    }
    #[test]
    fn round_trip_and_empty_layout() {
        let value = frame();
        assert_eq!(
            AtlasFrame::try_from(wire::AtlasFrame::from(value.clone())).unwrap(),
            value
        );
        let mut empty = value;
        empty.tiles.clear();
        empty.layout_revision = 0;
        assert!(empty.validate().is_ok());
    }
    #[test]
    fn atlas_uses_a_distinct_control_payload() {
        use prost::Message;
        let value = frame();
        let envelope = wire::ControlEnvelope {
            protocol_major: u32::from(crate::PROTOCOL_VERSION.major),
            protocol_minor: u32::from(crate::PROTOCOL_VERSION.minor),
            sequence: 1,
            payload: Some(wire::control_envelope::Payload::AtlasFrame(
                value.clone().into(),
            )),
        };
        let decoded = wire::ControlEnvelope::decode(envelope.encode_to_vec().as_slice()).unwrap();
        assert_eq!(
            crate::DomainControl::try_from(decoded).unwrap(),
            crate::DomainControl::AtlasFrame(value)
        );
    }
    #[test]
    fn rejects_ambiguous_or_renewed_layouts() {
        for field in 0..9 {
            let mut bad = frame();
            match field {
                0 => bad.tiles[1].window_id = bad.tiles[0].window_id,
                1 => bad.tiles[1].x = 4,
                2 => bad.tiles[1].x = u32::MAX,
                3 => bad.tiles[0].window_id = bad.stream_id,
                4 => bad.source_submitted_ns = 110,
                5 => bad.source_submitted_ns = 99,
                6 => bad.tiles[1].placement_generation = 3,
                7 => bad.tiles.reverse(),
                _ => bad.tiles[0].source_frame_id = 0,
            }
            assert!(bad.validate().is_err());
            assert!(AtlasFrame::try_from(wire::AtlasFrame::from(bad)).is_err());
        }
        let mut bad = wire::AtlasFrame::from(frame());
        bad.version = 2;
        assert!(AtlasFrame::try_from(bad).is_err());
    }
}
