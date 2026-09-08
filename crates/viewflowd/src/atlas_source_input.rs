//! Live capture/input ownership for the paired atlas source CLI.
use crate::{
    atlas_input_policy::{AtlasInputPolicy, AtlasSelectionContext},
    window_input_runtime::{
        AtlasCommittedInput, AtlasSelectionRequest, AuthorizedWindow, WindowInputSession,
    },
};
use anyhow::{Context, Result, ensure};
use std::{
    collections::{BTreeMap, VecDeque},
    os::unix::fs::MetadataExt,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, oneshot, watch};
use viewflow_hyprland::window_pointer_socket::{Connection, Listener};

const MAX_DESKTOP_ENROLLMENT_NS: u64 = 30_000_000_000;

pub(crate) struct AtlasSourceInput {
    acceptance_sender: mpsc::Sender<crate::window_input_runtime::AtlasSelectionAcceptanceRequest>,
    acceptance_requests:
        Option<mpsc::Receiver<crate::window_input_runtime::AtlasSelectionAcceptanceRequest>>,
    acceptance_pending: Option<(AtlasSelectionRequest, oneshot::Receiver<Result<()>>)>,
    rejection_sender: mpsc::Sender<crate::window_input_runtime::AtlasSelectionRejectionRequest>,
    rejection_requests:
        Option<mpsc::Receiver<crate::window_input_runtime::AtlasSelectionRejectionRequest>>,
    rejection_pending: Option<oneshot::Receiver<Result<()>>>,
    cursor_config: Option<crate::atlas_cursor_handoff::CursorConfig>,
    allow_wheel: bool,
    allow_keyboard: bool,
    path: PathBuf,
    socket_identity: (u64, u64),
    listener: Listener,
    native: Option<Connection>,
    network: quinn::Connection,
    writer: crate::shared_control::SharedControlSender,
    origin: Instant,
    startup_deadline: Instant,
    initial_window: viewflow_protocol::WindowId,
    idle_initial: AuthorizedWindow,
    policy: AtlasInputPolicy,
    history: VecDeque<AtlasCommittedInput>,
    membership: watch::Sender<crate::window_input_runtime::AtlasInputMembership>,
    requests: mpsc::Receiver<AtlasSelectionRequest>,
    request_sender: Option<mpsc::Sender<AtlasSelectionRequest>>,
    desktop_history: watch::Sender<Arc<VecDeque<AtlasCommittedInput>>>,
    desktop_phase: Arc<AtomicU8>,
    reverse_drag: crate::reverse_bridge::SharedNativeDrag,
    desktop_sender: Option<mpsc::Sender<crate::window_input_runtime::DesktopMoveRequest>>,
    desktop: Option<DesktopMoveWorker>,
    waiting: Option<AtlasSelectionRequest>,
    updates: Option<watch::Sender<AuthorizedWindow>>,
    task: Option<tokio::task::JoinHandle<Result<()>>>,
    max_capture_age_ns: u64,
    selections_timing_discarded: u64,
    selections_capture_discarded: u64,
    // Last rejected selection: sequence, source frame, capture age, age limit.
    last_capture_rejection: Option<[u64; 4]>,
    // Source queue delay, conservative event budget left, diagnostic sampling span.
    last_capture_rejection_timing: Option<[u64; 3]>,
    selections_authorized: u64,
}

impl AtlasSourceInput {
    pub(crate) fn reverse_drag(&self) -> crate::reverse_bridge::SharedNativeDrag { self.reverse_drag.clone() }

    pub(crate) async fn publish_application_icon(&self, icon: viewflow_protocol::ApplicationIcon) -> Result<()> {
        self.writer.send(viewflow_protocol::wire::control_envelope::Payload::ApplicationIcon(icon.into()),
            tokio::time::Instant::now() + std::time::Duration::from_secs(5)).await
    }

    /// Extend the source-local allowlist only after the desktop supervisor has
    /// authenticated and enrolled the exact native capture address. This does
    /// not create an authorization; a later fresh committed frame and normal
    /// AtlasWindowSelection are still required.
    pub(crate) fn enroll_local_window(
        &mut self,
        window: viewflow_protocol::WindowId,
        native_address: u64,
    ) -> Result<()> {
        self.policy.enroll_local_window(window, native_address)
    }

    pub(crate) fn retire_local_window(
        &mut self,
        window: viewflow_protocol::WindowId,
    ) -> Result<()> {
        self.policy.retire_local_window(window);
        let mut membership = self.membership.borrow().clone();
        if let Some(updates) = &self.updates {
            membership.authorization_floor = membership
                .authorization_floor
                .max(updates.borrow().generation);
        }
        let mut windows = membership.windows.clone();
        windows.remove(&window);
        membership.update(windows)?;
        self.membership.send_replace(membership);
        self.history
            .retain(|frame| frame.snapshot(window).is_none());
        self.desktop_history
            .send_replace(Arc::new(self.history.clone()));
        Ok(())
    }

    /// Continue source policy/native ownership while media awaits its peer.
    /// No uncommitted frame is published; errors still require owner shutdown.
    pub(crate) async fn while_media<T>(
        &mut self,
        media: impl std::future::Future<Output = Result<T>>,
    ) -> Result<T> {
        drive_media_with_input(media, async || {
            if let Err(error) = self.poll(None).await {
                self.network
                    .close(0_u32.into(), b"atlas source input failed");
                return Err(error);
            }
            Ok(())
        })
        .await
    }

    pub(crate) fn start(
        config: &crate::atlas_peer::AtlasSourceConfig,
        network: &quinn::Connection,
        writer: crate::shared_control::SharedControlSender,
        desktop_lane: Option<crate::desktop_source::SharedDesktopSourceLane>,
    ) -> Result<Self> {
        let pointer = config
            .pointer
            .as_ref()
            .context("atlas source pointer config missing")?;
        let (owner, source) = pointer.devices.devices()?;
        let allowed: Vec<_> = config
            .windows
            .iter()
            .map(|window| {
                Ok((
                    viewflow_protocol::Id128(u128::from_str_radix(&window.window_id, 16)?),
                    u64::from_str_radix(
                        window.address.strip_prefix("0x").unwrap_or(&window.address),
                        16,
                    )?,
                ))
            })
            .collect::<Result<_>>()?;
        let initial_window = allowed.first().map(|entry| entry.0).unwrap_or(viewflow_protocol::Id128(0));
        let policy = AtlasInputPolicy::new(owner, source, allowed, 5_000_000_000)?;
        let listener = Listener::bind(
            &pointer.native_socket,
            i32::try_from(config.compositor_pid)?,
        )?;
        let metadata = std::fs::symlink_metadata(&pointer.native_socket)?;
        let (sender, requests) = mpsc::channel(64);
        let (rejection_sender, rejection_requests) = mpsc::channel(1);
        let (acceptance_sender, acceptance_requests) = mpsc::channel(1);
        let origin = Instant::now();
        let (desktop_history, history_receive) = watch::channel(Arc::new(VecDeque::new()));
        let desktop_phase = Arc::new(AtomicU8::new(0));
        let reverse_drag = crate::reverse_bridge::SharedNativeDrag::default();
        let drag_transfer = crate::atlas_cursor_handoff::SharedDragTransfer::default();
        let (desktop_sender, desktop) =
            if let (Some(desktop), Some(lane)) = (&config.desktop, desktop_lane) {
                let (sender, receiver) = mpsc::channel(16);
                (
                    Some(sender),
                    Some(DesktopMoveWorker::start(
                        DesktopMoveController::new(config, desktop, lane, origin, drag_transfer.clone())?,
                        receiver,
                        history_receive,
                        desktop_phase.clone(),
                        origin,
                    )),
                )
            } else {
                (None, None)
            };
        let cursor_config = if let Some(monitor_id) = pointer.cursor_monitor_id {
            let desktop = config
                .desktop
                .as_ref()
                .context("cursor handoff requires global desktop configuration")?;
            Some(crate::atlas_cursor_handoff::CursorConfig {
                drag: drag_transfer,
                reverse_drag: reverse_drag.clone(),
                remote_scale: desktop.remote_display.scale,
                position_offset: (0.0, 0.0),
                position_scale: (1.0, 1.0),
                ready_file: None,
                raw_touchpad: true,
                local: crate::atlas_cursor_handoff::local_displays(&desktop.hyprland_socket, monitor_id)?,
                remote: desktop.remote_display.rect()?,
                monitor_id,
                topology_generation: desktop.topology_generation,
                owner: source,
                target: owner,
                fps: config.fps,
            })
        } else {
            None
        };
        Ok(Self {
            acceptance_sender,
            acceptance_requests: Some(acceptance_requests),
            acceptance_pending: None,
            rejection_sender,
            rejection_requests: Some(rejection_requests),
            rejection_pending: None,
            cursor_config,
            allow_wheel: pointer.wheel,
            allow_keyboard: pointer.direct_keyboard,
            path: pointer.native_socket.clone(),
            socket_identity: (metadata.dev(), metadata.ino()),
            listener,
            native: None,
            network: network.clone(),
            writer,
            origin,
            startup_deadline: origin + Duration::from_millis(config.startup_timeout_ms),
            initial_window,
            idle_initial: AuthorizedWindow::unbound(owner, source),
            policy,
            history: VecDeque::new(),
            membership: watch::channel(Default::default()).0,
            requests,
            request_sender: Some(sender),
            desktop_history,
            desktop_phase,
            reverse_drag,
            desktop_sender,
            desktop,
            waiting: None,
            updates: None,
            task: None,
            // Video age is a performance statistic, not permission to use a
            // still-live window. Native identity/geometry and membership are
            // validated independently when installing and delivering input.
            max_capture_age_ns: u64::MAX,
            selections_timing_discarded: 0,
            selections_capture_discarded: 0,
            last_capture_rejection: None,
            last_capture_rejection_timing: None,
            selections_authorized: 0,
        })
    }

