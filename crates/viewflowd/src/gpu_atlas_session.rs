//! Shared atlas media ownership plus each real `HyprCapture` producer's stop
//! authority. A socket receiver alone cannot establish checked stream shutdown.
use anyhow::{Context, Result, ensure};
use std::time::Duration;
use tokio::time::Instant;
use viewflow_core::AtlasSnapshot;
use viewflow_protocol::WindowId;

use crate::{
    compatible_encoder::CodecIdentity,
    gpu_atlas_capture::AtlasCapturePool,
    gpu_atlas_device::{AtlasDevicePoll, GpuAtlasDevice},
    gpu_atlas_sender::GpuAtlasSender,
    hyprcapture_runtime::{GpuStreamSession, GpuStreamShutdown},
};

pub struct GpuAtlasSession {
    device: Option<GpuAtlasDevice>,
    stops: GpuStreamShutdown,
    stopping: bool,
}

impl GpuAtlasSession {
    /// Cancel-safe readiness wait; periodic source housekeeping remains in
    /// the caller. This never reads, releases, or retimestamps a capture.
    pub(crate) async fn capture_readable(&mut self) {
        std::future::poll_fn(|cx| {
            self.device
                .as_mut()
                .map_or(std::task::Poll::Pending, |device| {
                    device.poll_capture_readable(cx)
                })
        })
        .await;
    }

    pub(crate) fn set_occlusion(
        &mut self,
        mode: crate::atlas_occlusion::AtlasOcclusionMode,
    ) -> Result<()> {
        self.device
            .as_mut()
            .context("atlas session retired")?
            .set_occlusion(mode)
    }

    /// Binding evidence is borrowed from the live capture owner and disappears
    /// on retirement. A committed API disposition is not an input permission.
    #[must_use]
    pub fn committed_input(&self) -> Option<&crate::window_input_runtime::AtlasCommittedInput> {
        if self.stopping {
            return None;
        }
        self.device.as_ref()?.committed_input()
    }

    /// Take real started producer sessions without discarding their control
    /// identities. The encoder must have been prepared before starting capture.
    /// # Errors
    /// Invalid layout/membership/resource limits trigger checked stop attempts
    /// for all supplied producers before returning the setup failure.
    pub async fn new(
        streams: Vec<(WindowId, GpuStreamSession)>,
        sender: GpuAtlasSender,
        codec: CodecIdentity,
        layout: AtlasSnapshot,
        geometry_epoch: u64,
        max_age_ns: u64,
    ) -> Result<Self> {
        let max_windows = layout.placements.len();
        Self::new_with_capacity(
            streams,
            sender,
            codec,
            layout,
            geometry_epoch,
            max_age_ns,
            max_windows,
        )
        .await
    }

    /// Build a session with an immutable negotiated upper bound and an initial
    /// subset of sources. New sources may be enrolled only between batches.
    pub(crate) async fn new_with_capacity(
        streams: Vec<(WindowId, GpuStreamSession)>,
        sender: GpuAtlasSender,
        codec: CodecIdentity,
        layout: AtlasSnapshot,
        geometry_epoch: u64,
        max_age_ns: u64,
        max_windows: usize,
    ) -> Result<Self> {
        let (receivers, controls): (Vec<_>, Vec<_>) = streams
            .into_iter()
            .map(|(window, stream)| {
                let (receiver, control) = stream.into_parts();
                ((window, receiver), (window, control))
            })
            .unzip();
        let stops = GpuStreamShutdown::new_named(controls);
        let pool = AtlasCapturePool::new_with_capacity(receivers, max_age_ns, max_windows);
        Self::from_parts_with_capacity(
            pool,
            stops,
            sender,
            codec,
            layout,
            geometry_epoch,
            max_windows,
        )
        .await
    }

    pub(crate) async fn from_parts_with_capacity(
        pool: Result<AtlasCapturePool>,
        mut stops: GpuStreamShutdown,
        sender: GpuAtlasSender,
        codec: CodecIdentity,
        layout: AtlasSnapshot,
        geometry_epoch: u64,
        max_windows: usize,
    ) -> Result<Self> {
        let device = pool.and_then(|pool| {
            GpuAtlasDevice::new_with_capacity(
                pool,
                sender,
                codec,
                layout,
                geometry_epoch,
                max_windows,
            )
        });
        match device {
            Ok(device) => Ok(Self {
                device: Some(device),
                stops,
                stopping: false,
            }),
            Err(error) => match stops.shutdown(Duration::from_secs(2)).await {
                Ok(()) => Err(error),
                Err(stop) => Err(error.context(format!("atlas setup cleanup failed: {stop:#}"))),
            },
        }
    }

