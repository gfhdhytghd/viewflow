//! Single-owner batch handoff: GPU source leases, encoder and QUIC sender.
//! This is not the capture discovery loop or a native presentation receipt.
use anyhow::{Context, Result, ensure};
use tokio::time::Instant;
use viewflow_core::AtlasSnapshot;
use viewflow_protocol::WindowId;

use crate::{
    atlas_session::AtlasSenderSession,
    compatible_encoder::CodecIdentity,
    gpu_compatible_encoder::{
        AtlasSource, AtlasSubmission, AtlasSubmitOutcome, GpuAtlasCompatibleEncoder,
    },
    gpu_nvenc_runtime::GpuAtlasIdentity,
    hyprcapture_gpu_socket::{GpuFrame, HyprCaptureGpuSocketReceiver},
};

/// Disabled by default. Sample startup and every 30th atlas so diagnostics do
/// not add a per-frame stderr write to the live scheduling path.
fn trace_enabled() -> bool {
    crate::atlas_feedback::trace_frame(0)
}

fn trace_frame(frame: u64) -> bool {
    crate::atlas_feedback::trace_frame(frame)
}

fn trace_clock(enabled: bool) -> Option<i64> {
    enabled
        .then(crate::gpu_nvenc_runtime::monotonic_ns)
        .and_then(Result::ok)
}

/// Owns the receiver as well as its outstanding frame. Dropping this value
/// closes the producer session without asserting GPU-read completion.
pub struct AtlasCaptureLease {
    pub window: WindowId,
    pub receiver: HyprCaptureGpuSocketReceiver,
    pub frame: Box<GpuFrame>,
    pub deadline_monotonic_ns: i64,
    /// Local post-recv sample only; never a replacement capture timestamp.
    pub received_monotonic_ns: i64,
}

pub struct AtlasBatch {
    pub activity: Option<viewflow_protocol::AtlasActivity>,
    pub codec: CodecIdentity,
    pub layout: AtlasSnapshot,
    pub identity: GpuAtlasIdentity,
    pub mapped_source_ns: u64,
    pub deadline_monotonic_ns: i64,
    pub sources: Vec<AtlasCaptureLease>,
    /// Built from the HCGF frames in `sources` before they are released.
    pub desktop: Option<viewflow_protocol::AtlasDesktopLayout>,
}

impl AtlasBatch {
    fn trace_encoded_budget(&self, lease_limit: i64) -> Result<()> {
        if self.identity.frame_id <= 6 {
            let now = crate::gpu_nvenc_runtime::monotonic_ns()?;
            eprintln!(
                "atlas-source-budget frame={} phase=encoded source_age_us={} remaining_us={}",
                self.identity.frame_id,
                now.saturating_sub(i64::try_from(self.identity.capture_monotonic_ns)?) / 1000,
                lease_limit.saturating_sub(now) / 1000
            );
        }
        Ok(())
    }

    fn input_snapshots(&self) -> Vec<(WindowId, crate::window_input_runtime::CapturedWindowInput)> {
        self.sources
            .iter()
            .map(|source| {
                (
                    source.window,
                    crate::window_input_runtime::CapturedWindowInput::from_gpu_frame(&source.frame),
                )
            })
            .collect()
    }
}

/// Reusable capture receivers are returned only after all releases succeeded.
pub struct AtlasBatchSent {
    pub capacity_limited: Option<String>,
    pub grown_canvas: Option<(u32, u32)>,
    pub submitted: bool,
    pub receivers: Vec<(WindowId, HyprCaptureGpuSocketReceiver)>,
    /// Previous frame's exact native disposition, collected while the current
    /// batch encodes. None also covers the first pipelined submission, whose
    /// receipt has not arrived yet; `submitted` distinguishes that case.
    pub manifest: Option<viewflow_protocol::AtlasFrame>,
    pub committed_input: Option<crate::window_input_runtime::AtlasCommittedInput>,
}