    pub(crate) async fn poll(&mut self, committed: Option<&AtlasCommittedInput>) -> Result<()> {
        if let Some(worker) = self.desktop.as_mut() {
            worker.check_health().await?;
        }
        if self
            .task
            .as_ref()
            .is_some_and(tokio::task::JoinHandle::is_finished)
        {
            self.task
                .take()
                .context("atlas input task missing")?
                .await
                .context("atlas source input task failed")??;
            anyhow::bail!("atlas source input ended");
        }
        if self.task.is_none() && self.native.is_none() {
            match self.listener.accept() {
                Ok(native) => self.native = Some(native),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error.into()),
            }
        }
        if let Some(committed) = committed {
            if self
                .history
                .back()
                .is_none_or(|old| old.manifest().frame_id != committed.manifest().frame_id)
            {
                let windows = committed
                    .manifest()
                    .tiles
                    .iter()
                    .map(|tile| tile.window_id)
                    .collect();
                let mut membership = self.membership.borrow().clone();
                if membership.windows.difference(&windows).next().is_some() {
                    if let Some(updates) = &self.updates {
                        membership.authorization_floor = membership
                            .authorization_floor
                            .max(updates.borrow().generation);
                    }
                }
                membership.update(windows)?;
                self.membership.send_replace(membership);
                self.policy
                    .observe_membership(&self.membership.borrow().windows);
                // A withdrawn window cannot regain authority from a retained
                // pre-withdrawal receipt when its capture fits again later.
                self.history.retain(|old| {
                    old.manifest()
                        .tiles
                        .iter()
                        .all(|tile| self.membership.borrow().windows.contains(&tile.window_id))
                });
                self.history.push_back(committed.clone());
                if self.history.len() > 32 {
                    self.history.pop_front();
                }
                self.desktop_history
                    .send_replace(Arc::new(self.history.clone()));
            }
        }
        let now = u64::try_from(self.origin.elapsed().as_nanos())?;
        let native_now = u64::try_from(crate::gpu_nvenc_runtime::monotonic_ns()?)?;
        if self.task.is_none() {
            ensure!(
                Instant::now() < self.startup_deadline,
                "atlas native pointer startup timed out"
            );
            if self.native.is_none() { return Ok(()); }
            let initial = if let Some(committed) = self.history.back() {
                self.policy.maintain_capture(committed, self.initial_window, now, native_now, self.max_capture_age_ns)?
            } else { None }.unwrap_or_else(|| self.idle_initial.clone());
            let mut session = WindowInputSession::prepare_atlas(
                self.native
                    .take()
                    .context("atlas native connection missing")?,
                initial.clone(),
                self.origin,
                self.allow_wheel,
                self.allow_keyboard,
            )?;
            session.attach_atlas_membership(self.membership.subscribe());
            if let Some(config) = self.cursor_config.take() {
                session.attach_cursor(crate::atlas_cursor_handoff::CursorBridge::start(
                    config,
                    self.writer.clone(),
                    self.network.clone(),
                    self.origin,
                    self.desktop_phase.clone(),
                ));
            }
            session.attach_selection_acceptances(
                self.acceptance_requests
                    .take()
                    .context("selection acceptance route missing")?,
                self.writer.clone(),
            );
            session.attach_selection_rejections(
                self.rejection_requests
                    .take()
                    .context("selection rejection route missing")?,
                self.writer.clone(),
            );
            self.policy.invalidate_current();
            self.desktop_phase.store(2, Ordering::Release);
            let (updates, receive) = watch::channel(initial);
            let network = self.network.clone();
            let writer = self.writer.clone();
            let requests = self
                .request_sender
                .take()
                .context("atlas selection sender missing")?;
            let desktop_moves = self.desktop_sender.take();
            self.task = Some(tokio::spawn(async move {
                if let Some(desktop_moves) = desktop_moves {
                    session
                        .serve_atlas_selections_with_desktop(
                            &network,
                            receive,
                            writer,
                            requests,
                            desktop_moves,
                            |_| Ok(()),
                        )
                        .await
                } else {
                    session
                        .serve_atlas_selections(&network, receive, writer, requests, |_| Ok(()))
                        .await
                }
            }));
            self.updates = Some(updates);
        }
        if let Some((request, pending)) = &mut self.acceptance_pending {
            match pending.try_recv() {
                Ok(result) => {
                    let request = *request;
                    self.acceptance_pending = None;
                    if let Err(error) = result {
                        eprintln!("atlas selection requires new native route: {error:#}");
                        self.reject_selection(
                            request,
                            viewflow_protocol::AtlasSelectionRejectionReason::NativeUnavailable,
                            0,
                            0,
                        )?;
                    }
                }
                Err(oneshot::error::TryRecvError::Empty) => return Ok(()),
                Err(_) => anyhow::bail!("selection acceptance native route ended"),
            }
        }
        if let Some(pending) = &mut self.rejection_pending {
            match pending.try_recv() {
                Ok(result) => {
                    result?;
                    self.rejection_pending = None;
                }
                Err(oneshot::error::TryRecvError::Empty) => return Ok(()),
                Err(_) => anyhow::bail!("selection rejection cleanup route ended"),
            }
        }
        let phase = self.desktop_phase.load(Ordering::Acquire);
        if phase != 0 {
            self.policy.invalidate_current();
        }
        if phase != 1 {
            self.apply_selection(now, native_now)?;
        }
        if self.acceptance_pending.is_none()
            && self.waiting.is_none()
            && self.desktop_phase.load(Ordering::Acquire) == 0
        {
            if let Some(latest) = self.history.back() {
                if let Some(renewed) = self.policy.maintain_capture(
                    latest,
                    self.initial_window,
                    now,
                    native_now,
                    self.max_capture_age_ns,
                )? {
                    self.updates
                        .as_ref()
                        .context("atlas input updates missing")?
                        .send(renewed)?;
                }
            }
        }
        Ok(())
    }

    fn apply_selection(&mut self, now: u64, native_now: u64) -> Result<()> {
        let request = if let Some(request) = self.waiting.take() {
            request
        } else {
            match self.requests.try_recv() {
                Ok(request) => request,
                Err(mpsc::error::TryRecvError::Empty) => return Ok(()),
                Err(mpsc::error::TryRecvError::Disconnected) => {
                    anyhow::bail!("atlas selection route ended")
                }
            }
        };
        ensure!(
            !request.selection.activate_keyboard || self.allow_keyboard,
            "atlas selection keyboard activation is not locally enabled"
        );
        // Deadline is checked before waiting for the source's local feedback
        // publication; packet arrival cannot manufacture committed evidence.
        if self
            .policy
            .discard_unusable_selection(request.selection, request.clock, now)?
        {
            self.selections_timing_discarded = self.selections_timing_discarded.saturating_add(1);
            return self.reject_selection(
                request,
                viewflow_protocol::AtlasSelectionRejectionReason::EventExpired,
                0,
                0,
            );
        }
        if !self
            .membership
            .borrow()
            .windows
            .contains(&request.selection.window_id)
        {
            self.policy
                .discard_withdrawn_selection(request.selection.sequence)?;
            return self.reject_selection(
                request,
                viewflow_protocol::AtlasSelectionRejectionReason::WindowWithdrawn,
                0,
                0,
            );
        }
        let Some(committed) = self
            .history
            .iter()
            .find(|frame| request.selection.matches(frame.manifest()))
        else {
            self.waiting = Some(request);
            return Ok(());
        };
        let selected = self.policy.select(
            request.selection,
            committed,
            AtlasSelectionContext {
                now_local_ns: now,
                now_native_ns: native_now,
                max_capture_age_ns: self.max_capture_age_ns,
                clock: request.clock,
            },
        );
        let authorized = match selected {
            Ok(authorized) => authorized,
            Err(error) if error.is::<crate::atlas_input_policy::AtlasSelectionSuperseded>() => {
                return self.reject_selection(
                    request,
                    viewflow_protocol::AtlasSelectionRejectionReason::NativeUnavailable,
                    0,
                    0,
                );
            }
            Err(error) if error.is::<crate::atlas_input_policy::AtlasSelectionUnavailable>() => {
                let expired = error
                    .downcast_ref::<crate::atlas_input_policy::AtlasSelectionUnavailable>()
                    .context("atlas capture rejection missing age")?;
                self.last_capture_rejection = Some([
                    request.selection.sequence,
                    request.selection.source_frame_id,
                    expired.age_ns,
                    expired.max_age_ns,
                ]);
                self.last_capture_rejection_timing = rejection_timing(request, now, self.origin);
                self.selections_capture_discarded =
                    self.selections_capture_discarded.saturating_add(1);
                return self.reject_selection(
                    request,
                    viewflow_protocol::AtlasSelectionRejectionReason::CaptureExpired,
                    expired.age_ns,
                    expired.max_age_ns,
                );
            }
            Err(error) => return Err(error),
        };
        if self.desktop_phase.load(Ordering::Acquire) == 2 {
            self.desktop_phase
                .compare_exchange(2, 0, Ordering::AcqRel, Ordering::Acquire)
                .map_err(|_| anyhow::anyhow!("desktop phase changed during selection"))?;
        }
        ensure!(
            self.acceptance_pending.is_none(),
            "overlapping selection acceptance"
        );
        let (completion, pending) = oneshot::channel();
        self.acceptance_sender
            .try_send(
                crate::window_input_runtime::AtlasSelectionAcceptanceRequest {
                    selection: request.selection,
                    authorization: authorized,
                    completion,
                },
            )
            .map_err(|_| anyhow::anyhow!("selection acceptance native owner unavailable"))?;
        self.acceptance_pending = Some((request, pending));
        self.selections_authorized = self.selections_authorized.saturating_add(1);
        Ok(())
    }

    fn reject_selection(
        &mut self,
        request: AtlasSelectionRequest,
        reason: viewflow_protocol::AtlasSelectionRejectionReason,
        capture_age_ns: u64,
        capture_limit_ns: u64,
    ) -> Result<()> {
        self.policy.invalidate_current();
        self.desktop_phase.store(2, Ordering::Release);
        ensure!(
            self.rejection_pending.is_none(),
            "selection rejection overlaps prior cleanup"
        );
        let (completion, pending) = oneshot::channel();
        self.rejection_sender
            .try_send(
                crate::window_input_runtime::AtlasSelectionRejectionRequest {
                    rejection: viewflow_protocol::AtlasWindowSelectionRejected {
                        selection: request.selection,
                        reason,
                        released_generation: 0,
                        capture_age_ns,
                        capture_limit_ns,
                    },
                    completion,
                },
            )
            .map_err(|_| anyhow::anyhow!("selection rejection native owner unavailable"))?;
        self.rejection_pending = Some(pending);
        Ok(())
    }

    pub(crate) async fn shutdown(mut self) -> Result<()> {
        let desktop_result = match self.desktop.as_mut() {
            Some(worker) => worker.shutdown().await,
            None => Ok(()),
        };
        self.network
            .close(0_u32.into(), b"atlas source input stopped");
        if let Some(task) = self.task.take() {
            task.abort();
            match task.await {
                Err(error) if error.is_cancelled() => {}
                Err(error) => return Err(error).context("atlas input shutdown task failed"),
                Ok(_) => {}
            }
        }
        desktop_result
    }
}

