use anyhow::Result;
use viewflow_core::StableAtlas;

/// Try successively larger canvases while retaining stable allocations. An
/// impossible tile alone must not expand the canvas or evict other sources.
pub(crate) fn stage_capture_layout_with_limit(
    current: &StableAtlas,
    captures: impl IntoIterator<Item = (viewflow_protocol::WindowId, u64, u32, u32)>,
    limit: (u32, u32),
) -> Result<(
    StableAtlas,
    std::collections::BTreeSet<viewflow_protocol::WindowId>,
)> {
    let captures: Vec<_> = captures.into_iter().collect();
    let mut best = stage_capture_layout(current, captures.iter().copied())?;
    if best.1.is_empty() {
        return Ok(best);
    }
    let snapshot = current.snapshot();
    let extents = |start: u32, max: u32| {
        let mut sizes = vec![start];
        while *sizes.last().unwrap() < max {
            sizes.push(sizes.last().unwrap().saturating_mul(2).min(max));
        }
        sizes
    };
    let mut sizes = Vec::new();
    for width in extents(snapshot.width, limit.0) {
        for height in extents(snapshot.height, limit.1) {
            if (width, height) != (snapshot.width, snapshot.height) {
                sizes.push((width, height));
            }
        }
    }
    sizes.sort_by_key(|&(width, height)| (u64::from(width) * u64::from(height), width, height));
    for (width, height) in sizes {
        let mut grown = current.clone();
        grown
            .grow(width, height)
            .map_err(|e| anyhow::anyhow!("atlas growth: {e:?}"))?;
        let attempt = stage_capture_layout(&grown, captures.iter().copied())?;
        if attempt.1.len() < best.1.len() {
            best = attempt;
        }
        if best.1.is_empty() {
            break;
        }
    }
    Ok(best)
}

/// Capacity pressure changes publication membership, never capture scale or
/// authenticated source ownership. Other layout errors remain terminal.
pub(crate) fn stage_capture_layout(
    current: &StableAtlas,
    captures: impl IntoIterator<Item = (viewflow_protocol::WindowId, u64, u32, u32)>,
) -> Result<(
    StableAtlas,
    std::collections::BTreeSet<viewflow_protocol::WindowId>,
)> {
    let mut layout = current.clone();
    let mut paused = std::collections::BTreeSet::new();
    for (window, epoch, width, height) in captures {
        match layout.place(window, epoch, width, height) {
            Ok(_) => {}
            Err(viewflow_core::AtlasError::NoSpace | viewflow_core::AtlasError::FragmentLimit) => {
                // Do not publish the old size/epoch after a failed resize.
                if layout.placement(window).is_some() {
                    layout
                        .remove(window)
                        .map_err(|e| anyhow::anyhow!("atlas removal: {e:?}"))?;
                }
                paused.insert(window);
            }
            Err(error) => {
                anyhow::bail!("invalid atlas capture geometry: {error:?}; window={window:?}")
            }
        }
    }
    Ok((layout, paused))
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_core::AtlasConfig;
    use viewflow_protocol::Id128;
    fn small() -> StableAtlas {
        StableAtlas::new(AtlasConfig {
            width: 1024,
            height: 1024,
            alignment: 2,
            max_windows: 8,
        })
        .unwrap()
    }
    #[test]
    fn grows_only_when_needed_and_keeps_existing_allocations() {
        let mut current = small();
        current.place(Id128(1), 1, 600, 600).unwrap();
        let placement = current.placement(Id128(1)).unwrap();
        let (same, paused) =
            stage_capture_layout_with_limit(&current, [(Id128(1), 1, 600, 600)], (8192, 4096))
                .unwrap();
        assert!(paused.is_empty());
        assert_eq!(same.snapshot(), current.snapshot());
        let (grown, paused) = stage_capture_layout_with_limit(
            &current,
            [(Id128(1), 1, 600, 600), (Id128(2), 1, 1600, 1200)],
            (8192, 4096),
        )
        .unwrap();
        assert!(paused.is_empty());
        assert_eq!(grown.placement(Id128(1)).unwrap(), placement);
        assert!(grown.snapshot().revision > current.snapshot().revision);
        assert!(grown.snapshot().width > 1024 || grown.snapshot().height > 1024);
    }
    #[test]
    fn full_canvas_and_oversize_have_bounded_local_behavior() {
        let (full, paused) =
            stage_capture_layout_with_limit(&small(), [(Id128(1), 1, 8192, 4096)], (8192, 4096))
                .unwrap();
        assert!(paused.is_empty());
        assert_eq!(
            (full.snapshot().width, full.snapshot().height),
            (8192, 4096)
        );
        let (unchanged, paused) = stage_capture_layout_with_limit(
            &small(),
            [(Id128(1), 1, 9000, 4096), (Id128(2), 1, 400, 400)],
            (8192, 4096),
        )
        .unwrap();
        assert_eq!(paused.into_iter().collect::<Vec<_>>(), vec![Id128(1)]);
        assert_eq!(
            (unchanged.snapshot().width, unchanged.snapshot().height),
            (1024, 1024)
        );
        assert!(unchanged.placement(Id128(2)).is_some());
    }
}

