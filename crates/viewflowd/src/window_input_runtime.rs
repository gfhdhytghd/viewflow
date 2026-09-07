//! Source-owned, connection-local window input. Construction requires a local
//! authorization decision and source-verified presented geometry; never build
//! this configuration from an incoming pointer event.

use crate::input_runtime::{ClockSnapshot, conservative_input_deadline};
use anyhow::{Context, Result, anyhow, bail};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::{io, time::Instant};
use viewflow_core::{PresentedInputGeometry, WindowPointerGrant};
use viewflow_hyprland::{
    window_pointer_socket::{Connection, Event},
    window_pointer_wire::{Outcome, Request},
};
use viewflow_protocol::{DeviceId, WindowPointerMotion};
use viewflow_transport::ClockEstimate;

#[path = "window_input_switch.rs"]
mod window_switch;

#[path = "window_keyboard_runtime.rs"]
mod window_keyboard;

/// Owned binding evidence for a captured frame whose GPU storage may be released
/// before the encoder output and presentation acknowledgement arrive. This does
/// not retain the native window: the owning capture session must remain alive.
#[derive(Clone, Debug)]
pub struct CapturedWindowInput {
    frame: crate::hyprcapture_gpu_wire::HcgfFrame,
    input: Option<crate::hyprcapture_gpu_wire::InputGeometry>,
}

impl CapturedWindowInput {
    #[must_use]
    pub fn from_gpu_frame(frame: &crate::hyprcapture_gpu_socket::GpuFrame) -> Self {
        Self {
            frame: frame.metadata().clone(),
            input: frame.input_geometry(),
        }
    }

    #[must_use]
    pub fn sequence(&self) -> u64 {
        self.frame.sequence
    }

    #[must_use]
    pub fn capture_monotonic_ns(&self) -> u64 {
        self.frame.capture_monotonic_ns
    }

    /// Match a source-owned snapshot to one tile, not the atlas frame counter.
    #[must_use]
    pub fn matches_atlas_tile(&self, tile: &viewflow_protocol::AtlasTile) -> bool {
        self.frame.sequence == tile.source_frame_id
            && self.frame.geometry_epoch == tile.geometry_epoch
            && self.frame.crop_width == tile.width
            && self.frame.crop_height == tile.height
    }

    /// Apply an explicit local policy decision only after the source pipeline
    /// verifies the receipt for this exact captured frame. A snapshot alone is
    /// not an authorization, nor does it extend the capture session's lifetime.
    /// # Errors
    /// Rejects mismatched presentation identity and invalid capture geometry.
    pub fn authorize(
        &self,
        owner: DeviceId,
        target_device: DeviceId,
        generation: u64,
        expires_local_ns: u64,
        presented: viewflow_core::PresentedInputIdentity,
    ) -> Result<AuthorizedWindow> {
        AuthorizedWindow::from_snapshot(
            &self.frame,
            self.input,
            owner,
            target_device,
            generation,
            expires_local_ns,
            presented,
        )
    }
}

/// Exact source snapshots for one receiver API-committed atlas. This is binding
/// evidence only: it is neither physical scanout evidence nor an input grant.
/// Its owner must discard it when capture or the authenticated session retires.
#[derive(Clone, Debug)]
pub struct AtlasCommittedInput {
    manifest: viewflow_protocol::AtlasFrame,
    snapshots: std::collections::BTreeMap<viewflow_protocol::WindowId, CapturedWindowInput>,
}

impl AtlasCommittedInput {
    #[cfg(any(test, feature = "native-gpu-nvenc"))]
    pub(crate) fn from_feedback(
        manifest: &viewflow_protocol::AtlasFrame,
        snapshots: Vec<(viewflow_protocol::WindowId, CapturedWindowInput)>,
        disposition: Option<crate::atlas_feedback::AtlasFrameDisposition>,
    ) -> Result<Option<Self>> {
        if disposition != Some(crate::atlas_feedback::AtlasFrameDisposition::Committed) {
            return Ok(None);
        }
        manifest
            .validate()
            .map_err(|error| anyhow!("invalid input atlas: {error:?}"))?;
        let count = snapshots.len();
        let snapshots: std::collections::BTreeMap<_, _> = snapshots.into_iter().collect();
        anyhow::ensure!(
            snapshots.len() == count && count == manifest.tiles.len(),
            "input atlas membership mismatch"
        );
        for tile in &manifest.tiles {
            anyhow::ensure!(
                snapshots
                    .get(&tile.window_id)
                    .is_some_and(|snapshot| snapshot.matches_atlas_tile(tile)),
                "input atlas capture identity mismatch"
            );
        }
        Ok(Some(Self {
            manifest: manifest.clone(),
            snapshots,
        }))
    }

    #[must_use]
    pub fn manifest(&self) -> &viewflow_protocol::AtlasFrame {
        &self.manifest
    }

    /// Caller still needs a local policy decision and an unexpired input lease.
    #[must_use]
    pub fn snapshot(&self, window: viewflow_protocol::WindowId) -> Option<&CapturedWindowInput> {
        self.snapshots.get(&window)
    }
}

#[derive(Clone)]
pub struct AuthorizedWindow {
    pub owner: DeviceId,
    pub target_device: DeviceId,
    pub generation: u64,
    pub geometry: PresentedInputGeometry,
    pub expires_local_ns: u64,
    pub native_address: u64,
    pub native_surface: u64,
    pub native_pid: u32,
    pub surface_extent: [f64; 2],
    /// Source capture content origin in the exact native surface coordinate space.
    pub content_origin: [f64; 2],
    pub content_scale: [f64; 2],
}

impl AuthorizedWindow {
    /// Construct from one retained source GPU frame and its exact, source-verified
    /// presentation receipt. The caller must authorize this peer/window first;
    /// neither a raw remote receipt nor incoming motion grants this authority.
    /// Keep the source capture session alive through native binding, and revoke
    /// input on capture retirement so its retained object tokens cannot go stale.
    /// # Errors
    /// Rejects absent capture binding, wrong frame/epoch, or invalid geometry.
    pub fn from_gpu_frame(
        frame: &crate::hyprcapture_gpu_socket::GpuFrame,
        owner: DeviceId,
        target_device: DeviceId,
        generation: u64,
        expires_local_ns: u64,
        presented: viewflow_core::PresentedInputIdentity,
    ) -> Result<Self> {
        CapturedWindowInput::from_gpu_frame(frame).authorize(
            owner,
            target_device,
            generation,
            expires_local_ns,
            presented,
        )
    }