impl Drop for AtlasSourceInput {
    fn drop(&mut self) {
        eprintln!(
            "atlas-source-input-retiring timing_discarded={} capture_discarded={} authorized={} last_capture_rejection={:?} rejection_timing_ns={:?} application_delivery_proven=false",
            self.selections_timing_discarded,
            self.selections_capture_discarded,
            self.selections_authorized,
            self.last_capture_rejection,
            self.last_capture_rejection_timing
        );
        self.network
            .close(0_u32.into(), b"atlas source input retired");
        if let Some(task) = &self.task {
            task.abort();
        }
        if let Ok(metadata) = std::fs::symlink_metadata(&self.path) {
            if (metadata.dev(), metadata.ino()) == self.socket_identity {
                let _ = std::fs::remove_file(&self.path);
            }
        }
    }
}

fn rejection_timing(request: AtlasSelectionRequest, now: u64, origin: Instant) -> Option<[u64; 3]> {
    let deadline = crate::input_runtime::conservative_input_deadline(
        request.selection.sender_not_after_ns,
        request.clock.map(
            |(estimate, measured_at_local_ns)| crate::input_runtime::ClockSnapshot {
                estimate,
                measured_at_local_ns,
            },
        ),
        now,
    )
    .ok()?;
    Some([
        now.checked_sub(request.received_local_ns)?,
        deadline.checked_sub(now)?,
        u64::try_from(origin.elapsed().as_nanos())
            .ok()?
            .checked_sub(now)?,
    ])
}

struct ActiveDesktopDrag {
    drag_id: viewflow_protocol::Id128,
    last_sequence: u64,
    token: String,
    expires_native_ns: u64,
    initial_bounds: viewflow_protocol::DesktopRect,
    base: viewflow_protocol::AtlasFrame,
}

fn desktop_drag_base(
    movement: viewflow_protocol::DesktopWindowMove,
    active: Option<&ActiveDesktopDrag>,
    history: &VecDeque<AtlasCommittedInput>,
) -> Option<viewflow_protocol::AtlasFrame> {
    active
        .filter(|active| {
            movement.phase != viewflow_protocol::DesktopWindowMovePhase::Begin
                && active.drag_id == movement.drag_id
        })
        .map(|active| active.base.clone())
        .or_else(|| {
            history
                .iter()
                .find(|frame| frame.manifest().frame_id == movement.base_atlas_frame)
                .map(|frame| frame.manifest().clone())
        })
}

