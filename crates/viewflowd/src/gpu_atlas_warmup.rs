//! Real captured atlas startup pictures; never admitted as live media.
use anyhow::{Context, Result, ensure};
use std::time::Duration;
use tokio::time::Instant;
use viewflow_core::{AtlasConfig, AtlasSnapshot, StableAtlas};
use viewflow_protocol::WindowId;

use crate::{
    atlas_presenter::AtlasWarmupFrame,
    atlas_session::AtlasSessionPlan,
    compatible_encoder::CodecIdentity,
    gpu_atlas_capture::AtlasCapturePool,
    gpu_compatible_encoder::{
        AtlasSource, AtlasSubmission, AtlasSubmitOutcome, GpuAtlasCompatibleEncoder,
    },
    gpu_nvenc_runtime::GpuAtlasIdentity,
    hyprcapture_runtime::{GpuStreamSession, GpuStreamShutdown},
};

pub struct GpuAtlasWarmup {
    active: Option<(AtlasCapturePool, GpuAtlasCompatibleEncoder)>,
    stops: GpuStreamShutdown,
    plan: AtlasSessionPlan,
    layout: AtlasSnapshot,
    captured_layout: Option<StableAtlas>,
    next_frame: u64,
    stopping: bool,
}

impl GpuAtlasWarmup {
    /// Collect exactly three startup pictures under one original deadline and
    /// stop all producers before returning payloads for network negotiation.
    /// # Errors
    /// Stop, timeout, capture/encode failure or unconfirmed cleanup aborts startup.
    pub async fn collect_until(
        &mut self,
        deadline: Instant,
        stop: impl std::future::Future<Output = ()>,
    ) -> Result<[AtlasWarmupFrame; 3]> {
        let result = self.collect_active_until(deadline, stop).await;
        let cleanup = self.shutdown().await;
        match (result, cleanup) {
            (Ok(frames), Ok(())) => Ok(frames),
            (Err(error), Ok(())) | (Ok(_), Err(error)) => Err(error),
            (Err(error), Err(cleanup)) => {
                Err(error.context(format!("warmup cleanup failed: {cleanup:#}")))
            }
        }
    }

    /// Leave ownership active for continuously drained network negotiation.
    /// The caller must transfer it to a live session or await shutdown on error.
    pub(crate) async fn collect_active_until(
        &mut self,
        deadline: Instant,
        stop: impl std::future::Future<Output = ()>,
    ) -> Result<[AtlasWarmupFrame; 3]> {
        tokio::pin!(stop);
        async {
            let mut frames = Vec::with_capacity(3);
            loop {
                // Observe stop before submitting another synchronous GPU batch.
                tokio::select! {
                    biased;
                    () = &mut stop => anyhow::bail!("local stop during atlas warmup"),
                    () = tokio::time::sleep_until(deadline) => anyhow::bail!("atlas warmup timed out"),
                    () = std::future::ready(()) => {},
                }
                if let Some(frame) = self.poll(deadline)? {
                    frames.push(frame);
                    if frames.len() == 3 {
                        return frames.try_into().map_err(|_| anyhow::anyhow!("warmup count"));
                    }
                }
                tokio::select! {
                    biased;
                    () = &mut stop => anyhow::bail!("local stop during atlas warmup"),
                    () = tokio::time::sleep_until(deadline) => anyhow::bail!("atlas warmup timed out"),
                    () = tokio::time::sleep(Duration::from_millis(1)) => {},
                }
            }
        }.await
    }

    /// Drive network startup while releasing captures never submitted to GPU.
    pub(crate) async fn await_draining<T>(
        &mut self,
        work: impl std::future::Future<Output = Result<T>>,
        deadline: Instant,
        stop: impl std::future::Future<Output = ()>,
    ) -> Result<T> {
        tokio::pin!(work);
        tokio::pin!(stop);
        loop {
            tokio::select! {
                biased;
                () = &mut stop => anyhow::bail!("local stop during drained atlas startup"),
                () = tokio::time::sleep_until(deadline) => anyhow::bail!("drained atlas startup timed out"),
                result = &mut work => return result,
                () = tokio::time::sleep(Duration::from_millis(1)) => self.drain()?,
            }
        }
    }

    fn drain(&mut self) -> Result<()> {
        ensure!(!self.stopping, "warmup is stopping");
        let (mut pool, encoder) = self.active.take().context("warmup retired")?;
        if let Some(mut leases) = pool.poll_ready()? {
            // None of these frames has been submitted to any GPU reader.
            for lease in &mut leases {
                lease.receiver.release_after_source_reads(&lease.frame)?;
            }
            pool.restore(leases.into_iter().map(|s| (s.window, s.receiver)).collect())?;
        }
        self.active = Some((pool, encoder));
        Ok(())
    }