    fn from_snapshot(
        frame: &crate::hyprcapture_gpu_wire::HcgfFrame,
        input: Option<crate::hyprcapture_gpu_wire::InputGeometry>,
        owner: DeviceId,
        target_device: DeviceId,
        generation: u64,
        expires_local_ns: u64,
        presented: viewflow_core::PresentedInputIdentity,
    ) -> Result<Self> {
        use viewflow_core::{CaptureGeometry, CaptureSlice};
        use viewflow_protocol::{Point, Rect, Size};
        if presented.frame != frame.sequence || presented.geometry_epoch != frame.geometry_epoch {
            bail!("presentation does not match captured source frame");
        }
        let input = input.ok_or_else(|| anyhow!("capture has no window input binding"))?;
        let full = Rect {
            origin: Point {
                x: frame.logical_x,
                y: frame.logical_y,
            },
            size: Size {
                width: frame.logical_width,
                height: frame.logical_height,
            },
        };
        let content = Rect {
            origin: Point {
                x: input.content[0],
                y: input.content[1],
            },
            size: Size {
                width: input.content[2],
                height: input.content[3],
            },
        };
        let capture = CaptureGeometry::new(content, full, frame.crop_width, frame.crop_height)
            .map_err(|e| anyhow!("invalid captured input geometry: {e:?}"))?;
        let geometry = PresentedInputGeometry::new(
            presented,
            capture,
            CaptureSlice {
                desktop_rect: full,
                source_pixels: Rect {
                    origin: Point::default(),
                    size: Size {
                        width: f64::from(frame.crop_width),
                        height: f64::from(frame.crop_height),
                    },
                },
            },
        )
        .ok_or_else(|| anyhow!("invalid presented identity"))?;
        let content_scale = [
            input.surface_extent[0] / content.size.width,
            input.surface_extent[1] / content.size.height,
        ];
        if content_scale.iter().any(|v| !v.is_finite() || *v <= 0.0) {
            bail!("invalid captured surface scale");
        }
        Ok(Self {
            owner,
            target_device,
            generation,
            geometry,
            expires_local_ns,
            native_address: input.window,
            native_surface: input.surface,
            native_pid: u32::try_from(input.pid)?,
            surface_extent: input.surface_extent,
            content_origin: [0.0, 0.0],
            content_scale,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum State {
    Beginning,
    Ready,
    Moving,
    Pressing,
    Scrolling,
    Keying,
    SwitchingEnd,
    ResizeSuspended,
    DesktopEnding,
    DesktopPaused,
    Ended,
}

#[derive(Clone, Copy)]
enum PointerAction {
    Motion,
    Button(viewflow_protocol::PointerButtonEvent),
    Wheel(viewflow_protocol::PointerWheelEvent),
}

fn native_wheel_delta(delta: viewflow_protocol::PointerWheelEvent) -> Result<[i32; 2]> {
    use viewflow_hyprland::window_pointer_wire::MAX_WHEEL_120;
    let mut result = [0; 2];
    for (out, detents) in result
        .iter_mut()
        .zip([delta.vertical_delta_detents, delta.horizontal_delta_detents])
    {
        let scaled = detents * 120.0;
        let rounded = scaled.round();
        anyhow::ensure!(
            scaled.is_finite()
                && rounded.abs() <= f64::from(MAX_WHEEL_120)
                && (scaled - rounded).abs() <= 4.0 * f64::EPSILON * scaled.abs().max(1.0),
            "wheel delta is not representable in native value120"
        );
        #[allow(clippy::cast_possible_truncation)] // Integral and bounded above.
        {
            *out = rounded as i32;
        }
    }
    anyhow::ensure!(result != [0, 0], "empty wheel delta");
    Ok(result)
}

/// Cumulative withdrawal counters ensure a watch receiver cannot miss a brief
/// absent layout followed immediately by reappearance of the same window.
#[derive(Clone, Default)]
pub(crate) struct AtlasInputMembership {
    pub(crate) windows: std::collections::BTreeSet<viewflow_protocol::WindowId>,
    pub(crate) withdrawals: std::collections::BTreeMap<viewflow_protocol::WindowId, u64>,
    pub(crate) authorization_floor: u64,
}

impl AtlasInputMembership {
    pub(crate) fn update(
        &mut self,
        windows: std::collections::BTreeSet<viewflow_protocol::WindowId>,
    ) -> Result<()> {
        for window in self.windows.difference(&windows) {
            let count = self.withdrawals.entry(*window).or_default();
            *count = count
                .checked_add(1)
                .context("atlas withdrawal counter exhausted")?;
        }
        self.windows = windows;
        Ok(())
    }
}

pub struct WindowInputSession {
    selection_acceptances: Option<(
        tokio::sync::mpsc::Receiver<AtlasSelectionAcceptanceRequest>,
        crate::shared_control::SharedControlSender,
    )>,
    selection_rejections: Option<(
        tokio::sync::mpsc::Receiver<AtlasSelectionRejectionRequest>,
        crate::shared_control::SharedControlSender,
    )>,
    native_grant_ever_active: bool,
    last_ended_generation: u64,
    cursor: Option<crate::atlas_cursor_handoff::CursorBridge>,
    connection: Connection,
    grant: WindowPointerGrant,
    keyboard_grant: Option<viewflow_core::WindowKeyboardGrant>,
    allow_keyboard: bool,
    pending_keyboard_mode: Option<bool>,
    pending_key: Option<viewflow_protocol::WindowKeyboardEvent>,
    owner: DeviceId,
    generation: u64,
    sequence: u64,
    origin: Instant,
    expires: u64,
    content_origin: [f64; 2],
    content_scale: [f64; 2],
    surface_extent: [f64; 2],
    native_binding: (u64, u64, u32),
    // Local policy only: a peer or renewal cannot promote a motion-only session.
    allow_buttons: bool,
    allow_wheel: bool,
    // Diagnostic only: [sequence, send-start monotonic ns, send-end ns, deadline].
    last_native_send: Option<[u64; 4]>,
    last_motion_rejected: bool,
    motion_takeover_pending: bool,
    // Diagnostic only: network sequence, native-clock receive and completion.
    last_delivery: Option<[u64; 3]>,
    state: State,
    pending_switch: Option<AuthorizedWindow>,
    resize_suspension: Option<viewflow_protocol::WindowPointerAuthorization>,
    // The authorization that was active when a desktop drag took ownership of
    // this native route. It is deliberately not reusable: a move can resume
    // only from a newer source decision with fresh presented geometry.
    desktop_suspension: Option<viewflow_protocol::WindowPointerAuthorization>,
    allow_resize_recovery: bool,
    recovery_unconfirmed: Arc<AtomicBool>,
    atlas_membership: Option<tokio::sync::watch::Receiver<AtlasInputMembership>>,
    observed_withdrawals: std::collections::BTreeMap<viewflow_protocol::WindowId, u64>,
    closed_windows: std::collections::BTreeSet<viewflow_protocol::WindowId>,
}

impl WindowInputSession {
    pub(crate) fn attach_selection_acceptances(
        &mut self,
        requests: tokio::sync::mpsc::Receiver<AtlasSelectionAcceptanceRequest>,
        writer: crate::shared_control::SharedControlSender,
    ) {
        self.selection_acceptances = Some((requests, writer));
    }

    pub(crate) fn attach_selection_rejections(
        &mut self,
        requests: tokio::sync::mpsc::Receiver<AtlasSelectionRejectionRequest>,
        writer: crate::shared_control::SharedControlSender,
    ) {
        self.selection_rejections = Some((requests, writer));
    }

    pub(crate) fn attach_cursor(&mut self, cursor: crate::atlas_cursor_handoff::CursorBridge) {
        self.cursor = Some(cursor);
    }
    pub(crate) fn attach_atlas_membership(
        &mut self,
        membership: tokio::sync::watch::Receiver<AtlasInputMembership>,
    ) {
        self.atlas_membership = Some(membership);
    }

    pub(crate) fn recovery_unconfirmed(&self) -> Arc<AtomicBool> {
        self.recovery_unconfirmed.clone()
    }
    /// Run the daemon's shared reliable-control dispatcher with this locally
    /// authorized window route installed. This owns the connection's reader
    /// and writer; do not run another control loop on the same connection.
    /// The connection measures and refreshes its own clock evidence. Presentation
    /// receipts still come from the source pipeline, not remote input claims.
    /// Metadata is synchronously forwarded to the owning native dispatcher.
    /// # Errors
    /// Disconnect, revoked/expired source context, malformed control or native
    /// failure terminates the session and closes both connections.
    pub async fn serve(
        self,
        network: &quinn::Connection,
        presentations: tokio::sync::watch::Receiver<PresentedInputGeometry>,
        metadata: impl FnMut(Vec<u8>) -> Result<()> + Send,
    ) -> Result<()> {
        let origin = self.origin;
        let result = crate::serve_authorized_window_connection(
            network,
            origin,
            self,
            presentations,
            None,
            WindowInputRouting::default(),
            metadata,
        )
        .await;
        network.close(0_u32.into(), b"window input session ended");
        result
    }

    /// Serve source-owned presentation updates and explicit lease renewals on
    /// the shared dispatcher. Closing the authorization owner revokes input.
    /// The initial watch value must be the authorization used by `begin`.
    /// # Errors
    /// Rejects changed native bindings, invalid renewals, or connection failure.
    pub async fn serve_authorizations(
        self,
        network: &quinn::Connection,
        authorizations: tokio::sync::watch::Receiver<AuthorizedWindow>,
        metadata: impl FnMut(Vec<u8>) -> Result<()> + Send,
    ) -> Result<()> {
        self.serve_selected_authorizations_inner(
            network,
            authorizations,
            WindowInputRouting::default(),
            metadata,
        )
        .await
    }

    /// Serve explicit source-selected windows on one native seat route. A
    /// changed target requires a newer local authorization and confirmed native
    /// END/BEGIN; remote motion never selects or authorizes a different window.
    /// # Errors
    /// Owner loss, stale decisions and failed switching retire both connections.
    pub async fn serve_selected_authorizations(
        self,
        network: &quinn::Connection,
        authorizations: tokio::sync::watch::Receiver<AuthorizedWindow>,
        metadata: impl FnMut(Vec<u8>) -> Result<()> + Send,
    ) -> Result<()> {
        self.serve_selected_authorizations_inner(
            network,
            authorizations,
            WindowInputRouting {
                allow_switching: true,
                ..WindowInputRouting::default()
            },
            metadata,
        )
        .await
    }

    /// Reuse the atlas source's sole writer; this task owns only inbound control
    /// dispatch and input-clock probes. Keep the writer owner alive externally.
    /// # Errors
    /// Foreign writer bindings and all ordinary input retirement conditions fail.
    pub async fn serve_selected_on_shared_control(
        self,
        network: &quinn::Connection,
        authorizations: tokio::sync::watch::Receiver<AuthorizedWindow>,
        sender: crate::shared_control::SharedControlSender,
        metadata: impl FnMut(Vec<u8>) -> Result<()> + Send,
    ) -> Result<()> {
        self.serve_selected_authorizations_inner(
            network,
            authorizations,
            WindowInputRouting {
                allow_switching: true,
                shared: Some(sender),
                selections: None,
                desktop_moves: None,
            },
            metadata,
        )
        .await
    }

    /// Forward frame-bound atlas selections to the local capture supervisor.
    /// That supervisor decides using its retained capture bindings and sends
    /// authorization updates; a peer request itself never opens a native target.
    /// # Errors
    /// Closed/full selection queues or ordinary input errors retire the route.
    pub async fn serve_atlas_selections(
        self,
        network: &quinn::Connection,
        authorizations: tokio::sync::watch::Receiver<AuthorizedWindow>,
        sender: crate::shared_control::SharedControlSender,
        selections: tokio::sync::mpsc::Sender<AtlasSelectionRequest>,
        metadata: impl FnMut(Vec<u8>) -> Result<()> + Send,
    ) -> Result<()> {
        if selections.max_capacity() > 64 || selections.is_closed() {
            network.close(0_u32.into(), b"atlas selection owner unavailable");
            bail!("atlas selection queue unavailable or too large");
        }
        self.serve_selected_authorizations_inner(
            network,
            authorizations,
            WindowInputRouting {
                allow_switching: true,
                shared: Some(sender),
                selections: Some(selections),
                desktop_moves: None,
            },
            metadata,
        )
        .await
    }

    /// Atlas selection service with an explicitly bounded desktop-move source
    /// controller. The shared QUIC reader remains the only control reader.
    pub(crate) async fn serve_atlas_selections_with_desktop(
        self,
        network: &quinn::Connection,
        authorizations: tokio::sync::watch::Receiver<AuthorizedWindow>,
        sender: crate::shared_control::SharedControlSender,
        selections: tokio::sync::mpsc::Sender<AtlasSelectionRequest>,
        desktop_moves: tokio::sync::mpsc::Sender<DesktopMoveRequest>,
        metadata: impl FnMut(Vec<u8>) -> Result<()> + Send,
    ) -> Result<()> {
        if selections.max_capacity() > 64
            || selections.is_closed()
            || desktop_moves.max_capacity() > 16
            || desktop_moves.is_closed()
        {
            network.close(0_u32.into(), b"atlas desktop owner unavailable");
            bail!("atlas selection or desktop move queue unavailable or too large");
        }
        self.serve_selected_authorizations_inner(
            network,
            authorizations,
            WindowInputRouting {
                allow_switching: true,
                shared: Some(sender),
                selections: Some(selections),
                desktop_moves: Some(desktop_moves),
            },
            metadata,
        )
        .await
    }

    async fn serve_selected_authorizations_inner(
        self,
        network: &quinn::Connection,
        authorizations: tokio::sync::watch::Receiver<AuthorizedWindow>,
        routing: WindowInputRouting,
        metadata: impl FnMut(Vec<u8>) -> Result<()> + Send,
    ) -> Result<()> {
        let (presentation_owner, presentations) =
            tokio::sync::watch::channel(authorizations.borrow().geometry);
        let result = crate::serve_authorized_window_connection(
            network,
            self.origin,
            self,
            presentations,
            Some(authorizations),
            routing,
            metadata,
        )
        .await;
        drop(presentation_owner);
        network.close(0_u32.into(), b"window input session ended");
        result
    }

    /// Dispatch one authenticated event without accepting any network streams.
    /// The owning shared-connection reader retains sequencing and sends the
    /// returned acknowledgement. Success requires the native backend's reply.
    /// The caller must revoke/drop the session if this operation is cancelled.
    /// # Errors
    /// A native/context/disconnect failure revokes the local input session.
    pub async fn deliver(
        &mut self,
        network: &quinn::Connection,
        event: WindowPointerMotion,
        estimate: Option<(ClockEstimate, u64)>,
        presentations: &mut tokio::sync::watch::Receiver<PresentedInputGeometry>,
        metadata: &mut impl FnMut(Vec<u8>) -> Result<()>,
    ) -> Result<viewflow_protocol::WindowPointerAck> {
        self.deliver_pointer(
            network,
            event,
            estimate,
            presentations,
            metadata,
            PointerAction::Motion,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn deliver_pointer(
        &mut self,
        network: &quinn::Connection,
        event: WindowPointerMotion,
        estimate: Option<(ClockEstimate, u64)>,
        presentations: &mut tokio::sync::watch::Receiver<PresentedInputGeometry>,
        metadata: &mut impl FnMut(Vec<u8>) -> Result<()>,
        action: PointerAction,
    ) -> Result<viewflow_protocol::WindowPointerAck> {
        use viewflow_protocol::{WindowPointerAck, WindowPointerResult};
        let received_native = native_clock_ns().unwrap_or(0);
        let work = async {
            self.wait_native(network, presentations, metadata).await?;
            if self.state != State::Ready {
                return Ok(WindowPointerAck::for_motion(
                    event,
                    WindowPointerResult::Rejected,
                ));
            }
            if presentations.has_changed()? {
                self.install_receipt(Ok(()), presentations)?;
            }
            if let Some(reason) = network.close_reason() {
                return Err(reason).context("window input peer disconnected");
            }
            let sent = match action {
                PointerAction::Motion => self.motion(event, estimate),
                PointerAction::Button(transition) => self.button(
                    viewflow_protocol::WindowPointerButton {
                        position: event,
                        transition,
                    },
                    estimate,
                ),
                PointerAction::Wheel(delta) => self.wheel(
                    viewflow_protocol::WindowPointerWheel {
                        position: event,
                        delta,
                    },
                    estimate,
                ),
            };
            let result = if sent.is_ok() {
                self.wait_native(network, presentations, metadata).await?;
                match action {
                    PointerAction::Motion if self.last_motion_rejected => {
                        WindowPointerResult::Rejected
                    }
                    PointerAction::Motion => WindowPointerResult::MotionSent,
                    PointerAction::Button(_) => WindowPointerResult::ButtonSent,
                    PointerAction::Wheel(_) => WindowPointerResult::WheelSent,
                }
            } else {
                if self.state == State::Ended {
                    bail!("native window input connection failed");
                }
                WindowPointerResult::Rejected
            };
            Ok(WindowPointerAck::for_motion(event, result))
        }
        .await;
        self.last_delivery = Some([
            event.sequence,
            received_native,
            native_clock_ns().unwrap_or(0),
        ]);
        if work.is_err() {
            self.revoke();
        }
        work
    }

    fn install_receipt(
        &mut self,
        changed: std::result::Result<(), tokio::sync::watch::error::RecvError>,
        presentations: &mut tokio::sync::watch::Receiver<PresentedInputGeometry>,
    ) -> Result<()> {
        changed?;
        if !self.advance_presented(*presentations.borrow_and_update()) {
            bail!("source presentation invalidated window grant");
        }
        Ok(())
    }

    async fn wait_native(
        &mut self,
        network: &quinn::Connection,
        presentations: &mut tokio::sync::watch::Receiver<PresentedInputGeometry>,
        metadata: &mut impl FnMut(Vec<u8>) -> Result<()>,
    ) -> Result<()> {
        self.wait_native_until(
            network,
            presentations,
            metadata,
            Instant::now() + std::time::Duration::from_secs(5),
        )
        .await
    }

    async fn wait_native_until(
        &mut self,
        network: &quinn::Connection,
        presentations: &mut tokio::sync::watch::Receiver<PresentedInputGeometry>,
        metadata: &mut impl FnMut(Vec<u8>) -> Result<()>,
        deadline: Instant,
    ) -> Result<()> {
        let waiting_for = self.state;
        let generation = self.generation;
        let sequence = self.sequence;
        let native_send = self.last_native_send;
        let started = Instant::now();
        let mut last_poll = started;
        let mut polls = 0_u64;
        let mut metadata_packets = 0_u64;
        let mut max_poll_gap_us = 0_u128;
        let timeout_error = |polls, metadata_packets, max_poll_gap_us, state| {
            let now = Instant::now();
            let elapsed_us = now.saturating_duration_since(started).as_micros();
            let overdue_us = now.saturating_duration_since(deadline).as_micros();
            anyhow!(
                "native window acknowledgement timed out: command={waiting_for:?} generation={generation} sequence={sequence} elapsed_us={elapsed_us} overdue_us={overdue_us} polls={polls} metadata_packets={metadata_packets} max_poll_gap_us={max_poll_gap_us} final_state={state:?} native_send={native_send:?}"
            )
        };
        let timeout = tokio::time::sleep_until(deadline.into());
        tokio::pin!(timeout);
        let mut metadata_batch = 0;
        while !matches!(
            self.state,
            State::Ready | State::ResizeSuspended | State::DesktopPaused
        ) || self.cursor.as_ref().is_some_and(|cursor| cursor.pending())
        {
            let now = Instant::now();
            max_poll_gap_us =
                max_poll_gap_us.max(now.saturating_duration_since(last_poll).as_micros());
            if now >= deadline {
                return Err(timeout_error(
                    polls,
                    metadata_packets,
                    max_poll_gap_us,
                    self.state,
                ));
            }
            last_poll = now;
            polls += 1;
            let received_metadata = if let Some(Event::Metadata(bytes)) = self.poll()? {
                metadata_packets += 1;
                metadata(bytes)?;
                true
            } else {
                false
            };
            // Polling or a synchronous metadata callback can spend the budget.
            // A ready native reply must not win over an already elapsed timer.
            if Instant::now() >= deadline {
                return Err(timeout_error(
                    polls,
                    metadata_packets,
                    max_poll_gap_us,
                    self.state,
                ));
            }
            if presentations.has_changed()? {
                self.install_receipt(Ok(()), presentations)?;
            }
            if let Some(reason) = network.close_reason() {
                return Err(reason).context("window input peer disconnected");
            }
            if self.state == State::Ready
                && !self.cursor.as_ref().is_some_and(|cursor| cursor.pending())
            {
                break;
            }
            // Metadata and command ACKs share this ordered native socket. Do
            // not impose a timer tick per queued metadata packet before an ACK.
            // Retain per-packet deadline/context checks and yield every bounded
            // batch so a busy producer cannot monopolize the shared dispatcher.
            if received_metadata {
                metadata_batch += 1;
                if metadata_batch < 32 {
                    continue;
                }
            }
            metadata_batch = 0;
            tokio::select! {
                () = &mut timeout => return Err(timeout_error(
                    polls,
                    metadata_packets,
                    max_poll_gap_us.max(Instant::now().saturating_duration_since(last_poll).as_micros()),
                    self.state,
                )),
                reason = network.closed() => return Err(reason).context("window input disconnected"),
                changed = presentations.changed() => self.install_receipt(changed, presentations)?,
                () = async {
                    if received_metadata {
                        tokio::task::yield_now().await;
                    } else {
                        tokio::time::sleep(std::time::Duration::from_millis(1)).await;
                    }
                } => {}
            }
        }
        Ok(())
    }

    /// `origin` must be the same process clock epoch used for clock sync.
    /// # Errors
    /// Rejects invalid/expired authorization or failure to send native begin.
    #[allow(clippy::needless_pass_by_value)] // Consume the source authorization decision.
    pub fn begin(
        connection: Connection,
        authorized: AuthorizedWindow,
        origin: Instant,
    ) -> Result<Self> {
        Self::begin_with_mode(connection, authorized, origin, false)
    }

    /// Begin with an explicit local decision permitting pointer buttons.
    /// Never call this merely because the remote peer requested button input.
    /// # Errors
    /// Rejects invalid/expired authorization or failure to send native begin.
    pub fn begin_buttons(
        connection: Connection,
        authorized: AuthorizedWindow,
        origin: Instant,
    ) -> Result<Self> {
        Self::begin_with_mode(connection, authorized, origin, true)
    }

    #[allow(clippy::needless_pass_by_value)]
    fn begin_with_mode(
        connection: Connection,
        authorized: AuthorizedWindow,
        origin: Instant,
        allow_buttons: bool,
    ) -> Result<Self> {
        Self::begin_with_capabilities(connection, authorized, origin, allow_buttons, false, false)
    }

    /// Begin under an explicit local button and wheel authorization decision.
    /// A remote wheel packet or a grant renewal must not enable this mode.
    /// # Errors
    /// Rejects invalid/expired authorization or native begin failure.
    pub fn begin_buttons_wheel(
        connection: Connection,
        authorized: AuthorizedWindow,
        origin: Instant,
    ) -> Result<Self> {
        Self::begin_with_capabilities(connection, authorized, origin, true, true, false)
    }

    #[allow(clippy::needless_pass_by_value)] // Consume the source's local authorization decision.
    fn begin_with_capabilities(
        connection: Connection,
        authorized: AuthorizedWindow,
        origin: Instant,
        allow_buttons: bool,
        allow_wheel: bool,
        allow_keyboard: bool,
    ) -> Result<Self> {
        Self::begin_capabilities_mode(
            connection,
            authorized,
            origin,
            allow_buttons,
            allow_wheel,
            allow_keyboard,
            false,
        )
    }

    /// Prepare atlas routing without acquiring the local seat. A fresh explicit
    /// remote selection must be approved before the first native BEGIN.
    pub(crate) fn prepare_atlas(
        connection: Connection,
        authorized: AuthorizedWindow,
        origin: Instant,
        allow_wheel: bool,
        allow_keyboard: bool,
    ) -> Result<Self> {
        Self::begin_capabilities_mode(
            connection,
            authorized,
            origin,
            true,
            allow_wheel,
            allow_keyboard,
            true,
        )
    }

    fn begin_capabilities_mode(
        mut connection: Connection,
        authorized: AuthorizedWindow,
        origin: Instant,
        allow_buttons: bool,
        allow_wheel: bool,
        allow_keyboard: bool,
        deferred: bool,
    ) -> Result<Self> {
        if authorized
            .content_origin
            .iter()
            .any(|v| !v.is_finite() || *v < 0.0)
        {
            bail!("invalid content origin");
        }
        if authorized
            .content_scale
            .iter()
            .any(|v| !v.is_finite() || *v <= 0.0)
        {
            bail!("invalid content scale");
        }
        let mut grant = WindowPointerGrant::new(
            authorized.owner,
            authorized.target_device,
            authorized.generation,
            authorized.geometry,
            authorized.expires_local_ns,
        )
        .ok_or_else(|| anyhow!("invalid window grant"))?;
        let deadline = native_deadline(origin, authorized.expires_local_ns)?;
        let mut keyboard_grant = (allow_keyboard && !deferred)
            .then(|| Self::new_keyboard_grant(&authorized))
            .transpose()?;
        let begin = if allow_keyboard {
            Request::begin_direct_keyboard
        } else if allow_wheel {
            Request::begin_buttons_wheel
        } else if allow_buttons {
            Request::begin_buttons
        } else {
            Request::begin
        };
        let request = begin(
            1,
            authorized.generation,
            authorized.native_address,
            authorized.native_pid,
            deadline,
            authorized.surface_extent,
            authorized.native_surface,
        )
        .map_err(|e| anyhow!("native begin: {e:?}"))?;
        let desktop_suspension = if deferred {
            let previous = grant
                .authorization(elapsed_ns(origin)?)
                .context("initial atlas grant expired")?;
            grant.revoke();
            if let Some(keyboard) = &mut keyboard_grant {
                keyboard.revoke();
            }
            Some(previous)
        } else {
            connection.send(request)?;
            None
        };
        Ok(Self {
            selection_acceptances: None,
            selection_rejections: None,
            native_grant_ever_active: false,
            last_ended_generation: 0,
            connection,
            grant,
            keyboard_grant,
            allow_keyboard,
            pending_keyboard_mode: None,
            pending_key: None,
            owner: authorized.owner,
            generation: authorized.generation,
            sequence: if deferred { 0 } else { 1 },
            origin,
            expires: authorized.expires_local_ns,
            content_origin: authorized.content_origin,
            content_scale: authorized.content_scale,
            surface_extent: authorized.surface_extent,
            native_binding: (
                authorized.native_address,
                authorized.native_surface,
                authorized.native_pid,
            ),
            state: if deferred {
                State::DesktopPaused
            } else {
                State::Beginning
            },
            pending_switch: None,
            resize_suspension: None,
            desktop_suspension,
            allow_resize_recovery: false,
            recovery_unconfirmed: Arc::new(AtomicBool::new(!deferred)),
            atlas_membership: None,
            observed_withdrawals: Default::default(),
            closed_windows: Default::default(),
            allow_buttons,
            allow_wheel,
            cursor: None,
            last_native_send: None,
            last_motion_rejected: false,
            motion_takeover_pending: false,
            last_delivery: None,
        })
    }

    /// Renew from a new explicit source decision backed by a newer verified
    /// presentation. Never retarget a live session or extend an old generation.
    /// Publication and motion remain disabled until native BEGIN is confirmed.
    /// # Errors
    /// Rejects pending commands, expired grants, changed bindings, stale evidence,
    /// excessive deadlines, and native transport failure.
    #[allow(clippy::float_cmp)] // Retained native binding must match exactly.
    #[allow(clippy::needless_pass_by_value)] // Consume the new source policy decision.
    pub fn renew(&mut self, authorized: AuthorizedWindow) -> Result<()> {
        if self.state != State::Ready {
            bail!("window renewal requires a confirmed idle native session");
        }
        let now = elapsed_ns(self.origin)?;
        let previous = self
            .grant
            .authorization(now)
            .ok_or_else(|| anyhow!("cannot renew expired window authorization"))?;
        let grant = WindowPointerGrant::new(
            authorized.owner,
            authorized.target_device,
            authorized.generation,
            authorized.geometry,
            authorized.expires_local_ns,
        )
        .ok_or_else(|| anyhow!("invalid renewed window grant"))?;
        let next = grant
            .authorization(now)
            .ok_or_else(|| anyhow!("renewed window authorization already expired"))?;
        if next.owner_device != previous.owner_device
            || next.target_device != previous.target_device
            || next.target_window != previous.target_window
            || next.geometry_epoch != previous.geometry_epoch
            || next.presented_frame <= previous.presented_frame
            || next.lease_generation <= previous.lease_generation
            || next.source_not_after_ns <= previous.source_not_after_ns
            || self.native_binding
                != (
                    authorized.native_address,
                    authorized.native_surface,
                    authorized.native_pid,
                )
            || self.surface_extent != authorized.surface_extent
            || self.content_origin != authorized.content_origin
            || self.content_scale != authorized.content_scale
        {
            bail!("renewal changed binding or failed to advance source authorization");
        }
        let deadline = native_deadline(self.origin, authorized.expires_local_ns)?;
        let sequence = self.connection.next_sequence();
        let begin = if self.keyboard_grant.is_some() {
            Request::begin_direct_keyboard
        } else if self.allow_wheel {
            Request::begin_buttons_wheel
        } else if self.allow_buttons {
            Request::begin_buttons
        } else {
            Request::begin
        };
        let request = begin(
            sequence,
            authorized.generation,
            authorized.native_address,
            authorized.native_pid,
            deadline,
            authorized.surface_extent,
            authorized.native_surface,
        )
        .map_err(|e| anyhow!("native renewal: {e:?}"))?;
        if let Some(keyboard) = &mut self.keyboard_grant {
            anyhow::ensure!(
                keyboard.renew(
                    authorized.owner,
                    authorized.target_device,
                    authorized.generation,
                    authorized.geometry.identity(),
                    authorized.expires_local_ns,
                    now,
                ),
                "keyboard renewal rejected"
            );
        }
        if let Err(error) = self.connection.send(request) {
            self.revoke();
            return Err(error.into());
        }
        self.grant = grant;
        self.generation = authorized.generation;
        self.sequence = sequence;
        self.expires = authorized.expires_local_ns;
        self.state = State::Beginning;
        self.recovery_unconfirmed.store(true, Ordering::Release);
        self.last_native_send = None;
        Ok(())
    }

    /// End the native window route before a desktop drag is handed to its
    /// source-owned mover. Completion is observed by [`Self::poll`]; callers
    /// must not forward the drag until the state becomes `DesktopPaused`.
    ///
    /// The previous grant is retained only as comparison evidence until the
    /// native `Ended` reply arrives. It can never be used to resume input.
    pub(super) fn pause_for_desktop(&mut self) -> Result<()> {
        self.pause_for_desktop_mode(false)
    }

    fn pause_for_desktop_mode(&mut self, preserve_focus: bool) -> Result<()> {
        anyhow::ensure!(
            matches!(self.state, State::Ready | State::ResizeSuspended),
            "desktop move requires a confirmed idle native session"
        );
        // Expired grants still identify exactly which held state END must release.
        let previous = self
            .resize_suspension
            .or_else(|| self.grant.authorization(0))
            .context("desktop move authority expired")?;
        let sequence = self.connection.next_sequence();
        let end = if preserve_focus {
            Request::end_preserving_focus
        } else {
            Request::end
        };
        let end = end(sequence, self.generation)
            .map_err(|error| anyhow!("native desktop end: {error:?}"))?;
        if let Err(error) = self.connection.send(end) {
            self.revoke();
            return Err(error.into());
        }
        self.sequence = sequence;
        self.desktop_suspension = Some(previous);
        self.resize_suspension = None;
        self.state = State::DesktopEnding;
        self.recovery_unconfirmed.store(true, Ordering::Release);
        self.last_native_send = None;
        Ok(())
    }

    /// Re-open the existing native connection after an explicitly newer
    /// source authorization. This is intentionally stricter than a renewal:
    /// the old desktop-drag grant was revoked by the confirmed native END.
    pub(super) fn resume_after_desktop_pause(
        &mut self,
        authorized: AuthorizedWindow,
    ) -> Result<()> {
        anyhow::ensure!(
            self.state == State::DesktopPaused,
            "desktop resume requires a confirmed native end"
        );
        let now = elapsed_ns(self.origin)?;
        let previous = self
            .desktop_suspension
            .context("missing desktop pause authorization")?;
        let grant = window_switch::switch_grant(&authorized, self.origin)?;
        let next = grant
            .authorization(now)
            .context("desktop resume authorization expired")?;
        anyhow::ensure!(
            !self.closed_windows.contains(&next.target_window),
            "closed atlas target cannot resume"
        );
        anyhow::ensure!(
            next.owner_device == previous.owner_device
                && next.target_device == previous.target_device
                && next.lease_generation > previous.lease_generation,
            "desktop resume did not provide newer source authorization"
        );
        if next.target_window == previous.target_window {
            // A no-op drag may leave its geometry epoch unchanged. It still
            // needs a newer lease generation and non-regressing frame;
            // neither an old receipt nor a geometry regression can revive it.
            anyhow::ensure!(
                next.geometry_epoch >= previous.geometry_epoch
                    && next.presented_frame >= previous.presented_frame,
                "desktop resume did not provide fresh same-window geometry"
            );
        } else {
            // Epoch/frame values are per-window, so they are not comparable
            // across a selection. Require the new source policy to bind a
            // different native target before reissuing BEGIN on this socket.
            anyhow::ensure!(
                (
                    authorized.native_address,
                    authorized.native_surface,
                    authorized.native_pid,
                ) != self.native_binding,
                "desktop resume changed window without a fresh native binding"
            );
        }
        // A capture cancellation releases input but leaves the native authority
        // revoked. Complete END before BEGIN; DesktopPaused alone is not an END
        // receipt. Initial atlas startup has never installed a native grant.
        if self.native_grant_ever_active && self.last_ended_generation != self.generation {
            let sequence = self.connection.next_sequence();
            let end = Request::end_preserving_focus(sequence, self.generation)
                .map_err(|error| anyhow!("native resume end: {error:?}"))?;
            self.connection.send(end)?;
            self.sequence = sequence;
            self.pending_switch = Some(authorized);
            self.state = State::SwitchingEnd;
            self.recovery_unconfirmed.store(true, Ordering::Release);
            return Ok(());
        }
        let sequence = self.connection.next_sequence();
        let keyboard_mode = self
            .pending_keyboard_mode
            .unwrap_or(self.keyboard_grant.is_some());
        anyhow::ensure!(
            !keyboard_mode || self.allow_keyboard,
            "keyboard activation exceeds local capability"
        );
        let keyboard_grant = keyboard_mode
            .then(|| Self::new_keyboard_grant(&authorized))
            .transpose()?;
        let begin = if keyboard_grant.is_some() {
            Request::begin_direct_keyboard
        } else if self.allow_wheel {
            Request::begin_buttons_wheel
        } else if self.allow_buttons {
            Request::begin_buttons
        } else {
            Request::begin
        };
        let request = begin(
            sequence,
            authorized.generation,
            authorized.native_address,
            authorized.native_pid,
            native_deadline(self.origin, authorized.expires_local_ns)?,
            authorized.surface_extent,
            authorized.native_surface,
        )
        .map_err(|error| anyhow!("native desktop resume begin: {error:?}"))?;
        if let Err(error) = self.connection.send(request) {
            self.revoke();
            return Err(error.into());
        }
        self.grant = grant;
        self.keyboard_grant = keyboard_grant;
        self.pending_keyboard_mode = None;
        self.owner = authorized.owner;
        self.generation = authorized.generation;
        self.sequence = sequence;
        self.expires = authorized.expires_local_ns;
        self.content_origin = authorized.content_origin;
        self.content_scale = authorized.content_scale;
        self.surface_extent = authorized.surface_extent;
        self.native_binding = (
            authorized.native_address,
            authorized.native_surface,
            authorized.native_pid,
        );
        self.desktop_suspension = None;
        self.state = State::Beginning;
        self.recovery_unconfirmed.store(true, Ordering::Release);
        self.last_native_send = None;
        Ok(())
    }

    /// Drain regularly, forwarding returned metadata to the source dispatcher.
    /// Acknowledgements are not reported until the native backend confirms them.
    /// # Errors
    /// Expiry, disconnect, rejection, or a mismatched state revokes the grant.
    pub fn poll(&mut self) -> Result<Option<Event>> {
        if self.state == State::Ended {
            bail!("window session ended");
        }
        // END cleans the old grant; its expiry cannot cancel that cleanup or
        // invalidate the separately checked replacement waiting behind it.
        if !matches!(
            self.state,
            State::DesktopPaused | State::SwitchingEnd | State::DesktopEnding
        ) && elapsed_ns(self.origin)? >= self.expires
        {
            self.revoke();
            bail!("window grant expired");
        }
        for _ in 0..32 {
            return match self.connection.receive() {
                Ok(Event::CaptureReceipt(receipt)) => {
                    self.cursor
                        .as_mut()
                        .context("capture receipt without cursor owner")?
                        .receipt(receipt)?;
                    continue;
                }
                Ok(Event::Metadata(bytes)) => {
                    if let Some(cursor) = &self.cursor {
                        if cursor.metadata(&bytes)? {
                            continue;
                        }
                    }
                    Ok(Some(Event::Metadata(bytes)))
                }
                Ok(Event::Revoked { generation, reason }) => {
                    use viewflow_hyprland::window_pointer_socket::RevocationReason;
                    if matches!(self.state, State::SwitchingEnd | State::DesktopEnding)
                        && generation == self.generation
                    {
                        // Retirement can emit expiry/focus notifications before
                        // replying to the already-issued END. Await that exact
                        // cleanup result; no input is eligible in these states.
                        return Ok(None);
                    }
                    if self.atlas_membership.is_some()
                        && matches!(
                            self.state,
                            State::Ready | State::ResizeSuspended | State::DesktopEnding
                        )
                        && generation == self.generation
                        && matches!(
                            reason,
                            RevocationReason::WindowUnmapped
                                | RevocationReason::SurfaceUnmapped
                                | RevocationReason::SurfaceDestroyed
                        )
                    {
                        let previous = self
                            .desktop_suspension
                            .or(self.resize_suspension)
                            .or_else(|| self.grant.authorization(elapsed_ns(self.origin).ok()?))
                            .context("closed atlas target authority missing")?;
                        anyhow::ensure!(
                            self.closed_windows.len() < 4096,
                            "closed atlas input bound exhausted"
                        );
                        self.closed_windows.insert(previous.target_window);
                        self.grant.revoke();
                        if let Some(keyboard) = &mut self.keyboard_grant {
                            keyboard.revoke();
                        }
                        // No input is live. Routed maintenance still requires an
                        // exact native END before accepting another selection.
                        if self.state != State::DesktopEnding {
                            self.resize_suspension = Some(previous);
                            self.state = State::ResizeSuspended;
                        }
                        self.recovery_unconfirmed.store(true, Ordering::Release);
                        return Ok(None);
                    }
                    if reason == RevocationReason::Cancelled
                        && self.state == State::DesktopPaused
                        && generation == self.generation
                        && self.last_ended_generation == generation
                        && self
                            .cursor
                            .as_ref()
                            .is_some_and(|cursor| cursor.pending_release_generation().is_some())
                    {
                        // Only an already-END-confirmed window may observe this
                        // duplicate cancellation during an explicit native capture
                        // release. Its separate capture receipt is still required.
                        return Ok(None);
                    }
                    if self.cursor.is_some()
                        && matches!(self.state, State::Ready | State::Moving)
                        && generation == self.generation
                        && matches!(
                            reason,
                            RevocationReason::LocalMotion
                                | RevocationReason::LocalButton
                                | RevocationReason::LocalAxis
                                | RevocationReason::LocalKey
                                | RevocationReason::Cancelled
                        )
                    {
                        self.desktop_suspension =
                            self.grant.authorization(elapsed_ns(self.origin)?);
                        self.grant.revoke();
                        if let Some(keyboard) = &mut self.keyboard_grant {
                            keyboard.revoke();
                        }
                        if self.state == State::Moving {
                            // Keep the socket's outstanding command until its exact
                            // result arrives. Local takeover retires this route,
                            // not the media connection or the other atlas tiles.
                            self.motion_takeover_pending = true;
                        } else {
                            self.state = State::DesktopPaused;
                        }
                        self.cursor
                            .as_ref()
                            .expect("cursor checked")
                            .local_takeover();
                        self.recovery_unconfirmed.store(true, Ordering::Release);
                        return Ok(None);
                    }

                    if self.allow_resize_recovery
                        && self.state == State::Ready
                        && generation == self.generation
                        && reason
                            == viewflow_hyprland::window_pointer_socket::RevocationReason::Resized
                    {
                        if let Some(previous) = self.grant.authorization(elapsed_ns(self.origin)?) {
                            self.resize_suspension = Some(previous);
                            self.grant.revoke();
                            if let Some(keyboard) = &mut self.keyboard_grant {
                                keyboard.revoke();
                            }
                            self.state = State::ResizeSuspended;
                            // New plugins notify after cleanup, but older peers used
                            // the same reason code before cleanup. Keep the recovery
                            // fence until explicit REBIND receives Begun. This is
                            // never an ACK for an in-flight event (Ready only).
                            self.recovery_unconfirmed.store(true, Ordering::Release);
                            return Ok(None);
                        }
                    }
                    self.revoke();
                    bail!(
                        "native window authorization revoked: generation={generation} reason={reason:?}"
                    );
                }
                Ok(Event::Completed(outcome)) => {
                    if self.state == State::Moving && self.motion_takeover_pending {
                        anyhow::ensure!(
                            matches!(outcome, Outcome::Rejected | Outcome::MotionSent),
                            "unexpected motion completion during local takeover"
                        );
                        self.last_motion_rejected = outcome == Outcome::Rejected;
                        self.motion_takeover_pending = false;
                        self.state = State::DesktopPaused;
                        return Ok(Some(Event::Completed(outcome)));
                    }
                    if self.state == State::Moving && outcome == Outcome::Rejected {
                        self.last_motion_rejected = true;
                        self.state = State::Ready;
                        self.recovery_unconfirmed.store(false, Ordering::Release);
                        return Ok(Some(Event::Completed(outcome)));
                    }
                    if self.state == State::Beginning && outcome == Outcome::Rejected {
                        // A target may become temporarily unavailable while the
                        // selection is in flight. End this generation explicitly
                        // and retain the connection for the next selection.
                        self.desktop_suspension = self.grant.authorization(0);
                        let sequence = self.connection.next_sequence();
                        let end = Request::end_preserving_focus(sequence, self.generation)
                            .map_err(|error| anyhow!("rejected begin cleanup: {error:?}"))?;
                        self.connection.send(end)?;
                        self.sequence = sequence;
                        self.grant.revoke();
                        if let Some(keyboard) = &mut self.keyboard_grant {
                            keyboard.revoke();
                        }
                        self.state = State::DesktopEnding;
                        self.recovery_unconfirmed.store(true, Ordering::Release);
                        self.last_native_send = None;
                        return Ok(Some(Event::Completed(outcome)));
                    }
                    if outcome == Outcome::Begun {
                        self.native_grant_ever_active = true;
                    }
                    if self.state == State::DesktopEnding && outcome == Outcome::Ended {
                        // The native seat has now released the window. Retire the
                        // old grants before notifying the desktop mover, so an
                        // incoming pointer packet cannot race the move handler.
                        self.grant.revoke();
                        if let Some(keyboard) = &mut self.keyboard_grant {
                            keyboard.revoke();
                        }
                        self.last_ended_generation = self.generation;
                        self.state = State::DesktopPaused;
                        self.recovery_unconfirmed.store(true, Ordering::Release);
                        return Ok(Some(Event::Completed(outcome)));
                    }
                    if self.state == State::Keying && outcome == Outcome::KeySent {
                        let confirmed = self.pending_key.take().is_some_and(|event| {
                            self.keyboard_grant.as_mut().is_some_and(|grant| {
                                elapsed_ns(self.origin).is_ok_and(|now| grant.confirm(event, now))
                            })
                        });
                        if !confirmed {
                            self.revoke();
                            bail!("late or unmatched native keyboard confirmation");
                        }
                        self.state = State::Ready;
                        self.recovery_unconfirmed.store(false, Ordering::Release);
                        return Ok(Some(Event::Completed(outcome)));
                    }
                    if self.state == State::SwitchingEnd && outcome == Outcome::Ended {
                        self.last_ended_generation = self.generation;
                        if let Err(error) = self.begin_after_switch_end() {
                            self.revoke();
                            return Err(error);
                        }
                        return Ok(Some(Event::Completed(outcome)));
                    }
                    if matches!(
                        (self.state, outcome),
                        (State::Beginning, Outcome::Begun)
                            | (State::Moving, Outcome::MotionSent)
                            | (State::Pressing, Outcome::ButtonSent)
                            | (State::Scrolling, Outcome::WheelSent)
                    ) {
                        self.state = State::Ready;
                        self.recovery_unconfirmed.store(false, Ordering::Release);
                        Ok(Some(Event::Completed(outcome)))
                    } else {
                        self.revoke();
                        bail!("native window command rejected: {outcome:?}");
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(None),
                Err(error) => {
                    self.revoke();
                    Err(error.into())
                }
            };
        }
        Ok(None)
    }

    /// The event arrives on the authenticated connection whose owner was bound
    /// at construction. `estimate` and its sample time come from that connection.
    /// # Errors
    /// Rejects timing/identity/geometry failures, backpressure, or native send failure.
    pub fn motion(
        &mut self,
        event: WindowPointerMotion,
        estimate: Option<(ClockEstimate, u64)>,
    ) -> Result<()> {
        self.send_pointer(event, estimate, PointerAction::Motion)
    }

    /// Send a button transition only under an explicit local button grant.
    /// # Errors
    /// Any failure retires the native session, including a rejected release.
    pub fn button(
        &mut self,
        event: viewflow_protocol::WindowPointerButton,
        estimate: Option<(ClockEstimate, u64)>,
    ) -> Result<()> {
        let result = if self.allow_buttons {
            self.send_pointer(
                event.position,
                estimate,
                PointerAction::Button(event.transition),
            )
        } else {
            Err(anyhow!("window session is motion-only"))
        };
        if result.is_err() {
            self.revoke();
        }
        result
    }

    fn send_pointer(
        &mut self,
        event: WindowPointerMotion,
        estimate: Option<(ClockEstimate, u64)>,
        action: PointerAction,
    ) -> Result<()> {
        let now = elapsed_ns(self.origin)?;
        let deadline = conservative_input_deadline(
            event.sender_not_after_ns,
            estimate.map(|(estimate, measured_at_local_ns)| ClockSnapshot {
                estimate,
                measured_at_local_ns,
            }),
            now,
        )
        .ok();
        let point = self
            .grant
            .admit_motion(self.owner, event, deadline, now)
            .ok_or_else(|| anyhow!("window motion not admitted"))?;
        if self.state != State::Ready {
            bail!("native window command pending or ended");
        }
        let point = [
            point.x * self.content_scale[0] + self.content_origin[0],
            point.y * self.content_scale[1] + self.content_origin[1],
        ];
        if point
            .iter()
            .zip(self.surface_extent)
            .any(|(v, extent)| !v.is_finite() || *v < 0.0 || *v >= extent)
        {
            bail!("point outside bound surface");
        }
        let deadline = native_deadline(
            self.origin,
            deadline
                .ok_or_else(|| anyhow!("missing deadline"))?
                .min(self.expires),
        )?;
        self.sequence = self.connection.next_sequence();
        let request = match action {
            PointerAction::Button(button) => {
                use viewflow_protocol::{InputSwitchState, PointerButton};
                let code = match button.button {
                    PointerButton::Left => 1,
                    PointerButton::Middle => 2,
                    PointerButton::Right => 3,
                    PointerButton::Back => 4,
                    PointerButton::Forward => 5,
                };
                let state = match button.state {
                    InputSwitchState::Pressed => 1,
                    InputSwitchState::Released => 2,
                };
                Request::button(self.sequence, self.generation, deadline, point, code, state)
            }
            PointerAction::Motion => {
                Request::motion(self.sequence, self.generation, deadline, point)
            }
            PointerAction::Wheel(delta) => Request::wheel(
                self.sequence,
                self.generation,
                deadline,
                point,
                native_wheel_delta(delta)?,
            ),
        }
        .map_err(|e| anyhow!("native pointer request: {e:?}"))?;
        let send_started = native_clock_ns().unwrap_or(0);
        if let Err(error) = self.connection.send(request) {
            self.revoke();
            return Err(error.into());
        }
        self.last_native_send = Some([
            self.sequence,
            send_started,
            native_clock_ns().unwrap_or(0),
            deadline,
        ]);
        self.last_motion_rejected = false;
        self.state = match action {
            PointerAction::Motion => State::Moving,
            PointerAction::Button(_) => State::Pressing,
            PointerAction::Wheel(_) => State::Scrolling,
        };
        self.recovery_unconfirmed.store(true, Ordering::Release);
        Ok(())
    }

    pub fn advance_presented(&mut self, geometry: PresentedInputGeometry) -> bool {
        if !self.grant.advance_presented(geometry) {
            return false;
        }
        if self
            .keyboard_grant
            .as_mut()
            .is_some_and(|grant| !grant.advance_presented(geometry.identity()))
        {
            self.revoke();
            return false;
        }
        true
    }

    /// Send a scroll only under explicit local wheel authority. Never retry an
    /// uncertain non-idempotent scroll or extend its event-time deadline.
    /// # Errors
    /// Any failure retires the session, including missing wheel permission.
    pub fn wheel(
        &mut self,
        event: viewflow_protocol::WindowPointerWheel,
        estimate: Option<(ClockEstimate, u64)>,
    ) -> Result<()> {
        let result = if self.allow_wheel {
            self.send_pointer(event.position, estimate, PointerAction::Wheel(event.delta))
        } else {
            Err(anyhow!("window session has no wheel authority"))
        };
        if result.is_err() {
            self.revoke();
        }
        result
    }

    #[allow(clippy::float_cmp)]
    fn install_authorization(&mut self, authorized: AuthorizedWindow) -> Result<()> {
        if authorized.generation != self.generation {
            return self.renew(authorized);
        }
        let now = elapsed_ns(self.origin)?;
        let previous = self
            .grant
            .authorization(now)
            .ok_or_else(|| anyhow!("source window authorization expired"))?;
        if authorized.owner != previous.owner_device
            || authorized.target_device != previous.target_device
            || authorized.expires_local_ns != self.expires
            || self.native_binding
                != (
                    authorized.native_address,
                    authorized.native_surface,
                    authorized.native_pid,
                )
            || self.surface_extent != authorized.surface_extent
            || self.content_origin != authorized.content_origin
            || self.content_scale != authorized.content_scale
        {
            bail!("source presentation changed native authorization binding");
        }
        // A watch may initially hold the BEGIN value. Identical authorization
        // is harmless; all subsequent frames must advance the source identity.
        let next = WindowPointerGrant::new(
            authorized.owner,
            authorized.target_device,
            authorized.generation,
            authorized.geometry,
            authorized.expires_local_ns,
        )
        .and_then(|grant| grant.authorization(now));
        if next == Some(previous) {
            return Ok(());
        }
        if !self.advance_presented(authorized.geometry) {
            bail!("source presentation invalidated window authorization");
        }
        Ok(())
    }

    pub fn revoke(&mut self) {
        if let Some(keyboard) = &mut self.keyboard_grant {
            keyboard.revoke();
        }
        self.pending_key = None;
        self.pending_switch = None;
        self.resize_suspension = None;
        self.desktop_suspension = None;
        self.grant.revoke();
        self.state = State::Ended;
        self.recovery_unconfirmed.store(true, Ordering::Release);
        self.connection.close();
    }
}

/// Owned by the single shared network reader. No remote message can construct
/// this route; its session and receipt watch come from the source pipeline.
pub(crate) struct AtlasSelectionAcceptanceRequest {
    pub(crate) selection: viewflow_protocol::AtlasWindowSelection,
    pub(crate) authorization: AuthorizedWindow,
    pub(crate) completion: tokio::sync::oneshot::Sender<Result<()>>,
}

pub(crate) struct AtlasSelectionRejectionRequest {
    pub(crate) rejection: viewflow_protocol::AtlasWindowSelectionRejected,
    pub(crate) completion: tokio::sync::oneshot::Sender<Result<()>>,
}

#[derive(Clone, Copy)]
pub struct AtlasSelectionRequest {
    pub selection: viewflow_protocol::AtlasWindowSelection,
    /// Clock domain of this input session, not the independent video clock.
    pub clock: Option<(viewflow_transport::ClockEstimate, u64)>,
    pub received_local_ns: u64,
}

/// A desktop-move control is forwarded exactly once by the sole QUIC reader to
/// the source desktop controller. The completion reply is intentionally local:
/// the source controller owns native move application and the shared writer
/// later emits the wire acknowledgement.
pub(crate) struct DesktopMoveRequest {
    pub(crate) movement: viewflow_protocol::DesktopWindowMove,
    pub(crate) clock: Option<(viewflow_transport::ClockEstimate, u64)>,
    pub(crate) received_local_ns: u64,
    pub(crate) completion:
        tokio::sync::oneshot::Sender<Result<viewflow_protocol::DesktopWindowMoveAck>>,
}

#[derive(Default)]
pub(crate) struct WindowInputRouting {
    pub(crate) allow_switching: bool,
    pub(crate) shared: Option<crate::shared_control::SharedControlSender>,
    pub(crate) selections: Option<tokio::sync::mpsc::Sender<AtlasSelectionRequest>>,
    pub(crate) desktop_moves: Option<tokio::sync::mpsc::Sender<DesktopMoveRequest>>,
}

pub(crate) struct RoutedWindowInput<'a> {
    session: WindowInputSession,
    clocks: tokio::sync::watch::Receiver<Option<ClockSnapshot>>,
    presentations: tokio::sync::watch::Receiver<PresentedInputGeometry>,
    metadata: Box<dyn FnMut(Vec<u8>) -> Result<()> + Send + 'a>,
    announced: Option<viewflow_protocol::WindowPointerAuthorization>,
    announced_keyboard: Option<viewflow_protocol::WindowKeyboardAuthorization>,
    authorizations: Option<tokio::sync::watch::Receiver<AuthorizedWindow>>,
    allow_switching: bool,
    selected_presentation_owner: Option<tokio::sync::watch::Sender<PresentedInputGeometry>>,
    selections: Option<tokio::sync::mpsc::Sender<AtlasSelectionRequest>>,
    desktop_moves: Option<tokio::sync::mpsc::Sender<DesktopMoveRequest>>,
    desktop_drag_active: bool,
    desktop_authorization_floor: u64,
}

impl<'a> RoutedWindowInput<'a> {
    pub(crate) fn new(
        mut session: WindowInputSession,
        clocks: tokio::sync::watch::Receiver<Option<ClockSnapshot>>,
        presentations: tokio::sync::watch::Receiver<PresentedInputGeometry>,
        authorizations: Option<tokio::sync::watch::Receiver<AuthorizedWindow>>,
        allow_switching: bool,
        metadata: impl FnMut(Vec<u8>) -> Result<()> + Send + 'a,
    ) -> Self {
        session.allow_resize_recovery = allow_switching && authorizations.is_some();
        Self {
            session,
            clocks,
            presentations,
            metadata: Box::new(metadata),
            announced: None,
            announced_keyboard: None,
            authorizations,
            allow_switching,
            selected_presentation_owner: None,
            selections: None,
            desktop_moves: None,
            desktop_drag_active: false,
            desktop_authorization_floor: 0,
        }
    }

    fn fence_desktop_authorizations(&mut self) {
        self.desktop_authorization_floor = self
            .desktop_authorization_floor
            .max(self.session.generation);
        if let Some(owner) = &mut self.authorizations {
            self.desktop_authorization_floor = self
                .desktop_authorization_floor
                .max(owner.borrow_and_update().generation);
        }
    }

    pub(crate) fn attach_selections(
        &mut self,
        selections: Option<tokio::sync::mpsc::Sender<AtlasSelectionRequest>>,
    ) {
        self.selections = selections;
    }

    pub(crate) fn attach_desktop_moves(
        &mut self,
        desktop_moves: Option<tokio::sync::mpsc::Sender<DesktopMoveRequest>>,
    ) {
        self.desktop_moves = desktop_moves;
    }

    pub(crate) async fn release_window_input(&mut self, network: &quinn::Connection,
        window: viewflow_protocol::WindowId) -> Result<()> {
        if self.session.grant.authorization(0).is_some_and(|auth| auth.target_window == window) {
            self.session.wait_native(network, &mut self.presentations, &mut self.metadata).await?;
            if !matches!(self.session.state, State::Ready | State::ResizeSuspended) { return Ok(()); }
            self.session.pause_for_desktop_mode(true)?;
            self.session.wait_native(network, &mut self.presentations, &mut self.metadata).await?;
            self.fence_desktop_authorizations();
        }
        Ok(())
    }

    /// Forward one validated desktop movement to the source controller. This
    /// never opens a second QUIC reader or native connection.
    pub(crate) async fn desktop_move(
        &mut self,
        network: &quinn::Connection,
        movement: viewflow_protocol::DesktopWindowMove,
    ) -> Result<viewflow_protocol::DesktopWindowMoveAck> {
        let sender = self
            .desktop_moves
            .clone()
            .ok_or_else(|| anyhow!("desktop move routing is not enabled"))?;
        movement
            .validate()
            .map_err(|error| anyhow!("invalid desktop move: {error:?}"))?;
        self.clocks.has_changed()?;
        let clock = self
            .clocks
            .borrow()
            .map(|snapshot| (snapshot.estimate, snapshot.measured_at_local_ns));
        let received_local_ns = elapsed_ns(self.session.origin)?;
        // The source desktop worker validates the wire deadline and returns
        // a scoped rejection. This router waits on its local operation budget;
        // a multi-frame drag must never go through pointer freshness admission.
        let deadline = tokio::time::Instant::now()
            + std::time::Duration::from_nanos(crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS);

        match movement.phase {
            viewflow_protocol::DesktopWindowMovePhase::Begin => {
                if self.session.state != State::DesktopPaused {
                    self.session.pause_for_desktop()?;
                }
                self.session
                    .wait_native_until(
                        network,
                        &mut self.presentations,
                        &mut self.metadata,
                        deadline.into_std(),
                    )
                    .await?;
                anyhow::ensure!(
                    self.session.state == State::DesktopPaused,
                    "desktop move native end was not confirmed"
                );
                self.desktop_drag_active = true;
                self.fence_desktop_authorizations();
            }
            viewflow_protocol::DesktopWindowMovePhase::Update
            | viewflow_protocol::DesktopWindowMovePhase::End
            | viewflow_protocol::DesktopWindowMovePhase::Cancel => anyhow::ensure!(
                self.session.state == State::DesktopPaused,
                "desktop move update requires a paused native route"
            ),
        }
        let (completion, receiver) = tokio::sync::oneshot::channel();
        // Once routed, retain ordered ownership through the source result.
        // Its native operation watchdog yields a scoped rejection; cancelling
        // this waiter could strand an accepted Begin or discard End cleanup.
        sender
            .send(DesktopMoveRequest {
                movement,
                clock,
                received_local_ns,
                completion,
            })
            .await
            .map_err(|_| anyhow!("desktop move source controller unavailable"))?;
        let ack = receiver
            .await
            .map_err(|_| anyhow!("desktop move source controller dropped completion"))??;
        if (matches!(
            movement.phase,
            viewflow_protocol::DesktopWindowMovePhase::End
                | viewflow_protocol::DesktopWindowMovePhase::Cancel
        ) && ack.result == viewflow_protocol::DesktopWindowMoveResult::Ended)
            || (movement.phase == viewflow_protocol::DesktopWindowMovePhase::Begin
                && ack.result == viewflow_protocol::DesktopWindowMoveResult::Rejected)
        {
            // Source policy has now invalidated the old grant. Drain any
            // earlier watch renewal before accepting a post-End selection.
            self.fence_desktop_authorizations();
            self.desktop_drag_active = false;
        }
        Ok(ack)
    }

    pub(crate) fn select_atlas(
        &mut self,
        selection: viewflow_protocol::AtlasWindowSelection,
    ) -> Result<()> {
        anyhow::ensure!(
            !self.desktop_drag_active,
            "atlas selection overlaps desktop drag"
        );
        let sender = self
            .selections
            .as_ref()
            .ok_or_else(|| anyhow!("atlas selection is not enabled"))?;
        self.clocks.has_changed()?;
        let clock = self
            .clocks
            .borrow()
            .map(|snapshot| (snapshot.estimate, snapshot.measured_at_local_ns));
        sender
            .try_send(AtlasSelectionRequest {
                selection,
                clock,
                received_local_ns: elapsed_ns(self.session.origin)?,
            })
            .map_err(|_| anyhow!("atlas selection owner unavailable or queue full"))
    }

    /// Called only by the shared writer owner after native maintenance. This
    /// contains no native object token and cannot grant device-wide input.
    pub(crate) fn announcement(
        &mut self,
    ) -> Result<Option<viewflow_protocol::WindowPointerAuthorization>> {
        if self.session.state != State::Ready || self.clocks.borrow().is_none() {
            return Ok(None);
        }
        if let Some(owner) = &self.authorizations {
            if owner.has_changed()? {
                return Ok(None);
            }
        }
        let authorization = self
            .session
            .grant
            .authorization(elapsed_ns(self.session.origin)?)
            .ok_or_else(|| anyhow!("window authorization expired before publication"))?;
        if self.announced == Some(authorization) {
            return Ok(None);
        }
        self.announced = Some(authorization);
        Ok(Some(authorization))
    }

    async fn accept_selection(&mut self, network: &quinn::Connection) -> Result<bool> {
        let Some((requests, writer)) = &mut self.session.selection_acceptances else {
            return Ok(false);
        };
        let request = match requests.try_recv() {
            Ok(request) => request,
            Err(tokio::sync::mpsc::error::TryRecvError::Empty) => return Ok(false),
            Err(_) => bail!("atlas selection acceptance source disappeared"),
        };
        let writer = writer.clone();
        let result: Result<()> = async {
            // A selected authorization is delivered by a non-coalescing queue.
            // Older maintenance watch values cannot replace its exact decision.
            if let Some(authorizations) = &mut self.authorizations {
                authorizations.borrow_and_update();
            }
            self.install_atlas_authorization(request.selection, request.authorization)?;
            self.session.wait_native(network, &mut self.presentations, &mut self.metadata).await?;
            anyhow::ensure!(self.session.state == State::Ready, "accepted selection native authorization unconfirmed");
            let authorization = self.session.grant.authorization(elapsed_ns(self.session.origin)?)
                .context("accepted selection authorization expired")?;
            let accepted = viewflow_protocol::AtlasWindowSelectionAccepted { selection: request.selection, authorization };
            accepted.validate().map_err(|error| anyhow!("accepted selection differs from installed native grant: {error:?}"))?;
            // This is a bounded receipt, never an extension of the input event.
            writer.send(viewflow_protocol::wire::control_envelope::Payload::AtlasWindowSelectionAccepted(accepted.into()),
                tokio::time::Instant::now() + std::time::Duration::from_millis(100)).await?;
            self.announced = Some(authorization);
            Ok(())
        }.await;
        let failure = result.as_ref().err().map(|error| format!("{error:#}"));
        let _ = request.completion.send(result);
        if let Some(failure) = failure {
            // A local takeover can retire the grant between source selection
            // and native installation. Report that exact selection to the
            // source owner for ordered rejection/END, keeping this route alive.
            if matches!(
                self.session.state,
                State::Ready | State::DesktopPaused | State::ResizeSuspended
            ) {
                eprintln!("selection acceptance retry: {failure}");
            } else {
                bail!("selection acceptance failed: {failure}");
            }
        }
        Ok(true)
    }

    async fn reject_selection(&mut self, network: &quinn::Connection) -> Result<bool> {
        let Some((requests, writer)) = &mut self.session.selection_rejections else {
            return Ok(false);
        };
        let request = match requests.try_recv() {
            Ok(request) => request,
            Err(tokio::sync::mpsc::error::TryRecvError::Empty) => return Ok(false),
            Err(_) => bail!("atlas selection rejection source disappeared"),
        };
        let writer = writer.clone();
        self.fence_desktop_authorizations();
        // Rejection is a safety transaction, never an extension of the rejected event.
        let deadline = Instant::now() + std::time::Duration::from_millis(100);
        let result: Result<()> = async {
            if self.session.state == State::DesktopPaused && self.session.native_grant_ever_active && self.session.last_ended_generation != self.session.generation {
                let sequence = self.session.connection.next_sequence();
                let end = Request::end_preserving_focus(sequence,self.session.generation).map_err(|error|anyhow!("selection rejection END: {error:?}"))?;
                self.session.connection.send(end)?;
                self.session.sequence=sequence;
                self.session.state=State::DesktopEnding;
                self.session.wait_native_until(network,&mut self.presentations,&mut self.metadata,deadline).await?;
            }
            if self.session.state != State::DesktopPaused {
                self.session.pause_for_desktop_mode(true)?;
                self.session.wait_native_until(network, &mut self.presentations, &mut self.metadata, deadline).await?;
            }
            anyhow::ensure!(self.session.state == State::DesktopPaused, "selection rejection native END unconfirmed");
            anyhow::ensure!(!self.session.native_grant_ever_active || self.session.last_ended_generation == self.session.generation, "selection rejection lacks native cleanup proof");
            let rejection = viewflow_protocol::AtlasWindowSelectionRejected { released_generation:self.session.last_ended_generation, ..request.rejection };
            rejection.validate().map_err(|error| anyhow!("selection rejection invalid: {error:?}"))?;
            writer.send(viewflow_protocol::wire::control_envelope::Payload::AtlasWindowSelectionRejected(rejection.into()), deadline.into()).await?;
            eprintln!("atlas-selection-rejected sequence={} reason={:?} released_generation={} capture_age_ns={} capture_limit_ns={}", rejection.selection.sequence,rejection.reason,rejection.released_generation,rejection.capture_age_ns,rejection.capture_limit_ns);
            Ok(())
        }.await;
        let failure = result.as_ref().err().map(|error| format!("{error:#}"));
        let _ = request.completion.send(result);
        if let Some(failure) = failure {
            bail!("selection rejection cleanup failed: {failure}");
        }
        Ok(true)
    }

    pub(crate) async fn maintain(&mut self, network: &quinn::Connection) -> Result<()> {
        if self
            .selections
            .as_ref()
            .is_some_and(tokio::sync::mpsc::Sender::is_closed)
        {
            bail!("atlas selection owner disappeared");
        }
        if self
            .desktop_moves
            .as_ref()
            .is_some_and(tokio::sync::mpsc::Sender::is_closed)
        {
            bail!("desktop move source controller disappeared");
        }
        self.session
            .wait_native(network, &mut self.presentations, &mut self.metadata)
            .await?;
        if self.reject_selection(network).await? {
            return Ok(());
        }
        // Observe a queued resize/terminal revocation before deciding whether a
        // changed authorization needs END/BEGIN or explicit resize rebind.
        for _ in 0..32 {
            match self.session.poll()? {
                Some(Event::Metadata(bytes)) => (self.metadata)(bytes)?,
                Some(Event::CaptureReceipt(_)) => bail!("unrouted capture receipt"),
                Some(Event::Completed(_)) => bail!("unexpected native acknowledgement while idle"),
                Some(Event::Revoked { .. }) => bail!("unhandled native revocation"),
                None => break,
            }
        }
        // An absent tile is an explicit source withdrawal. Confirm native
        // END (including release of pressed input) before accepting selection.
        if let Some(membership) = &self.session.atlas_membership {
            membership.has_changed()?;
            let identity = self
                .session
                .resize_suspension
                .or(self.session.desktop_suspension)
                .or_else(|| {
                    self.session
                        .grant
                        .authorization(elapsed_ns(self.session.origin).ok()?)
                });
            let changed = identity.is_some_and(|id| {
                let latest = membership.borrow();
                self.session.closed_windows.contains(&id.target_window)
                    || !latest.windows.contains(&id.target_window)
                    || latest.withdrawals.get(&id.target_window)
                        != self.session.observed_withdrawals.get(&id.target_window)
            });
            let observed = membership.borrow().withdrawals.clone();
            self.desktop_authorization_floor = self
                .desktop_authorization_floor
                .max(membership.borrow().authorization_floor);
            if changed {
                if matches!(self.session.state, State::Ready | State::ResizeSuspended) {
                    self.session.pause_for_desktop()?;
                    self.session
                        .wait_native(network, &mut self.presentations, &mut self.metadata)
                        .await?;
                    anyhow::ensure!(
                        self.session.state == State::DesktopPaused,
                        "atlas withdrawal END unconfirmed"
                    );
                    self.desktop_authorization_floor = self
                        .desktop_authorization_floor
                        .max(self.session.generation);
                }
            }
            self.session.observed_withdrawals = observed;
        }
        if let Some(cursor) = &mut self.session.cursor {
            if cursor.service(&mut self.session.connection, *self.clocks.borrow())? {
                if let Some(Event::Metadata(bytes)) = self.session.poll()? {
                    (self.metadata)(bytes)?;
                }
                return Ok(());
            }
        }
        if self.accept_selection(network).await? {
            return Ok(());
        }
        if let Some(authorizations) = &mut self.authorizations
            && authorizations.has_changed()?
        {
            let authorization = authorizations.borrow_and_update().clone();
            if self
                .session
                .atlas_membership
                .as_ref()
                .is_some_and(|membership| {
                    !membership
                        .borrow()
                        .windows
                        .contains(&authorization.geometry.identity().window)
                })
            {
                self.desktop_authorization_floor = self
                    .desktop_authorization_floor
                    .max(authorization.generation);
                return Ok(());
            }
            self.install_selected_authorization(authorization)?;
            self.session
                .wait_native(network, &mut self.presentations, &mut self.metadata)
                .await?;
            self.authorizations
                .as_ref()
                .expect("source authorization owner")
                .has_changed()?;
        }
        if self.presentations.has_changed()? && self.session.state != State::ResizeSuspended {
            self.session
                .install_receipt(Ok(()), &mut self.presentations)?;
        }
        if self.clocks.has_changed().is_err() {
            bail!("window input clock owner disappeared");
        }
        if let Some(event) = self.session.poll()? {
            match event {
                Event::Metadata(bytes) => (self.metadata)(bytes)?,
                Event::CaptureReceipt(_) => bail!("unrouted capture receipt"),
                Event::Completed(_) => bail!("unexpected native acknowledgement while idle"),
                Event::Revoked { .. } => bail!("native window authorization revoked while idle"),
            }
        }
        Ok(())
    }

    pub(crate) async fn deliver(
        &mut self,
        network: &quinn::Connection,
        motion: WindowPointerMotion,
    ) -> Result<viewflow_protocol::WindowPointerAck> {
        self.deliver_pointer(network, motion, PointerAction::Motion)
            .await
    }

    pub(crate) async fn deliver_button(
        &mut self,
        network: &quinn::Connection,
        button: viewflow_protocol::WindowPointerButton,
    ) -> Result<viewflow_protocol::WindowPointerAck> {
        self.deliver_pointer(
            network,
            button.position,
            PointerAction::Button(button.transition),
        )
        .await
    }

    pub(crate) async fn deliver_wheel(
        &mut self,
        network: &quinn::Connection,
        wheel: viewflow_protocol::WindowPointerWheel,
    ) -> Result<viewflow_protocol::WindowPointerAck> {
        self.deliver_pointer(network, wheel.position, PointerAction::Wheel(wheel.delta))
            .await
    }

    async fn deliver_pointer(
        &mut self,
        network: &quinn::Connection,
        motion: WindowPointerMotion,
        action: PointerAction,
    ) -> Result<viewflow_protocol::WindowPointerAck> {
        // A source selection can arrive while the shared reader awaits an
        // event. Apply it before admitting that event against the old route.
        if self
            .authorizations
            .as_ref()
            .is_some_and(|owner| owner.has_changed().unwrap_or(true))
        {
            self.maintain(network).await?;
        }
        if let Some(authorizations) = &self.authorizations {
            authorizations.has_changed()?;
        }
        if self.clocks.has_changed().is_err() {
            bail!("window input clock owner disappeared");
        }
        let estimate = self
            .clocks
            .borrow()
            .map(|snapshot| (snapshot.estimate, snapshot.measured_at_local_ns));
        self.session
            .deliver_pointer(
                network,
                motion,
                estimate,
                &mut self.presentations,
                &mut self.metadata,
                action,
            )
            .await
    }
}

impl Drop for WindowInputSession {
    fn drop(&mut self) {
        if self.last_delivery.is_some() {
            eprintln!(
                "window-input-retiring delivery={:?} native_send={:?}",
                self.last_delivery, self.last_native_send
            );
        }
        self.revoke();
    }
}

fn elapsed_ns(origin: Instant) -> Result<u64> {
    Ok(u64::try_from(origin.elapsed().as_nanos())?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use nix::sys::socket::{self, AddressFamily, MsgFlags, SockFlag, SockType, UnixAddr};
    use std::os::fd::AsRawFd;
    use viewflow_core::{CaptureGeometry, PresentedInputIdentity};
    use viewflow_hyprland::window_pointer_socket::Listener;
    use viewflow_protocol::{Id128, Point, Rect, Size};

    #[test]
    fn membership_watch_retains_withdrawal_even_when_intermediate_layout_is_skipped() {
        let mut state = AtlasInputMembership::default();
        state.update([Id128(3)].into()).unwrap();
        let (sender, receiver) = tokio::sync::watch::channel(state.clone());
        state.update(Default::default()).unwrap();
        sender.send_replace(state.clone());
        state.update([Id128(3)].into()).unwrap();
        sender.send_replace(state);
        let latest = receiver.borrow();
        assert!(latest.windows.contains(&Id128(3)));
        assert_eq!(latest.withdrawals.get(&Id128(3)), Some(&1));
    }

    #[tokio::test]
    async fn selection_acceptance_waits_for_native_begin_and_replies_to_unchanged_grant() {
        use std::{os::unix::fs::PermissionsExt, time::Duration};
        use viewflow_transport::{
            PeerIdentity, build_client_config, build_server_config, receive_control,
        };
        for scenario in 0..4 {
            let rejected_begin = scenario == 3;
            let already_active = scenario == 1;
            let stale_after_takeover = scenario == 2;
            let identity = PeerIdentity::from_pem(
                include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
                include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
                include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
            )
            .unwrap();
            let server = quinn::Endpoint::server(
                build_server_config(&identity).unwrap(),
                "127.0.0.1:0".parse().unwrap(),
            )
            .unwrap();
            let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
            client.set_default_client_config(build_client_config(&identity).unwrap());
            let (remote, source) = tokio::join!(
                client
                    .connect(server.local_addr().unwrap(), "localhost")
                    .unwrap(),
                async { server.accept().await.unwrap().await }
            );
            let remote = remote.unwrap();
            let source = source.unwrap();
            let writer = crate::shared_control::SharedControlWriter::start(&source).unwrap();
            let directory = tempfile::tempdir().unwrap();
            std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
                .unwrap();
            let path = directory.path().join("accept.sock");
            let listener =
                Listener::bind(&path, i32::try_from(std::process::id()).unwrap()).unwrap();
            let native = socket::socket(
                AddressFamily::Unix,
                SockType::SeqPacket,
                SockFlag::SOCK_NONBLOCK,
                None,
            )
            .unwrap();
            socket::connect(native.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
            let authorized = window_switch::tests::authorization(3, 7);
            let geometry = authorized.geometry;
            let mut session = if already_active {
                WindowInputSession::begin(
                    listener.accept().unwrap(),
                    authorized.clone(),
                    Instant::now(),
                )
                .unwrap()
            } else {
                WindowInputSession::prepare_atlas(
                    listener.accept().unwrap(),
                    authorized.clone(),
                    Instant::now(),
                    false,
                    false,
                )
                .unwrap()
            };
            if already_active {
                window_switch::tests::receive(&native);
                window_switch::tests::reply(&native, 1, 7, 1);
                session.poll().unwrap();
            }
            let (requests, receiver) = tokio::sync::mpsc::channel(1);
            session.attach_selection_acceptances(receiver, writer.sender());
            let (_clock, clock) = tokio::sync::watch::channel(None);
            let (_presentation, presentation) = tokio::sync::watch::channel(geometry);
            let mut route =
                RoutedWindowInput::new(session, clock, presentation, None, true, |_| Ok(()));
            let selected = if already_active || stale_after_takeover {
                authorized
            } else {
                window_switch::tests::authorization(4, 8)
            };
            let generation = selected.generation;
            let selection = viewflow_protocol::AtlasWindowSelection {
                activate_keyboard: false,
                stream_id: Id128(99),
                atlas_frame_id: 1,
                atlas_geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 1,
                window_id: selected.geometry.identity().window,
                placement_generation: 1,
                source_frame_id: 5,
                source_geometry_epoch: 4,
                sequence: 2,
                sender_not_after_ns: 23_390_000,
            };
            if already_active {
                route.announced = route.session.grant.authorization(0); // An identical announcement would be deduplicated.
            }
            let (completion, mut completed) = tokio::sync::oneshot::channel();
            requests
                .send(AtlasSelectionAcceptanceRequest {
                    selection,
                    authorization: selected,
                    completion,
                })
                .await
                .unwrap();
            let observe = async {
                if stale_after_takeover {
                    assert!(completed.await.unwrap().is_err());
                    assert!(
                        tokio::time::timeout(Duration::from_millis(5), receive_control(&remote))
                            .await
                            .is_err()
                    );
                    assert!(source.close_reason().is_none());
                    return;
                }
                if !already_active {
                    let mut bytes = [0u8; 128];
                    loop {
                        match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                            Ok(_) => break,
                            Err(nix::errno::Errno::EAGAIN) => {
                                tokio::time::sleep(Duration::from_millis(1)).await
                            }
                            Err(error) => panic!("{error}"),
                        }
                    }
                    assert!(completed.try_recv().is_err());
                    assert!(
                        tokio::time::timeout(Duration::from_millis(2), receive_control(&remote))
                            .await
                            .is_err()
                    );
                    if rejected_begin {
                        window_switch::tests::reply(&native, 1, generation, 0);
                        loop {
                            match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                                Ok(_) => break,
                                Err(nix::errno::Errno::EAGAIN) => {
                                    tokio::time::sleep(Duration::from_millis(1)).await
                                }
                                Err(error) => panic!("{error}"),
                            }
                        }
                        window_switch::tests::reply(&native, 2, generation, 3);
                        assert!(completed.await.unwrap().is_err());
                        assert!(source.close_reason().is_none());
                        return;
                    }
                    window_switch::tests::reply(&native, 1, generation, 1);
                }
                let wire = tokio::time::timeout(Duration::from_secs(1), receive_control(&remote))
                    .await
                    .unwrap()
                    .unwrap();
                let viewflow_protocol::DomainControl::AtlasWindowSelectionAccepted(actual) =
                    viewflow_protocol::DomainControl::try_from(wire).unwrap()
                else {
                    panic!("missing correlated acceptance")
                };
                assert_eq!(actual.selection, selection);
                assert_eq!(actual.authorization.lease_generation, generation);
                completed.await.unwrap().unwrap();
            };
            let accept = async {
                assert!(route.accept_selection(&source).await.unwrap());
            };
            tokio::time::timeout(Duration::from_secs(1), async {
                tokio::join!(accept, observe);
            })
            .await
            .unwrap();
            if already_active {
                let release = route.release_window_input(&source, selection.window_id);
                let confirm = async {
                    let mut bytes = [0u8; 128];
                    loop {
                        match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                            Ok(_) => break,
                            Err(nix::errno::Errno::EAGAIN) => tokio::time::sleep(Duration::from_millis(1)).await,
                            Err(error) => panic!("{error}"),
                        }
                    }
                    assert_eq!(u16::from_le_bytes(bytes[6..8].try_into().unwrap()), 62);
                    window_switch::tests::reply(&native, 2, generation, 3);
                };
                let (result, ()) = tokio::join!(release, confirm);
                result.unwrap();
                assert_eq!(route.session.state, State::DesktopPaused);
                assert!(source.close_reason().is_none());
                route.session.resume_after_desktop_pause(
                    window_switch::tests::authorization(4, generation + 1)).unwrap();
                window_switch::tests::receive(&native);
                window_switch::tests::reply(&native, 3, generation + 1, 1);
                route.session.poll().unwrap();
                assert_eq!(route.session.state, State::Ready);
            }
            if rejected_begin {
                assert_eq!(route.session.state, State::DesktopPaused);
                assert_eq!(route.session.last_ended_generation, generation);
                route.session.resume_after_desktop_pause(
                    window_switch::tests::authorization(4, generation + 1)
                ).unwrap();
                window_switch::tests::receive(&native);
                window_switch::tests::reply(&native, 3, generation + 1, 1);
                route.session.poll().unwrap();
                assert_eq!(route.session.state, State::Ready);
            }
        }
    }

    #[tokio::test]
    async fn local_button_during_motion_drains_result_then_recovers_on_same_socket() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("motion-rejection.sock");
        let listener = Listener::bind(&path, i32::try_from(std::process::id()).unwrap()).unwrap();
        let native = socket::socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_NONBLOCK,
            None,
        )
        .unwrap();
        socket::connect(native.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
        let origin = Instant::now();
        let mut session = WindowInputSession::begin(
            listener.accept().unwrap(),
            window_switch::tests::authorization(3, 7),
            origin,
        )
        .unwrap();
        window_switch::tests::receive(&native);
        window_switch::tests::reply(&native, 1, 7, 1);
        session.poll().unwrap();
        session.attach_cursor(crate::atlas_cursor_handoff::CursorBridge::fixture());
        for (event_sequence, outcome) in [(1, 0)] {
            let now = elapsed_ns(origin).unwrap();
            let event = WindowPointerMotion {
                lease_generation: 7,
                target_device: Id128(2),
                target_window: Id128(3),
                geometry_epoch: 4,
                presented_frame: 5,
                sequence: event_sequence,
                sender_not_after_ns: now + 20_000_000,
                x_pixels: 20,
                y_pixels: 10,
                viewport_width: 200,
                viewport_height: 100,
            };
            session
                .motion(
                    event,
                    Some((
                        ClockEstimate {
                            remote_offset_ns: 0,
                            network_round_trip_ns: 0,
                            uncertainty_ns: 0,
                        },
                        now,
                    )),
                )
                .unwrap();
            let (_, sequence, generation) = window_switch::tests::receive(&native);
            window_switch::tests::revoked(&native, 2, generation, 8);
            session.poll().unwrap();
            assert_eq!(session.state, State::Moving);
            assert!(session.motion_takeover_pending);
            window_switch::tests::reply_for(&native, 3, sequence, generation, outcome);
            session.poll().unwrap();
            assert_eq!(session.state, State::DesktopPaused);
            assert!(session.last_motion_rejected);
            // A fresh lease may resume the same still-presented window/frame
            // after confirmed cleanup; no artificial capture change is needed.
            session
                .resume_after_desktop_pause(window_switch::tests::authorization(3, 8))
                .unwrap();
            let (tag, seq, generation) = window_switch::tests::receive(&native);
            assert_eq!((tag, generation), (62, 7));
            window_switch::tests::reply_for(&native, 4, seq, generation, 3);
            session.poll().unwrap();
            let (tag, seq, generation) = window_switch::tests::receive(&native);
            assert_eq!((tag, generation), (50, 8));
            window_switch::tests::reply_for(&native, 5, seq, generation, 1);
            session.poll().unwrap();
            assert_eq!(session.state, State::Ready);
            assert!(!session.recovery_unconfirmed.load(Ordering::Acquire));
        }
    }

    #[test]
    fn rejected_motion_keeps_native_route_for_next_motion() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("motion-rejection.sock");
        let listener = Listener::bind(&path, i32::try_from(std::process::id()).unwrap()).unwrap();
        let native = socket::socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_NONBLOCK,
            None,
        )
        .unwrap();
        socket::connect(native.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
        let origin = Instant::now();
        let mut session = WindowInputSession::begin(
            listener.accept().unwrap(),
            window_switch::tests::authorization(3, 7),
            origin,
        )
        .unwrap();
        window_switch::tests::receive(&native);
        window_switch::tests::reply(&native, 1, 7, 1);
        session.poll().unwrap();
        for (event_sequence, outcome) in [(1, 0), (2, 2)] {
            let now = elapsed_ns(origin).unwrap();
            let event = WindowPointerMotion {
                lease_generation: 7,
                target_device: Id128(2),
                target_window: Id128(3),
                geometry_epoch: 4,
                presented_frame: 5,
                sequence: event_sequence,
                sender_not_after_ns: now + 20_000_000,
                x_pixels: 20,
                y_pixels: 10,
                viewport_width: 200,
                viewport_height: 100,
            };
            session
                .motion(
                    event,
                    Some((
                        ClockEstimate {
                            remote_offset_ns: 0,
                            network_round_trip_ns: 0,
                            uncertainty_ns: 0,
                        },
                        now,
                    )),
                )
                .unwrap();
            let (_, sequence, generation) = window_switch::tests::receive(&native);
            window_switch::tests::reply(&native, sequence, generation, outcome);
            session.poll().unwrap();
            assert_eq!(session.state, State::Ready);
            assert_eq!(session.last_motion_rejected, outcome == 0);
            assert!(!session.recovery_unconfirmed.load(Ordering::Acquire));
        }
    }

    #[tokio::test]
    async fn cursor_release_cancellation_requires_ready_or_confirmed_paused_binding() {
        use std::os::unix::fs::PermissionsExt;
        use viewflow_hyprland::capture_wire::CaptureCommand;
        // Ready, clean paused, then missing-release, missing-END, wrong-generation.
        for scenario in 0..5 {
            let directory = tempfile::tempdir().unwrap();
            std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
                .unwrap();
            let path = directory.path().join("cursor-rollback.sock");
            let listener =
                Listener::bind(&path, i32::try_from(std::process::id()).unwrap()).unwrap();
            let native = socket::socket(
                AddressFamily::Unix,
                SockType::SeqPacket,
                SockFlag::SOCK_NONBLOCK,
                None,
            )
            .unwrap();
            socket::connect(native.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
            let mut session = WindowInputSession::begin(
                listener.accept().unwrap(),
                window_switch::tests::authorization(3, 7),
                Instant::now(),
            )
            .unwrap();
            window_switch::tests::receive(&native);
            window_switch::tests::reply(&native, 1, 7, 1);
            session.poll().unwrap();
            if scenario != 0 {
                session.pause_for_desktop().unwrap();
                let (_, sequence, generation) = window_switch::tests::receive(&native);
                window_switch::tests::reply(&native, sequence, generation, 3);
                session.poll().unwrap();
                assert_eq!(session.state, State::DesktopPaused);
                assert_eq!(session.last_ended_generation, 7);
            }
            let (cursor, mut release) =
                crate::atlas_cursor_handoff::CursorBridge::fixture_pending_release(2);
            session.cursor = Some(if scenario == 2 {
                crate::atlas_cursor_handoff::CursorBridge::fixture()
            } else {
                cursor
            });
            if scenario == 3 {
                session.last_ended_generation = 0;
            }
            session
                .connection
                .send_capture(CaptureCommand::Release {
                    generation: 2,
                    return_position: None,
                })
                .unwrap();
            window_switch::tests::receive(&native);
            let mut revoked = b"VFHY\x01\x00".to_vec();
            revoked.extend(54_u16.to_le_bytes());
            revoked.extend(16_u32.to_le_bytes());
            revoked.extend(100_u64.to_le_bytes());
            revoked.extend(if scenario == 4 { 6_u64 } else { 7_u64 }.to_le_bytes());
            revoked.extend(1_u32.to_le_bytes()); // Cancelled
            revoked.extend(0_u32.to_le_bytes());
            socket::send(native.as_raw_fd(), &revoked, MsgFlags::MSG_NOSIGNAL).unwrap();
            let result = session.poll();
            if scenario >= 2 {
                assert!(result.is_err());
                continue;
            }
            result.unwrap();
            assert_eq!(session.state, State::DesktopPaused);
            assert!(
                release.try_recv().is_err(),
                "Cancelled is not a capture release receipt"
            );
            let mut receipt = b"VFHY\x01\x00".to_vec();
            receipt.extend(43_u16.to_le_bytes());
            receipt.extend(11_u32.to_le_bytes());
            receipt.extend(101_u64.to_le_bytes());
            receipt.extend(2_u64.to_le_bytes());
            receipt.extend(41_u16.to_le_bytes());
            receipt.push(1);
            socket::send(native.as_raw_fd(), &receipt, MsgFlags::MSG_NOSIGNAL).unwrap();
            session.poll().unwrap();
            release.await.unwrap().unwrap();
            assert!(
                session
                    .cursor
                    .as_ref()
                    .unwrap()
                    .pending_release_generation()
                    .is_none()
            );
            assert_eq!(session.state, State::DesktopPaused);
            // A click after capture rollback explicitly activates the keyboard.
            // Cancellation is not an END receipt: finish the old generation
            // before installing the click's new route on the same connection.
            session.allow_keyboard = true;
            session.pending_keyboard_mode = Some(true);
            session
                .resume_after_desktop_pause(window_switch::tests::authorization(4, 8))
                .unwrap();
            let (tag, sequence, generation) = window_switch::tests::receive(&native);
            if scenario == 0 {
                assert_eq!((tag, generation), (62, 7));
                assert_eq!(session.state, State::SwitchingEnd);
                window_switch::tests::reply_for(&native, 102, sequence, generation, 3);
                session.poll().unwrap();
                let (tag, sequence, generation) = window_switch::tests::receive(&native);
                assert_eq!((tag, generation), (59, 8));
                window_switch::tests::reply_for(&native, 103, sequence, generation, 1);
            } else {
                assert_eq!((tag, generation), (59, 8));
                window_switch::tests::reply_for(&native, 103, sequence, generation, 1);
            }
            session.poll().unwrap();
            assert_eq!(session.state, State::Ready);
            assert!(session.keyboard_grant.is_some());
        }
    }

    #[tokio::test]
    async fn selection_rejection_419ms_requires_confirmed_end_or_never_begun() {
        use std::{os::unix::fs::PermissionsExt, time::Duration};
        use viewflow_transport::{
            PeerIdentity, build_client_config, build_server_config, receive_control,
        };
        for scenario in 0..3 {
            let identity = PeerIdentity::from_pem(
                include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
                include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
                include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
            )
            .unwrap();
            let server = quinn::Endpoint::server(
                build_server_config(&identity).unwrap(),
                "127.0.0.1:0".parse().unwrap(),
            )
            .unwrap();
            let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
            client.set_default_client_config(build_client_config(&identity).unwrap());
            let (remote, source) = tokio::join!(
                client
                    .connect(server.local_addr().unwrap(), "localhost")
                    .unwrap(),
                async { server.accept().await.unwrap().await }
            );
            let remote = remote.unwrap();
            let source = source.unwrap();
            let writer = crate::shared_control::SharedControlWriter::start(&source).unwrap();
            let directory = tempfile::tempdir().unwrap();
            std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
                .unwrap();
            let path = directory.path().join("reject.sock");
            let listener =
                Listener::bind(&path, i32::try_from(std::process::id()).unwrap()).unwrap();
            let native = socket::socket(
                AddressFamily::Unix,
                SockType::SeqPacket,
                SockFlag::SOCK_NONBLOCK,
                None,
            )
            .unwrap();
            socket::connect(native.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
            let authorized = window_switch::tests::authorization(3, 7);
            let geometry = authorized.geometry;
            let mut session = if scenario == 2 {
                WindowInputSession::prepare_atlas(
                    listener.accept().unwrap(),
                    authorized,
                    Instant::now(),
                    false,
                    false,
                )
                .unwrap()
            } else if scenario == 0 {
                WindowInputSession::begin_direct_keyboard(
                    listener.accept().unwrap(),
                    authorized,
                    Instant::now(),
                )
                .unwrap()
            } else {
                WindowInputSession::begin(listener.accept().unwrap(), authorized, Instant::now())
                    .unwrap()
            };
            if scenario != 2 {
                window_switch::tests::receive(&native);
                window_switch::tests::reply(&native, 1, 7, 1);
                session.poll().unwrap();
            }
            let (requests, receiver) = tokio::sync::mpsc::channel(1);
            session.attach_selection_rejections(receiver, writer.sender());
            let (_clock, clock) = tokio::sync::watch::channel(None);
            let (_presentation, presentation) = tokio::sync::watch::channel(geometry);
            let mut route =
                RoutedWindowInput::new(session, clock, presentation, None, true, |_| Ok(()));
            let selection = viewflow_protocol::AtlasWindowSelection {
                activate_keyboard: false,
                stream_id: Id128(99),
                atlas_frame_id: 1,
                atlas_geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 1,
                window_id: Id128(3),
                placement_generation: 1,
                source_frame_id: 1,
                source_geometry_epoch: 1,
                sequence: 2,
                sender_not_after_ns: 23_390_000,
            };
            let rejection = viewflow_protocol::AtlasWindowSelectionRejected {
                selection,
                reason: viewflow_protocol::AtlasSelectionRejectionReason::CaptureExpired,
                released_generation: 0,
                capture_age_ns: 41_924_882,
                capture_limit_ns: 33_333_333,
            };
            let (completion, mut completed) = tokio::sync::oneshot::channel();
            requests
                .send(AtlasSelectionRejectionRequest {
                    rejection,
                    completion,
                })
                .await
                .unwrap();
            let observe = async {
                if scenario != 2 {
                    let mut bytes = [0u8; 128];
                    loop {
                        match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                            Ok(_) => break,
                            Err(nix::errno::Errno::EAGAIN) => {
                                tokio::time::sleep(Duration::from_millis(1)).await
                            }
                            Err(error) => panic!("{error}"),
                        }
                    }
                    assert_eq!(u16::from_le_bytes(bytes[6..8].try_into().unwrap()), 62);
                    assert!(completed.try_recv().is_err());
                    assert!(
                        tokio::time::timeout(Duration::from_millis(2), receive_control(&remote))
                            .await
                            .is_err()
                    );
                    window_switch::tests::reply(&native, 2, 7, if scenario == 1 { 0 } else { 3 });
                }
                if scenario == 1 {
                    assert!(completed.await.unwrap().is_err());
                    assert!(
                        tokio::time::timeout(Duration::from_millis(10), receive_control(&remote))
                            .await
                            .is_err()
                    );
                } else {
                    let wire =
                        tokio::time::timeout(Duration::from_secs(1), receive_control(&remote))
                            .await
                            .unwrap()
                            .unwrap();
                    let viewflow_protocol::DomainControl::AtlasWindowSelectionRejected(actual) =
                        viewflow_protocol::DomainControl::try_from(wire).unwrap()
                    else {
                        panic!("missing explicit rejection")
                    };
                    assert_eq!(
                        actual,
                        viewflow_protocol::AtlasWindowSelectionRejected {
                            released_generation: if scenario == 2 { 0 } else { 7 },
                            ..rejection
                        }
                    );
                    completed.await.unwrap().unwrap();
                }
            };
            let (result, ()) = tokio::join!(route.reject_selection(&source), observe);
            assert_eq!(result.is_err(), scenario == 1);
            if scenario != 1 {
                assert_eq!(route.session.state, State::DesktopPaused);
                assert!(route.session.grant.authorization(0).is_none());
                assert!(
                    route
                        .session
                        .resume_after_desktop_pause(window_switch::tests::authorization(3, 7))
                        .is_err()
                );
                route
                    .session
                    .resume_after_desktop_pause(window_switch::tests::authorization(4, 8))
                    .unwrap();
                let (_, sequence, generation) = window_switch::tests::receive(&native);
                assert_eq!(generation, 8);
                window_switch::tests::reply(&native, sequence, 8, 1);
                route.session.poll().unwrap();
                assert_eq!(route.session.state, State::Ready);
                assert!(source.close_reason().is_none());
            }
        }
    }

    #[test]
    fn captured_binding_requires_exact_presented_frame_and_epoch() {
        let snapshot = CapturedWindowInput {
            frame: crate::hyprcapture_gpu_wire::HcgfFrame {
                sequence: 5,
                capture_monotonic_ns: 1,
                geometry_epoch: 4,
                logical_x: 10.0,
                logical_y: 20.0,
                logical_width: 100.0,
                logical_height: 50.0,
                image_width: 200,
                image_height: 100,
                fourcc: 0,
                stride: 800,
                modifier: 0,
                offset: 0,
                crop_x: 0,
                crop_y: 0,
                crop_width: 200,
                crop_height: 100,
                flip_y: false,
                shadow: None,
            },
            input: Some(crate::hyprcapture_gpu_wire::InputGeometry {
                window: 123,
                surface: 456,
                pid: 789,
                content: [10.0, 20.0, 100.0, 50.0],
                surface_extent: [100.0, 50.0],
            }),
        };
        let identity = PresentedInputIdentity {
            window: Id128(3),
            frame: 5,
            geometry_epoch: 4,
        };
        let tile = viewflow_protocol::AtlasTile {
            window_id: identity.window,
            placement_generation: 1,
            geometry_epoch: 4,
            source_frame_id: 5,
            source_submitted_ns: 10,
            x: 0,
            y: 0,
            width: 200,
            height: 100,
        };
        let manifest = viewflow_protocol::AtlasFrame {
            stream_id: Id128(99),
            frame_id: 123,
            geometry_epoch: 2,
            config_generation: 1,
            layout_revision: 1,
            width: 200,
            height: 100,
            source_submitted_ns: 10,
            tiles: vec![tile.clone()],
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: None,
        };
        use crate::atlas_feedback::AtlasFrameDisposition::{Committed, ExpiredUnbound};
        let bind = |manifest: &viewflow_protocol::AtlasFrame, disposition| {
            AtlasCommittedInput::from_feedback(
                manifest,
                vec![(Id128(3), snapshot.clone())],
                disposition,
            )
        };
        // Atlas identity deliberately differs from per-window capture identity.
        let evidence = bind(&manifest, Some(Committed)).unwrap().unwrap();
        assert_eq!(evidence.manifest(), &manifest);
        assert_eq!(evidence.snapshot(Id128(3)).unwrap().sequence(), 5);
        assert!(evidence.snapshot(Id128(4)).is_none());
        {
            use crate::atlas_input_policy::{AtlasInputPolicy, AtlasSelectionContext};
            let context = AtlasSelectionContext {
                now_local_ns: 100,
                now_native_ns: 2,
                max_capture_age_ns: 10,
                clock: Some((
                    ClockEstimate {
                        remote_offset_ns: 0,
                        uncertainty_ns: 0,
                        network_round_trip_ns: 0,
                    },
                    100,
                )),
            };
            let mut policy =
                AtlasInputPolicy::new(Id128(1), Id128(2), vec![(Id128(3), 123)], 1_000_000_000)
                    .unwrap();
            let select = |sequence| {
                viewflow_protocol::AtlasWindowSelection::from_frame(
                    &manifest,
                    Id128(3),
                    sequence,
                    200,
                )
                .unwrap()
            };
            let first = policy.select(select(1), &evidence, context).unwrap();
            assert_eq!((first.generation, first.native_address), (1, 123));
            assert_eq!(first.expires_local_ns, 1_000_000_100);
            assert!(policy.select(select(1), &evidence, context).is_err());
            let repeated = policy.select(select(2), &evidence, context).unwrap();
            assert_eq!(
                (repeated.generation, repeated.expires_local_ns),
                (first.generation, first.expires_local_ns)
            );
            let mut activation_policy =
                AtlasInputPolicy::new(Id128(1), Id128(2), vec![(Id128(3), 123)], 1_000_000_000)
                    .unwrap();
            activation_policy
                .select(select(1), &evidence, context)
                .unwrap();
            let activated = activation_policy
                .select(
                    viewflow_protocol::AtlasWindowSelection {
                        activate_keyboard: true,
                        ..select(3)
                    },
                    &evidence,
                    context,
                )
                .unwrap();
            assert!(activated.generation > repeated.generation);
            assert_eq!(activated.geometry.identity(), repeated.geometry.identity());
            let hovered = activation_policy
                .select(select(4), &evidence, context)
                .unwrap();
            assert_eq!(hovered.generation, activated.generation);
            let activated_again = activation_policy
                .select(
                    viewflow_protocol::AtlasWindowSelection {
                        activate_keyboard: true,
                        ..select(5)
                    },
                    &evidence,
                    context,
                )
                .unwrap();
            assert_eq!(activated_again.generation, activated.generation);
            let mut geometry_policy =
                AtlasInputPolicy::new(Id128(1), Id128(2), vec![(Id128(3), 123)], 1_000_000_000)
                    .unwrap();
            let original = geometry_policy
                .select(select(1), &evidence, context)
                .unwrap();
            let mut changed = evidence.clone();
            changed.manifest.frame_id += 1;
            changed.manifest.layout_revision += 1;
            changed.manifest.tiles[0].placement_generation += 1;
            changed.manifest.tiles[0].source_frame_id += 1;
            changed.manifest.tiles[0].geometry_epoch += 1;
            let captured = changed.snapshots.get_mut(&Id128(3)).unwrap();
            captured.frame.sequence += 1;
            captured.frame.geometry_epoch += 1;
            let request = viewflow_protocol::AtlasWindowSelection::from_frame(
                changed.manifest(),
                Id128(3),
                2,
                200,
            )
            .unwrap();
            let rebound = geometry_policy.select(request, &changed, context).unwrap();
            assert!(rebound.generation > original.generation);
            assert_eq!(rebound.geometry.identity().geometry_epoch, 5);
            assert_eq!(rebound.native_surface, original.native_surface);
            assert!(geometry_policy.select(select(3), &evidence, context)
                .err().unwrap().is::<crate::atlas_input_policy::AtlasSelectionSuperseded>());
            let recovered = geometry_policy.select(
                viewflow_protocol::AtlasWindowSelection { sequence: 4, ..request },
                &changed, context,
            ).unwrap();
            assert_eq!(recovered.geometry.identity(), rebound.geometry.identity());
            let mut mismatch = select(3);
            mismatch.source_frame_id += 1;
            assert!(policy.select(mismatch, &evidence, context).is_err());
            assert!(policy.select(select(3), &evidence, context).is_err());
            assert!(
                policy
                    .select(
                        select(4),
                        &evidence,
                        AtlasSelectionContext {
                            clock: None,
                            ..context
                        }
                    )
                    .is_err()
            );
            assert!(
                policy
                    .select(
                        select(5),
                        &evidence,
                        AtlasSelectionContext {
                            now_native_ns: 11,
                            ..context
                        }
                    )
                    .is_err()
            );
            let mut expired_request = select(6);
            expired_request.sender_not_after_ns = 99;
            assert!(policy.select(expired_request, &evidence, context).is_err());
            assert!(policy.select(select(7), &evidence, context).is_ok());
            assert!(
                policy
                    .discard_unusable_selection(select(8), None, 100)
                    .unwrap()
            );
            assert!(policy.select(select(8), &evidence, context).is_err());
            let mut bad_clock = context.clock.unwrap();
            bad_clock.0.uncertainty_ns = 5_000_000;
            assert!(
                policy
                    .discard_unusable_selection(select(9), Some(bad_clock), 100)
                    .unwrap()
            );
            assert!(policy.select(select(9), &evidence, context).is_err());
            let mut stale = select(10);
            stale.sender_not_after_ns = 100;
            assert!(
                policy
                    .discard_unusable_selection(stale, context.clock, 100)
                    .unwrap()
            );
            assert!(policy.select(select(10), &evidence, context).is_err());
            assert!(
                !policy
                    .discard_unusable_selection(select(11), context.clock, 100)
                    .unwrap()
            );
            let recovered = policy.select(select(11), &evidence, context).unwrap();
            assert_eq!(recovered.generation, first.generation);
            assert_eq!(recovered.expires_local_ns, first.expires_local_ns);
            let stale_capture = policy
                .select(
                    select(12),
                    &evidence,
                    AtlasSelectionContext {
                        now_native_ns: 11,
                        ..context
                    },
                )
                .err()
                .unwrap();
            let rejected_age = stale_capture
                .downcast_ref::<crate::atlas_input_policy::AtlasSelectionUnavailable>()
                .unwrap();
            assert_eq!((rejected_age.age_ns, rejected_age.max_age_ns), (10, 10));
            assert!(policy.select(select(12), &evidence, context).is_err());
            assert!(policy.select(select(13), &evidence, context).is_ok());
            policy.invalidate_current();
            assert!(
                policy
                    .maintain_capture(&evidence, Id128(3), 100, 1, 10)
                    .unwrap()
                    .is_none()
            );
            let after_desktop = policy.select(select(14), &evidence, context).unwrap();
            assert!(after_desktop.generation > first.generation);
            // Withdrawal must revoke before the normal half-lease renewal
            // threshold, and a returning capture needs explicit selection.
            policy.observe_membership(&Default::default());
            assert!(
                policy
                    .maintain_capture(&evidence, Id128(3), 101, 1, 10)
                    .unwrap()
                    .is_none()
            );
            let resumed = policy.select(select(15), &evidence, context).unwrap();
            assert!(resumed.generation > after_desktop.generation);
            let mut empty = evidence.clone();
            empty.manifest.tiles.clear();
            empty.snapshots.clear();
            assert!(
                policy
                    .maintain_capture(&empty, Id128(3), 101, 1, 10)
                    .unwrap()
                    .is_none()
            );
            assert!(
                policy
                    .maintain_capture(&evidence, Id128(3), 102, 1, 10)
                    .unwrap()
                    .is_none()
            );
            policy.discard_withdrawn_selection(16).unwrap();
            assert!(policy.select(select(16), &evidence, context).is_err());

            for allowed in [vec![(Id128(4), 123)], vec![(Id128(3), 999)]] {
                let mut denied =
                    AtlasInputPolicy::new(Id128(1), Id128(2), allowed, 1_000_000_000).unwrap();
                assert!(denied.select(select(1), &evidence, context).is_err());
            }
            let mut maintained =
                AtlasInputPolicy::new(Id128(1), Id128(2), vec![(Id128(3), 123)], 1_000_000_000)
                    .unwrap();
            assert!(
                maintained
                    .maintain_capture(&evidence, Id128(3), 99, 11, 10)
                    .unwrap()
                    .is_none()
            );
            assert!(
                maintained
                    .maintain_capture(&evidence, Id128(3), 99, 0, 10)
                    .is_err()
            );
            assert!(
                maintained
                    .maintain_capture(&evidence, Id128(3), 99, 1, 0)
                    .is_err()
            );
            let initial = maintained
                .maintain_capture(&evidence, Id128(3), 100, 1, 10)
                .unwrap()
                .unwrap();
            assert_eq!(initial.generation, 1);
            assert!(
                maintained
                    .maintain_capture(&evidence, Id128(3), 200, 1, 10)
                    .unwrap()
                    .is_none()
            );
            assert!(
                maintained
                    .maintain_capture(&evidence, Id128(3), 600_000_100, 1, 10)
                    .unwrap()
                    .is_none()
            );
            let mut newer = evidence.clone();
            newer.manifest.tiles[0].source_frame_id += 1;
            newer.snapshots.get_mut(&Id128(3)).unwrap().frame.sequence += 1;
            assert!(
                maintained
                    .maintain_capture(&newer, Id128(3), 600_000_099, 11, 10)
                    .unwrap()
                    .is_none()
            );
            let renewed = maintained
                .maintain_capture(&newer, Id128(3), 600_000_100, 1, 10)
                .unwrap()
                .unwrap();
            assert_eq!(renewed.generation, 2);
            assert_eq!(renewed.expires_local_ns, 1_600_000_100);
            let mut frozen =
                AtlasInputPolicy::new(Id128(1), Id128(2), vec![(Id128(3), 123)], 1_000_000_000)
                    .unwrap();
            let unchanged = frozen
                .maintain_capture(&evidence, Id128(3), 100, 1, 10)
                .unwrap()
                .unwrap();
            for now in [
                500_000_100,
                600_000_100,
                900_000_100,
                unchanged.expires_local_ns - 1,
            ] {
                assert!(
                    frozen
                        .maintain_capture(&evidence, Id128(3), now, 1, 10)
                        .unwrap()
                        .is_none()
                );
            }
            // Polling the same frame never keeps input alive at the original end.
            assert!(
                frozen
                    .maintain_capture(&evidence, Id128(3), unchanged.expires_local_ns, 1, 10)
                    .is_err()
            );
            assert!(
                frozen
                    .maintain_capture(&newer, Id128(3), unchanged.expires_local_ns, 1, 10)
                    .is_err()
            );
            for changed in 0..5 {
                let mut bound =
                    AtlasInputPolicy::new(Id128(1), Id128(2), vec![(Id128(3), 123)], 1_000_000_000)
                        .unwrap();
                bound
                    .maintain_capture(&evidence, Id128(3), 100, 1, 10)
                    .unwrap()
                    .unwrap();
                let mut invalid = evidence.clone();
                let snapshot = invalid.snapshots.get_mut(&Id128(3)).unwrap();
                match changed {
                    0 => snapshot.input.as_mut().unwrap().surface += 1,
                    1 => snapshot.input.as_mut().unwrap().pid += 1,
                    2 => snapshot.input.as_mut().unwrap().window += 1,
                    3 => {
                        snapshot.frame.geometry_epoch += 1;
                        invalid.manifest.tiles[0].geometry_epoch += 1;
                    }
                    _ => {
                        snapshot.frame.sequence -= 1;
                        invalid.manifest.tiles[0].source_frame_id -= 1;
                    }
                }
                assert!(
                    bound
                        .maintain_capture(&invalid, Id128(3), 600_000_100, 1, 10)
                        .is_err(),
                    "changed binding {changed}"
                );
            }
            let mut waiting =
                AtlasInputPolicy::new(Id128(1), Id128(2), vec![(Id128(3), 123)], 1_000_000_000)
                    .unwrap();
            let original = waiting
                .maintain_capture(&evidence, Id128(3), 100, 1, 10)
                .unwrap()
                .unwrap();
            let mut resized = newer.clone();
            resized
                .snapshots
                .get_mut(&Id128(3))
                .unwrap()
                .frame
                .geometry_epoch += 1;
            resized.manifest.tiles[0].geometry_epoch += 1;
            for now in [600_000_100, original.expires_local_ns - 1] {
                assert!(
                    waiting
                        .maintain_capture(&resized, Id128(3), now, 1, 10)
                        .unwrap()
                        .is_none()
                );
            }
            assert!(
                waiting
                    .maintain_capture(&resized, Id128(3), original.expires_local_ns, 1, 10)
                    .is_err()
            );
            assert!(
                maintained
                    .maintain_capture(&newer, Id128(3), 1_600_000_100, 1, 10)
                    .is_err()
            );
        }
        assert!(bind(&manifest, None).unwrap().is_none());
        assert!(bind(&manifest, Some(ExpiredUnbound)).unwrap().is_none());
        for field in 0..4 {
            let mut wrong = manifest.clone();
            match field {
                0 => wrong.tiles[0].source_frame_id += 1,
                1 => wrong.tiles[0].geometry_epoch += 1,
                2 => wrong.tiles[0].width -= 1,
                _ => wrong.tiles[0].window_id = Id128(4),
            }
            assert!(bind(&wrong, Some(Committed)).is_err());
        }
        assert!(AtlasCommittedInput::from_feedback(&manifest, vec![], Some(Committed)).is_err());
        assert!(
            AtlasCommittedInput::from_feedback(
                &manifest,
                vec![(Id128(3), snapshot.clone()), (Id128(3), snapshot.clone())],
                Some(Committed)
            )
            .is_err()
        );
        let mut pair = manifest.clone();
        pair.width = 400;
        pair.tiles.push(viewflow_protocol::AtlasTile {
            window_id: Id128(4),
            source_frame_id: 8,
            x: 200,
            ..tile
        });
        let mut second = snapshot.clone();
        second.frame.sequence = 8;
        let evidence = AtlasCommittedInput::from_feedback(
            &pair,
            vec![(Id128(4), second.clone()), (Id128(3), snapshot.clone())],
            Some(Committed),
        )
        .unwrap()
        .unwrap();
        assert_eq!(evidence.snapshot(Id128(3)).unwrap().sequence(), 5);
        assert_eq!(evidence.snapshot(Id128(4)).unwrap().sequence(), 8);
        assert!(
            AtlasCommittedInput::from_feedback(
                &pair,
                vec![(Id128(3), second), (Id128(4), snapshot.clone())],
                Some(Committed)
            )
            .is_err()
        );
        let authorize = |snapshot: &CapturedWindowInput, presented| {
            snapshot.authorize(Id128(1), Id128(2), 7, 1_000_000_000, presented)
        };
        assert_eq!(snapshot.sequence(), 5);
        let authorized = authorize(&snapshot, identity).unwrap();
        assert_eq!(authorized.native_address, 123);
        assert_eq!(authorized.native_surface, 456);
        assert_eq!(authorized.native_pid, 789);
        assert_eq!(
            authorized.geometry.map_pointer(
                identity,
                Size {
                    width: 200.0,
                    height: 100.0
                },
                Point { x: 100.0, y: 50.0 },
            ),
            Some(Point { x: 50.0, y: 25.0 }),
        );
        assert!(
            authorize(
                &snapshot,
                PresentedInputIdentity {
                    frame: 6,
                    ..identity
                }
            )
            .is_err()
        );
        assert!(
            authorize(
                &snapshot,
                PresentedInputIdentity {
                    geometry_epoch: 5,
                    ..identity
                }
            )
            .is_err()
        );
        let mut missing = snapshot.clone();
        missing.input = None;
        assert!(authorize(&missing, identity).is_err());
    }

    #[derive(Clone, Copy, PartialEq)]
    enum SharedEnd {
        ForwardedPreview,
        SelectedSharedWriter,
        SelectedWindow,
        SelectedGeometry,
        ResizedGeometry,
        DisconnectDuringBegin,
        MetadataBurst,
        SlowMetadata,
        OwnerLost,
        Cancelled,
        ClockTimeout,
        Refreshed,
        PreviewProducer,
        OrderedPreview,
        AuthorizationOwnerLost,
        NativeRevocation,
        Button,
        ButtonDisconnect,
        ButtonDenied,
        Wheel,
        WheelDenied,
        Keyboard,
        KeyboardDenied,
        KeyboardWrongAck,
        KeyboardPreview,
        KeyboardForwarded,
    }

    #[tokio::test]
    async fn selected_window_is_announced_only_after_native_end_and_begin() {
        shared_dispatch_roundtrip(SharedEnd::SelectedWindow).await;
    }

    #[tokio::test]
    async fn selected_geometry_is_announced_after_end_begin_and_rejects_old_input() {
        shared_dispatch_roundtrip(SharedEnd::SelectedGeometry).await;
    }

    #[tokio::test]
    async fn resized_geometry_is_announced_only_after_explicit_native_rebind() {
        shared_dispatch_roundtrip(SharedEnd::ResizedGeometry).await;
    }

    #[tokio::test]
    async fn atlas_and_selected_input_share_the_same_live_writer() {
        shared_dispatch_roundtrip(SharedEnd::SelectedSharedWriter).await;
    }

    #[tokio::test]
    async fn atlas_pump_and_forwarded_preview_complete_native_motion_on_one_connection() {
        shared_dispatch_roundtrip(SharedEnd::ForwardedPreview).await;
    }

    #[tokio::test]
    async fn mtls_button_requires_native_confirmation_and_stale_release_closes() {
        shared_dispatch_roundtrip(SharedEnd::Button).await;
    }

    #[tokio::test]
    async fn mtls_wheel_requires_native_confirmation_and_replay_closes() {
        shared_dispatch_roundtrip(SharedEnd::Wheel).await;
    }

    #[tokio::test]
    async fn mtls_keyboard_requires_native_confirmation_and_replay_closes() {
        shared_dispatch_roundtrip(SharedEnd::Keyboard).await;
    }

    #[tokio::test]
    async fn mtls_pointer_permission_cannot_grant_keyboard_authority() {
        shared_dispatch_roundtrip(SharedEnd::KeyboardDenied).await;
    }

    #[tokio::test]
    async fn mtls_keyboard_wrong_native_ack_never_publishes_success() {
        shared_dispatch_roundtrip(SharedEnd::KeyboardWrongAck).await;
    }

    #[tokio::test]
    async fn receiver_mixed_fifo_and_source_dispatch_complete_keyboard_over_mtls() {
        shared_dispatch_roundtrip(SharedEnd::KeyboardPreview).await;
    }

    #[tokio::test]
    async fn atlas_forwarded_receiver_and_source_complete_keyboard_over_mtls() {
        shared_dispatch_roundtrip(SharedEnd::KeyboardForwarded).await;
    }

    #[tokio::test]
    async fn mtls_motion_only_session_cannot_gain_wheel_authority() {
        shared_dispatch_roundtrip(SharedEnd::WheelDenied).await;
    }

    #[tokio::test]
    async fn mtls_disconnect_during_native_begin_preserves_cause_and_closes_route() {
        shared_dispatch_roundtrip(SharedEnd::DisconnectDuringBegin).await;
    }

    #[tokio::test]
    async fn mtls_disconnect_after_confirmed_press_closes_native_route() {
        shared_dispatch_roundtrip(SharedEnd::ButtonDisconnect).await;
    }

    #[tokio::test]
    async fn mtls_motion_only_session_does_not_accept_peer_button_authority() {
        shared_dispatch_roundtrip(SharedEnd::ButtonDenied).await;
    }

    #[tokio::test]
    async fn queued_native_metadata_does_not_delay_an_already_available_ack() {
        shared_dispatch_roundtrip(SharedEnd::MetadataBurst).await;
    }

    #[tokio::test]
    async fn slow_native_metadata_callback_cannot_extend_ack_deadline() {
        shared_dispatch_roundtrip(SharedEnd::SlowMetadata).await;
    }

    #[tokio::test]
    async fn mtls_motion_is_acknowledged_only_after_native_confirmation() {
        shared_dispatch_roundtrip(SharedEnd::OwnerLost).await;
    }

    #[tokio::test]
    async fn source_authorization_watch_drives_shared_dispatch_and_revokes_on_drop() {
        shared_dispatch_roundtrip(SharedEnd::AuthorizationOwnerLost).await;
    }

    #[tokio::test]
    async fn native_revocation_closes_idle_shared_route_without_another_motion() {
        shared_dispatch_roundtrip(SharedEnd::NativeRevocation).await;
    }

    #[tokio::test]
    async fn cancelling_shared_dispatch_closes_native_and_network_routes() {
        shared_dispatch_roundtrip(SharedEnd::Cancelled).await;
    }

    #[tokio::test]
    async fn missing_periodic_clock_reply_resynchronizes_without_closing_window_route() {
        shared_dispatch_roundtrip(SharedEnd::ClockTimeout).await;
    }

    #[tokio::test]
    async fn refreshed_clock_reply_precedes_next_window_motion() {
        shared_dispatch_roundtrip(SharedEnd::Refreshed).await;
    }

    #[tokio::test]
    async fn preview_producer_and_source_dispatchers_forward_confirmed_motion() {
        shared_dispatch_roundtrip(SharedEnd::PreviewProducer).await;
    }

    #[tokio::test]
    async fn ordered_preview_and_source_confirm_down_motion_up() {
        shared_dispatch_roundtrip(SharedEnd::OrderedPreview).await;
    }

    async fn shared_dispatch_roundtrip(termination: SharedEnd) {
        use std::{os::unix::fs::PermissionsExt, time::Duration};
        use viewflow_protocol::{DomainControl, PROTOCOL_VERSION, WindowPointerResult, wire};
        use viewflow_transport::{
            PeerIdentity, build_client_config, build_server_config, receive_control, send_control,
        };
        let identity = PeerIdentity::from_pem(
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
            include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
        )
        .unwrap();
        let server = quinn::Endpoint::server(
            build_server_config(&identity).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(build_client_config(&identity).unwrap());
        let connecting = client
            .connect(server.local_addr().unwrap(), "localhost")
            .unwrap();
        let (remote, source) =
            tokio::join!(connecting, async { server.accept().await.unwrap().await });
        let remote = remote.unwrap();
        let source = source.unwrap();
        let shared_writer = if matches!(
            termination,
            SharedEnd::SelectedSharedWriter
                | SharedEnd::ForwardedPreview
                | SharedEnd::KeyboardForwarded
        ) {
            Some(crate::shared_control::SharedControlWriter::start(&source).unwrap())
        } else {
            None
        };
        let shared_sender = shared_writer
            .as_ref()
            .map(crate::shared_control::SharedControlWriter::sender);
        let (mut atlas_sender, mut atlas_receiver) = if let Some(shared) = &shared_sender {
            let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
            let plan = crate::atlas_session::tests::plan();
            let (sender, receiver) = tokio::join!(
                crate::atlas_session::offer_atlas(&source, plan, deadline),
                crate::atlas_session::accept_atlas(&remote, plan, deadline)
            );
            let mut sender = sender.unwrap();
            sender.attach_shared_control(shared.clone()).unwrap();
            (Some(sender), Some(receiver.unwrap()))
        } else {
            (None, None)
        };
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("native.sock");
        let listener = Listener::bind(&path, i32::try_from(std::process::id()).unwrap()).unwrap();
        let native = socket::socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_NONBLOCK,
            None,
        )
        .unwrap();
        socket::connect(native.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
        let rect = Rect {
            origin: Point::default(),
            size: Size {
                width: 100.0,
                height: 50.0,
            },
        };
        let capture = CaptureGeometry::new(rect, rect, 200, 100).unwrap();
        let geometry = PresentedInputGeometry::new(
            PresentedInputIdentity {
                window: Id128(3),
                geometry_epoch: 4,
                frame: 5,
            },
            capture,
            capture.slice_for_display(Point::default(), rect).unwrap(),
        )
        .unwrap();
        let origin = Instant::now();
        let begin = if matches!(
            termination,
            SharedEnd::Keyboard
                | SharedEnd::KeyboardWrongAck
                | SharedEnd::KeyboardPreview
                | SharedEnd::KeyboardForwarded
        ) {
            WindowInputSession::begin_direct_keyboard
        } else if termination == SharedEnd::Wheel {
            WindowInputSession::begin_buttons_wheel
        } else if matches!(
            termination,
            SharedEnd::Button | SharedEnd::ButtonDisconnect | SharedEnd::OrderedPreview
        ) {
            WindowInputSession::begin_buttons
        } else {
            WindowInputSession::begin
        };
        let mut session = begin(
            listener.accept().unwrap(),
            AuthorizedWindow {
                owner: Id128(1),
                target_device: Id128(2),
                generation: 7,
                geometry,
                expires_local_ns: 1_000_000_000,
                native_address: 123,
                native_surface: 789,
                native_pid: 456,
                surface_extent: [100.0, 50.0],
                content_origin: [0.0, 0.0],
                content_scale: [1.0, 1.0],
            },
            origin,
        )
        .unwrap();
        let mut bytes = [0; 128];
        assert_eq!(
            socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
            76
        );
        let ack_native = |seq: u64, request: u64, outcome: u32| {
            let mut bytes = b"VFHY\x01\x00".to_vec();
            bytes.extend(53_u16.to_le_bytes());
            bytes.extend(24_u32.to_le_bytes());
            bytes.extend(seq.to_le_bytes());
            bytes.extend(7_u64.to_le_bytes());
            bytes.extend(request.to_le_bytes());
            bytes.extend(outcome.to_le_bytes());
            bytes.extend(0_u32.to_le_bytes());
            socket::send(native.as_raw_fd(), &bytes, MsgFlags::MSG_NOSIGNAL).unwrap();
        };
        if matches!(
            termination,
            SharedEnd::MetadataBurst | SharedEnd::SlowMetadata
        ) {
            for sequence in 1_u64..=64 {
                let mut packet = b"VFHY\x01\x00".to_vec();
                packet.extend(3_u16.to_le_bytes());
                packet.extend(0_u32.to_le_bytes());
                packet.extend(sequence.to_le_bytes());
                socket::send(native.as_raw_fd(), &packet, MsgFlags::MSG_NOSIGNAL).unwrap();
            }
            ack_native(65, 1, 1);
            let (_owner, mut receiver) = tokio::sync::watch::channel(geometry);
            let mut received = 0;
            let result = session
                .wait_native_until(&source, &mut receiver, &mut |_| {
                    received += 1;
                    if termination == SharedEnd::SlowMetadata {
                        std::thread::sleep(Duration::from_millis(30));
                    }
                    Ok(())
                }, Instant::now() + Duration::from_millis(24))
                .await;
            if termination == SharedEnd::SlowMetadata {
                assert!(
                    result
                        .unwrap_err()
                        .to_string()
                        .contains("command=Beginning")
                );
                assert_eq!(received, 1);
                assert_eq!(session.state, State::Beginning);
            } else {
                result.unwrap();
                assert_eq!(received, 64);
                assert_eq!(session.state, State::Ready);
            }
            return;
        }
        if termination == SharedEnd::DisconnectDuringBegin {
            let (_receipts, mut receipt_rx) = tokio::sync::watch::channel(geometry);
            let close = async {
                tokio::task::yield_now().await;
                remote.close(42_u32.into(), b"disconnect during native begin");
            };
            let mut metadata = |_| Ok(());
            let (result, ()) = tokio::join!(
                session.wait_native(&source, &mut receipt_rx, &mut metadata),
                close
            );
            let error = result.unwrap_err();
            assert!(session.recovery_unconfirmed().load(Ordering::Acquire));
            assert!(matches!(
                error.downcast_ref::<quinn::ConnectionError>(),
                Some(quinn::ConnectionError::ApplicationClosed(_))
            ));
            drop(session);
            assert_eq!(
                socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
                0
            );
            return;
        }
        ack_native(1, 1, 1);
        let (receipts, mut receipt_rx) = tokio::sync::watch::channel(geometry);
        // The native BEGIN reply is already readable. Simulate resuming after
        // the absolute wait budget: readiness cannot override the deadline or
        // consume that reply before the admission check.
        let expired = session
            .wait_native_until(
                &source,
                &mut receipt_rx,
                &mut |_| Ok(()),
                Instant::now() - Duration::from_millis(1),
            )
            .await
            .unwrap_err();
        assert!(expired.to_string().contains("acknowledgement timed out"));
        assert!(
            expired
                .to_string()
                .contains("command=Beginning generation=7 sequence=1")
        );
        assert!(expired.to_string().contains("polls=0 metadata_packets=0"));
        assert!(expired.to_string().contains("final_state=Beginning"));
        assert_eq!(session.state, State::Beginning);
        let (authorization_owner, authorization_rx) =
            tokio::sync::watch::channel(AuthorizedWindow {
                owner: Id128(1),
                target_device: Id128(2),
                generation: 7,
                geometry,
                expires_local_ns: 1_000_000_000,
                native_address: 123,
                native_surface: 789,
                native_pid: 456,
                surface_extent: [100.0, 50.0],
                content_origin: [0.0, 0.0],
                content_scale: [1.0, 1.0],
            });
        let (selection_sender, mut selection_requests) = tokio::sync::mpsc::channel(16);
        let work = tokio::spawn(async move {
            if let Some(shared) = shared_sender {
                if termination == SharedEnd::SelectedSharedWriter {
                    session
                        .serve_atlas_selections(
                            &source,
                            authorization_rx,
                            shared,
                            selection_sender,
                            |_| Ok(()),
                        )
                        .await
                } else {
                    session
                        .serve_selected_on_shared_control(&source, authorization_rx, shared, |_| {
                            Ok(())
                        })
                        .await
                }
            } else if matches!(
                termination,
                SharedEnd::SelectedWindow
                    | SharedEnd::SelectedGeometry
                    | SharedEnd::ResizedGeometry
            ) {
                session
                    .serve_selected_authorizations(&source, authorization_rx, |_| Ok(()))
                    .await
            } else if termination == SharedEnd::AuthorizationOwnerLost {
                session
                    .serve_authorizations(&source, authorization_rx, |_| Ok(()))
                    .await
            } else {
                session.serve(&source, receipt_rx, |_| Ok(())).await
            }
        });
        if matches!(
            termination,
            SharedEnd::PreviewProducer
                | SharedEnd::OrderedPreview
                | SharedEnd::ForwardedPreview
                | SharedEnd::KeyboardPreview
                | SharedEnd::KeyboardForwarded
        ) {
            use crate::window_preview_input::{
                PreviewPointerSample, PreviewPointerState, WindowPreviewInput,
            };
            let presented = PresentedInputIdentity {
                window: Id128(3),
                geometry_epoch: 4,
                frame: 5,
            };
            let empty = PreviewPointerState {
                presented: Some(presented),
                motion: None,
            };
            let (samples, sample_rx) = tokio::sync::watch::channel(empty);
            let (acks, mut ack_rx) = tokio::sync::watch::channel(None);
            let preview =
                WindowPreviewInput::new(Id128(1), Id128(2), Id128(3), origin, sample_rx, acks)
                    .unwrap();
            let (events, event_rx) = crate::window_preview_input::PreviewPointerEvents::channel();
            let preview = if matches!(
                termination,
                SharedEnd::OrderedPreview
                    | SharedEnd::KeyboardPreview
                    | SharedEnd::KeyboardForwarded
            ) {
                if matches!(
                    termination,
                    SharedEnd::KeyboardPreview | SharedEnd::KeyboardForwarded
                ) {
                    preview.with_direct_keyboard(event_rx).unwrap()
                } else {
                    preview.with_buttons(event_rx).unwrap()
                }
            } else {
                preview
            };
            let mut sample_sequence = 0;
            let preview_connection = remote.clone();
            let mut pump_work = None;
            let frames_seen = Arc::new(std::sync::atomic::AtomicUsize::new(0));
            let preview_writer = if matches!(
                termination,
                SharedEnd::ForwardedPreview | SharedEnd::KeyboardForwarded
            ) {
                Some(crate::shared_control::SharedControlWriter::start(&remote).unwrap())
            } else {
                None
            };
            let preview_work = if let Some(writer) = &preview_writer {
                let (controls, forwarded) = tokio::sync::mpsc::channel(16);
                let mut receiver = atlas_receiver.take().unwrap();
                receiver.attach_shared_controls(controls).unwrap();
                let frames = frames_seen.clone();
                pump_work = Some(tokio::spawn(async move {
                    loop {
                        match receiver
                            .next_frame(
                                || 110,
                                tokio::time::Instant::now() + Duration::from_millis(100),
                            )
                            .await
                        {
                            Ok(frame) => {
                                assert_eq!(frame.layout.frame_id, 1);
                                frames.fetch_add(1, Ordering::AcqRel);
                            }
                            Err(error)
                                if error
                                    .downcast_ref::<crate::atlas_session::AtlasWaitExpired>()
                                    .is_some() => {}
                            Err(error) => return Err::<(), _>(error),
                        }
                    }
                }));
                let shared = writer.sender();
                tokio::spawn(async move {
                    preview
                        .serve_forwarded(&preview_connection, forwarded, shared)
                        .await
                })
            } else {
                tokio::spawn(async move { preview.serve(&preview_connection).await })
            };
            if matches!(
                termination,
                SharedEnd::ForwardedPreview | SharedEnd::KeyboardForwarded
            ) {
                let manifest = viewflow_protocol::AtlasFrame {
                    stream_id: Id128(99),
                    frame_id: 1,
                    geometry_epoch: 1,
                    config_generation: 1,
                    layout_revision: 0,
                    width: 64,
                    height: 64,
                    source_submitted_ns: 100,
                    tiles: vec![],
                    color_keyframe: true,
                    alpha_keyframe: true,
                    desktop: None,
                };
                atlas_sender
                    .as_mut()
                    .unwrap()
                    .send_frame(
                        manifest,
                        bytes::Bytes::from(vec![0x65; 512]),
                        viewflow_transport::encode_alpha_rle(64, 64, &[0; 4096]).unwrap(),
                        1,
                        tokio::time::Instant::now() + Duration::from_millis(100),
                    )
                    .await
                    .unwrap();
            }
            tokio::time::timeout(Duration::from_millis(100), async {
                loop {
                    match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                        Ok(52) => break,
                        Err(nix::errno::Errno::EAGAIN) => {}
                        other => panic!("expected preview-produced native move: {other:?}"),
                    }
                    sample_sequence += 1;
                    let sample = PreviewPointerSample {
                        sample_sequence,
                        presented,
                        sender_not_after_ns: elapsed_ns(origin).unwrap() + 30_000_000,
                        x_pixels: 100,
                        y_pixels: 40,
                        viewport_width: 200,
                        viewport_height: 100,
                    };
                    if matches!(
                        termination,
                        SharedEnd::OrderedPreview
                            | SharedEnd::KeyboardPreview
                            | SharedEnd::KeyboardForwarded
                    ) {
                        events
                            .push(crate::window_preview_input::PreviewPointerEvent {
                                key: None,
                                wheel: None,
                                sample,
                                button: None,
                            })
                            .unwrap();
                    }
                    samples
                        .send(PreviewPointerState {
                            presented: Some(presented),
                            motion: Some(sample),
                        })
                        .unwrap();
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
            })
            .await
            .unwrap();
            samples.send(empty).unwrap();
            assert!(
                tokio::time::timeout(Duration::from_millis(2), ack_rx.changed())
                    .await
                    .is_err()
            );
            ack_native(2, 2, 2);
            tokio::time::timeout(Duration::from_millis(24), ack_rx.changed())
                .await
                .unwrap()
                .unwrap();
            let ack = ack_rx.borrow_and_update().unwrap();
            assert_eq!(ack.event_sequence, 1);
            assert_eq!(ack.result, WindowPointerResult::MotionSent);
            assert_eq!(ack.target_window, Id128(3));
            if matches!(
                termination,
                SharedEnd::OrderedPreview
                    | SharedEnd::KeyboardPreview
                    | SharedEnd::KeyboardForwarded
            ) {
                use viewflow_protocol::{InputSwitchState, PointerButton, PointerButtonEvent};
                for (index, button) in [
                    Some(PointerButtonEvent {
                        button: PointerButton::Left,
                        state: InputSwitchState::Pressed,
                    }),
                    None,
                    Some(PointerButtonEvent {
                        button: PointerButton::Left,
                        state: InputSwitchState::Released,
                    }),
                ]
                .into_iter()
                .enumerate()
                {
                    sample_sequence += 1;
                    events
                        .push(crate::window_preview_input::PreviewPointerEvent {
                            key: None,
                            wheel: None,
                            sample: PreviewPointerSample {
                                sample_sequence,
                                presented,
                                sender_not_after_ns: elapsed_ns(origin).unwrap() + 30_000_000,
                                x_pixels: 101,
                                y_pixels: 41,
                                viewport_width: 200,
                                viewport_height: 100,
                            },
                            button,
                        })
                        .unwrap();
                    tokio::time::timeout(Duration::from_millis(20), async {
                        loop {
                            match socket::recv(
                                native.as_raw_fd(),
                                &mut bytes,
                                MsgFlags::MSG_DONTWAIT,
                            ) {
                                Ok(52) if index == 0 => {
                                    // Ordered startup motion remains ahead of the press;
                                    // unlike a watch, the FIFO cannot overwrite it.
                                    let request =
                                        u64::from_le_bytes(bytes[12..20].try_into().unwrap());
                                    ack_native(request, request, 2);
                                    tokio::time::timeout(
                                        Duration::from_millis(24),
                                        ack_rx.changed(),
                                    )
                                    .await
                                    .unwrap()
                                    .unwrap();
                                    assert_eq!(
                                        ack_rx.borrow_and_update().unwrap().result,
                                        WindowPointerResult::MotionSent
                                    );
                                }
                                Ok(size) => {
                                    assert_eq!(size, if button.is_some() { 60 } else { 52 });
                                    break;
                                }
                                Err(nix::errno::Errno::EAGAIN) => {
                                    tokio::time::sleep(Duration::from_millis(1)).await
                                }
                                other => panic!("expected ordered native event: {other:?}"),
                            }
                        }
                    })
                    .await
                    .unwrap();
                    assert!(
                        tokio::time::timeout(Duration::from_millis(2), ack_rx.changed())
                            .await
                            .is_err()
                    );
                    let native_sequence = u64::from_le_bytes(bytes[12..20].try_into().unwrap());
                    ack_native(
                        native_sequence,
                        native_sequence,
                        if button.is_some() { 4 } else { 2 },
                    );
                    tokio::time::timeout(Duration::from_millis(24), ack_rx.changed())
                        .await
                        .unwrap()
                        .unwrap();
                    let ack = ack_rx.borrow_and_update().unwrap();
                    assert_eq!(ack.event_sequence, native_sequence - 1);
                    assert_eq!(
                        ack.result,
                        if button.is_some() {
                            WindowPointerResult::ButtonSent
                        } else {
                            WindowPointerResult::MotionSent
                        }
                    );
                }
            }
            if matches!(
                termination,
                SharedEnd::KeyboardPreview | SharedEnd::KeyboardForwarded
            ) {
                super::window_keyboard::tests::preview_keys(
                    &events,
                    &mut ack_rx,
                    &native,
                    origin,
                    presented,
                    &mut sample_sequence,
                )
                .await;
            }
            drop(samples);
            assert!(
                tokio::time::timeout(Duration::from_secs(1), preview_work)
                    .await
                    .unwrap()
                    .unwrap()
                    .is_err()
            );
            assert!(
                tokio::time::timeout(Duration::from_secs(1), work)
                    .await
                    .unwrap()
                    .unwrap()
                    .is_err()
            );
            if let Some(pump) = pump_work {
                assert!(
                    tokio::time::timeout(Duration::from_secs(1), pump)
                        .await
                        .unwrap()
                        .unwrap()
                        .is_err()
                );
                assert_eq!(frames_seen.load(Ordering::Acquire), 1);
            }
            assert_eq!(
                socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
                0
            );
            return;
        }
        let message = |sequence| wire::ControlEnvelope {
            protocol_major: u32::from(PROTOCOL_VERSION.major),
            protocol_minor: u32::from(PROTOCOL_VERSION.minor),
            sequence,
            payload: Some(wire::control_envelope::Payload::WindowPointerMotion(
                wire::WindowPointerMotion {
                    lease_generation: 7,
                    target_device: Some(wire::Id128 { high: 0, low: 2 }),
                    target_window: Some(wire::Id128 { high: 0, low: 3 }),
                    geometry_epoch: 4,
                    presented_frame: 5,
                    event_sequence: sequence,
                    sender_not_after_ns: elapsed_ns(origin).unwrap() + 30_000_000,
                    x_pixels: 100,
                    y_pixels: 40,
                    viewport_width: 200,
                    viewport_height: 100,
                },
            )),
        };
        let initial_probe = tokio::time::timeout(Duration::from_secs(1), receive_control(&remote))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(initial_probe.sequence, 1);
        let DomainControl::ClockSyncProbe(initial_probe) =
            DomainControl::try_from(initial_probe).unwrap()
        else {
            panic!("expected connection-owned clock probe");
        };
        let probe_received_ns = elapsed_ns(origin).unwrap();
        // No caller-supplied synthetic clock can make this first event eligible.
        send_control(&remote, &message(1)).await.unwrap();
        let before_sync =
            tokio::time::timeout(Duration::from_millis(100), receive_control(&remote))
                .await
                .unwrap()
                .unwrap();
        assert_eq!(before_sync.sequence, 2);
        let DomainControl::WindowPointerAck(before_sync) =
            DomainControl::try_from(before_sync).unwrap()
        else {
            panic!("expected rejection before clock evidence");
        };
        assert_eq!(before_sync.result, WindowPointerResult::Rejected);
        assert!(socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).is_err());
        send_control(
            &remote,
            &wire::ControlEnvelope {
                protocol_major: u32::from(PROTOCOL_VERSION.major),
                protocol_minor: u32::from(PROTOCOL_VERSION.minor),
                sequence: 2,
                payload: Some(wire::control_envelope::Payload::ClockSyncReply(
                    wire::ClockSyncReply {
                        probe_id: initial_probe.probe_id,
                        t0_send_ns: initial_probe.t0_send_ns,
                        t1_receive_ns: probe_received_ns,
                        t2_send_ns: elapsed_ns(origin).unwrap(),
                    },
                )),
            },
        )
        .await
        .unwrap();
        let mut announcement =
            tokio::time::timeout(Duration::from_millis(100), receive_control(&remote))
                .await
                .unwrap()
                .unwrap();
        assert_eq!(announcement.sequence, 3);
        if matches!(
            termination,
            SharedEnd::Keyboard
                | SharedEnd::KeyboardWrongAck
                | SharedEnd::KeyboardPreview
                | SharedEnd::KeyboardForwarded
        ) {
            let DomainControl::WindowKeyboardAuthorization(auth) =
                DomainControl::try_from(announcement).unwrap()
            else {
                panic!("expected separate keyboard authorization");
            };
            assert_eq!(auth.lease_generation, 7);
            assert_eq!(auth.owner_device, Id128(1));
            assert_eq!(auth.target_window, Id128(3));
            assert_eq!(
                auth.mode,
                viewflow_protocol::WindowKeyboardMode::DirectApplication
            );
            announcement =
                tokio::time::timeout(Duration::from_millis(100), receive_control(&remote))
                    .await
                    .unwrap()
                    .unwrap();
            assert_eq!(announcement.sequence, 4);
        }
        let DomainControl::WindowPointerAuthorization(authorization) =
            DomainControl::try_from(announcement).unwrap()
        else {
            panic!("expected source-created window authorization");
        };
        assert_eq!(
            authorization,
            viewflow_protocol::WindowPointerAuthorization {
                lease_generation: 7,
                owner_device: Id128(1),
                target_device: Id128(2),
                target_window: Id128(3),
                geometry_epoch: 4,
                presented_frame: 5,
                source_not_after_ns: 1_000_000_000,
            }
        );
        if matches!(
            termination,
            SharedEnd::Keyboard | SharedEnd::KeyboardDenied | SharedEnd::KeyboardWrongAck
        ) {
            super::window_keyboard::tests::shared_keyboard(
                &remote,
                &native,
                work,
                origin,
                termination == SharedEnd::KeyboardDenied,
                termination == SharedEnd::KeyboardWrongAck,
            )
            .await;
            return;
        }
        if let Some(atlas) = atlas_sender {
            let manifest = viewflow_protocol::AtlasFrame {
                stream_id: Id128(99),
                frame_id: 10,
                geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 0,
                width: 64,
                height: 64,
                source_submitted_ns: 100,
                tiles: vec![],
                color_keyframe: true,
                alpha_keyframe: true,
                desktop: None,
            };
            atlas
                .send_manifest(
                    manifest.clone(),
                    10,
                    tokio::time::Instant::now() + Duration::from_millis(24),
                )
                .await
                .unwrap();
            let message = receive_control(&remote).await.unwrap();
            assert_eq!(message.sequence, 4);
            let DomainControl::AtlasFrame(received) = DomainControl::try_from(message).unwrap()
            else {
                panic!("expected interleaved atlas manifest");
            };
            assert_eq!(received, manifest);
        }
        if matches!(
            termination,
            SharedEnd::SelectedWindow
                | SharedEnd::SelectedSharedWriter
                | SharedEnd::SelectedGeometry
                | SharedEnd::ResizedGeometry
        ) {
            let first_sequence = if termination == SharedEnd::SelectedSharedWriter {
                let selection = viewflow_protocol::AtlasWindowSelection {
                    activate_keyboard: false,
                    stream_id: Id128(99),
                    atlas_frame_id: 10,
                    atlas_geometry_epoch: 1,
                    config_generation: 1,
                    layout_revision: 1,
                    window_id: Id128(4),
                    placement_generation: 1,
                    source_frame_id: 5,
                    source_geometry_epoch: 4,
                    sequence: 1,
                    sender_not_after_ns: elapsed_ns(origin).unwrap() + 30_000_000,
                };
                send_control(
                    &remote,
                    &wire::ControlEnvelope {
                        protocol_major: u32::from(PROTOCOL_VERSION.major),
                        protocol_minor: u32::from(PROTOCOL_VERSION.minor),
                        sequence: 3,
                        payload: Some(wire::control_envelope::Payload::AtlasWindowSelection(
                            selection.into(),
                        )),
                    },
                )
                .await
                .unwrap();
                let request =
                    tokio::time::timeout(Duration::from_millis(100), selection_requests.recv())
                        .await
                        .unwrap()
                        .unwrap();
                assert_eq!(request.selection, selection);
                assert!(request.clock.is_some());
                assert!(request.received_local_ns < selection.sender_not_after_ns);
                // A received selection alone cannot open or switch a native target.
                assert!(
                    socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).is_err()
                );
                4
            } else {
                3
            };
            super::window_switch::tests::shared_switch(
                &remote,
                &native,
                authorization_owner,
                work,
                origin,
                first_sequence,
                matches!(
                    termination,
                    SharedEnd::SelectedGeometry | SharedEnd::ResizedGeometry
                ),
                termination == SharedEnd::ResizedGeometry,
            )
            .await;
            return;
        }
        // The receiver uses the source's published identity, not a grant made
        // from the incoming event. The first announcement follows clock sync.
        send_control(&remote, &message(3)).await.unwrap();
        tokio::time::timeout(Duration::from_millis(20), async {
            loop {
                match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                    Ok(52) => break,
                    Err(nix::errno::Errno::EAGAIN) => {
                        tokio::time::sleep(Duration::from_millis(1)).await
                    }
                    other => panic!("expected native move: {other:?}"),
                }
            }
        })
        .await
        .unwrap();
        let reply = receive_control(&remote);
        tokio::pin!(reply);
        assert!(
            tokio::time::timeout(Duration::from_millis(2), &mut reply)
                .await
                .is_err()
        );
        ack_native(2, 2, 2);
        let DomainControl::WindowPointerAck(ack) = DomainControl::try_from(
            tokio::time::timeout(Duration::from_millis(24), &mut reply)
                .await
                .unwrap()
                .unwrap(),
        )
        .unwrap() else {
            panic!("expected window ack");
        };
        assert_eq!(ack.result, WindowPointerResult::MotionSent);
        assert_eq!(ack.event_sequence, 3);
        if matches!(
            termination,
            SharedEnd::Button
                | SharedEnd::ButtonDisconnect
                | SharedEnd::ButtonDenied
                | SharedEnd::Wheel
                | SharedEnd::WheelDenied
        ) {
            let wheel = matches!(termination, SharedEnd::Wheel | SharedEnd::WheelDenied);
            let mut press = message(4);
            let Some(wire::control_envelope::Payload::WindowPointerMotion(position)) =
                press.payload.take()
            else {
                panic!("missing position");
            };
            press.payload = Some(if wheel {
                wire::control_envelope::Payload::WindowPointerWheel(wire::WindowPointerWheel {
                    position: Some(position),
                    delta: Some(wire::PointerWheelEvent {
                        vertical_delta_detents: 0.25,
                        horizontal_delta_detents: -0.5,
                    }),
                })
            } else {
                wire::control_envelope::Payload::WindowPointerButton(wire::WindowPointerButton {
                    position: Some(position),
                    transition: Some(wire::PointerButtonEvent {
                        button: 1,
                        state: 1,
                    }),
                })
            });
            send_control(&remote, &press).await.unwrap();
            if matches!(
                termination,
                SharedEnd::ButtonDenied | SharedEnd::WheelDenied
            ) {
                assert!(
                    tokio::time::timeout(Duration::from_secs(1), work)
                        .await
                        .unwrap()
                        .unwrap()
                        .is_err()
                );
                assert_eq!(
                    socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
                    0
                );
                return;
            }
            tokio::time::timeout(Duration::from_millis(20), async {
                loop {
                    match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                        Ok(60) => break,
                        Err(nix::errno::Errno::EAGAIN) => {
                            tokio::time::sleep(Duration::from_millis(1)).await
                        }
                        other => panic!("expected native button: {other:?}"),
                    }
                }
            })
            .await
            .unwrap();
            assert_eq!(
                u16::from_le_bytes(bytes[6..8].try_into().unwrap()),
                if wheel { 57 } else { 55 }
            );
            if wheel {
                assert_eq!(i32::from_le_bytes(bytes[52..56].try_into().unwrap()), 30);
                assert_eq!(i32::from_le_bytes(bytes[56..60].try_into().unwrap()), -60);
            }
            let reply = receive_control(&remote);
            tokio::pin!(reply);
            assert!(
                tokio::time::timeout(Duration::from_millis(2), &mut reply)
                    .await
                    .is_err()
            );
            ack_native(3, 3, if wheel { 5 } else { 4 });
            let DomainControl::WindowPointerAck(ack) = DomainControl::try_from(
                tokio::time::timeout(Duration::from_millis(24), &mut reply)
                    .await
                    .unwrap()
                    .unwrap(),
            )
            .unwrap() else {
                panic!("expected button ack");
            };
            assert_eq!(
                ack.result,
                if wheel {
                    WindowPointerResult::WheelSent
                } else {
                    WindowPointerResult::ButtonSent
                }
            );
            assert_eq!(ack.event_sequence, 4);
            if termination == SharedEnd::ButtonDisconnect {
                // No release or further input arrives: transport loss alone must
                // close the native route so its disconnect cleanup can release.
                remote.close(0_u32.into(), b"disconnect with button held");
                let error = tokio::time::timeout(Duration::from_secs(1), work)
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap_err();
                assert!(error.chain().any(|cause| matches!(
                    cause.downcast_ref::<quinn::ConnectionError>(),
                    Some(quinn::ConnectionError::ApplicationClosed(_))
                )));
                assert_eq!(
                    socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
                    0
                );
                return;
            }
            press.sequence = 5;
            if let Some(wire::control_envelope::Payload::WindowPointerButton(button)) =
                &mut press.payload
            {
                button.transition.as_mut().unwrap().state = 2;
            }
            send_control(&remote, &press).await.unwrap();
            assert!(
                tokio::time::timeout(Duration::from_secs(1), work)
                    .await
                    .unwrap()
                    .unwrap()
                    .is_err()
            );
            assert_eq!(
                socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
                0
            );
            return;
        }
        // A different control family uses the SAME dispatcher and outgoing
        // sequencer after window input. Hold its QUIC stream open across native
        // maintenance ticks; abandoning the partial read would lose this probe.
        let probe = wire::ControlEnvelope {
            protocol_major: u32::from(PROTOCOL_VERSION.major),
            protocol_minor: u32::from(PROTOCOL_VERSION.minor),
            sequence: 4,
            payload: Some(wire::control_envelope::Payload::ClockSyncProbe(
                wire::ClockSyncProbe {
                    probe_id: 91,
                    t0_send_ns: 1234,
                },
            )),
        };
        let mut encoded = b"VFRS\x01\x01\x00\x00".to_vec();
        encoded.extend(prost::Message::encode_to_vec(&probe));
        let mut partial = remote.open_uni().await.unwrap();
        partial.write_all(&encoded[..3]).await.unwrap();
        tokio::time::sleep(Duration::from_millis(4)).await;
        partial.write_all(&encoded[3..]).await.unwrap();
        partial.finish().unwrap();
        let reply = tokio::time::timeout(Duration::from_millis(100), receive_control(&remote))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(reply.sequence, 5);
        let DomainControl::ClockSyncReply(reply) = DomainControl::try_from(reply).unwrap() else {
            panic!("expected shared-dispatch clock reply");
        };
        assert_eq!(reply.probe_id, 91);
        assert_eq!(reply.t0_send_ns, 1234);
        let mut expired = message(5);
        if let Some(wire::control_envelope::Payload::WindowPointerMotion(motion)) =
            &mut expired.payload
        {
            motion.sender_not_after_ns = 1;
        }
        send_control(&remote, &expired).await.unwrap();
        let DomainControl::WindowPointerAck(ack) = DomainControl::try_from(
            tokio::time::timeout(Duration::from_millis(24), receive_control(&remote))
                .await
                .unwrap()
                .unwrap(),
        )
        .unwrap() else {
            panic!("expected rejection");
        };
        assert_eq!(ack.result, WindowPointerResult::Rejected);
        assert!(socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).is_err());
        if termination == SharedEnd::Refreshed {
            let refresh = tokio::time::timeout(Duration::from_secs(1), receive_control(&remote))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(refresh.sequence, 7);
            let DomainControl::ClockSyncProbe(refresh) = DomainControl::try_from(refresh).unwrap()
            else {
                panic!("expected periodic clock refresh");
            };
            let t1_receive_ns = elapsed_ns(origin).unwrap();
            assert_eq!(refresh.probe_id, initial_probe.probe_id + 1);
            send_control(
                &remote,
                &wire::ControlEnvelope {
                    protocol_major: u32::from(PROTOCOL_VERSION.major),
                    protocol_minor: u32::from(PROTOCOL_VERSION.minor),
                    sequence: 6,
                    payload: Some(wire::control_envelope::Payload::ClockSyncReply(
                        wire::ClockSyncReply {
                            probe_id: refresh.probe_id,
                            t0_send_ns: refresh.t0_send_ns,
                            t1_receive_ns,
                            t2_send_ns: elapsed_ns(origin).unwrap(),
                        },
                    )),
                },
            )
            .await
            .unwrap();
            send_control(&remote, &message(7)).await.unwrap();
            tokio::time::timeout(Duration::from_millis(20), async {
                loop {
                    match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                        Ok(52) => break,
                        Err(nix::errno::Errno::EAGAIN) => {
                            tokio::time::sleep(Duration::from_millis(1)).await
                        }
                        other => panic!("expected refreshed native move: {other:?}"),
                    }
                }
            })
            .await
            .unwrap();
            ack_native(3, 3, 2);
            let reply = tokio::time::timeout(Duration::from_millis(24), receive_control(&remote))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(reply.sequence, 8);
            let DomainControl::WindowPointerAck(reply) = DomainControl::try_from(reply).unwrap()
            else {
                panic!("expected motion ACK after refresh");
            };
            assert_eq!(reply.event_sequence, 7);
            assert_eq!(reply.result, WindowPointerResult::MotionSent);
        }
        if matches!(
            termination,
            SharedEnd::OwnerLost | SharedEnd::AuthorizationOwnerLost
        ) {
            let advanced = PresentedInputGeometry::new(
                PresentedInputIdentity {
                    window: Id128(3),
                    geometry_epoch: 4,
                    frame: 6,
                },
                capture,
                capture.slice_for_display(Point::default(), rect).unwrap(),
            )
            .unwrap();
            if termination == SharedEnd::AuthorizationOwnerLost {
                let mut next = authorization_owner.borrow().clone();
                next.geometry = advanced;
                authorization_owner.send(next).unwrap();
            } else {
                receipts.send(advanced).unwrap();
            }
            let update = tokio::time::timeout(Duration::from_millis(100), receive_control(&remote))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(update.sequence, 7);
            let DomainControl::WindowPointerAuthorization(update) =
                DomainControl::try_from(update).unwrap()
            else {
                panic!("expected source presentation authorization update");
            };
            assert_eq!(
                update,
                viewflow_protocol::WindowPointerAuthorization {
                    presented_frame: 6,
                    ..authorization
                }
            );
            send_control(&remote, &message(6)).await.unwrap();
            // The older frame is still a verified receipt in this generation.
            // Its event must retain that identity and wait for a native ACK.
            tokio::time::timeout(Duration::from_millis(20), async {
                loop {
                    match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                        Ok(52) => break,
                        Err(nix::errno::Errno::EAGAIN) => {
                            tokio::time::sleep(Duration::from_millis(1)).await;
                        }
                        other => panic!("expected retained-frame native move: {other:?}"),
                    }
                }
            })
            .await
            .unwrap();
            ack_native(3, 3, 2);
            let retained =
                tokio::time::timeout(Duration::from_millis(24), receive_control(&remote))
                    .await
                    .unwrap()
                    .unwrap();
            let DomainControl::WindowPointerAck(retained) =
                DomainControl::try_from(retained).unwrap()
            else {
                panic!("expected retained-frame confirmation");
            };
            assert_eq!(retained.result, WindowPointerResult::MotionSent);
            assert_eq!(retained.presented_frame, 5);
            let mut unknown = message(7);
            if let Some(wire::control_envelope::Payload::WindowPointerMotion(event)) =
                &mut unknown.payload
            {
                event.presented_frame = 4;
            }
            send_control(&remote, &unknown).await.unwrap();
            let rejected =
                tokio::time::timeout(Duration::from_millis(100), receive_control(&remote))
                    .await
                    .unwrap()
                    .unwrap();
            let DomainControl::WindowPointerAck(rejected) =
                DomainControl::try_from(rejected).unwrap()
            else {
                panic!("expected stale presentation rejection");
            };
            assert_eq!(rejected.result, WindowPointerResult::Rejected);
            assert!(socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).is_err());
        }
        if termination == SharedEnd::NativeRevocation {
            let mut revoked = b"VFHY\x01\x00".to_vec();
            revoked.extend(54_u16.to_le_bytes());
            revoked.extend(16_u32.to_le_bytes());
            revoked.extend(3_u64.to_le_bytes());
            revoked.extend(7_u64.to_le_bytes());
            revoked.extend(10_u32.to_le_bytes());
            revoked.extend(0_u32.to_le_bytes());
            socket::send(native.as_raw_fd(), &revoked, MsgFlags::MSG_NOSIGNAL).unwrap();
            let error = tokio::time::timeout(Duration::from_millis(100), work)
                .await
                .unwrap()
                .unwrap()
                .unwrap_err();
            assert!(error.to_string().contains("LocalKey"), "{error:#}");
        } else if termination == SharedEnd::Cancelled {
            work.abort();
            assert!(work.await.unwrap_err().is_cancelled());
        } else if termination == SharedEnd::ClockTimeout {
            let next_probe = tokio::time::timeout(Duration::from_secs(1), receive_control(&remote))
                .await
                .unwrap()
                .unwrap();
            let DomainControl::ClockSyncProbe(next_probe) =
                DomainControl::try_from(next_probe).unwrap()
            else {
                panic!("expected periodic clock refresh");
            };
            assert_eq!(next_probe.probe_id, initial_probe.probe_id + 1);
            // Withhold the response. The next probe must still be sent on
            // the same connection without destroying the native input route.
            let retry = tokio::time::timeout(Duration::from_secs(1), receive_control(&remote))
                .await.unwrap().unwrap();
            let DomainControl::ClockSyncProbe(retry) = DomainControl::try_from(retry).unwrap() else {
                panic!("expected resynchronization probe");
            };
            assert_eq!(retry.probe_id, next_probe.probe_id + 1);
            for (sequence, probe) in [(6, next_probe), (7, retry)] {
                let received = elapsed_ns(origin).unwrap();
                send_control(&remote, &wire::ControlEnvelope {
                    protocol_major: u32::from(PROTOCOL_VERSION.major),
                    protocol_minor: u32::from(PROTOCOL_VERSION.minor),
                    sequence,
                    payload: Some(wire::control_envelope::Payload::ClockSyncReply(
                        wire::ClockSyncReply {
                            probe_id: probe.probe_id,
                            t0_send_ns: probe.t0_send_ns,
                            t1_receive_ns: received,
                            t2_send_ns: elapsed_ns(origin).unwrap(),
                        }
                    )),
                }).await.unwrap();
            }
            // An old reply cannot poison the current probe or block the
            // shared receiver. Fresh input works after the replacement reply.
            send_control(&remote, &message(8)).await.unwrap();
            tokio::time::timeout(Duration::from_millis(100), async {
                loop {
                    match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                        Ok(52) => break,
                        Err(nix::errno::Errno::EAGAIN) => tokio::time::sleep(Duration::from_millis(1)).await,
                        other => panic!("expected motion after resynchronization: {other:?}"),
                    }
                }
            }).await.unwrap();
            ack_native(3, 3, 2);
            let ack = tokio::time::timeout(Duration::from_millis(100), receive_control(&remote))
                .await.unwrap().unwrap();
            let DomainControl::WindowPointerAck(ack) = DomainControl::try_from(ack).unwrap() else {
                panic!("expected recovered motion acknowledgement");
            };
            assert_eq!(ack.result, WindowPointerResult::MotionSent);
            assert!(remote.close_reason().is_none());
            assert!(!work.is_finished());
            work.abort();
            assert!(work.await.unwrap_err().is_cancelled());
        } else {
            drop(receipts); // Source presentation owner disappeared: revoke both paths.
            drop(authorization_owner);
            assert!(
                tokio::time::timeout(Duration::from_secs(1), work)
                    .await
                    .unwrap()
                    .unwrap()
                    .is_err()
            );
        }
        tokio::time::timeout(Duration::from_secs(1), remote.closed())
            .await
            .expect("shared writer must close even when its owner is cancelled");
        assert_eq!(
            socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
            0
        );
    }

    #[test]
    fn listener_rejects_wrong_process_and_deadlines_fail_closed() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("native.sock");
        let listener =
            Listener::bind(&path, i32::try_from(std::process::id()).unwrap() + 1).unwrap();
        let peer = socket::socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_NONBLOCK,
            None,
        )
        .unwrap();
        socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
        assert_eq!(
            listener.accept().err().unwrap().kind(),
            io::ErrorKind::PermissionDenied
        );
        let origin = Instant::now();
        assert!(native_deadline(origin, 0).is_err());
        assert!(native_deadline(origin, u64::MAX).is_err());
        assert!(native_deadline(origin, 1_000_000_000).is_ok());
    }

    #[test]
    fn authorized_motion_roundtrip_and_revocation_over_real_socket() {
        authorized_roundtrip(0, false);
    }

    #[test]
    fn explicit_button_mode_survives_renewal_over_real_socket() {
        authorized_roundtrip(1, false);
    }

    #[test]
    fn explicit_wheel_mode_survives_renewal_and_old_grants_reject_it() {
        for mode in 0..=2 {
            authorized_roundtrip(mode, true);
        }
    }

    #[test]
    fn native_wheel_conversion_preserves_ticks_and_rejects_lossy_values() {
        use viewflow_protocol::PointerWheelEvent;
        for ticks in [1, -1, 30, -60, 120, -240, 67_108_863] {
            let value = native_wheel_delta(PointerWheelEvent {
                vertical_delta_detents: f64::from(ticks) / 120.0,
                horizontal_delta_detents: -f64::from(ticks) / 120.0,
            })
            .unwrap();
            assert_eq!(value, [ticks, -ticks]);
        }
        for invalid in [
            0.0,
            f64::NAN,
            f64::INFINITY,
            f64::MAX,
            0.001,
            67_108_864.0 / 120.0,
        ] {
            assert!(
                native_wheel_delta(PointerWheelEvent {
                    vertical_delta_detents: invalid,
                    horizontal_delta_detents: 0.0,
                })
                .is_err()
            );
        }
    }

    fn authorized_roundtrip(mode: u8, wheel_event: bool) {
        let allow_buttons = mode != 0;
        let allow_wheel = mode == 2;
        let directory = tempfile::tempdir().unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("native.sock");
        let listener = Listener::bind(&path, i32::try_from(std::process::id()).unwrap()).unwrap();
        let peer = socket::socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_NONBLOCK,
            None,
        )
        .unwrap();
        socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
        let connection = listener.accept().unwrap();
        let rect = Rect {
            origin: Point::default(),
            size: Size {
                width: 100.0,
                height: 50.0,
            },
        };
        let capture = CaptureGeometry::new(rect, rect, 200, 100).unwrap();
        let geometry = PresentedInputGeometry::new(
            PresentedInputIdentity {
                window: Id128(3),
                geometry_epoch: 4,
                frame: 5,
            },
            capture,
            capture.slice_for_display(Point::default(), rect).unwrap(),
        )
        .unwrap();
        let origin = Instant::now();
        let begin = if allow_wheel {
            WindowInputSession::begin_buttons_wheel
        } else if allow_buttons {
            WindowInputSession::begin_buttons
        } else {
            WindowInputSession::begin
        };
        let mut session = begin(
            connection,
            AuthorizedWindow {
                owner: Id128(1),
                target_device: Id128(2),
                generation: 7,
                geometry,
                expires_local_ns: 1_000_000_000,
                native_address: 123,
                native_surface: 789,
                native_pid: 456,
                surface_extent: [50.0, 25.0],
                content_origin: [0.0, 0.0],
                content_scale: [0.5, 0.5],
            },
            origin,
        )
        .unwrap();
        let mut bytes = [0_u8; 128];
        assert_eq!(
            socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
            76
        );
        assert_eq!(u64::from_le_bytes(bytes[68..76].try_into().unwrap()), 789);
        let expected_opcode = if allow_wheel {
            58
        } else if allow_buttons {
            56
        } else {
            50
        };
        assert_eq!(
            u16::from_le_bytes(bytes[6..8].try_into().unwrap()),
            expected_opcode
        );
        assert_eq!(session.allow_buttons, allow_buttons);
        let ack = |seq: u64, request: u64, outcome: u32, generation: u64| {
            let mut bytes = b"VFHY\x01\x00".to_vec();
            bytes.extend(53_u16.to_le_bytes());
            bytes.extend(24_u32.to_le_bytes());
            bytes.extend(seq.to_le_bytes());
            bytes.extend(generation.to_le_bytes());
            bytes.extend(request.to_le_bytes());
            bytes.extend(outcome.to_le_bytes());
            bytes.extend(0_u32.to_le_bytes());
            socket::send(peer.as_raw_fd(), &bytes, MsgFlags::MSG_NOSIGNAL).unwrap();
        };
        ack(1, 1, 1, 7);
        assert!(matches!(
            session.poll().unwrap(),
            Some(Event::Completed(Outcome::Begun))
        ));
        let now = elapsed_ns(origin).unwrap();
        let mut event = WindowPointerMotion {
            lease_generation: 7,
            target_device: Id128(2),
            target_window: Id128(3),
            geometry_epoch: 4,
            presented_frame: 5,
            sequence: 1,
            sender_not_after_ns: now + 30_000_000,
            x_pixels: 100,
            y_pixels: 40,
            viewport_width: 200,
            viewport_height: 100,
        };
        assert!(session.motion(event, None).is_err());
        assert!(socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).is_err());
        let estimate = Some((
            ClockEstimate {
                remote_offset_ns: 0,
                uncertainty_ns: 0,
                network_round_trip_ns: 0,
            },
            now,
        ));
        assert!(session.motion(event, estimate).is_err()); // spent timing failure cannot replay
        event.sequence = 2;
        session.motion(event, estimate).unwrap();
        assert_eq!(
            socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
            52
        );
        assert_eq!(f64::from_le_bytes(bytes[36..44].try_into().unwrap()), 25.0);
        assert_eq!(f64::from_le_bytes(bytes[44..52].try_into().unwrap()), 10.0);
        ack(2, 2, 2, 7);
        assert!(matches!(
            session.poll().unwrap(),
            Some(Event::Completed(Outcome::MotionSent))
        ));
        let renewal = || AuthorizedWindow {
            owner: Id128(1),
            target_device: Id128(2),
            generation: 8,
            geometry: PresentedInputGeometry::new(
                PresentedInputIdentity {
                    window: Id128(3),
                    geometry_epoch: 4,
                    frame: 6,
                },
                capture,
                capture.slice_for_display(Point::default(), rect).unwrap(),
            )
            .unwrap(),
            expires_local_ns: 2_000_000_000,
            native_address: 123,
            native_surface: 789,
            native_pid: 456,
            surface_extent: [50.0, 25.0],
            content_origin: [0.0, 0.0],
            content_scale: [0.5, 0.5],
        };
        let mut changed = renewal();
        changed.native_surface = 790;
        assert!(session.renew(changed).is_err());
        let mut stale = renewal();
        stale.geometry = geometry;
        assert!(session.renew(stale).is_err());
        let mut excessive = renewal();
        excessive.expires_local_ns = u64::MAX;
        assert!(session.renew(excessive).is_err());
        assert!(socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).is_err());
        session.renew(renewal()).unwrap();
        assert_eq!(session.state, State::Beginning);
        assert_eq!(
            socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
            76
        );
        assert_eq!(u64::from_le_bytes(bytes[12..20].try_into().unwrap()), 3);
        assert_eq!(u64::from_le_bytes(bytes[20..28].try_into().unwrap()), 8);
        assert_eq!(
            u16::from_le_bytes(bytes[6..8].try_into().unwrap()),
            expected_opcode
        );
        assert_eq!(session.allow_buttons, allow_buttons);
        assert!(session.renew(renewal()).is_err());
        ack(3, 3, 1, 8);
        assert!(matches!(
            session.poll().unwrap(),
            Some(Event::Completed(Outcome::Begun))
        ));
        assert_eq!(session.state, State::Ready);
        assert_eq!(
            session
                .grant
                .authorization(elapsed_ns(origin).unwrap())
                .unwrap()
                .lease_generation,
            8
        );
        event.lease_generation = 8;
        event.presented_frame = 6;
        event.sequence = 1;
        if wheel_event {
            let wheel = viewflow_protocol::WindowPointerWheel {
                position: event,
                delta: viewflow_protocol::PointerWheelEvent {
                    vertical_delta_detents: 0.25,
                    horizontal_delta_detents: -0.5,
                },
            };
            assert_eq!(session.allow_wheel, allow_wheel);
            if allow_wheel {
                session.wheel(wheel, estimate).unwrap();
                assert_eq!(session.state, State::Scrolling);
                assert!(session.recovery_unconfirmed.load(Ordering::Acquire));
                assert_eq!(
                    socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
                    60
                );
                assert_eq!(u16::from_le_bytes(bytes[6..8].try_into().unwrap()), 57);
                assert_eq!(f64::from_le_bytes(bytes[36..44].try_into().unwrap()), 25.0);
                assert_eq!(f64::from_le_bytes(bytes[44..52].try_into().unwrap()), 10.0);
                assert_eq!(i32::from_le_bytes(bytes[52..56].try_into().unwrap()), 30);
                assert_eq!(i32::from_le_bytes(bytes[56..60].try_into().unwrap()), -60);
                ack(4, 4, 5, 8);
                assert!(matches!(
                    session.poll().unwrap(),
                    Some(Event::Completed(Outcome::WheelSent))
                ));
                assert_eq!(session.state, State::Ready);
                assert!(!session.recovery_unconfirmed.load(Ordering::Acquire));
                assert!(session.wheel(wheel, estimate).is_err()); // Replay cannot scroll twice.
            } else {
                assert!(session.wheel(wheel, estimate).is_err());
            }
            assert_eq!(session.state, State::Ended);
            assert_eq!(
                socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
                0
            );
            return;
        }
        let mut button = viewflow_protocol::WindowPointerButton {
            position: event,
            transition: viewflow_protocol::PointerButtonEvent {
                button: viewflow_protocol::PointerButton::Left,
                state: viewflow_protocol::InputSwitchState::Pressed,
            },
        };
        if allow_buttons {
            session.button(button, estimate).unwrap();
            assert_eq!(session.state, State::Pressing);
            assert_eq!(
                socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
                60
            );
            assert_eq!(u16::from_le_bytes(bytes[6..8].try_into().unwrap()), 55);
            assert_eq!(u32::from_le_bytes(bytes[52..56].try_into().unwrap()), 1);
            assert_eq!(u32::from_le_bytes(bytes[56..60].try_into().unwrap()), 1);
            ack(4, 4, 4, 8);
            assert!(matches!(
                session.poll().unwrap(),
                Some(Event::Completed(Outcome::ButtonSent))
            ));
            assert_eq!(session.state, State::Ready);
            // A stale release cannot be ignored while native buttons remain held.
            button.transition.state = viewflow_protocol::InputSwitchState::Released;
            assert!(session.button(button, estimate).is_err());
        } else {
            assert!(session.button(button, estimate).is_err());
        }
        assert_eq!(session.state, State::Ended);
        session.revoke();
        assert_eq!(
            socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
            0
        );
    }
}

// Sample native time BEFORE the process clock: subtraction then produces a
// conservative deadline, never extending the authorization by sampling latency.
pub(crate) fn native_clock_ns() -> Result<u64> {
    let native = nix::time::clock_gettime(nix::time::ClockId::CLOCK_MONOTONIC)?;
    u64::try_from(native.tv_sec())?
        .checked_mul(1_000_000_000)
        .and_then(|v| v.checked_add(u64::try_from(native.tv_nsec()).ok()?))
        .ok_or_else(|| anyhow!("native clock overflow"))
}

fn native_deadline(origin: Instant, deadline: u64) -> Result<u64> {
    let native = native_clock_ns()?;
    let remaining = deadline
        .checked_sub(elapsed_ns(origin)?)
        .filter(|v| *v > 0 && *v <= 5_000_000_000)
        .ok_or_else(|| anyhow!("expired or excessive window deadline"))?;
    native
        .checked_add(remaining)
        .ok_or_else(|| anyhow!("native deadline overflow"))
}