/// The source-local desktop controller. It owns no network reader and accepts
/// only requests already sequenced by `RoutedWindowInput` on this connection.
/// Owns native drag commands independently of GPU capture/encode polling.
/// In-flight commands run to completion so enrollment tokens remain recoverable.
struct DesktopMoveWorker {
    stop: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<Result<()>>>,
}

impl DesktopMoveWorker {
    fn start(
        mut controller: DesktopMoveController,
        mut requests: mpsc::Receiver<crate::window_input_runtime::DesktopMoveRequest>,
        history: watch::Receiver<Arc<VecDeque<AtlasCommittedInput>>>,
        phase: Arc<AtomicU8>,
        origin: Instant,
    ) -> Self {
        let (stop, mut stopped) = oneshot::channel();
        let task = tokio::spawn(async move {
            let work: Result<()> = async {
                loop {
                    let request = tokio::select! {
                        biased;
                        _ = &mut stopped => break,
                        request = requests.recv() => match request {
                            Some(request) => request,
                            None => break,
                        },
                    };
                    let transfer_state = controller.transfer.clone();
                    let mut transfer = transfer_state.lock().await;
                    let begin = request.movement.phase == viewflow_protocol::DesktopWindowMovePhase::Begin;
                    if transfer.as_ref().is_some_and(|drag| drag.handed_off && drag.window == request.movement.window_id) && !begin {
                        let result = controller.finish_transfer(request.movement.window_id).await.and_then(|()|
                            desktop_ack(request.movement, viewflow_protocol::DesktopWindowMoveResult::Ended, controller.local_viewport));
                        phase.store(2, Ordering::Release);
                        let _ = request.completion.send(result);
                        continue;
                    }
                    if begin { *transfer = None; }
                    let started = Instant::now();
                    let now = u64::try_from(origin.elapsed().as_nanos())?;
                    let native_now = u64::try_from(crate::gpu_nvenc_runtime::monotonic_ns()?)?;
                    let begin = request.movement.phase == viewflow_protocol::DesktopWindowMovePhase::Begin;
                    if begin { phase.store(1, Ordering::Release); }
                    let frames = history.borrow().clone();
                    let base = desktop_drag_base(request.movement,
                        controller.active.get(&request.movement.window_id), &frames);
                    let result = match base {
                        Some(base) => controller.handle(request.movement, request.clock,
                            request.received_local_ns, now, native_now, &base).await,
                        None => desktop_ack(request.movement,
                            viewflow_protocol::DesktopWindowMoveResult::Rejected,
                            controller.remote_viewport),
                    };
                    let result = match result {
                        Ok(ack) => Ok(ack),
                        Err(error) => {
                            eprintln!("desktop-source move rejected locally: {error:#}");
                            // Restore only this gesture; a compositor rejection
                            // must not terminate the shared video/input owner.
                            controller.cancel_window(request.movement.window_id).await?;
                            phase.store(2, Ordering::Release);
                            desktop_ack(request.movement,
                                viewflow_protocol::DesktopWindowMoveResult::Rejected,
                                controller.remote_viewport)
                        }
                    };
                    if result.as_ref().is_ok_and(|ack|
                        ack.result == viewflow_protocol::DesktopWindowMoveResult::Ended ||
                        (begin && ack.result == viewflow_protocol::DesktopWindowMoveResult::Rejected)) {
                        phase.store(2, Ordering::Release);
                    }
                    if result.as_ref().is_ok_and(|ack| ack.result == viewflow_protocol::DesktopWindowMoveResult::Applied) {
                        if let Some(active) = controller.active.get(&request.movement.window_id) {
                            let binding = controller.lane.lock().map_err(|_| anyhow::anyhow!("desktop source state poisoned"))?.native_binding(request.movement.window_id);
                            if let Some(binding) = binding {
                                let resizing = transfer.as_ref().is_some_and(|drag| drag.resizing)
                                    || (request.movement.desired_width_millidip != 0 && request.movement.desired_width_millidip != active.initial_bounds.width_millidip)
                                    || (request.movement.desired_height_millidip != 0 && request.movement.desired_height_millidip != active.initial_bounds.height_millidip);
                                *transfer = Some(crate::atlas_cursor_handoff::DragTransfer {
                                    window: request.movement.window_id,
                                    target: viewflow_hyprland::capture_wire::DragTarget { pid: binding.pid, address: binding.address, surface: binding.surface, reverse_id: 0 },
                                    handed_off: false, resizing, move_confirmed: !begin,
                                });
                            }
                        }
                    } else if !controller.active.contains_key(&request.movement.window_id) {
                        *transfer = None;
                    }
                    drop(transfer);
                    if std::env::var_os("VIEWFLOW_DESKTOP_TIMING").is_some() {
                        eprintln!("desktop-source-timing phase={:?} sequence={} queue_us={} handler_us={} outcome={:?}",
                            request.movement.phase, request.movement.sequence,
                            now.saturating_sub(request.received_local_ns) / 1000,
                            started.elapsed().as_micros(), result.as_ref().map(|ack| ack.result));
                    }
                    // The source action and cleanup are complete even if the
                    // caller has stopped waiting; do not kill the worker.
                    let _ = request.completion.send(result);
                }
                Ok(())
            }.await;
            let cleanup = controller.shutdown().await;
            match (work, cleanup) {
                (Err(work), Err(cleanup)) => Err(anyhow::anyhow!(
                    "{work:#}; desktop cleanup also failed: {cleanup:#}"
                )),
                (Err(error), _) | (_, Err(error)) => Err(error),
                _ => Ok(()),
            }
        });
        Self {
            stop: Some(stop),
            task: Some(task),
        }
    }

    async fn check_health(&mut self) -> Result<()> {
        if self
            .task
            .as_ref()
            .is_some_and(tokio::task::JoinHandle::is_finished)
        {
            self.task
                .take()
                .context("desktop worker missing")?
                .await
                .context("desktop worker failed")??;
            anyhow::bail!("desktop worker ended");
        }
        Ok(())
    }

    async fn shutdown(&mut self) -> Result<()> {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(task) = self.task.take() {
            task.await.context("desktop worker shutdown failed")??;
        }
        Ok(())
    }
}

impl Drop for DesktopMoveWorker {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}

struct DesktopMoveController {
    transfer: crate::atlas_cursor_handoff::SharedDragTransfer,
    client: viewflow_hyprland::DesktopWindowClient,
    lane: crate::desktop_source::SharedDesktopSourceLane,
    stream_id: viewflow_protocol::Id128,
    config_generation: u64,
    topology_generation: u64,
    local_viewport: viewflow_protocol::DesktopRect,
    remote_viewport: viewflow_protocol::DesktopRect,
    owner: viewflow_protocol::DeviceId,
    source: viewflow_protocol::DeviceId,
    active: BTreeMap<viewflow_protocol::WindowId, ActiveDesktopDrag>,
}

impl DesktopMoveController {
    fn new(
        config: &crate::atlas_peer::AtlasSourceConfig,
        desktop: &crate::desktop_config::AtlasSourceDesktopConfig,
        lane: crate::desktop_source::SharedDesktopSourceLane,
        _origin: Instant,
        transfer: crate::atlas_cursor_handoff::SharedDragTransfer,
    ) -> Result<Self> {
        let pointer = config
            .pointer
            .as_ref()
            .context("desktop source requires pointer configuration")?;
        let (owner, source) = pointer.devices.devices()?;
        let request_path = desktop.native_control_dir.join("desktop-window.json");
        Ok(Self {
            transfer,
            client: viewflow_hyprland::DesktopWindowClient::new(
                viewflow_hyprland::HyprIpcClient::new(desktop.hyprland_socket.clone()),
                request_path,
                i32::try_from(config.compositor_pid)?,
            ),
            lane,
            stream_id: config.media.plan()?.policy.stream_id,
            config_generation: config.media.config_generation,
            topology_generation: desktop.topology_generation,
            local_viewport: desktop.local_display.rect()?,
            remote_viewport: desktop.remote_display.rect()?,
            owner,
            source,
            active: BTreeMap::new(),
        })
    }