    pub(crate) async fn into_live(
        mut self,
        sender: crate::atlas_session::AtlasSenderSession,
    ) -> Result<crate::gpu_atlas_session::GpuAtlasSession> {
        let (mut pool, mut encoder) = match self.active.take() {
            Some(active) if !self.stopping => active,
            _ => {
                self.shutdown().await?;
                anyhow::bail!("warmup cannot transfer retired ownership");
            }
        };
        // Initial admission after decode-only startup still requires an IDR.
        // All source sequence/timestamp floors and GPU caches remain intact.
        encoder.request_keyframe();
        let tightened = pool.tighten_age(self.plan.policy.max_age_ns.min(200_000_000));
        crate::gpu_atlas_session::GpuAtlasSession::from_parts_with_capacity(
            tightened.map(|()| pool),
            self.stops,
            crate::gpu_atlas_sender::GpuAtlasSender::new(encoder, sender),
            CodecIdentity {
                window_id: self.plan.policy.stream_id,
                config_generation: self.plan.policy.config_generation,
            },
            self.layout,
            self.plan.policy.geometry_epoch,
            self.plan.policy.max_tiles,
        )
        .await
    }

    /// The supplied encoder must be prepared before starting the producers.
    /// # Errors
    /// Invalid policy/membership triggers checked producer cleanup.
    pub async fn new(
        streams: Vec<(WindowId, GpuStreamSession)>,
        encoder: GpuAtlasCompatibleEncoder,
        plan: AtlasSessionPlan,
        layout: AtlasSnapshot,
    ) -> Result<Self> {
        let (receivers, controls): (Vec<_>, Vec<_>) = streams
            .into_iter()
            .map(|(id, stream)| {
                let (receiver, control) = stream.into_parts();
                ((id, receiver), (id, control))
            })
            .unzip();
        let mut stops = GpuStreamShutdown::new_named(controls);
        let setup = (|| {
            plan.validate()?;
            // Startup only: bounded below the producer's 500ms release wait.
            // This allowance never changes the live two-refresh-period policy.
            let pool =
                AtlasCapturePool::new_with_capacity(receivers, 200_000_000, plan.policy.max_tiles)?;
            let windows: std::collections::BTreeSet<_> =
                layout.placements.iter().map(|p| p.window).collect();
            ensure!(
                &windows == pool.windows()
                    && windows.len() == layout.placements.len()
                    && !windows.contains(&plan.policy.stream_id),
                "warmup membership mismatch"
            );
            Ok(pool)
        })();
        match setup {
            Ok(pool) => Ok(Self {
                active: Some((pool, encoder)),
                stops,
                plan,
                layout,
                captured_layout: None,
                next_frame: 1,
                stopping: false,
            }),
            Err(error) => match stops.shutdown(Duration::from_secs(2)).await {
                Ok(()) => Err(error),
                Err(stop) => Err(error.context(format!("warmup setup cleanup failed: {stop:#}"))),
            },
        }
    }

    /// Polls each producer once. A clean expiry can be retried; any error
    /// retires GPU/capture ownership and requires explicit `shutdown`.
    /// No await point can detach a submitted GPU read from its capture lease.
    /// # Errors
    /// Propagates malformed captures, GPU failures, release or policy mismatch.
    pub fn poll(&mut self, deadline: Instant) -> Result<Option<AtlasWarmupFrame>> {
        ensure!(!self.stopping, "warmup is stopping");
        let (mut pool, mut encoder) = self.active.take().context("warmup retired")?;
        ensure!(Instant::now() < deadline, "warmup deadline expired");
        let Some(mut leases) = pool.poll_ready()? else {
            self.active = Some((pool, encoder));
            return Ok(None);
        };
        let captured = leases
            .iter()
            .map(|s| s.frame.metadata().capture_monotonic_ns)
            .min()
            .context("empty warmup batch")?;
        let native_now = crate::gpu_nvenc_runtime::monotonic_ns()?;
        let remaining = deadline.saturating_duration_since(Instant::now());
        let limit = native_now
            .checked_add(i64::try_from(remaining.as_nanos())?)
            .context("warmup deadline overflow")?;
        let limit = leases
            .iter()
            .fold(limit, |limit, s| limit.min(s.deadline_monotonic_ns));
        for lease in &leases {
            lease.receiver.validate_outstanding(&lease.frame)?;
        }
        let sources: Vec<_> = leases
            .iter()
            .map(|s| AtlasSource {
                window: s.window,
                frame: &s.frame,
                deadline_monotonic_ns: s.deadline_monotonic_ns,
            })
            .collect();
        let captured_layout = reconcile_warmup_layout(
            self.captured_layout.as_ref(),
            &self.layout,
            leases.iter().map(|lease| {
                let frame = lease.frame.metadata();
                (
                    lease.window,
                    frame.geometry_epoch,
                    frame.crop_width,
                    frame.crop_height,
                )
            }),
        )?;
        let snapshot = captured_layout.snapshot();
        // Each retained startup picture is independently decodable, including
        // after discarded expiry attempts. Live handoff retains this encoder.
        encoder.request_keyframe();
        let outcome = encoder.submit_recoverable(AtlasSubmission {
            codec: CodecIdentity {
                window_id: self.plan.policy.stream_id,
                config_generation: self.plan.policy.config_generation,
            },
            layout: &snapshot,
            identity: GpuAtlasIdentity {
                frame_id: self.next_frame,
                capture_monotonic_ns: captured,
                geometry_epoch: self.plan.policy.geometry_epoch,
            },
            mapped_source_ns: captured,
            deadline_monotonic_ns: limit,
            sources: &sources,
            desktop: None,
        })?;
        // Both successful outcomes prove reads complete. Errors above send no HCGR.
        for lease in &mut leases {
            lease.receiver.release_after_source_reads(&lease.frame)?;
        }
        let frame = match outcome {
            AtlasSubmitOutcome::ExpiredClean => None,
            AtlasSubmitOutcome::Encoded { mut media, .. } => {
                ensure!(media.len() == 1, "warmup requires exactly one plane pair");
                let descriptors = encoder.descriptors().context("warmup descriptors absent")?;
                ensure!(
                    descriptors.color == self.plan.color && descriptors.alpha == self.plan.alpha,
                    "warmup codec differs from local policy"
                );
                let media = media.remove(0);
                ensure!(
                    media
                        .color
                        .payload
                        .len()
                        .checked_add(media.alpha.payload.len())
                        .is_some_and(|n| n <= self.plan.policy.max_encoded_bytes),
                    "warmup encoded byte limit"
                );
                Some(AtlasWarmupFrame {
                    width: self.plan.policy.width,
                    height: self.plan.policy.height,
                    color: media.color.payload,
                    alpha: media.alpha.payload,
                })
            }
        };
        pool.restore(leases.into_iter().map(|s| (s.window, s.receiver)).collect())?;
        self.next_frame = self
            .next_frame
            .checked_add(1)
            .context("warmup sequence exhausted")?;
        self.layout = snapshot;
        self.captured_layout = Some(captured_layout);
        self.active = Some((pool, encoder));
        Ok(frame)
    }

