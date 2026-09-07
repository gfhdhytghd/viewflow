//! Stable, bounded pixel layout owned by a device-pair media session.
//!
//! This is a capture/composition plan, not GPU storage or remote publication.
//! Color and alpha must use the same snapshot; a backend still has to publish
//! the layout atomically with its encoded frame before using it for input.

use std::collections::BTreeMap;
use viewflow_protocol::WindowId;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AtlasConfig {
    pub width: u32,
    pub height: u32,
    /// Pixel alignment required by the selected encoder/chroma format.
    pub alignment: u32,
    pub max_windows: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AtlasError {
    InvalidConfig,
    InvalidWindow,
    InvalidSize,
    WindowLimit,
    FragmentLimit,
    NoSpace,
    UnknownWindow,
    StaleGeometry,
    SizeChangedWithoutEpoch,
    RevisionExhausted,
    InvalidSnapshot,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AtlasRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

impl AtlasRect {
    fn area(self) -> u64 {
        u64::from(self.width) * u64::from(self.height)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AtlasPlacement {
    pub window: WindowId,
    pub geometry_epoch: u64,
    /// Changes when this window is placed again; never reused after removal.
    pub generation: u64,
    /// Full decorated capture dimensions, not logical desktop dimensions.
    pub content_width: u32,
    pub content_height: u32,
    /// Aligned storage reservation. Padding is not window content.
    pub allocation: AtlasRect,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AtlasSnapshot {
    pub revision: u64,
    pub width: u32,
    pub height: u32,
    pub placements: Vec<AtlasPlacement>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Slot {
    placement: AtlasPlacement,
    valid: bool,
    size_known: bool,
}

/// Allocations do not repack unrelated windows. Free rectangles are merged
/// where possible; fragmented layouts may report `NoSpace` without moving them.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StableAtlas {
    config: AtlasConfig,
    revision: u64,
    slots: BTreeMap<WindowId, Slot>,
    free: Vec<AtlasRect>,
}

impl StableAtlas {
    /// Resume allocation from an already negotiated, fully visible layout.
    /// Preserve every placement/generation; reconstruct only unoccupied space.
    /// Invalidated (unpublished) reservations cannot be recovered from a snapshot.
    /// # Errors
    /// Rejects mismatched limits, overlap, out-of-bounds or malformed lineage.
    pub fn from_snapshot(
        config: AtlasConfig,
        snapshot: &AtlasSnapshot,
    ) -> Result<Self, AtlasError> {
        let mut atlas = Self::new(config)?;
        if snapshot.width != config.width
            || snapshot.height != config.height
            || snapshot.placements.len() > config.max_windows
        {
            return Err(AtlasError::InvalidSnapshot);
        }
        for placement in &snapshot.placements {
            let rect = placement.allocation;
            if placement.window.0 == 0
                || placement.geometry_epoch == 0
                || placement.generation == 0
                || placement.generation > snapshot.revision
                || placement.content_width == 0
                || placement.content_height == 0
                || placement.content_width > rect.width
                || placement.content_height > rect.height
                || rect.width == 0
                || rect.height == 0
                || [rect.x, rect.y, rect.width, rect.height]
                    .iter()
                    .any(|v| v % config.alignment != 0)
                || rect
                    .x
                    .checked_add(rect.width)
                    .is_none_or(|right| right > config.width)
                || rect
                    .y
                    .checked_add(rect.height)
                    .is_none_or(|bottom| bottom > config.height)
                || atlas.slots.contains_key(&placement.window)
            {
                return Err(AtlasError::InvalidSnapshot);
            }
            atlas.reserve_existing(rect)?;
            atlas.slots.insert(
                placement.window,
                Slot {
                    placement: *placement,
                    valid: true,
                    size_known: true,
                },
            );
        }
        atlas.revision = snapshot.revision;
        Ok(atlas)
    }

    fn reserve_existing(&mut self, reserved: AtlasRect) -> Result<(), AtlasError> {
        let mut remaining = Vec::new();
        let mut covered = 0_u64;
        for free in &self.free {
            let left = free.x.max(reserved.x);
            let top = free.y.max(reserved.y);
            let right = (free.x + free.width).min(reserved.x + reserved.width);
            let bottom = (free.y + free.height).min(reserved.y + reserved.height);
            if left >= right || top >= bottom {
                remaining.push(*free);
                continue;
            }
            covered = covered
                .checked_add(u64::from(right - left) * u64::from(bottom - top))
                .ok_or(AtlasError::InvalidSnapshot)?;
            for rect in [
                AtlasRect {
                    x: free.x,
                    y: free.y,
                    width: left - free.x,
                    height: free.height,
                },
                AtlasRect {
                    x: right,
                    y: free.y,
                    width: free.x + free.width - right,
                    height: free.height,
                },
                AtlasRect {
                    x: left,
                    y: free.y,
                    width: right - left,
                    height: top - free.y,
                },
                AtlasRect {
                    x: left,
                    y: bottom,
                    width: right - left,
                    height: free.y + free.height - bottom,
                },
            ] {
                if rect.width > 0 && rect.height > 0 {
                    remaining.push(rect);
                }
            }
        }
        // Already reserved pixels (overlap) cannot be subtracted a second time.
        if covered != reserved.area() {
            return Err(AtlasError::InvalidSnapshot);
        }
        if remaining.len() > self.config.max_windows * 4 + 1 {
            return Err(AtlasError::FragmentLimit);
        }
        self.free = remaining;
        Ok(())
    }

    /// # Errors
    /// Rejects empty/unaligned extents and unbounded window policies.
    pub fn new(config: AtlasConfig) -> Result<Self, AtlasError> {
        if config.width == 0
            || config.height == 0
            || !config.alignment.is_power_of_two()
            || config.width % config.alignment != 0
            || config.height % config.alignment != 0
            || config.max_windows == 0
            || config.max_windows > 4096
        {
            return Err(AtlasError::InvalidConfig);
        }
        Ok(Self {
            config,
            revision: 0,
            slots: BTreeMap::new(),
            free: vec![AtlasRect {
                x: 0,
                y: 0,
                width: config.width,
                height: config.height,
            }],
        })
    }

    #[must_use]
    pub fn snapshot(&self) -> AtlasSnapshot {
        AtlasSnapshot {
            revision: self.revision,
            width: self.config.width,
            height: self.config.height,
            placements: self
                .slots
                .values()
                .filter(|slot| slot.valid)
                .map(|slot| slot.placement)
                .collect(),
        }
    }

    #[must_use]
    pub fn placement(&self, window: WindowId) -> Option<AtlasPlacement> {
        self.slots
            .get(&window)
            .filter(|slot| slot.valid)
            .map(|slot| slot.placement)
    }

    /// Stage authoritative captured pixel dimensions. Failures leave the entire
    /// previous layout unchanged. A smaller image releases unused reservation space without moving.
    /// # Errors
    /// Rejects stale/conflicting geometry, resource exhaustion and overflow.
    pub fn place(
        &mut self,
        window: WindowId,
        epoch: u64,
        width: u32,
        height: u32,
    ) -> Result<AtlasPlacement, AtlasError> {
        if window.0 == 0 {
            return Err(AtlasError::InvalidWindow);
        }
        let align = |value: u32| {
            value
                .checked_add(self.config.alignment - 1)
                .map(|value| value & !(self.config.alignment - 1))
                .filter(|value| *value != 0)
                .ok_or(AtlasError::InvalidSize)
        };
        if width == 0 || height == 0 {
            return Err(AtlasError::InvalidSize);
        }
        let (aligned_width, aligned_height) = (align(width)?, align(height)?);
        let old = self.slots.get(&window).copied();
        if let Some(slot) = old {
            if epoch < slot.placement.geometry_epoch {
                return Err(AtlasError::StaleGeometry);
            }
            if epoch == slot.placement.geometry_epoch {
                if slot.size_known
                    && (width, height)
                        != (slot.placement.content_width, slot.placement.content_height)
                {
                    return Err(AtlasError::SizeChangedWithoutEpoch);
                }
                if slot.valid {
                    return Ok(slot.placement);
                }
            }
        } else if self.slots.len() >= self.config.max_windows {
            return Err(AtlasError::WindowLimit);
        }
        let revision = self
            .revision
            .checked_add(1)
            .ok_or(AtlasError::RevisionExhausted)?;
        let mut candidate = self.clone();
        let allocation = if let Some(slot) = old.filter(|slot| {
            aligned_width <= slot.placement.allocation.width
                && aligned_height <= slot.placement.allocation.height
        }) {
            let previous = slot.placement.allocation;
            // Retain the origin while returning the right and bottom strips.
            // Otherwise a formerly large window can starve a second window
            // even after both captures fit comfortably in the canvas.
            if previous.width > aligned_width {
                candidate.free.push(AtlasRect {
                    x: previous.x + aligned_width,
                    y: previous.y,
                    width: previous.width - aligned_width,
                    height: previous.height,
                });
            }
            if previous.height > aligned_height {
                candidate.free.push(AtlasRect {
                    x: previous.x,
                    y: previous.y + aligned_height,
                    width: aligned_width,
                    height: previous.height - aligned_height,
                });
            }
            candidate.merge_free();
            AtlasRect { width: aligned_width, height: aligned_height, ..previous }
        } else {
            if let Some(slot) = old {
                candidate.free.push(slot.placement.allocation);
                candidate.merge_free();
            }
            candidate.allocate(aligned_width, aligned_height)?
        };
        let placement = AtlasPlacement {
            window,
            geometry_epoch: epoch,
            generation: revision,
            content_width: width,
            content_height: height,
            allocation,
        };
        candidate.slots.insert(
            window,
            Slot {
                placement,
                valid: true,
                size_known: true,
            },
        );
        if candidate.free.len() > self.config.max_windows * 4 + 1 {
            return Err(AtlasError::FragmentLimit);
        }
        candidate.revision = revision;
        *self = candidate;
        Ok(placement)
    }

    /// Remove a tile from publication while retaining its stable reservation
    /// until capture supplies the newly committed geometry's actual pixels.
    /// # Errors
    /// Rejects an unknown window, stale epoch or exhausted revision counter.
    pub fn invalidate(&mut self, window: WindowId, epoch: u64) -> Result<(), AtlasError> {
        let slot = self
            .slots
            .get_mut(&window)
            .ok_or(AtlasError::UnknownWindow)?;
        if epoch <= slot.placement.geometry_epoch {
            return Err(AtlasError::StaleGeometry);
        }
        let revision = self
            .revision
            .checked_add(1)
            .ok_or(AtlasError::RevisionExhausted)?;
        slot.placement.geometry_epoch = epoch;
        slot.valid = false;
        slot.size_known = false;
        self.revision = revision;
        Ok(())
    }

    /// Retire the current connection's content, retaining allocations and
    /// geometry epochs for fresh capture after reconnect. No old tile is ready.
    /// # Errors
    /// Rejects revision exhaustion without changing any content validity.
    pub fn suspend(&mut self) -> Result<(), AtlasError> {
        if !self.slots.values().any(|slot| slot.valid) {
            return Ok(());
        }
        let revision = self
            .revision
            .checked_add(1)
            .ok_or(AtlasError::RevisionExhausted)?;
        for slot in self.slots.values_mut() {
            slot.valid = false;
        }
        self.revision = revision;
        Ok(())
    }

    /// # Errors
    /// Rejects an unknown window or exhausted revision counter without mutation.
    pub fn remove(&mut self, window: WindowId) -> Result<(), AtlasError> {
        let allocation = self
            .slots
            .get(&window)
            .ok_or(AtlasError::UnknownWindow)?
            .placement
            .allocation;
        let revision = self
            .revision
            .checked_add(1)
            .ok_or(AtlasError::RevisionExhausted)?;
        self.slots.remove(&window);
        self.free.push(allocation);
        self.merge_free();
        if self.slots.is_empty() {
            self.free = vec![AtlasRect {
                x: 0, y: 0, width: self.config.width, height: self.config.height,
            }];
        }
        self.revision = revision;
        Ok(())
    }

    pub(crate) fn contains(&self, window: WindowId) -> bool {
        self.slots.contains_key(&window)
    }

    fn allocate(&mut self, width: u32, height: u32) -> Result<AtlasRect, AtlasError> {
        let index = self
            .free
            .iter()
            .enumerate()
            .filter(|(_, rect)| rect.width >= width && rect.height >= height)
            .min_by_key(|(_, rect)| (rect.area(), rect.y, rect.x))
            .map(|(index, _)| index)
            .ok_or(AtlasError::NoSpace)?;
        let rect = self.free.remove(index);
        if rect.width > width {
            self.free.push(AtlasRect {
                x: rect.x + width,
                y: rect.y,
                width: rect.width - width,
                height: rect.height,
            });
        }
        if rect.height > height {
            self.free.push(AtlasRect {
                x: rect.x,
                y: rect.y + height,
                width,
                height: rect.height - height,
            });
        }
        Ok(AtlasRect {
            x: rect.x,
            y: rect.y,
            width,
            height,
        })
    }

    fn merge_free(&mut self) {
        loop {
            let mut merged = None;
            'pairs: for a in 0..self.free.len() {
                for b in a + 1..self.free.len() {
                    let (left, right) = (self.free[a], self.free[b]);
                    let horizontal = left.y == right.y
                        && left.height == right.height
                        && (left.x + left.width == right.x || right.x + right.width == left.x);
                    let vertical = left.x == right.x
                        && left.width == right.width
                        && (left.y + left.height == right.y || right.y + right.height == left.y);
                    if horizontal || vertical {
                        merged = Some((
                            a,
                            b,
                            AtlasRect {
                                x: left.x.min(right.x),
                                y: left.y.min(right.y),
                                width: if horizontal {
                                    left.width + right.width
                                } else {
                                    left.width
                                },
                                height: if vertical {
                                    left.height + right.height
                                } else {
                                    left.height
                                },
                            },
                        ));
                        break 'pairs;
                    }
                }
            }
            let Some((a, b, rect)) = merged else {
                break;
            };
            self.free.remove(b);
            self.free[a] = rect;
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn restored_single_window_can_grow_between_desktop_scales() {
        let config = AtlasConfig {
            width: 2048,
            height: 1536,
            alignment: 2,
            max_windows: 8,
        };
        let mut original = StableAtlas::new(config).unwrap();
        original.place(Id128(1), 1, 1174, 973).unwrap();
        let mut restored = StableAtlas::from_snapshot(config, &original.snapshot()).unwrap();
        restored.place(Id128(1), 2, 1564, 1296).unwrap();
    }

    use super::*;
    use viewflow_protocol::Id128;

    fn atlas() -> StableAtlas {
        StableAtlas::new(AtlasConfig {
            width: 128,
            height: 128,
            alignment: 2,
            max_windows: 8,
        })
        .unwrap()
    }

    #[test]
    fn negotiated_snapshot_resumes_without_moving_existing_tiles() {
        let mut original = atlas();
        original.place(Id128(2), 1, 32, 32).unwrap();
        original.place(Id128(1), 3, 31, 15).unwrap();
        let before = original.snapshot();
        let mut resumed = StableAtlas::from_snapshot(original.config, &before).unwrap();
        assert_eq!(resumed.snapshot(), before);
        let other = resumed.placement(Id128(2));
        let next = resumed.place(Id128(1), 4, 16, 8).unwrap();
        assert!(next.generation > before.revision);
        assert_eq!(resumed.placement(Id128(2)), other);
        let unchanged = resumed.clone();
        assert_eq!(
            resumed.place(Id128(1), 5, 512, 512),
            Err(AtlasError::NoSpace)
        );
        assert_eq!(resumed, unchanged);
        resumed.remove(Id128(1)).unwrap();
        resumed.remove(Id128(2)).unwrap();
        assert!(resumed.place(Id128(3), 6, 128, 128).is_ok());
    }

    #[test]
    fn malformed_negotiated_snapshot_cannot_reconstruct_free_space() {
        let mut original = atlas();
        original.place(Id128(1), 1, 32, 32).unwrap();
        original.place(Id128(2), 1, 32, 32).unwrap();
        let before = original.snapshot();
        for field in 0..11 {
            let mut bad = before.clone();
            match field {
                0 => bad.width += 2,
                1 => bad.revision = 0,
                2 => bad.placements[0].window = Id128(0),
                3 => bad.placements[0].geometry_epoch = 0,
                4 => bad.placements[0].generation = 0,
                5 => bad.placements[0].content_width = 33,
                6 => bad.placements[0].allocation.x = u32::MAX - 1,
                7 => bad.placements[0].allocation.x = 1,
                8 => bad.placements[0].allocation.width = 0,
                9 => bad.placements[1].window = bad.placements[0].window,
                _ => bad.placements[1].allocation = bad.placements[0].allocation,
            }
            assert_eq!(
                StableAtlas::from_snapshot(original.config, &bad),
                Err(AtlasError::InvalidSnapshot)
            );
        }
    }

    #[test]
    fn stable_slots_reuse_gaps_without_reusing_identity() {
        let mut atlas = atlas();
        let a = atlas.place(Id128(1), 0, 63, 63).unwrap();
        let b = atlas.place(Id128(2), 0, 64, 64).unwrap();
        assert_eq!(a.allocation.width, 64);
        atlas.remove(Id128(1)).unwrap();
        let c = atlas.place(Id128(3), 0, 63, 63).unwrap();
        assert_eq!(a.allocation, c.allocation);
        assert_ne!(a.generation, c.generation);
        assert_eq!(atlas.placement(Id128(2)), Some(b));
        atlas.remove(Id128(2)).unwrap();
        atlas.remove(Id128(3)).unwrap();
        assert!(atlas.place(Id128(4), 0, 128, 128).is_ok());
    }

    #[test]
    fn taller_second_window_can_use_full_height_beside_first() {
        let mut atlas = StableAtlas::new(AtlasConfig {
            width: 4096, height: 2560, alignment: 2, max_windows: 8,
        }).unwrap();
        atlas.place(Id128(1), 1, 1690, 1348).unwrap();
        // Startup hands off a published snapshot to the live GPU device.
        atlas = StableAtlas::from_snapshot(atlas.config, &atlas.snapshot()).unwrap();
        atlas.place(Id128(2), 1, 1894, 1582).unwrap();
        StableAtlas::from_snapshot(atlas.config, &atlas.snapshot()).unwrap();
    }

    #[test]
    fn shrinking_full_canvas_releases_space_for_another_window() {
        let mut atlas = StableAtlas::new(AtlasConfig {
            width: 4096, height: 2560, alignment: 2, max_windows: 8,
        }).unwrap();
        atlas.place(Id128(1), 1, 4096, 2560).unwrap();
        let small = atlas.place(Id128(1), 2, 1690, 1348).unwrap();
        let second = atlas.place(Id128(2), 1, 1894, 1582).unwrap();
        assert_eq!((small.allocation.x, small.allocation.y), (0, 0));
        assert!(second.allocation.x >= small.allocation.width);
        StableAtlas::from_snapshot(atlas.config, &atlas.snapshot()).unwrap();
    }

    #[test]
    fn epoch_invalidation_and_failed_resize_are_transactional() {
        let mut atlas = atlas();
        let old = atlas.place(Id128(1), 4, 64, 64).unwrap();
        let unchanged = atlas.clone();
        assert_eq!(
            atlas.place(Id128(1), 4, 63, 63),
            Err(AtlasError::SizeChangedWithoutEpoch)
        );
        assert_eq!(
            atlas.place(Id128(1), 5, u32::MAX, 64),
            Err(AtlasError::InvalidSize)
        );
        assert_eq!(atlas.place(Id128(1), 5, 256, 64), Err(AtlasError::NoSpace));
        assert_eq!(atlas, unchanged);
        atlas.invalidate(Id128(1), 5).unwrap();
        assert!(atlas.snapshot().placements.is_empty());
        assert_eq!(
            atlas.place(Id128(1), 4, 64, 64),
            Err(AtlasError::StaleGeometry)
        );
        let next = atlas.place(Id128(1), 5, 32, 32).unwrap();
        assert_eq!((next.allocation.x, next.allocation.y), (old.allocation.x, old.allocation.y));
        assert_eq!((next.allocation.width, next.allocation.height), (32, 32));
        assert!(next.generation > old.generation);
    }

    #[test]
    fn repeated_layout_changes_preserve_partition_and_failure_atomicity() {
        let mut atlas = atlas();
        let mut random = 1_u64;
        let mut removed = 0;
        let mut placed = 0;
        for epoch in 1..=2000 {
            random = random
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1);
            let window = Id128(u128::from((random >> 32) % 8 + 1));
            let old = atlas.clone();
            let result = if random.trailing_zeros() >= 2 {
                atlas.remove(window)
            } else {
                let width = u32::try_from((random >> 8) % 96 + 1).unwrap();
                let height = u32::try_from((random >> 16) % 96 + 1).unwrap();
                atlas.place(window, epoch, width, height).map(|_| ())
            };
            if result.is_err() {
                assert_eq!(atlas, old);
            } else if random.trailing_zeros() >= 2 {
                removed += 1;
            } else {
                placed += 1;
            }
            let rects: Vec<_> = atlas
                .free
                .iter()
                .copied()
                .chain(atlas.slots.values().map(|slot| slot.placement.allocation))
                .collect();
            let restored = StableAtlas::from_snapshot(atlas.config, &atlas.snapshot()).unwrap();
            assert_eq!(restored.snapshot(), atlas.snapshot());
            assert_eq!(
                restored.free.iter().map(|rect| rect.area()).sum::<u64>(),
                atlas.free.iter().map(|rect| rect.area()).sum::<u64>()
            );
            assert_eq!(rects.iter().map(|rect| rect.area()).sum::<u64>(), 128 * 128);
            for (index, a) in rects.iter().enumerate() {
                assert!(a.width > 0 && a.height > 0);
                assert!(a.x + a.width <= 128 && a.y + a.height <= 128);
                for b in &rects[index + 1..] {
                    assert!(
                        a.x + a.width <= b.x
                            || b.x + b.width <= a.x
                            || a.y + a.height <= b.y
                            || b.y + b.height <= a.y
                    );
                }
            }
        }
        assert!(removed > 50 && placed > 100);
        let windows: Vec<_> = atlas.slots.keys().copied().collect();
        for window in windows {
            atlas.remove(window).unwrap();
        }
        assert!(atlas.place(Id128(99), 0, 128, 128).is_ok());
    }

    #[test]
    fn configuration_and_pixel_dimensions_are_explicitly_bounded() {
        let config = AtlasConfig {
            width: 128,
            height: 128,
            alignment: 2,
            max_windows: 8,
        };
        for invalid in [
            AtlasConfig {
                alignment: 0,
                ..config
            },
            AtlasConfig {
                alignment: 3,
                ..config
            },
            AtlasConfig {
                width: 127,
                ..config
            },
            AtlasConfig {
                height: 0,
                ..config
            },
            AtlasConfig {
                max_windows: 4097,
                ..config
            },
        ] {
            assert_eq!(StableAtlas::new(invalid), Err(AtlasError::InvalidConfig));
        }
        let mut atlas = atlas();
        assert_eq!(
            atlas.place(Id128(0), 0, 32, 32),
            Err(AtlasError::InvalidWindow)
        );
        assert_eq!(
            atlas.place(Id128(1), 0, 0, 32),
            Err(AtlasError::InvalidSize)
        );
        assert_eq!(atlas.snapshot().revision, 0);
    }

    #[test]
    fn reconnect_retains_reservations_but_requires_fresh_content_identity() {
        let mut atlas = atlas();
        let first = atlas.place(Id128(1), 7, 64, 64).unwrap();
        let second = atlas.place(Id128(2), 9, 64, 64).unwrap();
        let before = atlas.snapshot().revision;
        atlas.suspend().unwrap();
        assert!(atlas.snapshot().placements.is_empty());
        assert!(atlas.snapshot().revision > before);
        let suspended = atlas.clone();
        assert_eq!(
            atlas.place(Id128(1), 7, 32, 32),
            Err(AtlasError::SizeChangedWithoutEpoch)
        );
        assert_eq!(atlas, suspended);
        atlas.suspend().unwrap();
        assert_eq!(atlas, suspended);
        let next = atlas.place(Id128(1), 7, 64, 64).unwrap();
        assert_eq!(next.allocation, first.allocation);
        assert_ne!(next.generation, first.generation);
        assert!(atlas.placement(Id128(2)).is_none());
        let next_second = atlas.place(Id128(2), 9, 64, 64).unwrap();
        assert_eq!(next_second.allocation, second.allocation);
        assert_ne!(next_second.generation, second.generation);
    }

    #[test]
    fn bounded_layout_and_exhausted_revision_never_partially_mutate() {
        let mut atlas = atlas();
        for id in 1..=8 {
            atlas.place(Id128(id), 0, 2, 2).unwrap();
        }
        assert_eq!(atlas.place(Id128(9), 0, 2, 2), Err(AtlasError::WindowLimit));
        atlas.revision = u64::MAX;
        let old = atlas.clone();
        assert_eq!(atlas.remove(Id128(1)), Err(AtlasError::RevisionExhausted));
        assert_eq!(atlas.suspend(), Err(AtlasError::RevisionExhausted));
        assert_eq!(
            atlas.invalidate(Id128(1), 1),
            Err(AtlasError::RevisionExhausted)
        );
        assert_eq!(atlas, old);
    }
}