    #[allow(clippy::too_many_arguments)]
    async fn handle(
        &mut self,
        movement: viewflow_protocol::DesktopWindowMove,
        clock: Option<(viewflow_transport::ClockEstimate, u64)>,
        _received_local_ns: u64,
        now_local_ns: u64,
        native_now_ns: u64,
        base: &viewflow_protocol::AtlasFrame,
    ) -> Result<viewflow_protocol::DesktopWindowMoveAck> {
        movement
            .validate()
            .map_err(|error| anyhow::anyhow!("invalid desktop move: {error:?}"))?;
        let bounds = base
            .desktop
            .as_ref()
            .context("desktop move has no immutable desktop frame")?
            .windows
            .iter()
            .find(|window| window.window_id == movement.window_id)
            .context("desktop move target is absent from committed desktop frame")?
            .bounds;
        let reject = || {
            desktop_ack(
                movement,
                viewflow_protocol::DesktopWindowMoveResult::Rejected,
                bounds,
            )
        };
        if movement.source_device != self.source
            || movement.owner_device != self.owner
            || movement.stream_id != self.stream_id
            || movement.config_generation != self.config_generation
            || movement.topology_generation != self.topology_generation
            || !desktop_tile_matches(movement, base)
        {
            return reject();
        }
        let local_deadline = match crate::input_runtime::conservative_operation_deadline(
            movement.sender_not_after_ns,
            clock.map(
                |(estimate, measured_at_local_ns)| crate::input_runtime::ClockSnapshot {
                    estimate,
                    measured_at_local_ns,
                },
            ),
            now_local_ns,
        ) {
            Ok(deadline) => deadline,
            Err(_) => return reject(),
        };
        let remaining = match local_deadline.checked_sub(now_local_ns) {
            Some(remaining) if remaining > 0 => remaining,
            _ => return reject(),
        };
        let native_deadline = match native_now_ns.checked_add(remaining) {
            Some(deadline) => deadline,
            None => return reject(),
        };
        // The local compositor capability is deliberately longer-lived than a
        // single wire control deadline, but still bounded. Each move itself
        // retains the caller's unextended mapped deadline above.
        let enrollment_deadline = match native_now_ns.checked_add(MAX_DESKTOP_ENROLLMENT_NS) {
            Some(deadline) => deadline,
            None => return reject(),
        };
        let binding = match self
            .lane
            .lock()
            .map_err(|_| anyhow::anyhow!("desktop source state poisoned"))?
            .native_binding(movement.window_id)
        {
            Some(binding) => binding,
            None => return reject(),
        };
        let mut desired = viewflow_protocol::DesktopRect {
            x_millidip: movement.desired_x_millidip,
            y_millidip: movement.desired_y_millidip,
            width_millidip: if movement.desired_width_millidip == 0 {
                bounds.width_millidip
            } else {
                movement.desired_width_millidip
            },
            height_millidip: if movement.desired_height_millidip == 0 {
                bounds.height_millidip
            } else {
                movement.desired_height_millidip
            },
        };
        if desired.validate().is_err() {
            return reject();
        }
        if movement.phase == viewflow_protocol::DesktopWindowMovePhase::End {
            if let Some(active) = self.active.get(&movement.window_id) {
                desired = desktop_return_bounds(
                    self.local_viewport,
                    self.remote_viewport,
                    active.initial_bounds,
                    desired,
                )?;
            }
        }
        match movement.phase {
            viewflow_protocol::DesktopWindowMovePhase::Begin => {
                if movement.sequence != 1 || self.active.contains_key(&movement.window_id) {
                    return reject();
                }
                let local_window_id = format!("{:032x}", movement.window_id.0);
                let client = self.client.clone();
                let enrollment = tokio::task::spawn_blocking(move || -> Result<_> {
                    let enrollment = client.enroll(&viewflow_hyprland::EnrollRequest {
                        local_window_id,
                        window_address: format!("0x{:x}", binding.address),
                        pid: binding.pid,
                        surface_address: Some(format!("0x{:x}", binding.surface)),
                        not_after_monotonic_ns: enrollment_deadline,
                    })?;
                    ensure!(
                        enrollment.expires_at_monotonic_ns == enrollment_deadline
                            && enrollment.expires_at_monotonic_ns >= native_deadline
                            && enrollment.token.len() == 48,
                        "desktop enrollment reply is unusable"
                    );
                    let moved = client.move_window(&viewflow_hyprland::MoveRequest {
                        local_window_id: enrollment.local_window_id.clone(),
                        token: enrollment.token.clone(),
                        sequence: movement.sequence,
                        not_after_monotonic_ns: native_deadline,
                        desired_full_capture_x: movement.desired_x_millidip as f64 / 1000.0,
                        desired_full_capture_y: movement.desired_y_millidip as f64 / 1000.0,
                        desired_full_capture_width: desired.width_millidip as f64 / 1000.0,
                        desired_full_capture_height: desired.height_millidip as f64 / 1000.0,
                    });
                    // Return the token even if moving fails. Retirement owns
                    // restoration with a fresh cleanup-only deadline.
                    Ok((enrollment, moved))
                })
                .await
                .context("desktop enrollment worker failed")?;
                let (enrollment, moved) = match enrollment {
                    Ok(enrollment) => enrollment,
                    Err(_) => return reject(),
                };
                self.active.insert(
                    movement.window_id,
                    ActiveDesktopDrag {
                        drag_id: movement.drag_id,
                        last_sequence: movement.sequence,
                        token: enrollment.token,
                        expires_native_ns: enrollment.expires_at_monotonic_ns,
                        initial_bounds: bounds,
                        base: base.clone(),
                    },
                );
                moved.context("desktop initial move failed; enrollment retained for cleanup")?;
                desktop_ack(
                    movement,
                    viewflow_protocol::DesktopWindowMoveResult::Applied,
                    bounds,
                )
            }
            viewflow_protocol::DesktopWindowMovePhase::Update => {
                let Some(active) = self.active.get_mut(&movement.window_id) else {
                    return reject();
                };
                if active.drag_id != movement.drag_id
                    || movement.sequence != active.last_sequence.saturating_add(1)
                    || native_deadline > active.expires_native_ns
                {
                    return reject();
                }
                let token = active.token.clone();
                let local_window_id = format!("{:032x}", movement.window_id.0);
                let client = self.client.clone();
                let moved = tokio::task::spawn_blocking(move || {
                    client.move_window(&viewflow_hyprland::MoveRequest {
                        local_window_id,
                        token,
                        sequence: movement.sequence,
                        not_after_monotonic_ns: native_deadline,
                        desired_full_capture_x: desired.x_millidip as f64 / 1000.0,
                        desired_full_capture_y: desired.y_millidip as f64 / 1000.0,
                        desired_full_capture_width: desired.width_millidip as f64 / 1000.0,
                        desired_full_capture_height: desired.height_millidip as f64 / 1000.0,
                    })
                })
                .await
                .context("desktop move worker failed")?;
                // The plugin consumes a valid sequence before checking its deadline.
                // Keep the attempted sequence even when the reply is a rejection.
                active.last_sequence = movement.sequence;
                moved.context("desktop move failed; enrollment retained for cleanup")?;
                desktop_ack(
                    movement,
                    viewflow_protocol::DesktopWindowMoveResult::Applied,
                    desired,
                )
            }
            viewflow_protocol::DesktopWindowMovePhase::End
            | viewflow_protocol::DesktopWindowMovePhase::Cancel => {
                let Some(active) = self.active.get_mut(&movement.window_id) else {
                    return reject();
                };
                if active.drag_id != movement.drag_id
                    || movement.sequence != active.last_sequence.saturating_add(1)
                    || native_deadline > active.expires_native_ns
                {
                    return reject();
                }
                let local_window_id = format!("{:032x}", movement.window_id.0);
                let client = self.client.clone();
                let restore = movement.phase == viewflow_protocol::DesktopWindowMovePhase::Cancel;
                let token = active.token.clone();
                let (attempted_sequence, released) = tokio::task::spawn_blocking(move || {
                    let mut attempted_sequence = movement.sequence;
                    let result = (|| -> Result<()> {
                        if !restore {
                            client.move_window(&viewflow_hyprland::MoveRequest {
                                local_window_id: local_window_id.clone(),
                                token: token.clone(),
                                sequence: movement.sequence,
                                not_after_monotonic_ns: native_deadline,
                                desired_full_capture_x: desired.x_millidip as f64 / 1000.0,
                                desired_full_capture_y: desired.y_millidip as f64 / 1000.0,
                                desired_full_capture_width: desired.width_millidip as f64 / 1000.0,
                                desired_full_capture_height: desired.height_millidip as f64
                                    / 1000.0,
                            })?;
                            attempted_sequence = movement
                                .sequence
                                .checked_add(1)
                                .context("desktop release sequence overflow")?;
                        }
                        client.release(&viewflow_hyprland::ReleaseRequest {
                            local_window_id,
                            token,
                            sequence: attempted_sequence,
                            not_after_monotonic_ns: native_deadline,
                            restore,
                        })?;
                        Ok(())
                    })();
                    (attempted_sequence, result)
                })
                .await
                .context("desktop release worker failed")?;
                active.last_sequence = attempted_sequence;
                released.context("desktop release failed; enrollment retained for cleanup")?;
                self.active.remove(&movement.window_id);
                desktop_ack(
                    movement,
                    viewflow_protocol::DesktopWindowMoveResult::Ended,
                    desired,
                )
            }
        }
    }