pub(crate) struct AtlasPublication {
    pub manifest: Option<viewflow_protocol::AtlasFrame>,
    pub committed_input: Option<crate::window_input_runtime::AtlasCommittedInput>,
}

struct SendCompletion {
    sender: AtlasSenderSession,
    publication: AtlasPublication,
    reference_gap: bool,
}

// The sole wire sender moves into one bounded task. No DMA-BUF or encoder
// owner crosses into it; the next capture can encode while feedback is pending.
struct PendingAtlasSend(tokio::task::JoinHandle<Result<SendCompletion>>);
impl Drop for PendingAtlasSend {
    fn drop(&mut self) {
        self.0.abort();
    }
}

pub struct GpuAtlasSender {
    encoder: Option<GpuAtlasCompatibleEncoder>,
    sender: Option<AtlasSenderSession>,
    pending: Option<PendingAtlasSend>,
    reference_gap: bool,
    canvas_limit: (u32, u32),
    last_batch_return_ns: Option<i64>,
}

impl GpuAtlasSender {
    pub(crate) fn fork_activity_lane(&mut self) -> Result<AtlasSenderSession> {
        ensure!(self.pending.is_none(), "activity split requires idle startup");
        self.sender.as_mut().context("atlas sender unavailable")?.fork_activity_lane()
    }

    pub(crate) async fn into_worker(mut self) -> std::result::Result<crate::gpu_atlas_worker::GpuAtlasWorker, (anyhow::Error, Self)> {
        if self.pending.is_some() {
            return Err((anyhow::anyhow!("atlas worker conversion requires an idle wire"), self));
        }
        let recipe = match self.worker_recipe() {
            Ok(recipe) => recipe,
            Err(error) => return Err((error, self)),
        };
        let Some(wire) = self.sender.take() else {
            return Err((anyhow::anyhow!("atlas wire sender unavailable"), self));
        };
        match crate::gpu_atlas_worker::GpuAtlasWorker::start(recipe, wire).await {
            Ok(worker) => Ok(worker),
            Err((error, wire)) => { self.sender = Some(wire); Err((error, self)) }
        }
    }
    pub(crate) fn worker_recipe(&self) -> Result<crate::gpu_compatible_encoder::AtlasEncoderRecipe> {
        self.encoder.as_ref().context("atlas encoder retired")?.worker_recipe()
    }
    pub(crate) fn occlusion_enabled(&self) -> bool {
        self.encoder
            .as_ref()
            .is_some_and(GpuAtlasCompatibleEncoder::occlusion_enabled)
    }

    pub(crate) fn set_occlusion(
        &mut self,
        mode: crate::atlas_occlusion::AtlasOcclusionMode,
    ) -> Result<()> {
        self.encoder
            .as_mut()
            .context("atlas encoder retired")?
            .set_occlusion(mode, self.canvas_limit);
        Ok(())
    }

