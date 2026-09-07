//! One persistent device-pair capture -> encode -> transport owner.
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
/// publication until they fit; canvas growth still requires negotiation.
pub struct GpuAtlasDevice {
    active: Option<(AtlasCapturePool, GpuAtlasSender)>,
    codec: CodecIdentity,
    layout: StableAtlas,
    geometry_epoch: u64,
    capacity_paused: std::collections::BTreeSet<viewflow_protocol::WindowId>,
    capture_geometry: std::collections::BTreeMap<viewflow_protocol::WindowId, (u64, u32, u32)>,
    next_frame: u64,
    last_empty_submission: Option<Instant>,
    empty_published: bool,
    committed_input: Option<crate::window_input_runtime::AtlasCommittedInput>,
    desktop: Option<crate::desktop_source::SharedDesktopSourceLane>,
}

impl GpuAtlasDevice {
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
        let layout = StableAtlas::from_snapshot(
            AtlasConfig {
                width: layout.width,
                height: layout.height,
                alignment: 2,
                max_windows,
            },
            &layout,
        )
        .map_err(|error| anyhow::anyhow!("invalid negotiated atlas snapshot: {error:?}"))?;
        Ok(Self {
            active: Some((pool, sender)),
            codec,
            layout,
            geometry_epoch,
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
        let mut candidate = self.layout.clone();
        match candidate.place(
            window,
            frame.geometry_epoch,
            frame.crop_width,
            frame.crop_height,
        ) {
            Ok(_) => Ok(true),
            Err(viewflow_core::AtlasError::NoSpace | viewflow_core::AtlasError::WindowLimit) => {
                Ok(false)
            }
            Err(error) => Err(anyhow::anyhow!(
                "invalid desktop candidate allocation: {error:?}"
            )),
        }
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
            && (self.empty_published || self.last_empty_submission
                .is_some_and(|last| last.elapsed() < std::time::Duration::from_nanos(1_000_000_000 / 60)))
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
        let (layout, paused) = stage_capture_layout(
            &self.layout,
            sources.iter().map(|source| {
                let frame = source.frame.metadata();
                (
                    source.window,
                    frame.geometry_epoch,
                    frame.crop_width,
                    frame.crop_height,
                )
            }),
        )?;
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
                    layout: layout.snapshot(),
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
        if let Some(manifest) = &result.manifest { self.empty_published = manifest.tiles.is_empty(); }
        self.committed_input = result.committed_input;
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

/// Capacity pressure changes publication membership, never capture scale or
/// authenticated source ownership. Other layout errors remain terminal.
fn stage_capture_layout(
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