    async fn finish_transfer(&mut self, window: viewflow_protocol::WindowId) -> Result<()> {
        let Some(active) = self.active.get(&window) else { return Ok(()); };
        let request = viewflow_hyprland::ReleaseRequest {
            local_window_id: format!("{:032x}", window.0), token: active.token.clone(),
            sequence: active.last_sequence.checked_add(1).context("desktop release sequence overflow")?,
            not_after_monotonic_ns: desktop_cleanup_deadline(u64::try_from(crate::gpu_nvenc_runtime::monotonic_ns()?)?, active.expires_native_ns)?,
            restore: false,
        };
        let client = self.client.clone();
        tokio::task::spawn_blocking(move || client.release(&request)).await.context("desktop transfer release failed")??;
        self.active.remove(&window);
        Ok(())
    }

    /// Release every locally owned compositor enrollment on normal source
    /// retirement. This is distinct from the plugin's expiry fallback and
    /// requests restoration because no remote End was confirmed.
    async fn shutdown(&mut self) -> Result<()> {
        let handed_off = self.transfer.lock().await.as_ref().filter(|drag| drag.handed_off).map(|drag| drag.window);
        if let Some(window) = handed_off { self.finish_transfer(window).await?; }
        let active = std::mem::take(&mut self.active);
        self.release_enrollments(active).await
    }

    async fn cancel_window(&mut self, window: viewflow_protocol::WindowId) -> Result<()> {
        let active = self.active.remove(&window).map(|drag| (window, drag)).into_iter().collect();
        self.release_enrollments(active).await
    }

    async fn release_enrollments(
        &mut self,
        active: BTreeMap<viewflow_protocol::WindowId, ActiveDesktopDrag>,
    ) -> Result<()> {
        let native_now = u64::try_from(crate::gpu_nvenc_runtime::monotonic_ns()?)?;
        let mut failure = None;
        for (window, active) in active {
            // A failed/expired token must not skip cleanup of other windows.
            let result = async {
                let deadline = desktop_cleanup_deadline(native_now, active.expires_native_ns)?;
                let client = self.client.clone();
                let local_window_id = format!("{:032x}", window.0);
                let sequence = active
                    .last_sequence
                    .checked_add(1)
                    .context("desktop release sequence overflow")?;
                tokio::task::spawn_blocking(move || {
                    let mut request = viewflow_hyprland::ReleaseRequest {
                        local_window_id,
                        token: active.token,
                        sequence,
                        not_after_monotonic_ns: deadline,
                        restore: true,
                    };
                    match client.release(&request) {
                        Err(viewflow_hyprland::DesktopWindowError::Rejected(message))
                            if message == "desktop-window sequence rejected"
                                && active.last_sequence > 0 =>
                        {
                            // A transport failure may mean the last attempted move never
                            // reached the plugin. A sequence rejection consumes nothing;
                            // retry only that immediately preceding sequence, same token
                            // and unchanged cleanup deadline.
                            request.sequence = active.last_sequence;
                            client.release(&request)
                        }
                        result => result,
                    }
                })
                .await
                .context("desktop retirement worker failed")??;
                Ok::<_, anyhow::Error>(())
            }
            .await;
            if let Err(error) = result {
                failure.get_or_insert_with(|| {
                    anyhow::anyhow!("desktop enrollment release failed: {error}")
                });
            }
        }
        if let Some(error) = failure {
            Err(error)
        } else {
            Ok(())
        }
    }
}

/// Preserve the exact requested rectangle, including partial seam overlap.
/// Completing a gesture must never fit the entire window into another display:
/// that turns a continuous pointer drag into a release-time jump.
fn desktop_return_bounds(
    _local: viewflow_protocol::DesktopRect,
    _remote: viewflow_protocol::DesktopRect,
    _initial: viewflow_protocol::DesktopRect,
    desired: viewflow_protocol::DesktopRect,
) -> Result<viewflow_protocol::DesktopRect> {
    desired
        .validate()
        .map_err(|error| anyhow::anyhow!("desktop return bounds invalid: {error:?}"))?;
    Ok(desired)
}

fn desktop_cleanup_deadline(now: u64, expires: u64) -> Result<u64> {
    let deadline = now.saturating_add(1_000_000_000).min(expires);
    ensure!(
        deadline > now,
        "desktop enrollment expired before checked release"
    );
    Ok(deadline)
}

fn desktop_ack(
    movement: viewflow_protocol::DesktopWindowMove,
    result: viewflow_protocol::DesktopWindowMoveResult,
    actual_bounds: viewflow_protocol::DesktopRect,
) -> Result<viewflow_protocol::DesktopWindowMoveAck> {
    let ack = viewflow_protocol::DesktopWindowMoveAck {
        source_device: movement.source_device,
        owner_device: movement.owner_device,
        stream_id: movement.stream_id,
        config_generation: movement.config_generation,
        topology_generation: movement.topology_generation,
        window_id: movement.window_id,
        drag_id: movement.drag_id,
        sequence: movement.sequence,
        result,
        actual_bounds,
    };
    ack.validate()
        .map_err(|error| anyhow::anyhow!("invalid desktop move acknowledgement: {error:?}"))?;
    Ok(ack)
}

fn desktop_tile_matches(
    movement: viewflow_protocol::DesktopWindowMove,
    manifest: &viewflow_protocol::AtlasFrame,
) -> bool {
    manifest.frame_id == movement.base_atlas_frame
        && manifest.tiles.iter().any(|tile| {
            tile.window_id == movement.window_id
                && tile.geometry_epoch == movement.base_geometry_epoch
        })
}