/// Admission is a dry run at negotiated capacity. Actual GPU growth happens
/// only after enrollment, at the normal drained publication boundary.
pub(crate) fn can_enroll_capture_with_limit(
    current: &StableAtlas,
    capture: (viewflow_protocol::WindowId, u64, u32, u32),
    limit: (u32, u32),
) -> Result<bool> {
    let mut candidate = current.clone();
    candidate
        .grow(limit.0, limit.1)
        .map_err(|error| anyhow::anyhow!("invalid atlas enrollment capacity: {error:?}"))?;
    match candidate.place(capture.0, capture.1, capture.2, capture.3) {
        Ok(_) => Ok(true),
        Err(
            viewflow_core::AtlasError::NoSpace
            | viewflow_core::AtlasError::WindowLimit
            | viewflow_core::AtlasError::FragmentLimit,
        ) => Ok(false),
        Err(error) => Err(anyhow::anyhow!(
            "invalid desktop candidate allocation: {error:?}"
        )),
    }
}

#[cfg(test)]
mod enrollment_tests {
    use super::*;
    use viewflow_core::AtlasConfig;
    use viewflow_protocol::Id128;
    #[test]
    fn first_large_window_is_admitted_before_canvas_growth() {
        let current = StableAtlas::new(AtlasConfig {
            width: 1024,
            height: 1024,
            alignment: 2,
            max_windows: 8,
        })
        .unwrap();
        let before = current.snapshot();
        for (width, height) in [(1566, 894), (1722, 1422), (8192, 4096)] {
            let capture = (Id128(1), 1, width, height);
            assert!(can_enroll_capture_with_limit(&current, capture, (8192, 4096)).unwrap());
            let (grown, paused) =
                stage_capture_layout_with_limit(&current, [capture], (8192, 4096)).unwrap();
            assert!(paused.is_empty());
            assert!(grown.placement(Id128(1)).is_some());
        }
        assert_eq!(current.snapshot(), before);
        assert!(
            !can_enroll_capture_with_limit(&current, (Id128(1), 1, 9000, 100), (8192, 4096))
                .unwrap()
        );
        assert!(
            !can_enroll_capture_with_limit(&current, (Id128(1), 1, 1566, 894), (1024, 1024))
                .unwrap()
        );
    }
    #[test]
    fn admission_preserves_existing_slots_and_window_limit() {
        let mut current = StableAtlas::new(AtlasConfig {
            width: 1024,
            height: 1024,
            alignment: 2,
            max_windows: 2,
        })
        .unwrap();
        current.place(Id128(1), 1, 800, 800).unwrap();
        let before = current.snapshot();
        assert!(
            can_enroll_capture_with_limit(&current, (Id128(2), 1, 1722, 1422), (8192, 4096))
                .unwrap()
        );
        assert_eq!(current.snapshot(), before);
        current.place(Id128(2), 1, 100, 100).unwrap();
        assert!(
            !can_enroll_capture_with_limit(&current, (Id128(3), 1, 100, 100), (8192, 4096))
                .unwrap()
        );
    }
}

