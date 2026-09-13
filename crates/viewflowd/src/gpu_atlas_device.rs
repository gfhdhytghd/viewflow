//! One persistent device-pair capture -> encode -> transport owner.
#[cfg(test)]
use crate::atlas_growth::stage_capture_layout;
use crate::atlas_growth::stage_capture_layout_with_limit;
use anyhow::{Result, ensure};
use tokio::time::Instant;
use viewflow_core::{AtlasConfig, AtlasSnapshot, StableAtlas};
use viewflow_protocol::AtlasFrame;

use crate::{
    compatible_encoder::CodecIdentity,
    gpu_atlas_capture::AtlasCapturePool,
    gpu_atlas_sender::{AtlasBatch, GpuAtlasSender},
    gpu_nvenc_runtime::GpuAtlasIdentity,
    hyprcapture_gpu_socket::HyprCaptureGpuSocketReceiver,
};

pub enum AtlasDevicePoll {
    Waiting,
    ExpiredClean,
    Submitted,
    Enqueued(AtlasFrame),
}

/// The application supplies authenticated capture connections, a prepared
/// encoder/sender, negotiated clock mapping and a scheduling cadence. Source
/// geometry may change within the negotiated canvas. Oversized captures pause
/// publication until they fit; canvas growth stays within negotiated capacity.
pub struct GpuAtlasDevice {
    active: Option<(AtlasCapturePool, GpuAtlasSender)>,
    codec: CodecIdentity,
    layout: StableAtlas,
    sparse_snapshot: Option<AtlasSnapshot>,
    sparse_enabled: bool,
    max_windows: usize,
    geometry_epoch: u64,
    canvas_limit: (u32, u32),
    capacity_paused: std::collections::BTreeSet<viewflow_protocol::WindowId>,
    capture_geometry: std::collections::BTreeMap<viewflow_protocol::WindowId, (u64, u32, u32)>,
    next_frame: u64,
    last_empty_submission: Option<Instant>,
    empty_published: bool,
    committed_input: Option<crate::window_input_runtime::AtlasCommittedInput>,
    desktop: Option<crate::desktop_source::SharedDesktopSourceLane>,
}

impl GpuAtlasDevice {
    pub(crate) fn poll_capture_readable(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<()> {
        self.active
            .as_mut()
            .map_or(std::task::Poll::Pending, |(pool, _)| pool.poll_readable(cx))
    }

    pub(crate) fn set_occlusion(
        &mut self,
        mode: crate::atlas_occlusion::AtlasOcclusionMode,
    ) -> Result<()> {
        let mode = if self.canvas_limit.0 < 128 || self.canvas_limit.1 < 128 {
            crate::atlas_occlusion::AtlasOcclusionMode::Off
        } else {
            mode
        };
        let (_, sender) = self
            .active
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("atlas device retired"))?;
        sender.set_occlusion(mode)?;
        self.sparse_enabled = mode != crate::atlas_occlusion::AtlasOcclusionMode::Off;
        Ok(())
    }

    /// # Errors
    /// Rejects zero identities, stream/source aliasing or layout membership drift.
    pub fn new(
        pool: AtlasCapturePool,
        sender: GpuAtlasSender,
        codec: CodecIdentity,
        layout: AtlasSnapshot,
        geometry_epoch: u64,
    ) -> Result<Self> {
        let max_windows = layout.placements.len();
        Self::new_with_capacity(pool, sender, codec, layout, geometry_epoch, max_windows)
    }

