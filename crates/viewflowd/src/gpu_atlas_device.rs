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
    active: Option<(AtlasCapturePool, Option<GpuAtlasSender>)>,
    activity: Option<ActivityLanes>,
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
        if let (Some(activity), Some((pool, _))) = (&mut self.activity, &mut self.active) {
            let now = activity.origin.elapsed().as_micros().min(u128::from(u64::MAX)) as u64;
            for lane in activity.scheduler.order(now) {
                if let Some(worker) = &mut activity.workers[lane] {
                    if worker.poll_readable(cx).is_ready() { return std::task::Poll::Ready(()); }
                }
                if !activity.busy(lane) && pool.poll_readable_subset(cx, &activity.scheduler.select(lane, now)).is_ready() {
                    return std::task::Poll::Ready(());
                }
            }
            return std::task::Poll::Pending;
        }
        self.active.as_mut().map_or(std::task::Poll::Pending, |(pool, _)| pool.poll_readable(cx))
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
        if let Some(sender) = sender { sender.set_occlusion(mode)?; }
        if let Some(activity) = &mut self.activity { activity.set_occlusion(mode); }
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
            active: Some((pool, Some(sender))),
            activity: None,
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
        if self.activity.is_some() { pool.withdraw_activity(window)?; }
        else { pool.remove_at_frame_boundary(window)?; }
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
        if self.activity.is_some() { return self.poll_activity(map_source_time, deadline).await; }
        let (mut pool, sender) = self
            .active
            .take()
            .ok_or_else(|| anyhow::anyhow!("atlas device is retired"))?;
        let mut sender = sender.ok_or_else(|| anyhow::anyhow!("atlas sender unavailable"))?;
        if let Some(publication) = sender.poll_feedback().await? {
            self.committed_input = publication.committed_input;
            if let Some(manifest) = publication.manifest {
                self.empty_published = manifest.tiles.is_empty();
                self.active = Some((pool, Some(sender)));
                return Ok(AtlasDevicePoll::Enqueued(manifest));
            }
        }
        if pool.windows().is_empty()
            && (self.empty_published
                || self.last_empty_submission.is_some_and(|last| {
                    last.elapsed() < std::time::Duration::from_nanos(1_000_000_000 / 60)
                }))
        {
            self.active = Some((pool, Some(sender)));
            return Ok(AtlasDevicePoll::Waiting);
        }
        let Some(sources) = pool.poll_ready()? else {
            self.active = Some((pool, Some(sender)));
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
            self.active = Some((pool, Some(sender)));
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
                    activity: None,
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
        self.active = Some((pool, Some(sender)));
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

fn activity_render_snapshot(layout: &StableAtlas, selected: &std::collections::BTreeSet<viewflow_protocol::WindowId>,
    prepared: (u32, u32), previous: Option<&AtlasSnapshot>) -> Result<AtlasSnapshot> {
    let mut snapshot = layout.snapshot();
    snapshot.width = snapshot.width.max(prepared.0);
    snapshot.height = snapshot.height.max(prepared.1);
    snapshot.placements.retain(|p| selected.contains(&p.window));
    if let Some(previous) = previous {
        snapshot.revision = snapshot.revision.max(previous.revision);
        if snapshot != *previous {
            snapshot.revision = snapshot.revision.max(previous.revision.checked_add(1).ok_or_else(|| anyhow::anyhow!("atlas layout revision exhausted"))?);
        }
    }
    Ok(snapshot)
}

struct ActivityLanes {
    workers: [Option<crate::gpu_atlas_worker::GpuAtlasWorker>; 2],
    fallback: Option<GpuAtlasSender>,
    scheduler: crate::activity_atlas_scheduler::AtlasActivityScheduler,
    priority_layout: StableAtlas,
    rendered: [Option<AtlasSnapshot>; 2],
    canvas: [(u32, u32); 2],
    growing: [Option<(u32, u32)>; 2],
    capacity_failed: [bool; 2],
    fallback_pending: bool,
    last_activation: Option<u32>,
    next_frame: [u64; 2],
    last_capture: [u64; 2],
    started: [Option<Instant>; 2],
    publications: std::collections::VecDeque<crate::gpu_atlas_sender::AtlasPublication>,
    origin: Instant,
}
impl ActivityLanes {
    fn set_occlusion(&mut self, mode: crate::atlas_occlusion::AtlasOcclusionMode) {
        for worker in self.workers.iter_mut().flatten() { worker.set_occlusion(mode); }
        if let Some(sender) = &mut self.fallback { let _ = sender.set_occlusion(mode); }
    }
    fn busy(&self, lane: usize) -> bool {
        self.workers[lane].as_ref().is_some_and(|worker| worker.busy())
    }
    async fn collect(&mut self, pool: &mut AtlasCapturePool) -> Result<()> {
        use crate::gpu_atlas_worker::WorkerEvent;
        let mut fallback = false;
        for lane in self.scheduler.order(self.origin.elapsed().as_micros().min(u128::from(u64::MAX)) as u64) {
            let Some(worker) = &mut self.workers[lane] else { continue; };
            while let Some(event) = worker.poll()? {
                match event {
                    WorkerEvent::Released(receivers) => pool.restore_subset(receivers)?,
                    WorkerEvent::Batch(batch) => {
                        ensure!(batch.receivers.is_empty(), "worker retained released sources");
                        self.started[lane] = None;
                        if let Some(error) = batch.capacity_limited {
                            self.capacity_failed[lane] = true;
                            fallback = true;
                            eprintln!("atlas-activity fallback=single reason=sparse-allocation lane={lane} detail={error}");
                        }
                        if let Some(canvas) = batch.grown_canvas { self.canvas[lane] = canvas; }
                        if batch.manifest.is_some() || batch.committed_input.is_some() {
                            self.publications.push_back(crate::gpu_atlas_sender::AtlasPublication {
                                manifest: batch.manifest, committed_input: batch.committed_input,
                            });
                        }
                    }
                    WorkerEvent::Publication(publication) => self.publications.push_back(publication),
                    WorkerEvent::Grown => {
                        self.started[lane] = None;
                        if let Some(size) = self.growing[lane].take() { self.canvas[lane] = size; }
                    }
                    WorkerEvent::CapacityLimited(error) => {
                        self.started[lane] = None;
                        self.growing[lane] = None;
                        self.capacity_failed[lane] = true;
                        fallback = true;
                        eprintln!("atlas-activity fallback=single reason=canvas-allocation lane={lane} detail={error}");
                    }
                }
            }
        }
        if fallback {
            self.fallback_pending = true;
            self.scheduler.fallback()?;
        }
        if self.fallback_pending && !self.busy(1) {
            if let Some(priority) = self.workers[1].take() { priority.shutdown().await?; }
            self.fallback_pending = false;
        }
        if let Some(fallback) = &mut self.fallback {
            if let Some(publication) = fallback.poll_feedback().await? { self.publications.push_back(publication); }
        }
        Ok(())
    }
}

impl GpuAtlasDevice {
    pub(crate) fn source_reads_pending(&self, window: viewflow_protocol::WindowId) -> bool {
        self.active.as_ref().is_some_and(|(pool, _)| pool.source_reads_pending(window))
    }

    pub(crate) async fn retire_activity_workers(&mut self) -> Result<()> {
        if let Some(activity) = &mut self.activity {
            for worker in &mut activity.workers {
                if let Some(worker) = worker.take() { worker.shutdown().await?; }
            }
            activity.fallback.take();
        }
        Ok(())
    }

    /// Enable only after both peers accepted the activity extension. Resource
    /// preparation failures retain the warmed sender and use weighted lane 0.
    pub(crate) async fn enable_activity(&mut self, handle: crate::activity_priority::ActivityHandle, target_fps: u32) -> Result<()> {
        ensure!(self.activity.is_none(), "atlas activity already enabled");
        let (pool, sender) = self.active.as_mut().ok_or_else(|| anyhow::anyhow!("atlas device retired"))?;
        handle.observe(|state, _| state.membership(&pool.windows().iter().map(|id| (id.0, 0)).collect::<Vec<_>>()));
        let mut original = sender.take().ok_or_else(|| anyhow::anyhow!("atlas sender unavailable"))?;
        let base = self.layout.snapshot();
        let small = (128.min(self.canvas_limit.0), 128.min(self.canvas_limit.1));
        let recipe = original.worker_recipe()?.with_size(small.0, small.1);
        let priority_wire = original.fork_activity_lane()?;
        let mut workers = [None, None];
        let mut fallback = None;
        match crate::gpu_atlas_worker::GpuAtlasWorker::start(recipe, priority_wire).await {
            Ok(priority) => match original.into_worker().await {
                Ok(background) => { workers = [Some(background), Some(priority)]; }
                Err((error, original)) => {
                    priority.shutdown().await?;
                    eprintln!("atlas-activity fallback=single reason=background-encoder detail={error:#}");
                    fallback = Some(original);
                }
            },
            Err((error, _wire)) => {
                eprintln!("atlas-activity fallback=single reason=priority-encoder detail={error:#}");
                fallback = Some(original);
            }
        }
        let dual = fallback.is_none();
        let first = self.next_frame.checked_add(self.next_frame % 2).ok_or_else(|| anyhow::anyhow!("atlas frame sequence exhausted"))?;
        self.activity = Some(ActivityLanes {
            workers, fallback,
            scheduler: crate::activity_atlas_scheduler::AtlasActivityScheduler::new(handle, dual, target_fps),
            priority_layout: StableAtlas::new(AtlasConfig { width: small.0, height: small.1, alignment: 2, max_windows: self.max_windows })
                .map_err(|error| anyhow::anyhow!("priority atlas layout: {error:?}"))?,
            rendered: [None, None], canvas: [(base.width, base.height), small],
            growing: [None, None], capacity_failed: [false, false], fallback_pending: false, last_activation: None,
            next_frame: [first, first.checked_add(1).ok_or_else(|| anyhow::anyhow!("atlas frame sequence exhausted"))?],
            started: [None, None], last_capture: [0, 0], publications: Default::default(), origin: Instant::now(),
        });
        Ok(())
    }

    async fn poll_activity(&mut self, map_source_time: impl FnOnce(u64) -> Result<u64>, deadline: Instant) -> Result<AtlasDevicePoll> {
        let (mut pool, sender) = self.active.take().ok_or_else(|| anyhow::anyhow!("atlas device retired"))?;
        ensure!(sender.is_none(), "activity has a duplicate legacy sender");
        let mut activity = self.activity.take().ok_or_else(|| anyhow::anyhow!("activity owner unavailable"))?;
        let result = self.poll_activity_inner(&mut pool, &mut activity, map_source_time, deadline).await;
        // Even an operation error retains native workers until the session's
        // checked shutdown drains their GPU reads before stopping producers.
        self.active = Some((pool, None));
        self.activity = Some(activity);
        result
    }

    async fn poll_activity_inner(&mut self, pool: &mut AtlasCapturePool, activity: &mut ActivityLanes,
        map_source_time: impl FnOnce(u64) -> Result<u64>, deadline: Instant) -> Result<AtlasDevicePoll> {
        activity.collect(pool).await?;
        if activity.capacity_failed[0] {
            // Preserve every allocation that fits the last successful canvas.
            // Oversized tiles keep their old receiver picture until they fit.
            self.canvas_limit = activity.canvas[0];
            self.sparse_enabled = false;
            activity.set_occlusion(crate::atlas_occlusion::AtlasOcclusionMode::Off);
            let mut snapshot = self.layout.snapshot();
            snapshot.width = self.canvas_limit.0;
            snapshot.height = self.canvas_limit.1;
            snapshot.placements.retain(|p| p.allocation.x.saturating_add(p.allocation.width) <= snapshot.width
                && p.allocation.y.saturating_add(p.allocation.height) <= snapshot.height);
            self.layout = StableAtlas::from_snapshot(AtlasConfig { width: snapshot.width, height: snapshot.height, alignment: 2, max_windows: self.max_windows }, &snapshot)
                .map_err(|error| anyhow::anyhow!("retained atlas capacity: {error:?}"))?;
            activity.capacity_failed[0] = false;
        }
        if let Some(publication) = activity.publications.pop_front() {
            self.committed_input = publication.committed_input;
            if let Some(manifest) = publication.manifest {
                self.empty_published = manifest.tiles.is_empty() && pool.windows().is_empty();
                return Ok(AtlasDevicePoll::Enqueued(manifest));
            }
        }
        if let Some(desktop) = &self.desktop {
            let (window, serial) = desktop.lock().map_err(|_| anyhow::anyhow!("desktop source poisoned"))?.activity_activation();
            if serial > 0 && activity.last_activation != Some(serial) {
                if let Some(window) = window { activity.scheduler.local_activation(window); }
                activity.last_activation = Some(serial);
            }
        }
        activity.scheduler.refresh(pool.windows())?;
        let now_us = activity.origin.elapsed().as_micros().min(u128::from(u64::MAX)) as u64;
        let oldest = activity.started.iter().flatten().map(|start| start.elapsed().as_micros().min(u128::from(u64::MAX)) as u64).max().unwrap_or(0);
        if activity.scheduler.observe_queue(now_us, oldest, false) {
            eprintln!("atlas-activity background_fps={} queue_us={oldest}", activity.scheduler.background_fps());
        }
        let empty = pool.windows().is_empty();
        if empty && (self.empty_published || self.last_empty_submission.is_some_and(|last| last.elapsed().as_micros() < 16_667)) {
            return Ok(AtlasDevicePoll::Waiting);
        }
        for lane in activity.scheduler.order(now_us) {
            if activity.busy(lane) || (activity.fallback.is_some() && lane == 1) { continue; }
            let selected = activity.scheduler.select(lane, now_us);
            if selected.is_empty() && !(empty && lane == 0) { continue; }
            let mut sources = pool.poll_available_subset(&selected)?;
            let mut fresh = Vec::new();
            let mut stale = Vec::new();
            for mut source in sources {
                if source.frame.metadata().capture_monotonic_ns <= activity.last_capture[lane] {
                    // A migrated collector may hold an older picture than this
                    // encoder's last submission. Release it unencoded; preserve
                    // its timestamp and ask the producer for a fresh picture.
                    source.receiver.release_after_source_reads(&source.frame)?;
                    stale.push((source.window, source.receiver));
                } else { fresh.push(source); }
            }
            pool.restore_subset(stale)?;
            sources = fresh;
            if sources.is_empty() && !empty { continue; }
            let admitted: std::collections::BTreeSet<_> = sources.iter().map(|source| source.window).collect();
            for source in &sources {
                let frame = source.frame.metadata();
                let geometry = (frame.geometry_epoch, frame.crop_width, frame.crop_height);
                if let Some(previous) = self.capture_geometry.get(&source.window) {
                    ensure!(geometry.0 >= previous.0 && (geometry.0 != previous.0 || geometry == *previous),
                        "atlas capture changed size without advancing geometry epoch");
                }
                self.capture_geometry.insert(source.window, geometry);
            }
            let captures: Vec<_> = sources.iter().map(|source| {
                let frame = source.frame.metadata();
                (source.window, frame.geometry_epoch, frame.crop_width, frame.crop_height)
            }).collect();
            // The background allocation retains every window's slot throughout
            // promotion. Priority has a separate compact, independently growing canvas.
            let (global, _) = stage_capture_layout_with_limit(&self.layout, captures.iter().copied(), self.canvas_limit)?;
            self.layout = global;
            let (layout, paused) = if lane == 1 {
                let mut previous = activity.priority_layout.clone();
                for placement in previous.snapshot().placements {
                    if !selected.contains(&placement.window) {
                        previous.remove(placement.window).map_err(|error| anyhow::anyhow!("priority atlas removal: {error:?}"))?;
                    }
                }
                let (next, paused) = stage_capture_layout_with_limit(&previous, captures, self.canvas_limit)?;
                activity.priority_layout = next.clone();
                (next, paused)
            } else {
                let paused = admitted.iter().filter(|id| self.layout.placement(**id).is_none()).copied().collect();
                (self.layout.clone(), paused)
            };
            let displayed = admitted.difference(&paused).copied().collect();
            let snapshot = activity_render_snapshot(&layout, &displayed, activity.canvas[lane], activity.rendered[lane].as_ref())?;
            let mut restored = Vec::new();
            let mut kept = Vec::new();
            for mut source in sources.drain(..) {
                if paused.contains(&source.window) {
                    source.receiver.release_after_source_reads(&source.frame)?;
                    restored.push((source.window, source.receiver));
                } else { kept.push(source); }
            }
            pool.restore_subset(restored)?;
            sources = kept;
            // Within background work, capture the last activated window first
            // while retaining the stable allocation and native stacking order.
            let focus = activity.scheduler.frame(lane)?.focus;
            sources.sort_by_key(|source| (Some(source.window) != focus, source.window));
            let needed = (snapshot.width, snapshot.height);
            if needed.0 > activity.canvas[lane].0 || needed.1 > activity.canvas[lane].1 {
                let mut restored = Vec::new();
                for mut source in sources {
                    source.receiver.release_after_source_reads(&source.frame)?;
                    restored.push((source.window, source.receiver));
                }
                pool.restore_subset(restored)?;
                if let Some(worker) = &mut activity.workers[lane] {
                    worker.grow(needed.0, needed.1)?;
                    activity.started[lane] = Some(Instant::now());
                    activity.growing[lane] = Some(needed);
                } else if let Some(fallback) = &mut activity.fallback {
                    let (publication, growth) = fallback.grow_canvas_recoverable(needed.0, needed.1).await?;
                    if let Some(publication) = publication { activity.publications.push_back(publication); }
                    match growth {
                        Ok(()) => activity.canvas[lane] = needed,
                        Err(error) => {
                            activity.capacity_failed[lane] = true;
                            eprintln!("atlas-activity retained_canvas={}x{} reason={error:#}", activity.canvas[lane].0, activity.canvas[lane].1);
                        }
                    }
                }
                return Ok(AtlasDevicePoll::Waiting);
            }
            let native_now = crate::gpu_nvenc_runtime::monotonic_ns()?;
            let captured = sources.iter().map(|source| source.frame.metadata().capture_monotonic_ns).min().unwrap_or(u64::try_from(native_now)?);
            let native_deadline = sources.iter().map(|source| source.deadline_monotonic_ns).min().unwrap_or(
                native_now.checked_add(i64::try_from(pool.max_age_ns())?).ok_or_else(|| anyhow::anyhow!("atlas deadline overflow"))?);
            let desktop = self.desktop.as_ref().map(|desktop| desktop.lock().map_err(|_| anyhow::anyhow!("desktop source poisoned"))?.layout_for_admitted(&sources)).transpose()?;
            let frame_id = activity.next_frame[lane];
            let batch = AtlasBatch {
                activity: Some(activity.scheduler.frame(lane)?), codec: self.codec, layout: snapshot.clone(),
                identity: GpuAtlasIdentity { frame_id, capture_monotonic_ns: captured, geometry_epoch: self.geometry_epoch },
                mapped_source_ns: map_source_time(captured)?, deadline_monotonic_ns: native_deadline, sources, desktop,
            };
            if let Some(worker) = &mut activity.workers[lane] {
                worker.submit(batch, frame_id, deadline)?;
                activity.started[lane] = Some(Instant::now());
            } else if let Some(fallback) = &mut activity.fallback {
                let result = fallback.submit_batch(batch, frame_id, deadline).await?;
                pool.restore_subset(result.receivers)?;
                if let Some(error) = result.capacity_limited {
                    activity.capacity_failed[lane] = true;
                    eprintln!("atlas-activity retained_canvas reason=sparse-allocation detail={error}");
                }
                if let Some(canvas) = result.grown_canvas { activity.canvas[lane] = canvas; }
                if result.manifest.is_some() || result.committed_input.is_some() {
                    activity.publications.push_back(crate::gpu_atlas_sender::AtlasPublication { manifest: result.manifest, committed_input: result.committed_input });
                }
            }
            activity.last_capture[lane] = captured;
            activity.next_frame[lane] = frame_id.checked_add(2).ok_or_else(|| anyhow::anyhow!("atlas frame sequence exhausted"))?;
            activity.rendered[lane] = Some(snapshot);
            activity.scheduler.admitted(lane, &admitted, now_us);
            if empty { self.last_empty_submission = Some(Instant::now()); }
            return Ok(AtlasDevicePoll::Submitted);
        }
        Ok(AtlasDevicePoll::Waiting)
    }
}

#[cfg(test)]
mod capacity_tests {
    use super::*;
    use viewflow_protocol::Id128;

    #[test]
    fn activity_subset_revisions_keep_background_slots_and_static_snapshots() {
        let mut layout = StableAtlas::new(AtlasConfig {width:128,height:128,alignment:2,max_windows:4}).unwrap();
        layout.place(Id128(1),1,32,32).unwrap();
        layout.place(Id128(2),1,32,32).unwrap();
        let stable = layout.snapshot();
        let first = activity_render_snapshot(&layout,&[Id128(1)].into(),(128,128),None).unwrap();
        let second = activity_render_snapshot(&layout,&[Id128(2)].into(),(128,128),Some(&first)).unwrap();
        assert!(second.revision > first.revision);
        assert_eq!(second.placements[0],stable.placements[1]);
        let unchanged = activity_render_snapshot(&layout,&[Id128(2)].into(),(128,128),Some(&second)).unwrap();
        assert_eq!(second,unchanged);
        assert_eq!(layout.snapshot(),stable);
        let grown = activity_render_snapshot(&layout,&[Id128(2)].into(),(256,128),Some(&second)).unwrap();
        assert_eq!((grown.width,grown.height),(256,128));
        assert!(grown.revision > second.revision);
    }

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
