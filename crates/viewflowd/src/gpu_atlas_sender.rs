//! Single-owner batch handoff: GPU source leases, encoder and QUIC sender.
//! This is not the capture discovery loop or a native presentation receipt.
use anyhow::{Result, ensure};
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
    static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ENABLED.get_or_init(|| {
        std::env::var_os("VIEWFLOW_ATLAS_TIMINGS").is_some_and(|value| value == "1")
    })
}

fn trace_frame(frame: u64) -> bool {
    trace_enabled() && (frame <= 8 || frame % 30 == 0)
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
    pub receivers: Vec<(WindowId, HyprCaptureGpuSocketReceiver)>,
    /// Enqueued metadata retained for later presentation-receipt correlation.
    /// None means a clean local expiry or exact remote expired-unbound feedback;
    /// neither is presentation, but the latter did transmit the encoded frame.
    pub manifest: Option<viewflow_protocol::AtlasFrame>,
    pub committed_input: Option<crate::window_input_runtime::AtlasCommittedInput>,
}

pub struct GpuAtlasSender {
    active: Option<(GpuAtlasCompatibleEncoder, AtlasSenderSession)>,
    last_batch_return_ns: Option<i64>,
}

impl GpuAtlasSender {
    pub(crate) fn next_frame_id(&self) -> Result<u64> {
        self.active
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("atlas sender retired"))?
            .0
            .next_frame_id()
    }

    #[must_use]
    pub fn is_retired(&self) -> bool {
        self.active.is_none()
    }

    #[must_use]
    pub fn new(encoder: GpuAtlasCompatibleEncoder, sender: AtlasSenderSession) -> Self {
        Self {
            active: Some((encoder, sender)),
            last_batch_return_ns: None,
        }
    }

    /// The encoder must have been prepared before capture leases were acquired.
    /// Native submission proves source reads complete before any HCGR is sent.
    /// A failed/cancelled call drops both active components and all receivers;
    /// only a fully successful call restores the persistent encoder and sender.
    /// # Errors
    /// Rejects foreign leases, failed encoding/releases or failed transport.
    pub async fn submit_batch(
        &mut self,
        mut batch: AtlasBatch,
        sequence: u64,
        deadline: Instant,
    ) -> Result<AtlasBatchSent> {
        let (mut encoder, mut sender) = self
            .active
            .take()
            .ok_or_else(|| anyhow::anyhow!("GPU atlas sender is retired"))?;
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
        let mut frame_disposition = None;
        let mut committed_input = None;
        let sent = match outcome {
            AtlasSubmitOutcome::ExpiredClean => {
                // The device advances atlas IDs even when nothing was encoded.
                // Its receiver therefore sees a frame gap and requires a fresh
                // paired keyframe; continuing a P chain would retire that peer.
                encoder.request_keyframe();
                None
            }
            AtlasSubmitOutcome::Encoded {
                manifest,
                mut media,
                ..
            } => {
                let manifest = *manifest;
                ensure!(media.len() == 1, "atlas encoder did not return one pair");
                let enqueued = send_or_expire(
                    &mut sender,
                    manifest.clone(),
                    media.remove(0),
                    sequence,
                    deadline,
                )
                .await?;
                if enqueued {
                    frame_disposition = sender.last_disposition();
                    committed_input =
                        crate::window_input_runtime::AtlasCommittedInput::from_feedback(
                            &manifest,
                            input_snapshots,
                            sender.last_disposition(),
                        )?;
                }
                if !enqueued
                    || sender.last_disposition()
                        == Some(crate::atlas_feedback::AtlasFrameDisposition::ExpiredUnbound)
                {
                    encoder.request_keyframe();
                    None
                } else {
                    Some(manifest)
                }
            }
        };
        let batch_return_ns = trace_clock(trace_enabled());
        if let (Some(start), Some(encoded), Some(released), Some(done)) =
            (encode_started, encoded_at, released_at, batch_return_ns)
        {
            let captured = i64::try_from(batch.identity.capture_monotonic_ns).unwrap_or(i64::MAX);
            let first_received = batch
                .sources
                .iter()
                .map(|source| source.received_monotonic_ns)
                .min()
                .unwrap_or(start);
            let max_socket_age = batch
                .sources
                .iter()
                .map(|source| {
                    source.received_monotonic_ns.saturating_sub(
                        i64::try_from(source.frame.metadata().capture_monotonic_ns)
                            .unwrap_or(i64::MAX),
                    )
                })
                .max()
                .unwrap_or(0);
            let previous_batch_return_ns = self.last_batch_return_ns;
            let queued_before_previous_return_us = previous_batch_return_ns
                .map(|previous| previous.saturating_sub(captured).max(0) / 1000)
                .unwrap_or(0);
            let identities: Vec<_> = batch
                .sources
                .iter()
                .map(|source| {
                    (
                        source.window,
                        source.frame.metadata().sequence,
                        source.frame.metadata().capture_monotonic_ns,
                        source.received_monotonic_ns,
                    )
                })
                .collect();
            eprintln!(
                "atlas-source-timing frame={} source_identities_window_sequence_capture_ns_received_ns={identities:?} encode_start_ns={start} encoded_ns={encoded} released_ns={released} feedback_return_ns={done} previous_batch_return_ns={previous_batch_return_ns:?} captured_before_previous_return_us={queued_before_previous_return_us} socket_age_max_us={} collector_to_encode_us={} capture_to_encode_start_us={} encode_us={} release_us={} send_feedback_us={} capture_to_feedback_us={} disposition={frame_disposition:?} published={} native_commit_time_not_measured=true",
                batch.identity.frame_id,
                max_socket_age / 1000,
                start.saturating_sub(first_received) / 1000,
                start.saturating_sub(captured) / 1000,
                encoded.saturating_sub(start) / 1000,
                released.saturating_sub(encoded) / 1000,
                done.saturating_sub(released) / 1000,
                done.saturating_sub(captured) / 1000,
                sent.is_some(),
            );
        }
        self.last_batch_return_ns = batch_return_ns;
        self.active = Some((encoder, sender));
        Ok(AtlasBatchSent {
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