    /// Construct a device whose initial snapshot may grow up to an already
    /// negotiated tile capacity. Capacity is fixed for the session; only
    /// membership changes at an idle frame boundary are permitted.
    pub(crate) fn new_with_capacity(
        pool: AtlasCapturePool,
        sender: GpuAtlasSender,
        codec: CodecIdentity,
        layout: AtlasSnapshot,
        geometry_epoch: u64,
        max_windows: usize,
    ) -> Result<Self> {
        ensure!(
            codec.window_id.0 != 0 && codec.config_generation > 0 && geometry_epoch > 0,
            "invalid atlas device identity"
        );
        let windows: std::collections::BTreeSet<_> = layout
            .placements
            .iter()
            .map(|placement| placement.window)
            .collect();
        ensure!(
            &windows == pool.windows()
                && windows.len() == layout.placements.len()
                && windows.len() <= max_windows
                && max_windows <= 4096
                && !windows.contains(&codec.window_id),
            "atlas device source membership mismatch"
        );
        let next_frame = sender.next_frame_id()?;
        let canvas_limit = sender.canvas_limit();
        let sparse_enabled = sender.occlusion_enabled();
        let sparse_snapshot = sparse_enabled.then(|| layout.clone());
        let layout = if sparse_enabled {
            StableAtlas::new(AtlasConfig {
                width: layout.width,
                height: layout.height,
                alignment: 2,
                max_windows,
            })
            .map_err(|e| anyhow::anyhow!("invalid sparse canvas: {e:?}"))?
        } else {
            StableAtlas::from_snapshot(
                AtlasConfig {
                    width: layout.width,
                    height: layout.height,
                    alignment: 2,
                    max_windows,
                },
                &layout,
            )
            .map_err(|error| anyhow::anyhow!("invalid negotiated atlas snapshot: {error:?}"))?
        };
        Ok(Self {
            active: Some((pool, sender)),
            codec,
            layout,
            sparse_snapshot,
            sparse_enabled,
            max_windows,
            geometry_epoch,
            canvas_limit,
            capacity_paused: Default::default(),
            capture_geometry: Default::default(),
            next_frame,
            last_empty_submission: None,
            empty_published: false,
            committed_input: None,
            desktop: None,
        })
    }

    /// Enable the source-side desktop lane after its configuration has been
    /// validated. Every later submitted batch carries HCGF-derived logical
    /// bounds, never a later compositor metadata query.
    pub(crate) fn attach_desktop_source(
        &mut self,
        desktop: crate::desktop_source::SharedDesktopSourceLane,
    ) {
        self.desktop = Some(desktop);
    }