/// Sparse mode reserves source geometry independently of atlas pixels. Actual
/// residency comes from GPU alpha classification and native cell packing.
pub(crate) fn stage_sparse_capture_layout(
    current: &viewflow_core::AtlasSnapshot,
    captures: impl IntoIterator<Item = (viewflow_protocol::WindowId, u64, u32, u32)>,
    limit: (u32, u32),
) -> Result<(
    viewflow_core::AtlasSnapshot,
    std::collections::BTreeSet<viewflow_protocol::WindowId>,
)> {
    use viewflow_core::{AtlasPlacement, AtlasRect};
    anyhow::ensure!(
        current.width > 0
            && current.height > 0
            && limit.0 >= 128
            && limit.1 >= 128
            && current.width <= limit.0
            && current.height <= limit.1,
        "invalid sparse canvas limits"
    );
    let mut next = current.clone();
    next.placements.clear();
    let mut paused = std::collections::BTreeSet::new();
    let captures: Vec<_> = captures.into_iter().collect();
    anyhow::ensure!(captures.len() <= 4096, "sparse source count exceeded");
    for &(window, epoch, width, height) in &captures {
        anyhow::ensure!(
            window.0 > 0 && epoch > 0 && width > 0 && height > 0,
            "invalid sparse source"
        );
        if width > limit.0 || height > limit.1 {
            paused.insert(window);
            continue;
        }
        while next.width < width.max(128) {
            next.width = next.width.saturating_mul(2).min(limit.0);
        }
        while next.height < height.max(128) {
            next.height = next.height.saturating_mul(2).min(limit.1);
        }
        let allocation = AtlasRect {
            x: 0,
            y: 0,
            width: (width + 1) & !1,
            height: (height + 1) & !1,
        };
        let previous = current.placements.iter().find(|p| p.window == window);
        let unchanged = previous.is_some_and(|p| {
            p.geometry_epoch == epoch
                && p.content_width == width
                && p.content_height == height
                && p.allocation == allocation
        });
        next.placements.push(AtlasPlacement {
            window,
            geometry_epoch: epoch,
            generation: if unchanged {
                previous.unwrap().generation
            } else {
                current
                    .revision
                    .checked_add(1)
                    .ok_or_else(|| anyhow::anyhow!("sparse revision exhausted"))?
            },
            content_width: width,
            content_height: height,
            allocation,
        });
    }
    next.placements.sort_by_key(|p| p.window);
    anyhow::ensure!(
        next.placements
            .windows(2)
            .all(|p| p[0].window != p[1].window),
        "duplicate sparse source"
    );
    if next != *current {
        next.revision = current
            .revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("sparse revision exhausted"))?;
    }
    Ok((next, paused))
}

#[cfg(test)]
mod sparse_tests {
    use super::*;
    #[test]
    fn sparse_membership_does_not_spend_whole_window_rectangles() {
        let initial = viewflow_core::AtlasSnapshot {
            revision: 1,
            width: 1024,
            height: 1024,
            placements: vec![],
        };
        let captures = (1..=12).map(|id| (viewflow_protocol::Id128(id), 1, 1000, 1000));
        let (all, paused) = stage_sparse_capture_layout(&initial, captures, (8192, 4096)).unwrap();
        assert!(paused.is_empty());
        assert_eq!(all.placements.len(), 12);
        assert_eq!((all.width, all.height), (1024, 1024));
        let (grown, paused) = stage_sparse_capture_layout(
            &all,
            [(viewflow_protocol::Id128(1), 2, 1722, 1422)],
            (8192, 4096),
        )
        .unwrap();
        assert!(paused.is_empty());
        assert_eq!((grown.width, grown.height), (2048, 2048));
        let (next, paused) = stage_sparse_capture_layout(
            &grown,
            [(viewflow_protocol::Id128(1), 3, 9000, 100)],
            (8192, 4096),
        )
        .unwrap();
        assert!(next.placements.is_empty());
        assert_eq!(paused.len(), 1);
    }
}