    pub(crate) fn next_frame_id(&self) -> Result<u64> {
        self.encoder
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("atlas sender retired"))?
            .next_frame_id()
    }

    #[must_use]
    pub fn is_retired(&self) -> bool {
        self.encoder.is_none()
    }

    #[must_use]
    pub fn new(encoder: GpuAtlasCompatibleEncoder, sender: AtlasSenderSession) -> Self {
        let canvas_limit = sender.canvas_limit();
        Self {
            encoder: Some(encoder),
            sender: Some(sender),
            pending: None,
            canvas_limit,
            reference_gap: false,
            last_batch_return_ns: None,
        }
    }

    pub(crate) fn canvas_limit(&self) -> (u32, u32) {
        self.canvas_limit
    }

    pub(crate) async fn grow_canvas(
        &mut self,
        width: u32,
        height: u32,
    ) -> Result<Option<AtlasPublication>> {
        let (publication, growth) = self.grow_canvas_recoverable(width, height).await?;
        growth?;
        Ok(publication)
    }

    /// Transport failure remains an outer error. Allocation failure leaves the
    /// old encoder untouched and is returned separately for lane fallback.
    pub(crate) async fn grow_canvas_recoverable(&mut self, width: u32, height: u32)
        -> Result<(Option<AtlasPublication>, Result<()>)> {
        ensure!(width <= self.canvas_limit.0 && height <= self.canvas_limit.1,
            "atlas growth exceeds negotiated capacity");
        let publication = self.finish_pending().await?;
        let growth = self.encoder.as_mut().context("atlas encoder retired")?.grow_canvas(width, height);
        Ok((publication, growth))
    }

    async fn finish_pending(&mut self) -> Result<Option<AtlasPublication>> {
        let Some(mut pending) = self.pending.take() else {
            return Ok(None);
        };
        let completed = (&mut pending.0)
            .await
            .map_err(|error| anyhow::anyhow!("atlas send worker: {error}"))??;
        self.reference_gap |= completed.reference_gap;
        self.sender = Some(completed.sender);
        Ok(Some(completed.publication))
    }

    pub(crate) async fn poll_feedback(&mut self) -> Result<Option<AtlasPublication>> {
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| pending.0.is_finished())
        {
            self.finish_pending().await
        } else {
            Ok(None)
        }
    }

    /// Cancel-safe wait used by an idle codec worker. The task stays in its
    /// owner if a newly queued capture wins the select; no polling timer needed.
    pub(crate) async fn wait_feedback(&mut self) -> Result<AtlasPublication> {
        let Some(pending) = self.pending.as_mut() else {
            return std::future::pending().await;
        };
        let completed = (&mut pending.0).await
            .map_err(|error| anyhow::anyhow!("atlas send worker: {error}"))??;
        self.pending.take();
        self.reference_gap |= completed.reference_gap;
        self.sender = Some(completed.sender);
        Ok(completed.publication)
    }

    /// The encoder must have been prepared before capture leases were acquired.
    /// Native submission proves source reads complete before any HCGR is sent.
    /// One wire task retains the sender while the next batch encodes. Source
    /// receivers return only after GPU reads complete, and input snapshots are
    /// published only with their own frame's exact native disposition.
    /// # Errors
    /// Rejects foreign leases, failed encoding/releases or failed transport.
    pub async fn submit_batch(
        &mut self,
        batch: AtlasBatch,
        sequence: u64,
        deadline: Instant,
    ) -> Result<AtlasBatchSent> {
        self.submit_batch_with_release(batch, sequence, deadline, None).await
    }

    /// Worker lanes return capture ownership as soon as native reads finish.
    /// Waiting for the prior network receipt must not pin a migrating source.
    pub(crate) async fn submit_batch_with_release(
        &mut self,
        mut batch: AtlasBatch,
        sequence: u64,
        deadline: Instant,
        released: Option<Box<dyn FnOnce(Vec<(WindowId, HyprCaptureGpuSocketReceiver)>) -> Result<()> + Send>>,
    ) -> Result<AtlasBatchSent> {
        let mut encoder = self
            .encoder
            .take()
            .ok_or_else(|| anyhow::anyhow!("GPU atlas sender is retired"))?;
        if self.reference_gap {
            encoder.request_keyframe();
        }
        // If the scheduling target elapsed before this turn, the zero native
        // budget below follows the encoder's clean-drop path and keeps owners.

        // Sample the native clock first: any time spent sampling the Tokio
        // clock can only shorten the native budget, never renew it.
        let native_now = crate::gpu_nvenc_runtime::monotonic_ns()?;
        let remaining = deadline.saturating_duration_since(Instant::now());
        let transport_limit = native_now
            .checked_add(i64::try_from(remaining.as_nanos())?)
            .ok_or_else(|| anyhow::anyhow!("atlas deadline overflow"))?;
        batch.deadline_monotonic_ns = batch.deadline_monotonic_ns.min(transport_limit);
        let lease_limit = batch
            .sources
            .iter()
            .fold(batch.deadline_monotonic_ns, |limit, source| {
                limit.min(source.deadline_monotonic_ns)
            });
        // Bound transport as well as GPU work by the oldest original lease.
        // Reverse the sample order when mapping native time back to Tokio.
        let send_clock = Instant::now();
        let native_now = crate::gpu_nvenc_runtime::monotonic_ns()?;
        let remaining = u64::try_from(lease_limit.saturating_sub(native_now).max(0))?;
        let deadline = deadline.min(send_clock + std::time::Duration::from_nanos(remaining));
        for source in &batch.sources {
            source.receiver.validate_outstanding(&source.frame)?;
        }
        // Copy only metadata while the authenticated frame is still owned.
        // This does not keep a DMA-BUF alive after source-read completion.
        let input_snapshots = batch.input_snapshots();
        let sources: Vec<_> = batch
            .sources
            .iter()
            .map(|source| AtlasSource {
                window: source.window,
                frame: &source.frame,
                deadline_monotonic_ns: source.deadline_monotonic_ns,
            })
            .collect();
        let trace = trace_frame(batch.identity.frame_id);
        let encode_started = trace_clock(trace);
        encoder.stable_sparse_placement = batch.activity.is_some();
        let outcome = encoder.submit_recoverable(AtlasSubmission {
            codec: batch.codec,
            layout: &batch.layout,
            identity: batch.identity,
            mapped_source_ns: batch.mapped_source_ns,
            deadline_monotonic_ns: batch.deadline_monotonic_ns,
            sources: &sources,
            desktop: batch.desktop.as_ref(),
        })?;
        let encoded_at = trace_clock(trace);
        batch.trace_encoded_budget(lease_limit)?;
        // Both Encoded and ExpiredClean prove source-read completion. Errors
        // return above without releasing any allocation.
        for source in &mut batch.sources {
            source.receiver.release_after_source_reads(&source.frame)?;
        }
        let released_at = trace_clock(trace);
        let source_trace: Vec<_> = batch.sources.iter().map(|source| (
            source.window, source.frame.metadata().sequence,
            source.frame.metadata().capture_monotonic_ns, source.received_monotonic_ns,
        )).collect();
        if let Some(released) = released {
            released(batch.sources.drain(..).map(|source| (source.window, source.receiver)).collect())?;
        }
        // At most one frame is on the wire and one is encoded ahead. Keep the
        // original capture deadline when waiting for the previous disposition.
        let previous = self.finish_pending().await?;
        let (sent, committed_input) = previous
            .map(|publication| (publication.manifest, publication.committed_input))
            .unwrap_or((None, None));
        let mut submitted = false;
        let mut grown_canvas = None;
        let mut capacity_limited = None;
        match outcome {
            AtlasSubmitOutcome::NeedsCanvas { width, height } => {
                ensure!(
                    width <= self.canvas_limit.0 && height <= self.canvas_limit.1,
                    "sparse growth exceeds negotiated capacity"
                );
                // Every producer lease was released above, and prior wire work
                // was drained before the old encoder is replaced.
                match encoder.grow_canvas(width, height) {
                    Ok(()) => {
                        grown_canvas = Some((width, height));
                        eprintln!("atlas-source-canvas sparse_grew={width}x{height}");
                    }
                    Err(error) if batch.activity.is_some() => capacity_limited = Some(format!("{error:#}")),
                    Err(error) => return Err(error),
                }
            }
            AtlasSubmitOutcome::ExpiredClean => {
                encoder.request_keyframe();
                self.reference_gap = true;
            }
            AtlasSubmitOutcome::Encoded {
                manifest,
                mut media,
                ..
            } => {
                let mut manifest = *manifest;
                manifest.activity = batch.activity.clone();
                ensure!(media.len() == 1, "atlas encoder did not return one pair");
                if self.reference_gap && !(manifest.color_keyframe && manifest.alpha_keyframe) {
                    // A previous clean drop invalidated this already-encoded P
                    // picture. Start a fresh pair next turn without sending it.
                    encoder.request_keyframe();
                } else {
                    let mut sender = self
                        .sender
                        .take()
                        .ok_or_else(|| anyhow::anyhow!("atlas wire sender missing"))?;
                    self.reference_gap = false;
                    self.pending = Some(PendingAtlasSend(tokio::spawn(async move {
                        let enqueued = send_or_expire(
                            &mut sender,
                            manifest.clone(),
                            media.remove(0),
                            sequence,
                            deadline,
                        )
                        .await?;
                        let disposition = sender.last_disposition();
                        let reference_gap = !enqueued
                            || disposition
                                == Some(
                                    crate::atlas_feedback::AtlasFrameDisposition::ExpiredUnbound,
                                );
                        let committed_input = if enqueued {
                            crate::window_input_runtime::AtlasCommittedInput::from_feedback(
                                &manifest,
                                input_snapshots,
                                disposition,
                            )?
                        } else {
                            None
                        };
                        Ok(SendCompletion {
                            sender,
                            reference_gap,
                            publication: AtlasPublication {
                                manifest: if reference_gap { None } else { Some(manifest) },
                                committed_input,
                            },
                        })
                    })));
                    submitted = true;
                }
            }
        }
        let batch_return_ns = trace_clock(trace_enabled());
        if let (Some(start), Some(encoded), Some(released), Some(done)) =
            (encode_started, encoded_at, released_at, batch_return_ns)
        {
            let captured = i64::try_from(batch.identity.capture_monotonic_ns).unwrap_or(i64::MAX);
            let first_received = source_trace.iter().map(|s| s.3).min().unwrap_or(start);
            let max_socket_age = source_trace.iter().map(|s|
                s.3.saturating_sub(i64::try_from(s.2).unwrap_or(i64::MAX))
            ).max().unwrap_or(0);
            let previous_batch_return_ns = self.last_batch_return_ns;
            let queued_before_previous_return_us = previous_batch_return_ns
                .map(|previous| previous.saturating_sub(captured).max(0) / 1000)
                .unwrap_or(0);
            let identities = source_trace;
            crate::atlas_feedback::trace_line(format_args!(
                "atlas-source-timing frame={} source_identities_window_sequence_capture_ns_received_ns={identities:?} encode_start_ns={start} encoded_ns={encoded} released_ns={released} batch_return_ns={done} previous_batch_return_ns={previous_batch_return_ns:?} captured_before_previous_return_us={queued_before_previous_return_us} socket_age_max_us={} collector_to_encode_us={} capture_to_encode_start_us={} encode_us={} release_us={} previous_feedback_wait_us={} capture_to_batch_return_us={} encoded_ahead_submitted={submitted} published={} native_commit_time_not_measured=true",
                batch.identity.frame_id,
                max_socket_age / 1000,
                start.saturating_sub(first_received) / 1000,
                start.saturating_sub(captured) / 1000,
                encoded.saturating_sub(start) / 1000,
                released.saturating_sub(encoded) / 1000,
                done.saturating_sub(released) / 1000,
                done.saturating_sub(captured) / 1000,
                sent.is_some(),
            ));
        }
        self.last_batch_return_ns = batch_return_ns;
        self.encoder = Some(encoder);
        Ok(AtlasBatchSent {
            capacity_limited,
            grown_canvas,
            submitted,
            receivers: batch
                .sources
                .into_iter()
                .map(|source| (source.window, source.receiver))
                .collect(),
            manifest: sent,
            committed_input,
        })
    }
}

async fn send_or_expire(
    sender: &mut AtlasSenderSession,
    manifest: viewflow_protocol::AtlasFrame,
    media: crate::compatible_encoder::MediaFrame,
    sequence: u64,
    deadline: Instant,
) -> Result<bool> {
    match sender
        .send_coded_frame(manifest, media, sequence, deadline)
        .await
    {
        Ok(()) => Ok(true),
        // Only this typed boundary proves that no manifest or media was queued.
        // The caller must request a keyframe and publish no input evidence.
        Err(error) if error.is::<crate::atlas_session::AtlasFrameExpiredBeforeSend>() => Ok(false),
        Err(error) => Err(error),
    }
}