    /// The caller has just completed a prior batch and owns a newly started,
    /// authenticated capture session. Do not call while `poll_and_send` is
    /// running; the pool rejects that state rather than changing a batch.
    pub(crate) fn enroll_at_frame_boundary(
        &mut self,
        window: viewflow_protocol::WindowId,
        receiver: HyprCaptureGpuSocketReceiver,
    ) -> Result<()> {
        let (pool, _) = self
            .active
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("atlas device is retired"))?;
        ensure!(
            window != self.codec.window_id,
            "atlas source aliases stream ID"
        );
        self.empty_published = false;
        pool.add_at_frame_boundary(window, receiver)
    }

    pub(crate) fn remove_at_frame_boundary(
        &mut self,
        window: viewflow_protocol::WindowId,
    ) -> Result<()> {
        let (pool, _) = self
            .active
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("atlas device is retired"))?;
        pool.remove_at_frame_boundary(window)?;
        if self.layout.placement(window).is_some() {
            self.layout
                .remove(window)
                .map_err(|error| anyhow::anyhow!("atlas source removal: {error:?}"))?;
        }
        self.capacity_paused.remove(&window);
        self.capture_geometry.remove(&window);
        self.committed_input = None;
        self.last_empty_submission = None;
        self.empty_published = false;
        Ok(())
    }

    pub(crate) fn can_enroll_capture(
        &self,
        window: viewflow_protocol::WindowId,
        frame: &crate::hyprcapture_gpu_wire::HcgfFrame,
    ) -> Result<bool> {
        if self.sparse_enabled {
            let (pool, _) = self
                .active
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("atlas device retired"))?;
            return Ok(window.0 != 0
                && window != self.codec.window_id
                && frame.geometry_epoch > 0
                && frame.crop_width > 0
                && frame.crop_height > 0
                && frame.crop_width <= self.canvas_limit.0
                && frame.crop_height <= self.canvas_limit.1
                && (pool.windows().contains(&window) || pool.windows().len() < self.max_windows));
        }
        crate::atlas_growth::can_enroll_capture_with_limit(
            &self.layout,
            (
                window,
                frame.geometry_epoch,
                frame.crop_width,
                frame.crop_height,
            ),
            self.canvas_limit,
        )
    }

    /// Poll each source at most once, then submit a complete batch. Waiting
    /// preserves partially collected slots. Errors or cancellation close the
    /// owner, including outstanding capture sessions; no detached task survives.
    /// # Errors
    /// Propagates capture, clock mapping, encoding, release and transport errors.
    pub async fn poll_and_send(
        &mut self,
        map_source_time: impl FnOnce(u64) -> Result<u64>,
        deadline: Instant,
    ) -> Result<AtlasDevicePoll> {
        let (mut pool, mut sender) = self
            .active
            .take()
            .ok_or_else(|| anyhow::anyhow!("atlas device is retired"))?;
        if let Some(publication) = sender.poll_feedback().await? {
            self.committed_input = publication.committed_input;
            if let Some(manifest) = publication.manifest {
                self.empty_published = manifest.tiles.is_empty();
                self.active = Some((pool, sender));
                return Ok(AtlasDevicePoll::Enqueued(manifest));
            }
        }
        if pool.windows().is_empty()
            && (self.empty_published
                || self.last_empty_submission.is_some_and(|last| {
                    last.elapsed() < std::time::Duration::from_nanos(1_000_000_000 / 60)
                }))
        {
            self.active = Some((pool, sender));
            return Ok(AtlasDevicePoll::Waiting);
        }
        let Some(sources) = pool.poll_ready()? else {
            self.active = Some((pool, sender));
            return Ok(AtlasDevicePoll::Waiting);
        };
        self.committed_input = None;
        // Stage all changed captures as one candidate. The encoder validates
        // the resulting snapshot and forces fresh color/alpha keyframes on a
        // layout change; publication remains atomic with that encoded pair.
        // Never scale a larger source into an old placement or reset epochs.
        for source in &sources {
            let frame = source.frame.metadata();
            let geometry = (frame.geometry_epoch, frame.crop_width, frame.crop_height);
            if let Some(previous) = self.capture_geometry.get(&source.window) {
                ensure!(
                    geometry.0 >= previous.0 && (geometry.0 != previous.0 || geometry == *previous),
                    "atlas capture changed size without advancing geometry epoch"
                );
            }
            self.capture_geometry.insert(source.window, geometry);
        }
        let captures: Vec<_> = sources
            .iter()
            .map(|source| {
                let f = source.frame.metadata();
                (source.window, f.geometry_epoch, f.crop_width, f.crop_height)
            })
            .collect();
        let (mut layout, paused, mut planned_snapshot) = if self.sparse_enabled {
            let previous = self
                .sparse_snapshot
                .clone()
                .unwrap_or_else(|| self.layout.snapshot());
            let (snapshot, paused) = crate::atlas_growth::stage_sparse_capture_layout(
                &previous,
                captures,
                self.canvas_limit,
            )?;
            let mut layout = self.layout.clone();
            if (snapshot.width, snapshot.height)
                != (layout.snapshot().width, layout.snapshot().height)
            {
                layout
                    .grow(snapshot.width, snapshot.height)
                    .map_err(|e| anyhow::anyhow!("sparse source growth: {e:?}"))?;
            }
            (layout, paused, snapshot)
        } else {
            let (layout, paused) =
                stage_capture_layout_with_limit(&self.layout, captures, self.canvas_limit)?;
            let snapshot = layout.snapshot();
            (layout, paused, snapshot)
        };
        if (layout.snapshot().width, layout.snapshot().height)
            != (self.layout.snapshot().width, self.layout.snapshot().height)
        {
            // Nothing in this batch was read by the GPU. Return producer leases
            // before draining feedback and allocating the larger codec canvas.
            let mut receivers = Vec::with_capacity(sources.len());
            for mut source in sources {
                source.receiver.release_after_source_reads(&source.frame)?;
                receivers.push((source.window, source.receiver));
            }
            pool.restore(receivers)?;
            let snapshot = layout.snapshot();
            let publication = sender.grow_canvas(snapshot.width, snapshot.height).await?;
            eprintln!(
                "atlas-source-canvas grew={}x{} maximum={}x{}",
                snapshot.width, snapshot.height, self.canvas_limit.0, self.canvas_limit.1
            );
            self.layout = layout;
            if self.sparse_enabled {
                self.sparse_snapshot = Some(planned_snapshot);
            }
            self.empty_published = false;
            self.active = Some((pool, sender));
            if let Some(publication) = publication {
                self.committed_input = publication.committed_input;
                if let Some(manifest) = publication.manifest {
                    return Ok(AtlasDevicePoll::Enqueued(manifest));
                }
            }
            return Ok(AtlasDevicePoll::Waiting);
        }
        for window in paused.symmetric_difference(&self.capacity_paused) {
            eprintln!(
                "atlas-source-capacity window={window:?} paused={} canvas={}x{}",
                paused.contains(window),
                layout.snapshot().width,
                layout.snapshot().height
            );
        }
        self.capacity_paused = paused;
        // Empty ownership is a transparent control publication, containing no
        // old pixels whose capture age could be renewed. Live source batches
        // always retain their original timestamps and lease deadlines.
        let (captured, native_deadline) = if sources.is_empty() {
            let now = crate::gpu_nvenc_runtime::monotonic_ns()?;
            self.last_empty_submission = Some(Instant::now());
            (
                u64::try_from(now)?,
                now.checked_add(i64::try_from(pool.max_age_ns())?)
                    .ok_or_else(|| anyhow::anyhow!("empty atlas deadline overflow"))?,
            )
        } else {
            (
                sources
                    .iter()
                    .map(|source| source.frame.metadata().capture_monotonic_ns)
                    .min()
                    .expect("nonempty"),
                sources
                    .iter()
                    .map(|source| source.deadline_monotonic_ns)
                    .min()
                    .expect("nonempty"),
            )
        };
        let mut withheld_receivers = Vec::new();
        let mut admitted = Vec::new();
        for mut source in sources {
            if self.capacity_paused.contains(&source.window) {
                // This lease was never submitted to a GPU reader. As with an
                // expired unencoded pool slot, releasing it needs no GPU fence.
                source.receiver.release_after_source_reads(&source.frame)?;
                withheld_receivers.push((source.window, source.receiver));
            } else {
                admitted.push(source);
            }
        }
        let sources = admitted;
        let captured = sources
            .iter()
            .map(|source| source.frame.metadata().capture_monotonic_ns)
            .min()
            .unwrap_or(captured);
        let next_frame = self
            .next_frame
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("atlas device frame sequence exhausted"))?;
        let desktop = self
            .desktop
            .as_ref()
            .map(|desktop| {
                let mut desktop = desktop
                    .lock()
                    .map_err(|_| anyhow::anyhow!("desktop source state poisoned"))?;
                desktop.layout_for_admitted(&sources)
            })
            .transpose()?;
        let result = sender
            .submit_batch(
                AtlasBatch {
                    codec: self.codec,
                    layout: planned_snapshot.clone(),
                    identity: GpuAtlasIdentity {
                        frame_id: self.next_frame,
                        capture_monotonic_ns: captured,
                        geometry_epoch: self.geometry_epoch,
                    },
                    mapped_source_ns: map_source_time(captured)?,
                    deadline_monotonic_ns: native_deadline,
                    sources,
                    desktop,
                },
                self.next_frame,
                deadline,
            )
            .await?;
        withheld_receivers.extend(result.receivers);
        pool.restore(withheld_receivers)?;
        if let Some(manifest) = &result.manifest {
            self.empty_published = manifest.tiles.is_empty();
        }
        self.committed_input = result.committed_input;
        if let Some((width, height)) = result.grown_canvas {
            layout
                .grow(width, height)
                .map_err(|e| anyhow::anyhow!("sparse residency growth: {e:?}"))?;
            planned_snapshot.width = width;
            planned_snapshot.height = height;
            planned_snapshot.revision = planned_snapshot
                .revision
                .checked_add(1)
                .ok_or_else(|| anyhow::anyhow!("sparse scene revision exhausted"))?;
        }
        if self.sparse_enabled {
            self.sparse_snapshot = Some(planned_snapshot);
        }
        self.layout = layout;
        self.next_frame = next_frame;
        self.active = Some((pool, sender));
        Ok(match result.manifest {
            Some(manifest) => AtlasDevicePoll::Enqueued(manifest),
            None if result.submitted => AtlasDevicePoll::Submitted,
            None => AtlasDevicePoll::ExpiredClean,
        })
    }

    pub(crate) fn committed_input(
        &self,
    ) -> Option<&crate::window_input_runtime::AtlasCommittedInput> {
        self.active.as_ref()?;
        self.committed_input.as_ref()
    }
}