async fn drive_media_with_input<T>(
    media: impl std::future::Future<Output = Result<T>>,
    mut input: impl AsyncFnMut() -> Result<()>,
) -> Result<T> {
    tokio::pin!(media);
    let mut tick = tokio::time::interval(Duration::from_millis(1));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            result = &mut media => return result,
            _ = tick.tick() => {},
        }
        // A policy poll may own a native command and its enrollment token.
        // Finish it even when the frame completes; cancelling it could leave
        // the compositor moved without recording its sequence or sending ACK.
        let poll = input();
        tokio::pin!(poll);
        let input_result = tokio::select! {
            result = &mut media => {
                let input_result = poll.await;
                return match (result, input_result) {
                    (Err(media), Err(input)) => Err(media.context(format!("atlas source input also ended: {input:#}"))),
                    (Err(error), _) | (_, Err(error)) => Err(error),
                    (Ok(value), Ok(())) => Ok(value),
                };
            },
            result = &mut poll => result,
        };
        if let Err(input) = input_result {
            return match tokio::time::timeout(Duration::from_secs(5), &mut media).await {
                Ok(Err(media)) => {
                    Err(media.context(format!("atlas source input also ended: {input:#}")))
                }
                Ok(Ok(_)) => Err(input),
                Err(_) => {
                    Err(input.context("atlas media cleanup did not finish within five seconds"))
                }
            };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desktop_return_preserves_partial_overlap_on_each_adjoining_edge() {
        let rect = |x, y, w, h| viewflow_protocol::DesktopRect {
            x_millidip: x,
            y_millidip: y,
            width_millidip: w,
            height_millidip: h,
        };
        let local = rect(0, 0, 100_000, 100_000);
        for (remote, initial, requested) in [
            (
                rect(100_000, 0, 100_000, 100_000),
                rect(110_000, 10_000, 20_000, 20_000),
                rect(99_000, 10_000, 20_000, 20_000),
            ),
            (
                rect(-100_000, 0, 100_000, 100_000),
                rect(-30_000, 10_000, 20_000, 20_000),
                rect(-19_000, 10_000, 20_000, 20_000),
            ),
            (
                rect(0, 100_000, 100_000, 100_000),
                rect(10_000, 110_000, 20_000, 20_000),
                rect(10_000, 99_000, 20_000, 20_000),
            ),
            (
                rect(0, -100_000, 100_000, 100_000),
                rect(10_000, -30_000, 20_000, 20_000),
                rect(10_000, -19_000, 20_000, 20_000),
            ),
        ] {
            let returned = desktop_return_bounds(local, remote, initial, requested).unwrap();
            assert_eq!(returned, requested);
            assert_eq!(returned.width_millidip, requested.width_millidip);
            assert_eq!(returned.height_millidip, requested.height_millidip);
            // Motion away from Linux or a no-op drag must not snap back.
            assert_eq!(
                desktop_return_bounds(local, remote, requested, initial).unwrap(),
                initial
            );
            assert_eq!(
                desktop_return_bounds(local, remote, requested, requested).unwrap(),
                requested
            );
        }
    }

    #[test]
    fn desktop_cleanup_uses_remaining_token_lifetime_without_extending_it() {
        assert_eq!(desktop_cleanup_deadline(100, 150).unwrap(), 150);
        assert_eq!(
            desktop_cleanup_deadline(100, 2_000_000_000).unwrap(),
            1_000_000_100
        );
        assert!(desktop_cleanup_deadline(100, 100).is_err());
        assert!(desktop_cleanup_deadline(100, 99).is_err());
    }

    #[tokio::test]
    async fn desktop_cleanup_expired_window_does_not_skip_live_window_or_uncertain_sequence() {
        use std::io::{Read, Write};
        use std::os::unix::{fs::PermissionsExt, net::UnixListener};
        use viewflow_protocol::Id128;
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = directory.path().join("hypr.sock");
        let request = directory.path().join("request.json");
        std::fs::write(&request, b"{}").unwrap();
        std::fs::set_permissions(&request, std::fs::Permissions::from_mode(0o600)).unwrap();
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let reply_path = request.clone();
        let worker = std::thread::spawn(move || {
            let deadline = std::time::Instant::now() + Duration::from_secs(2);
            let mut rejected = false;
            loop {
                if let Ok((mut peer, _)) = listener.accept() {
                    peer.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
                    let mut command = [0; 1024];
                    assert!(peer.read(&mut command).unwrap() > 0);
                    let payload: serde_json::Value =
                        serde_json::from_slice(&std::fs::read(&reply_path).unwrap()).unwrap();
                    assert_eq!(payload["localWindowId"], format!("{:032x}", 2));
                    assert_eq!(payload["restore"], true);
                    if !rejected {
                        assert_eq!(payload["sequence"], 2);
                        std::fs::write(&reply_path, br#"{"version":1,"ok":false,"error":"desktop-window sequence rejected"}"#).unwrap();
                        peer.write_all(b"ok").unwrap();
                        rejected = true;
                        continue;
                    }
                    assert_eq!(payload["sequence"], 1);
                    std::fs::write(&reply_path, br#"{"version":1,"ok":true}"#).unwrap();
                    peer.write_all(b"ok").unwrap();
                    return;
                }
                assert!(
                    std::time::Instant::now() < deadline,
                    "live window cleanup was skipped"
                );
                std::thread::sleep(Duration::from_millis(1));
            }
        });
        let bounds = desktop_manifest(1, 1, 1).desktop.unwrap().viewport;
        let lane = crate::desktop_source::DesktopSourceLane::new(
            crate::desktop_source::DesktopViewport {
                topology_generation: 1,
                bounds,
            },
            vec![crate::desktop_source::DesktopCandidate {
                window: Id128(2),
                address: "0x2".into(),
                native_address: 2,
                stable_id: Some("fixture".into()),
                expected_pid: Some(2),
            }],
            [Id128(2)],
            8,
        )
        .unwrap()
        .shared();
        let now = u64::try_from(crate::gpu_nvenc_runtime::monotonic_ns().unwrap()).unwrap();
        let mut controller = DesktopMoveController {
            transfer: Default::default(),
            client: viewflow_hyprland::DesktopWindowClient::new(
                viewflow_hyprland::HyprIpcClient::new(socket),
                request,
                i32::try_from(std::process::id()).unwrap(),
            ),
            lane,
            stream_id: Id128(99),
            config_generation: 1,
            topology_generation: 1,
            local_viewport: bounds,
            remote_viewport: bounds,
            owner: Id128(3),
            source: Id128(4),
            active: [(1, now - 1), (2, now + 5_000_000_000)]
                .into_iter()
                .map(|(id, expires)| {
                    (
                        Id128(id),
                        ActiveDesktopDrag {
                            drag_id: Id128(7),
                            last_sequence: 1,
                            token: "a".repeat(48),
                            expires_native_ns: expires,
                            initial_bounds: bounds,
                            base: desktop_manifest(1, 1, 1),
                        },
                    )
                })
                .collect(),
        };
        assert!(controller.shutdown().await.is_err());
        worker.join().unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn desktop_worker_completes_and_cleans_up_while_media_owner_is_blocked() {
        use viewflow_protocol::{DesktopWindowMove, DesktopWindowMovePhase, Id128};
        let directory = tempfile::tempdir().unwrap();
        let bounds = desktop_manifest(1, 1, 1).desktop.unwrap().viewport;
        let lane = crate::desktop_source::DesktopSourceLane::new(
            crate::desktop_source::DesktopViewport {
                topology_generation: 1,
                bounds,
            },
            vec![crate::desktop_source::DesktopCandidate {
                window: Id128(8),
                address: "0x8".into(),
                native_address: 8,
                stable_id: Some("fixture".into()),
                expected_pid: Some(8),
            }],
            [Id128(8)],
            8,
        )
        .unwrap()
        .shared();
        let controller = DesktopMoveController {
            transfer: Default::default(),
            client: viewflow_hyprland::DesktopWindowClient::new(
                viewflow_hyprland::HyprIpcClient::new(directory.path().join("absent.sock")),
                directory.path().join("request.json"),
                i32::try_from(std::process::id()).unwrap(),
            ),
            lane,
            stream_id: Id128(99),
            config_generation: 1,
            topology_generation: 1,
            local_viewport: bounds,
            remote_viewport: bounds,
            owner: Id128(3),
            source: Id128(4),
            active: BTreeMap::new(),
        };
        let (sender, receiver) = mpsc::channel(1);
        let (_history, history) = watch::channel(Arc::new(VecDeque::new()));
        let phase = Arc::new(AtomicU8::new(0));
        let mut worker =
            DesktopMoveWorker::start(controller, receiver, history, phase.clone(), Instant::now());
        let (completion, mut reply) = oneshot::channel();
        sender
            .send(crate::window_input_runtime::DesktopMoveRequest {
                movement: DesktopWindowMove {
                    source_device: Id128(4),
                    owner_device: Id128(3),
                    stream_id: Id128(99),
                    config_generation: 1,
                    topology_generation: 1,
                    window_id: Id128(8),
                    drag_id: Id128(9),
                    sequence: 1,
                    phase: DesktopWindowMovePhase::Begin,
                    base_atlas_frame: 1,
                    base_geometry_epoch: 1,
                    sender_not_after_ns: 1_000_000_000,
                    desired_x_millidip: 0,
                    desired_y_millidip: 0,
                    desired_width_millidip: 0,
                    desired_height_millidip: 0,
                },
                clock: None,
                received_local_ns: 0,
                completion,
            })
            .await
            .unwrap();
        // Simulate synchronous GPU work: no source-input poll or await services this request.
        std::thread::sleep(Duration::from_millis(100));
        let result = reply
            .try_recv()
            .expect("desktop request waited for media owner");
        assert_eq!(
            result.unwrap().result,
            viewflow_protocol::DesktopWindowMoveResult::Rejected
        );
        assert_eq!(phase.load(Ordering::Acquire), 2);
        worker.shutdown().await.unwrap();
    }

    fn desktop_manifest(
        frame_id: u64,
        atlas_epoch: u64,
        tile_epoch: u64,
    ) -> viewflow_protocol::AtlasFrame {
        let tile = viewflow_protocol::AtlasTile {
            window_id: viewflow_protocol::Id128(8),
            placement_generation: 4,
            geometry_epoch: tile_epoch,
            source_frame_id: 19,
            source_submitted_ns: 100,
            x: 0,
            y: 0,
            width: 16,
            height: 16,
        };
        viewflow_protocol::AtlasFrame {
            patches: None,
            stream_id: viewflow_protocol::Id128(99),
            frame_id,
            geometry_epoch: atlas_epoch,
            config_generation: 3,
            layout_revision: 4,
            width: 64,
            height: 64,
            source_submitted_ns: 100,
            tiles: vec![tile],
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: Some(viewflow_protocol::AtlasDesktopLayout {
                topology_generation: 5,
                viewport: viewflow_protocol::DesktopRect {
                    x_millidip: 0,
                    y_millidip: 0,
                    width_millidip: 64_000,
                    height_millidip: 64_000,
                },
                windows: vec![viewflow_protocol::AtlasWindowPlacement {
                    window_id: viewflow_protocol::Id128(8),
                    bounds: viewflow_protocol::DesktopRect {
                        x_millidip: 1_000,
                        y_millidip: 2_000,
                        width_millidip: 16_000,
                        height_millidip: 16_000,
                    },
                    movable: true,
                    z_order: 0,
                    raise_serial: 0,
                }],
            }),
        }
    }

    fn desktop_move(frame_id: u64, tile_epoch: u64) -> viewflow_protocol::DesktopWindowMove {
        viewflow_protocol::DesktopWindowMove {
            source_device: viewflow_protocol::Id128(1),
            owner_device: viewflow_protocol::Id128(2),
            stream_id: viewflow_protocol::Id128(99),
            config_generation: 3,
            topology_generation: 5,
            window_id: viewflow_protocol::Id128(8),
            drag_id: viewflow_protocol::Id128(7),
            sequence: 1,
            phase: viewflow_protocol::DesktopWindowMovePhase::Begin,
            base_atlas_frame: frame_id,
            base_geometry_epoch: tile_epoch,
            sender_not_after_ns: 1,
            desired_x_millidip: 1_000,
            desired_y_millidip: 2_000,
            desired_width_millidip: 0,
            desired_height_millidip: 0,
        }
    }

    #[test]
    fn active_drag_keeps_base_after_history_eviction_without_retaining_capture_buffers() {
        let base = desktop_manifest(41, 99, 7);
        let active = ActiveDesktopDrag {
            drag_id: viewflow_protocol::Id128(7),
            last_sequence: 1,
            token: "a".repeat(48),
            expires_native_ns: 30_000_000_000,
            initial_bounds: base.desktop.as_ref().unwrap().windows[0].bounds,
            base,
        };
        let mut movement = desktop_move(41, 7);
        movement.phase = viewflow_protocol::DesktopWindowMovePhase::Update;
        movement.sequence = 2;
        let retained = desktop_drag_base(movement, Some(&active), &VecDeque::new()).unwrap();
        assert!(desktop_tile_matches(movement, &retained));
        movement.phase = viewflow_protocol::DesktopWindowMovePhase::End;
        assert!(desktop_drag_base(movement, Some(&active), &VecDeque::new()).is_some());
        movement.drag_id = viewflow_protocol::Id128(100);
        assert!(desktop_drag_base(movement, Some(&active), &VecDeque::new()).is_none());
        movement.phase = viewflow_protocol::DesktopWindowMovePhase::Begin;
        assert!(desktop_drag_base(movement, Some(&active), &VecDeque::new()).is_none());
    }

    #[test]
    fn desktop_admission_uses_retained_frame_and_tile_epoch_not_atlas_epoch() {
        let retained = desktop_manifest(41, 99, 7);
        let newer = desktop_manifest(42, 100, 8);
        let history = [retained.clone(), newer];
        let movement = desktop_move(41, 7);
        let selected = history
            .iter()
            .find(|frame| frame.frame_id == movement.base_atlas_frame)
            .expect("retained base frame");
        assert!(desktop_tile_matches(movement, selected));
        assert_eq!(selected.geometry_epoch, 99);
        assert!(!desktop_tile_matches(desktop_move(41, 99), selected));
        assert!(!desktop_tile_matches(desktop_move(42, 7), selected));
    }

    #[test]
    fn desktop_enrollment_lifetime_is_thirty_seconds() {
        let native_now = 123_u64;
        assert_eq!(
            native_now.checked_add(MAX_DESKTOP_ENROLLMENT_NS),
            Some(30_000_000_123)
        );
    }

    #[tokio::test]
    async fn input_service_runs_before_media_completes_and_failures_propagate() {
        let (handled, waiting) = tokio::sync::oneshot::channel();
        let media = async {
            waiting.await.unwrap();
            Ok(7)
        };
        let mut handled = Some(handled);
        let mut completed = false;
        let input = async || {
            if let Some(handled) = handled.take() {
                handled.send(()).unwrap();
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
            completed = true;
            Ok(())
        };
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), drive_media_with_input(media, input))
                .await
                .unwrap()
                .unwrap(),
            7
        );
        assert!(
            completed,
            "media completion cancelled an admitted native poll"
        );
        let bounded_media = || async {
            tokio::time::sleep(Duration::from_millis(1)).await;
            Ok(())
        };
        let failed = drive_media_with_input(bounded_media(), async || {
            anyhow::bail!("native ownership lost")
        })
        .await;
        assert!(
            failed
                .unwrap_err()
                .to_string()
                .contains("native ownership lost")
        );
        assert!(
            drive_media_with_input(bounded_media(), async || { Ok(()) })
                .await
                .is_ok()
        );
    }

    #[tokio::test]
    async fn input_disconnect_does_not_erase_media_error_during_cleanup() {
        let (failed, observed) = tokio::sync::oneshot::channel();
        let media = async {
            failed.send(()).unwrap();
            // Model producer shutdown after dropping a failed media sender.
            tokio::time::sleep(Duration::from_millis(10)).await;
            anyhow::bail!("original GPU failure")
        };
        let mut observed = Some(observed);
        let input = async || {
            observed.take().unwrap().await.unwrap();
            anyhow::bail!("input disconnected after media failure")
        };
        let error = drive_media_with_input::<()>(media, input)
            .await
            .unwrap_err();
        assert_eq!(error.root_cause().to_string(), "original GPU failure");
        assert!(format!("{error:#}").contains("input disconnected after media failure"));
    }
}