    /// Stop producers while their receivers remain owned, then retire the GPU.
    /// # Errors
    /// Reports unconfirmed stops; cancellation retains stop responsibility.
    pub async fn shutdown(&mut self) -> Result<()> {
        self.stopping = true;
        let result = self.stops.shutdown(Duration::from_secs(2)).await;
        self.active = None;
        result
    }
}

// Probe dimensions precede the real capture stream and may belong to a different
// display scale. Only its first authenticated batch establishes stream geometry;
// all later batches retain the normal epoch and stable-allocation checks.
fn reconcile_warmup_layout(
    previous: Option<&StableAtlas>,
    expected: &AtlasSnapshot,
    sources: impl IntoIterator<Item = (WindowId, u64, u32, u32)>,
) -> Result<StableAtlas> {
    let mut atlas = match previous {
        Some(atlas) => atlas.clone(),
        None => StableAtlas::new(AtlasConfig {
            width: expected.width,
            height: expected.height,
            alignment: 2,
            max_windows: expected.placements.len(),
        })
        .map_err(|error| anyhow::anyhow!("invalid warmup capacity: {error:?}"))?,
    };
    let wanted: std::collections::BTreeSet<_> =
        expected.placements.iter().map(|p| p.window).collect();
    let mut seen = std::collections::BTreeSet::new();
    for (window, epoch, width, height) in sources {
        ensure!(
            wanted.contains(&window) && seen.insert(window),
            "warmup captured membership mismatch"
        );
        atlas
            .place(window, epoch, width, height)
            .map_err(|error| anyhow::anyhow!("warmup captured geometry rejected: {error:?}"))?;
    }
    ensure!(seen == wanted, "warmup captured membership incomplete");
    Ok(atlas)
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::Id128;
    #[test]
    fn real_startup_capture_replaces_probe_dimensions_but_later_epochs_remain_strict() {
        let mut probe = StableAtlas::new(AtlasConfig {
            width: 2048,
            height: 1536,
            alignment: 2,
            max_windows: 8,
        })
        .unwrap();
        probe.place(Id128(1), 1, 1174, 973).unwrap();
        let first =
            reconcile_warmup_layout(None, &probe.snapshot(), [(Id128(1), 1, 1564, 1296)]).unwrap();
        assert_eq!(first.placement(Id128(1)).unwrap().content_width, 1564);
        assert!(
            reconcile_warmup_layout(Some(&first), &first.snapshot(), [(Id128(1), 1, 1174, 973)])
                .is_err()
        );
        let scaled =
            reconcile_warmup_layout(Some(&first), &first.snapshot(), [(Id128(1), 2, 1174, 973)])
                .unwrap();
        assert!(scaled.snapshot().revision > first.snapshot().revision);
        assert!(
            reconcile_warmup_layout(None, &probe.snapshot(), [(Id128(2), 1, 100, 100)]).is_err()
        );
        assert!(
            reconcile_warmup_layout(None, &probe.snapshot(), [(Id128(1), 1, 4096, 4096)]).is_err()
        );
    }
}