#[cfg(test)]
mod capacity_tests {
    use super::*;
    use viewflow_protocol::Id128;

    #[test]
    fn oversized_resize_withdraws_only_that_tile_and_recovers_fresh() {
        let mut initial = StableAtlas::new(AtlasConfig {
            width: 2048,
            height: 1536,
            alignment: 2,
            max_windows: 8,
        })
        .unwrap();
        let old = initial.place(Id128(1), 1, 1564, 1296).unwrap();
        let other = initial.place(Id128(2), 1, 100, 100).unwrap();
        let (paused, withheld) = stage_capture_layout(
            &initial,
            [(Id128(1), 2, 1564, 1884), (Id128(2), 1, 100, 100)],
        )
        .unwrap();
        assert_eq!(withheld, [Id128(1)].into());
        assert!(paused.placement(Id128(1)).is_none());
        assert_eq!(paused.placement(Id128(2)), Some(other));
        let (resumed, withheld) = stage_capture_layout(
            &paused,
            [(Id128(1), 3, 1564, 1296), (Id128(2), 1, 100, 100)],
        )
        .unwrap();
        assert!(withheld.is_empty());
        let fresh = resumed.placement(Id128(1)).unwrap();
        assert_eq!(fresh.geometry_epoch, 3);
        assert!(fresh.generation > old.generation);
        assert_eq!(resumed.placement(Id128(2)), Some(other));
    }

    #[test]
    fn all_paused_is_empty_publication_and_bad_lineage_is_still_rejected() {
        let mut initial = StableAtlas::new(AtlasConfig {
            width: 128,
            height: 128,
            alignment: 2,
            max_windows: 1,
        })
        .unwrap();
        initial.place(Id128(1), 1, 64, 64).unwrap();
        assert!(stage_capture_layout(&initial, [(Id128(1), 1, 65, 64)]).is_err());
        let (paused, _) = stage_capture_layout(&initial, [(Id128(1), 2, 256, 128)]).unwrap();
        assert!(paused.snapshot().placements.is_empty());
        let revision = paused.snapshot().revision;
        let (still_paused, _) = stage_capture_layout(&paused, [(Id128(1), 2, 256, 128)]).unwrap();
        assert_eq!(still_paused.snapshot().revision, revision);
        assert!(initial.placement(Id128(1)).is_some());
    }
}