    /// # Errors
    /// Failed media work retires the device and checks all producer stops.
    /// Cancellation retains the stop authorities; the caller must await
    /// `shutdown` before declaring cleanup successful.
    pub async fn poll_and_send(
        &mut self,
        map_source_time: impl FnOnce(u64) -> Result<u64>,
        deadline: Instant,
    ) -> Result<AtlasDevicePoll> {
        ensure!(!self.stopping, "atlas capture session is stopping");
        let result = self
            .device
            .as_mut()
            .context("atlas capture device missing")?
            .poll_and_send(map_source_time, deadline)
            .await;
        match result {
            Ok(result) => Ok(result),
            Err(error) => match self.shutdown(Duration::from_secs(2)).await {
                Ok(()) => Err(error),
                Err(stop) => Err(error.context(format!("atlas media cleanup failed: {stop:#}"))),
            },
        }
    }

    /// Attach the configured desktop lane before the first live submission.
    /// Warmup remains descriptor-only; logical desktop geometry begins only
    /// once the persistent session owns the source bindings.
    pub(crate) fn attach_desktop_source(
        &mut self,
        desktop: crate::desktop_source::SharedDesktopSourceLane,
    ) -> Result<()> {
        ensure!(!self.stopping, "atlas capture session is stopping");
        self.device
            .as_mut()
            .context("atlas capture device missing")?
            .attach_desktop_source(desktop);
        Ok(())
    }

    /// Check capacity without changing the committed atlas layout.
    pub(crate) fn can_enroll_capture(
        &self,
        window: WindowId,
        frame: &crate::hyprcapture_gpu_wire::HcgfFrame,
    ) -> Result<bool> {
        self.device
            .as_ref()
            .context("atlas session retired")?
            .can_enroll_capture(window, frame)
    }

    /// Withdraw at an idle GPU boundary, then supervise the exact producer's
    /// stop asynchronously while unrelated sources continue to publish.
    pub(crate) fn remove_at_frame_boundary(&mut self, window: WindowId) -> Result<()> {
        ensure!(!self.stopping, "atlas capture session is stopping");
        self.device
            .as_mut()
            .context("atlas capture device missing")?
            .remove_at_frame_boundary(window)?;
        self.stops.begin_remove(window, Duration::from_secs(2))
    }

    pub(crate) async fn poll_removed(&mut self) -> Result<Vec<WindowId>> {
        self.stops.poll_removals().await
    }

    /// Enroll a real producer after the prior batch has restored every
    /// receiver. On failure the newly started producer is explicitly stopped;
    /// an accepted producer remains retained until whole-session shutdown.
    pub(crate) async fn enroll_at_frame_boundary(
        &mut self,
        window: WindowId,
        stream: GpuStreamSession,
    ) -> Result<()> {
        let (receiver, control) = stream.into_parts();
        // The caller has already started this producer. Even a rejected
        // session-state check must pass through checked producer cleanup.
        let result = if self.stopping {
            Err(anyhow::anyhow!("atlas capture session is stopping"))
        } else if let Some(device) = self.device.as_mut() {
            device.enroll_at_frame_boundary(window, receiver)
        } else {
            Err(anyhow::anyhow!("atlas capture device missing"))
        };
        if let Err(error) = result {
            return match control.stop_stream(Duration::from_secs(2)).await {
                Ok(()) => Err(error),
                Err(stop) => Err(error.context(format!(
                    "atlas rejected enrollment cleanup failed: {stop:#}"
                ))),
            };
        }
        self.stops.push_named(window, control);
        Ok(())
    }

    /// Freeze media submission, stop every producer, then retire GPU/socket
    /// ownership. A cancelled wait is resumable and never permits new frames.
    /// # Errors
    /// Reports every unconfirmed producer stop; dropping this owner is not a
    /// substitute for checked shutdown.
    pub async fn shutdown(&mut self, per_stream_timeout: Duration) -> Result<()> {
        ensure!(
            !per_stream_timeout.is_zero() && per_stream_timeout <= Duration::from_secs(30),
            "invalid atlas stop timeout"
        );
        self.stopping = true;
        let result = self.stops.shutdown(per_stream_timeout).await;
        self.device = None;
        result
    }

    #[must_use]
    pub fn is_shutdown_confirmed(&self) -> bool {
        self.stopping && self.device.is_none() && self.stops.is_confirmed()
    }
}
