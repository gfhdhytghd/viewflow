//! Cursor capture on the atlas connection. This worker never owns a socket reader.
use anyhow::{Context, Result, bail, ensure};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot, watch};
use viewflow_hyprland::capture_wire::{CaptureCommand, CaptureReceipt};
use viewflow_protocol::{
    DesktopRect, Id128, InputEvent, InputEventKind, InputLease, InputLeaseState,
};

#[derive(Clone, Copy)]
pub(crate) struct DragTransfer {
    pub window: viewflow_protocol::WindowId,
    pub target: viewflow_hyprland::capture_wire::DragTarget,
    pub handed_off: bool,
    pub resizing: bool,
    pub move_confirmed: bool,
}
pub(crate) type SharedDragTransfer = std::sync::Arc<tokio::sync::Mutex<Option<DragTransfer>>>;

pub(crate) struct CursorConfig {
    pub drag: SharedDragTransfer,
    pub reverse_drag: crate::reverse_bridge::SharedNativeDrag,
    pub remote_scale: f64,
    pub position_offset: (f64, f64),
    pub position_scale: (f64, f64),
    pub ready_file: Option<std::path::PathBuf>,
    pub local: Vec<DesktopRect>,
    pub remote: DesktopRect,
    pub monitor_id: i64,
    pub topology_generation: u64,
    pub owner: Id128,
    pub target: Id128,
    pub fps: u32,
}
impl CursorConfig {
    fn position(&self, x: f64, y: f64) -> Result<InputEventKind> {
        position((x + self.position_offset.0) * self.position_scale.0,
                 (y + self.position_offset.1) * self.position_scale.1)
    }
}
#[derive(Default)]
struct NativeCaptureQueue {
    queued: std::sync::Mutex<std::collections::VecDeque<(Vec<u8>, Instant)>>,
    ready: tokio::sync::Notify,
}
impl NativeCaptureQueue {
    fn push(&self, mut packet: Vec<u8>, received: Instant) -> Result<()> {
        let mut queue = self.queued.lock().map_err(|_| anyhow::anyhow!("capture queue poisoned"))?;
        if let Some((previous, previous_time)) = queue.back_mut() {
            // Adjacent relative motions can be summed without crossing a key,
            // button, wheel, lease boundary, or native sequence regression.
            if packet.len() == 88 && previous.len() == 88
                && packet[6..8] == 31u16.to_le_bytes() && previous[6..8] == packet[6..8]
                && packet[20..44] == previous[20..44]
                && u64_at(&packet, 44)? > u64_at(previous, 44)? {
                let dx = double(&packet, 56)? + double(previous, 56)?;
                let dy = double(&packet, 64)? + double(previous, 64)?;
                ensure!(dx.is_finite() && dy.is_finite(), "capture motion accumulation overflow");
                packet[56..64].copy_from_slice(&dx.to_le_bytes());
                packet[64..72].copy_from_slice(&dy.to_le_bytes());
                *previous = packet;
                *previous_time = received;
                return Ok(());
            }
        }
        ensure!(queue.len() < 4096, "capture ordered control resource exhausted");
        queue.push_back((packet, received));
        drop(queue);
        self.ready.notify_one();
        Ok(())
    }
    async fn recv(&self) -> (Vec<u8>, Instant) {
        loop {
            let notified = self.ready.notified();
            if let Some(event) = self.queued.lock().expect("capture queue poisoned").pop_front() {
                return event;
            }
            notified.await;
        }
    }
}

#[derive(Debug)]
struct NativeCaptureRejected;
impl std::fmt::Display for NativeCaptureRejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str("native capture command rejected") }
}
impl std::error::Error for NativeCaptureRejected {}

struct NativeRequest {
    deadline: tokio::time::Instant,
    command: CaptureCommand,
    reply: oneshot::Sender<Result<()>>,
}
pub(crate) struct CursorBridge {
    phase: std::sync::Arc<std::sync::atomic::AtomicU8>,
    events: std::sync::Arc<NativeCaptureQueue>,
    commands: mpsc::Receiver<NativeRequest>,
    pending: Option<NativeRequest>,
    clocks: watch::Sender<Option<crate::input_runtime::ClockSnapshot>>,
    task: tokio::task::JoinHandle<Result<()>>,
}
impl Drop for CursorBridge {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl CursorBridge {
    #[cfg(test)]
    pub(crate) fn fixture() -> Self {
        let events = std::sync::Arc::new(NativeCaptureQueue::default());
        let (_, commands) = mpsc::channel(4);
        let (clocks, _) = watch::channel(None);
        Self {
            phase: std::sync::Arc::new(std::sync::atomic::AtomicU8::new(0)),
            events,
            commands,
            pending: None,
            clocks,
            task: tokio::spawn(std::future::pending()),
        }
    }

    pub fn start(
        config: CursorConfig,
        writer: crate::shared_control::SharedControlSender,
        network: quinn::Connection,
        origin: Instant,
        phase: std::sync::Arc<std::sync::atomic::AtomicU8>,
    ) -> Self {
        let events = std::sync::Arc::new(NativeCaptureQueue::default());
        let receive = events.clone();
        let (commands, requests) = mpsc::channel(4);
        let (clocks, clock) = watch::channel(None);
        let task = tokio::spawn(async move {
            let result = run(config, writer, origin, receive, commands, clock).await;
            retire_on_failure(&network, &result);
            result
        });
        Self {
            phase,
            events,
            commands: requests,
            pending: None,
            clocks,
            task,
        }
    }
    pub(crate) fn pending_release_generation(&self) -> Option<u64> {
        self.pending.as_ref().and_then(|request| {
            match request.command {
                CaptureCommand::Release { generation, .. } => Some(generation),
                _ => None,
            }
        })
    }
    #[cfg(test)]
    pub(crate) fn fixture_pending_release(
        generation: u64,
    ) -> (Self, oneshot::Receiver<Result<()>>) {
        let mut bridge = Self::fixture();
        let (reply, receive) = oneshot::channel();
        bridge.pending = Some(NativeRequest {
            command: CaptureCommand::Release {
                generation,
                drag_target: None,
                return_position: None,
            },
            deadline: tokio::time::Instant::now() + Duration::from_secs(1),
            reply,
        });
        (bridge, receive)
    }
    pub fn local_takeover(&self) {
        self.phase.store(2, std::sync::atomic::Ordering::Release);
    }
    pub fn metadata(&self, bytes: &[u8]) -> Result<bool> {
        if bytes.len() < 20 {
            return Ok(false);
        }
        let tag = u16::from_le_bytes(bytes[6..8].try_into()?);
        if !(30..=37).contains(&tag) {
            return Ok(false);
        }
        let mut received = Instant::now();
        let time_offset = match tag {
            30 => Some(53),
            31..=33 | 35 => Some(52),
            _ => None,
        };
        if let Some(offset) = time_offset {
            let timestamp = u32::from_le_bytes(
                bytes
                    .get(offset..offset + 4)
                    .context("short native input timestamp")?
                    .try_into()?,
            );
            let native_now = (crate::window_input_runtime::native_clock_ns()? / 1_000_000) as u32;
            let age = native_now.wrapping_sub(timestamp).saturating_add(1);
            // Preserve age for the worker, which can release the active
            // lease locally. A late packet must not kill the shared dispatcher.
            received = received
                .checked_sub(Duration::from_millis(u64::from(age)))
                .context("native event timestamp underflow")?;
        }
        self.events.push(bytes.to_vec(), received)?;
        Ok(true)
    }
    pub fn receipt(&mut self, receipt: CaptureReceipt) -> Result<()> {
        let request = self
            .pending
            .take()
            .context("unsolicited cursor capture receipt")?;
        // The native Connection validates generation and command against its pending record.
        if tokio::time::Instant::now() > request.deadline {
            eprintln!("cursor native receipt delayed; applied={}", receipt.applied);
        }
        let result = if receipt.applied {
            Ok(())
        } else {
            Err(NativeCaptureRejected.into())
        };
        let _ = request.reply.send(result);
        // Deliver a negative receipt to the handoff worker so it can revoke
        // this lease. The shared native/video dispatcher remains available.
        Ok(())
    }
    /// Called by the sole native owner only with no window command in flight.
    pub fn pending(&self) -> bool {
        self.pending.is_some()
    }
    pub fn service(
        &mut self,
        connection: &mut viewflow_hyprland::window_pointer_socket::Connection,
        clock: Option<crate::input_runtime::ClockSnapshot>,
    ) -> Result<bool> {
        self.clocks.send_replace(clock);
        ensure!(!self.task.is_finished(), "cursor handoff worker stopped");
        if self.pending.is_none() {
            match self.commands.try_recv() {
                Ok(request) => {
                    connection.send_capture(request.command)?;
                    self.pending = Some(request);
                }
                Err(mpsc::error::TryRecvError::Empty) => {}
                Err(_) => bail!("cursor native command queue closed"),
            }
        }
        Ok(self.pending.is_some())
    }
}
async fn native(
    commands: &mpsc::Sender<NativeRequest>,
    command: CaptureCommand,
    deadline: tokio::time::Instant,
) -> Result<()> {
    let (reply, result) = oneshot::channel();
    commands.send(NativeRequest { command, reply, deadline }).await?;
    // Once queued, finish the native operation; a late receipt still describes
    // the actual capture state and must not be replaced by a guessed rollback.
    result.await??;
    if tokio::time::Instant::now() > deadline {
        eprintln!("cursor native operation delayed; receipt confirmed");
    }
    Ok(())
}
fn contains(rect: DesktopRect, x: f64, y: f64) -> bool {
    x >= rect.x_millidip as f64 / 1000.
        && y >= rect.y_millidip as f64 / 1000.
        && x < (rect.x_millidip as f64 + rect.width_millidip as f64) / 1000.
        && y < (rect.y_millidip as f64 + rect.height_millidip as f64) / 1000.
}
fn double(bytes: &[u8], offset: usize) -> Result<f64> {
    let value = f64::from_le_bytes(
        bytes
            .get(offset..offset + 8)
            .context("short cursor packet")?
            .try_into()?,
    );
    ensure!(value.is_finite(), "nonfinite cursor packet");
    Ok(value)
}
fn u64_at(bytes: &[u8], offset: usize) -> Result<u64> {
    Ok(u64::from_le_bytes(
        bytes
            .get(offset..offset + 8)
            .context("short cursor packet")?
            .try_into()?,
    ))
}
fn position(x: f64, y: f64) -> Result<InputEventKind> {
    ensure!(
        x.is_finite() && y.is_finite() && x.abs() < 1e9 && y.abs() < 1e9,
        "invalid global cursor position"
    );
    Ok(InputEventKind::DesktopPointerPosition(
        viewflow_protocol::DesktopPointerPosition {
            x_millidip: (x * 1000.).round() as i64,
            y_millidip: (y * 1000.).round() as i64,
        },
    ))
}
// Claim only the shared edge, within two physical remote pixels and while
// moving toward the local screen. Other Windows edges retain native Snap.
fn drag_seam_return(local: DesktopRect, remote: DesktopRect, scale: f64,
    previous: (f64, f64), current: (f64, f64)) -> Option<(f64, f64)> {
    let (lx, ly) = (local.x_millidip as f64 / 1000., local.y_millidip as f64 / 1000.);
    let (lr, lb) = (lx + local.width_millidip as f64 / 1000., ly + local.height_millidip as f64 / 1000.);
    let (rx, ry) = (remote.x_millidip as f64 / 1000., remote.y_millidip as f64 / 1000.);
    let (rr, rb) = (rx + remote.width_millidip as f64 / 1000., ry + remote.height_millidip as f64 / 1000.);
    let (x, y) = current;
    let band = 2. / scale;
    if (lr-rx).abs() < 0.001 && x < previous.0 && x <= rx+band && x >= lx && y >= ly.max(ry) && y < lb.min(rb) {
        return Some((x.min(lr-0.001), y));
    }
    if (rr-lx).abs() < 0.001 && x > previous.0 && x >= rr-band && x < lr && y >= ly.max(ry) && y < lb.min(rb) {
        return Some((x.max(lx), y));
    }
    if (lb-ry).abs() < 0.001 && y < previous.1 && y <= ry+band && y >= ly && x >= lx.max(rx) && x < lr.min(rr) {
        return Some((x, y.min(lb-0.001)));
    }
    if (rb-ly).abs() < 0.001 && y > previous.1 && y >= rb-band && y < lb && x >= lx.max(rx) && x < lr.min(rr) {
        return Some((x, y.max(ly)));
    }
    None
}

async fn run(
    config: CursorConfig,
    writer: crate::shared_control::SharedControlSender,
    origin: Instant,
    events: std::sync::Arc<NativeCaptureQueue>,
    commands: mpsc::Sender<NativeRequest>,
    _clocks: watch::Receiver<Option<crate::input_runtime::ClockSnapshot>>,
) -> Result<()> {
    ensure!(
        config.fps > 0 && config.monitor_id >= 0 && config.remote_scale.is_finite() && config.remote_scale > 0.0,
        "invalid cursor capture policy"
    );
    for local in &config.local {
        local.validate().map_err(|e| anyhow::anyhow!("local desktop: {e:?}"))?;
    }
    config
        .remote
        .validate()
        .map_err(|e| anyhow::anyhow!("remote desktop: {e:?}"))?;
    let motion_budget =
        Duration::from_nanos((2_000_000_000 / u64::from(config.fps)).min(33_333_334));
    let budget = Duration::from_nanos(crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS);
    native(
        &commands,
        CaptureCommand::Configure {
            generation: config.topology_generation,
            monitor_id: config.monitor_id,
            x: config.remote.x_millidip as f64 / 1000.,
            y: config.remote.y_millidip as f64 / 1000.,
            width: config.remote.width_millidip as f64 / 1000.,
            height: config.remote.height_millidip as f64 / 1000.,
        },
        tokio::time::Instant::now() + budget,
    )
    .await?;
    eprintln!(
        "atlas-cursor-handoff phase=configured topology_generation={} local_displays={:?}",
        config.topology_generation, config.local
    );
    if let Some(path) = &config.ready_file {
        std::fs::write(path, format!("{}\n", std::process::id()))?;
    }
    let mut generation = 0u64;
    let mut active = false;
    let mut x = 0.;
    let mut y = 0.;
    let mut sequence = 0u64;
    let mut native_sequence = None;
    loop {
        let (packet, received) = events.recv().await;
        let tag = u16::from_le_bytes(packet[6..8].try_into()?);
        let bytes = &packet[20..];
        // The native FIFO may still contain packets from the now-revoked lease.
        // Their timestamps cannot revive input or invalidate confirmed cleanup.
        if revoked_capture_tail(active, tag) {
            continue;
        }
        let event_budget = if tag == 31 { motion_budget } else { budget };
        let deadline = tokio::time::Instant::now() + budget;
        if active && Instant::now() >= received + motion_budget && tag == 31 {
            // Late motion is disposable; keep the integrated position so the
            // next real sample/button uses the right coordinates. It must not
            // release a held Win key or abandon capture in the middle of a drag.
            ensure!(
                bytes.len() == 68
                    && u64_at(bytes, 0)? == generation
                    && bytes[8..24] == config.target.0.to_be_bytes(),
                "cursor native lease mismatch"
            );
            let next = u64_at(bytes, 24)?;
            ensure!(
                native_sequence.is_none_or(|old| next > old),
                "cursor native event replay"
            );
            native_sequence = Some(next);
            (x, y) = advance_displays(
                &config.local,
                config.remote,
                (x, y),
                (double(bytes, 36)?, double(bytes, 44)?),
            );
            continue;
        }
        let previous_position = (x, y);
        let event = if tag == 30 {
            ensure!(
                !active && (bytes.len() == 37 || bytes.len() == 53),
                "unexpected cursor edge candidate"
            );
            x = double(bytes, 17)?;
            y = double(bytes, 25)?;
            let local = config.local.iter().copied().find(|local| contains(*local, x, y))
                .context("cursor entry outside local displays")?;
            match bytes[8] {
                0 => x = local.x_millidip as f64 / 1000. - 0.001,
                1 => {
                    x = (local.x_millidip as f64 + local.width_millidip as f64)
                        / 1000.
                }
                2 => y = local.y_millidip as f64 / 1000. - 0.001,
                3 => {
                    y = (local.y_millidip as f64 + local.height_millidip as f64)
                        / 1000.
                }
                _ => bail!("invalid shared edge"),
            }
            if bytes.len() == 53 {
                x = double(bytes, 37)?;
                y = double(bytes, 45)?;
            }
            ensure!(
                contains(config.remote, x, y),
                "cursor edge does not adjoin configured remote rectangle"
            );
            for state in [InputLeaseState::Offered, InputLeaseState::Active] {
                generation = generation
                    .checked_add(1)
                    .context("cursor lease exhausted")?;
                writer
                    .send(
                        crate::input_runtime::input_lease_payload(InputLease {
                            generation,
                            owner: config.owner,
                            route_to: config.target,
                            state,
                        }),
                        deadline,
                    )
                    .await?;
            }
            if let Err(error) = native(
                &commands,
                CaptureCommand::Activate {
                    generation,
                    target: config.target.0.to_be_bytes(),
                    loopback: true,
                },
                deadline,
            )
            .await
            {
                eprintln!(
                    "atlas-cursor-handoff phase=activation-rejected generation={generation} reason={error:#}"
                );
                generation = rollback_capture(
                    &config,
                    &writer,
                    &commands,
                    generation,
                    budget,
                )
                .await?;
                active = false;
                native_sequence = None;
                continue;
            }
            eprintln!(
                "atlas-cursor-handoff phase=native-active generation={generation} x={x} y={y}"
            );
            active = true;
            sequence = 0;
            native_sequence = None;
            config.position(x, y)?
        } else {
            // Late capture packets from a successfully revoked lease cannot create another lease.
            if !active {
                continue;
            }
            ensure!(
                bytes.len() >= 32
                    && u64_at(bytes, 0)? == generation
                    && bytes[8..24] == config.target.0.to_be_bytes(),
                "cursor native lease mismatch"
            );
            let next = u64_at(bytes, 24)?;
            ensure!(
                native_sequence.is_none_or(|old| next > old),
                "cursor native event replay"
            );
            native_sequence = Some(next);
            match tag {
                31 => {
                    ensure!(bytes.len() == 68, "invalid motion packet");
                    (x, y) = advance_displays(
                        &config.local,
                        config.remote,
                        (x, y),
                        (double(bytes, 36)?, double(bytes, 44)?),
                    );
                    config.position(x, y)?
                }
                32 => {
                    ensure!(bytes.len() == 41, "invalid button packet");
                    let code = u32::from_le_bytes(bytes[36..40].try_into()?);
                    let button = match code {
                        272 => viewflow_protocol::PointerButton::Left,
                        273 => viewflow_protocol::PointerButton::Right,
                        274 => viewflow_protocol::PointerButton::Middle,
                        275 => viewflow_protocol::PointerButton::Back,
                        276 => viewflow_protocol::PointerButton::Forward,
                        _ => bail!("unsupported captured button"),
                    };
                    ensure!(bytes[40] <= 1, "invalid button state");
                    InputEventKind::PointerButton(viewflow_protocol::PointerButtonEvent {
                        button,
                        state: if bytes[40] == 1 {
                            viewflow_protocol::InputSwitchState::Pressed
                        } else {
                            viewflow_protocol::InputSwitchState::Released
                        },
                    })
                }
                33 => {
                    ensure!(bytes.len() == 60, "invalid wheel packet");
                    let axis = u32::from_le_bytes(bytes[40..44].try_into()?);
                    let delta = double(bytes, 48)? / 15.;
                    if delta == 0. {
                        continue;
                    }
                    ensure!(axis <= 1, "invalid wheel axis");
                    InputEventKind::PointerWheel(viewflow_protocol::PointerWheelEvent {
                        vertical_delta_detents: if axis == 0 { -delta } else { 0. },
                        horizontal_delta_detents: if axis == 1 { delta } else { 0. },
                    })
                }
                34 => continue,
                35 => {
                    ensure!(
                        bytes.len() == 42 && bytes[40] <= 1,
                        "invalid captured keyboard packet"
                    );
                    let code = u32::from_le_bytes(bytes[36..40].try_into()?);
                    InputEventKind::KeyboardHidUsage(viewflow_protocol::KeyboardHidUsage {
                        usage_page: 7,
                        usage_id: keyboard_usage(code).context("unsupported captured key")?,
                        state: if bytes[40] == 1 {
                            viewflow_protocol::InputSwitchState::Pressed
                        } else {
                            viewflow_protocol::InputSwitchState::Released
                        },
                        repeat: false,
                    })
                }
                37 => {
                    ensure!(bytes.len() == 104, "invalid touchpad packet");
                    let word = |offset| -> Result<u32> { Ok(u32::from_le_bytes(bytes[offset..offset+4].try_into()?)) };
                    let count = word(40)?;
                    ensure!(count <= 5, "invalid touchpad count");
                    let mut frame = viewflow_protocol::TouchpadFrame {
                        width: word(32)?, height: word(36)?, count: count as u8,
                        ..viewflow_protocol::TouchpadFrame::default()
                    };
                    for (i, c) in frame.contacts.iter_mut().enumerate() {
                        let base = 44 + i * 12;
                        *c = viewflow_protocol::TouchpadContact { id: word(base)?, x: word(base+4)?, y: word(base+8)? };
                    }
                    frame.validate().map_err(|e| anyhow::anyhow!("invalid touchpad frame: {e:?}"))?;
                    InputEventKind::Touchpad(frame)
                }
                36 => InputEventKind::ReleaseAll,
                _ => bail!("unexpected capture packet"),
            }
        };
        // Serialize takeover with source geometry writes. Once claimed, queued
        // remote Update/End messages must not move this native drag backwards.
        let mut transfer = config.drag.lock().await;
        let mut reverse_drag = config.reverse_drag.lock().await;
        let candidate = transfer.as_ref().filter(|drag| !drag.handed_off && !drag.resizing && drag.move_confirmed);
        let seam_return = if tag == 31 && (candidate.is_some() || reverse_drag.as_ref().is_some_and(|drag| !drag.handed_off)) {
            config.local.iter().find_map(|local| drag_seam_return(*local, config.remote, config.remote_scale, previous_position, (x, y)))
        } else { None };
        if let Some(point) = seam_return { (x, y) = point; }
        if config.local.iter().any(|local| contains(*local, x, y)) || matches!(event, InputEventKind::ReleaseAll) {
            let drag_target = if config.local.iter().any(|local| contains(*local, x, y)) && tag == 31 {
                transfer.as_mut().filter(|drag| !drag.handed_off && !drag.resizing && drag.move_confirmed).map(|drag| {
                    drag.target
                }).or_else(|| reverse_drag.as_mut().filter(|drag| !drag.handed_off).map(|drag| {
                    viewflow_hyprland::capture_wire::DragTarget { pid: drag.pid, address: drag.address, surface: 0, reverse_id: drag.id }
                }))
            } else { None };
            let native_generation = generation;
            generation = generation
                .checked_add(1)
                .context("cursor lease exhausted")?;
            crate::send_desktop_revoke_confirmed(
                &writer.outbound(),
                viewflow_protocol::InputLeaseRevoke {
                    operation_id: Id128(u128::from(generation)),
                    lease_generation: generation,
                    owner_device: config.owner,
                    target_device: config.target,
                    state: InputLeaseState::Revoked,
                },
                deadline,
            )
            .await
            .map_err(|e| anyhow::anyhow!("cursor revoke: {e:?}"))?;
            let returned = native(
                &commands,
                CaptureCommand::Release {
                    generation: native_generation,
                    drag_target,
                return_position: if config.local.iter().any(|local| contains(*local, x, y)) {
                        Some((x, y))
                    } else {
                        None
                    },
                },
                deadline,
            )
            .await;
            if let Err(error) = returned {
                eprintln!("atlas-cursor-handoff return rejected: {error:#}; releasing locally without drag");
                if !error.is::<NativeCaptureRejected>() { return Err(error); }
                release_capture_locally(&commands, native_generation, budget).await?;
            } else if let Some(target) = drag_target {
                if let Some(drag) = transfer.as_mut().filter(|drag| drag.target == target) { drag.handed_off = true; }
                if let Some(drag) = reverse_drag.as_mut().filter(|drag| drag.id == target.reverse_id) { drag.handed_off = true; }
            }
            eprintln!(
                "atlas-cursor-handoff phase=return-complete generation={generation} x={x} y={y}"
            );
            active = false;
            continue;
        }
        drop(transfer);
        drop(reverse_drag);
        // Clamp only nonshared exterior boundaries; local return was checked first.
        x = x.clamp(
            config.remote.x_millidip as f64 / 1000.,
            (config.remote.x_millidip as f64 + config.remote.width_millidip as f64) / 1000. - 0.001,
        );
        y = y.clamp(
            config.remote.y_millidip as f64 / 1000.,
            (config.remote.y_millidip as f64 + config.remote.height_millidip as f64) / 1000.
                - 0.001,
        );
        let event = if matches!(event, InputEventKind::DesktopPointerPosition(_)) {
            config.position(x, y)?
        } else {
            event
        };
        if matches!(event, InputEventKind::PointerButton(_) | InputEventKind::PointerWheel(_)) {
            // Motion may have been coalesced. Send the latest position before
            // the transition on the same ordered stream; no round trip is needed.
            sequence = sequence.checked_add(1).context("cursor sequence exhausted")?;
            let positioned = InputEvent {
                lease_generation: generation,
                target_device: config.target,
                sequence,
                sender_not_after_ns: sender_event_expiry(
                    u64::try_from(received.duration_since(origin).as_nanos())?,
                    crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS)?,
                event: config.position(x, y)?,
            };
            writer.send(crate::input_runtime::input_event_payload(positioned), deadline).await?;
        }
        sequence = sequence
            .checked_add(1)
            .context("cursor sequence exhausted")?;
        let sender_not_after_ns = sender_event_expiry(
            u64::try_from(received.duration_since(origin).as_nanos())?,
            u64::try_from(event_budget.as_nanos())?,
        )?;
        let event = InputEvent {
            lease_generation: generation,
            target_device: config.target,
            sequence,
            sender_not_after_ns,
            event,
        };
        // Completion here means transport write only. Receiver injection runs
        // in the same FIFO order and does not send per-event Applied replies.
        writer
            .send(crate::input_runtime::input_event_payload(event), deadline)
            .await?;
    }
}

fn retire_on_failure(network: &quinn::Connection, result: &Result<()>) {
    if let Err(error) = result {
        eprintln!("atlas-cursor-handoff failed: {error:#}");
        network.close(0u32.into(), b"cursor handoff failed");
    }
}

fn revoked_capture_tail(active: bool, tag: u16) -> bool {
    !active && (31..=37).contains(&tag)
}

async fn release_capture_locally(
    commands: &mpsc::Sender<NativeRequest>, generation: u64, budget: Duration,
) -> Result<()> {
    loop {
        match native(commands, CaptureCommand::Release {
            generation, drag_target: None, return_position: None,
        }, tokio::time::Instant::now() + budget).await {
            Ok(()) => return Ok(()),
            Err(error) if error.is::<NativeCaptureRejected>() => {
                eprintln!("cursor local release rejected; retaining session and retrying cleanup");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            Err(error) => return Err(error),
        }
    }
}

async fn rollback_capture(
    config: &CursorConfig,
    writer: &crate::shared_control::SharedControlSender,
    commands: &mpsc::Sender<NativeRequest>,
    generation: u64,
    budget: Duration,
) -> Result<u64> {
    // The revoke follows all prior input on the same ordered stream and
    // confirms native release, without waiting for per-event acknowledgments.
    let revoked_generation = generation
        .checked_add(1)
        .context("cursor lease exhausted")?;
    // Track cleanup latency independently from the triggering event. A delayed
    // receipt retains the route; only actual transport/owner loss is fatal.
    let cleanup_deadline = tokio::time::Instant::now() + budget;
    crate::send_desktop_revoke_confirmed(
        &writer.outbound(),
        viewflow_protocol::InputLeaseRevoke {
            operation_id: Id128(u128::from(revoked_generation)),
            lease_generation: revoked_generation,
            owner_device: config.owner,
            target_device: config.target,
            state: InputLeaseState::Revoked,
        },
        cleanup_deadline,
    )
    .await
    .map_err(|error| anyhow::anyhow!("cursor rollback receiver cleanup: {error:?}"))?;
    release_capture_locally(commands, generation, budget).await
        .context("cursor rollback native release")?;
    eprintln!(
        "atlas-cursor-handoff phase=rollback-complete generation={revoked_generation} requires=fresh-physical-edge"
    );
    Ok(revoked_generation)
}

fn sender_event_expiry(original_event_ns: u64, original_budget_ns: u64) -> Result<u64> {
    // The peer first checks the mapped horizon, before subtracting clock
    // uncertainty. Spending the entire horizon would reject legitimate events
    // when its current offset estimate maps the expiry slightly into the future.
    // Reserve the existing maximum sample uncertainty plus maximum sample-age
    // drift, without retimestamping the physical event or extending its ACK.
    let wire_budget = original_budget_ns
        .checked_sub(crate::input_runtime::INPUT_CLOCK_MAPPING_HEADROOM_NS)
        .filter(|budget| *budget > 0)
        .context("cursor event budget cannot cover clock mapping headroom")?;
    original_event_ns
        .checked_add(wire_budget)
        .context("cursor event expiry overflow")
}

#[cfg(test)]
async fn drain_applied(applied: &mut tokio::task::JoinSet<Result<()>>) -> Result<()> {
    while let Some(result) = applied.join_next().await {
        result??;
    }
    Ok(())
}

#[cfg(test)]
async fn await_cursor_ack(
    mut pending: crate::PendingInputAck,
    deadline: tokio::time::Instant,
    motion: bool,
) -> Result<()> {
    let result = pending
        .wait_until(deadline)
        .await
        .map_err(|error| anyhow::anyhow!("cursor ACK watchdog: {error:?}"))?;
    // A rejected obsolete motion has no held state to unwind.
    if motion && result == viewflow_protocol::InputAppliedResult::RejectedExpired {
        return Ok(());
    }
    crate::classify_input_result(result)
        .map_err(|error| anyhow::anyhow!("cursor applied result: {error:?}"))
}

#[cfg(test)]
async fn await_applied(
    pending: crate::PendingInputAck,
    deadline: tokio::time::Instant,
) -> Result<()> {
    await_cursor_ack(pending, deadline, false).await
}

/// Standard Linux evdev keyboard positions mapped to USB keyboard usages.
fn keyboard_usage(code: u32) -> Option<u16> {
    const LETTERS: [u32; 26] = [
        30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17,
        45, 21, 44,
    ];
    if let Some(index) = LETTERS.iter().position(|key| *key == code) {
        return Some(4 + index as u16);
    }
    Some(match code {
        2..=10 => 0x1e + (code - 2) as u16,
        11 => 0x27,
        28 => 0x28,
        1 => 0x29,
        14 => 0x2a,
        15 => 0x2b,
        57 => 0x2c,
        12 => 0x2d,
        13 => 0x2e,
        26 => 0x2f,
        27 => 0x30,
        43 => 0x31,
        39 => 0x33,
        40 => 0x34,
        41 => 0x35,
        51 => 0x36,
        52 => 0x37,
        53 => 0x38,
        58 => 0x39,
        59..=68 => 0x3a + (code - 59) as u16,
        87 => 0x44,
        88 => 0x45,
        99 => 0x46,
        70 => 0x47,
        110 => 0x49,
        102 => 0x4a,
        104 => 0x4b,
        111 => 0x4c,
        107 => 0x4d,
        109 => 0x4e,
        106 => 0x4f,
        105 => 0x50,
        108 => 0x51,
        103 => 0x52,
        69 => 0x53,
        98 => 0x54,
        55 => 0x55,
        74 => 0x56,
        78 => 0x57,
        96 => 0x58,
        79 => 0x59,
        80 => 0x5a,
        81 => 0x5b,
        75 => 0x5c,
        76 => 0x5d,
        77 => 0x5e,
        71 => 0x5f,
        72 => 0x60,
        73 => 0x61,
        82 => 0x62,
        83 => 0x63,
        86 => 0x64,
        127 => 0x65,
        29 => 0xe0,
        42 => 0xe1,
        56 => 0xe2,
        125 => 0xe3,
        97 => 0xe4,
        54 => 0xe5,
        100 => 0xe6,
        126 => 0xe7,
        _ => return None,
    })
}

/// Use each real display separately: a bounding box would create paths through gaps.
fn advance_displays(locals: &[DesktopRect], remote: DesktopRect,
    previous: (f64, f64), delta: (f64, f64)) -> (f64, f64) {
    for local in locals {
        let point = advance(*local, remote, previous, delta);
        if contains(*local, point.0, point.1) { return point; }
    }
    (previous.0 + delta.0, previous.1 + delta.1)
}

pub(crate) fn local_displays(socket: &std::path::Path, remote_id: i64) -> Result<Vec<DesktopRect>> {
    let ipc = viewflow_hyprland::HyprIpcClient::new(socket.to_path_buf());
    let monitors = viewflow_hyprland::parse_monitors(&ipc.request("j/monitors")?)?;
    monitors.into_iter().filter(|monitor| !monitor.disabled && monitor.id != remote_id)
        .map(|monitor| {
            let bounds = monitor.bounds_dip();
            let rect = DesktopRect {
                x_millidip: (bounds.origin.x * 1000.).round() as i64,
                y_millidip: (bounds.origin.y * 1000.).round() as i64,
                width_millidip: (bounds.size.width * 1000.).round() as u64,
                height_millidip: (bounds.size.height * 1000.).round() as u64,
            };
            rect.validate().map_err(|e| anyhow::anyhow!("local display: {e:?}"))?;
            Ok(rect)
        }).collect()
}

/// Detect crossing of the shared seam even when one motion skips the whole local display.
fn advance(
    local: DesktopRect,
    remote: DesktopRect,
    previous: (f64, f64),
    delta: (f64, f64),
) -> (f64, f64) {
    let (x, y) = previous;
    let (dx, dy) = delta;
    let l = local.x_millidip as f64 / 1000.;
    let t = local.y_millidip as f64 / 1000.;
    let r = l + local.width_millidip as f64 / 1000.;
    let b = t + local.height_millidip as f64 / 1000.;
    let rl = remote.x_millidip as f64 / 1000.;
    let rt = remote.y_millidip as f64 / 1000.;
    let rr = rl + remote.width_millidip as f64 / 1000.;
    let rb = rt + remote.height_millidip as f64 / 1000.;
    let crossing = if r == rl && dx < 0. {
        Some(((r - x) / dx, true))
    } else if l == rr && dx > 0. {
        Some(((l - x) / dx, true))
    } else if b == rt && dy < 0. {
        Some(((b - y) / dy, false))
    } else if t == rb && dy > 0. {
        Some(((t - y) / dy, false))
    } else {
        None
    };
    if let Some((at, vertical)) = crossing {
        if (0.0..=1.0).contains(&at) {
            let cx = x + dx * at;
            let cy = y + dy * at;
            if (vertical && cy >= t && cy < b) || (!vertical && cx >= l && cx < r) {
                return ((x + dx).clamp(l, r - 0.001), (y + dy).clamp(t, b - 0.001));
            }
        }
    }
    (x + dx, y + dy)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bottom_neighbor_supports_pointer_and_drag_without_filling_gap() {
        let main = DesktopRect { x_millidip: 0, y_millidip: 0,
            width_millidip: 3_072_000, height_millidip: 1_728_000 };
        let remote = DesktopRect { x_millidip: 3_072_000, y_millidip: 390_000,
            width_millidip: 1_920_000, height_millidip: 1_200_000 };
        let bottom = DesktopRect { x_millidip: 3_072_000, y_millidip: 1_590_000,
            width_millidip: 1_376_000, height_millidip: 1_032_000 };
        let locals = [main, bottom];
        for delta in [(0., 3.), (0., 3000.)] {
            let point = advance_displays(&locals, remote, (3500., 1589.), delta);
            assert!(contains(bottom, point.0, point.1));
        }
        let point = advance_displays(&locals, remote, (4800., 1589.), (0., 3.));
        assert!(!locals.iter().any(|local| contains(*local, point.0, point.1)));
        let returned = locals.iter().find_map(|local|
            drag_seam_return(*local, remote, 2., (3500., 1587.), (3500., 1589.)));
        let point = returned.unwrap();
        assert!(contains(bottom, point.0, point.1));
    }

    #[tokio::test]
    async fn cursor_without_any_event_acks_preserves_connection_and_click_position() {
        use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};
        let (_client, _server, connection, remote) = crate::atlas_session::tests::pair().await;
        let owner = crate::shared_control::SharedControlWriter::start(&connection).unwrap();
        let writer = owner.sender();
        let registry = writer.outbound().input_acks.clone();
        let release = Arc::new(AtomicBool::new(false));
        let held = Arc::new(Mutex::new(Vec::new()));
        let (observed, mut events_seen) = mpsc::unbounded_channel();
        let reader = {
            let release = release.clone(); let held = held.clone(); let registry = registry.clone();
            tokio::spawn(async move {
                let mut sequencer = viewflow_transport::ControlSequencer::default();
                loop {
                    let envelope = viewflow_transport::receive_control_sequenced(&remote, &mut sequencer).await.unwrap();
                    if let viewflow_protocol::DomainControl::InputEvent(event) = viewflow_protocol::DomainControl::try_from(envelope).unwrap() {
                        observed.send(event).unwrap();
                        let ack = viewflow_protocol::InputAppliedAck {
                            lease_generation: event.lease_generation, target_device: event.target_device,
                            event_sequence: event.sequence, result: viewflow_protocol::InputAppliedResult::Applied,
                        };
                        if release.load(Ordering::Acquire) { registry.resolve(ack); }
                        else { held.lock().unwrap().push(ack); }
                    }
                }
            })
        };
        let origin = Instant::now();
        let (clock_owner, clock) = watch::channel(None);
        let (commands, mut requests) = mpsc::channel::<NativeRequest>(4);
        let native = tokio::spawn(async move { while let Some(request) = requests.recv().await { let _ = request.reply.send(Ok(())); } });
        let queue = Arc::new(NativeCaptureQueue::default());
        let worker = tokio::spawn(run(CursorConfig {
            drag: Default::default(), reverse_drag: Default::default(), remote_scale: 2.0, position_offset: (-100.0, 0.0), position_scale: (1.0, 0.9), ready_file: None,
            local: vec![rect(0, 0)], remote: rect(100_000, 0), monitor_id: 1,
            topology_generation: 1, owner: Id128(1), target: Id128(2), fps: 60,
        }, writer, origin, queue.clone(), commands, clock));
        let mut edge = vec![0; 57];
        edge[6..8].copy_from_slice(&30u16.to_le_bytes());
        edge[28] = 1;
        edge[37..45].copy_from_slice(&99.0f64.to_le_bytes());
        edge[45..53].copy_from_slice(&50.0f64.to_le_bytes());
        queue.push(edge, Instant::now()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), events_seen.recv()).await.unwrap().unwrap();
        for sequence in 1u64..=80 {
            let mut packet = vec![0; 88];
            packet[6..8].copy_from_slice(&31u16.to_le_bytes());
            packet[20..28].copy_from_slice(&2u64.to_le_bytes());
            packet[28..44].copy_from_slice(&2u128.to_be_bytes());
            packet[44..52].copy_from_slice(&sequence.to_le_bytes());
            packet[56..64].copy_from_slice(&0.25f64.to_le_bytes());
            queue.push(packet, Instant::now()).unwrap();
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
        assert!(held.lock().unwrap().len() > 32);
        assert!(!worker.is_finished() && connection.close_reason().is_none());
        let mut button = vec![0; 61];
        button[6..8].copy_from_slice(&32u16.to_le_bytes());
        button[20..28].copy_from_slice(&2u64.to_le_bytes());
        button[28..44].copy_from_slice(&2u128.to_be_bytes());
        button[44..52].copy_from_slice(&81u64.to_le_bytes());
        button[56..60].copy_from_slice(&272u32.to_le_bytes()); button[60] = 1;
        queue.push(button, Instant::now()).unwrap();
        // Deliberately never acknowledge any ordinary input, including clicks.
        let mut previous = None;
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let event = events_seen.recv().await.unwrap();
                if matches!(event.event, InputEventKind::PointerButton(_)) {
                    let InputEventKind::DesktopPointerPosition(position) = previous.unwrap() else { panic!("click lacks position barrier") };
                    assert_eq!(position.x_millidip, 20_000);
                    assert_eq!(position.y_millidip, 45_000);
                    break;
                }
                previous = Some(event.event);
            }
        }).await.unwrap();
        assert!(!worker.is_finished() && connection.close_reason().is_none());
        // Full touchpad frames use the same FIFO and need no frame/clock ack.
        for (native_sequence, count) in [(82u64, 5u32), (83, 0)] {
            let mut packet = vec![0; 124];
            packet[6..8].copy_from_slice(&37u16.to_le_bytes());
            packet[20..28].copy_from_slice(&2u64.to_le_bytes());
            packet[28..44].copy_from_slice(&2u128.to_be_bytes());
            packet[44..52].copy_from_slice(&native_sequence.to_le_bytes());
            packet[52..56].copy_from_slice(&16000u32.to_le_bytes());
            packet[56..60].copy_from_slice(&11000u32.to_le_bytes());
            packet[60..64].copy_from_slice(&count.to_le_bytes());
            for i in 0..5usize {
                let base = 64 + i * 12;
                packet[base..base+4].copy_from_slice(&(i as u32 + 100).to_le_bytes());
                packet[base+4..base+8].copy_from_slice(&2000u32.to_le_bytes());
                packet[base+8..base+12].copy_from_slice(&4000u32.to_le_bytes());
            }
            queue.push(packet, Instant::now()).unwrap();
            let event = tokio::time::timeout(Duration::from_secs(1), events_seen.recv()).await.unwrap().unwrap();
            let InputEventKind::Touchpad(frame) = event.event else { panic!("touchpad lost in native/network bridge") };
            assert_eq!(u32::from(frame.count), count);
            assert_eq!((frame.width, frame.height), (16000, 11000));
            if count > 0 { assert_eq!(frame.contacts[4].id, 104); }
        }
        assert!(!worker.is_finished() && connection.close_reason().is_none());
        worker.abort(); native.abort(); reader.abort(); drop(clock_owner);
    }

    #[tokio::test]
    async fn stalled_capture_queue_coalesces_motion_without_crossing_button_order() {
        let queue = NativeCaptureQueue::default();
        let start = Instant::now();
        let motion = |sequence: u64, dx: f64| {
            let mut packet = vec![0; 88];
            packet[6..8].copy_from_slice(&31u16.to_le_bytes());
            packet[20..28].copy_from_slice(&2u64.to_le_bytes());
            packet[44..52].copy_from_slice(&sequence.to_le_bytes());
            packet[56..64].copy_from_slice(&dx.to_le_bytes());
            packet
        };
        for sequence in 1..=10_000 {
            queue.push(motion(sequence, 1.0), start).unwrap();
        }
        let mut button = vec![0; 61];
        button[6..8].copy_from_slice(&32u16.to_le_bytes());
        queue.push(button.clone(), start).unwrap();
        for sequence in 10_001..=20_000 {
            queue.push(motion(sequence, -1.0), start).unwrap();
        }
        assert_eq!(queue.queued.lock().unwrap().len(), 3);
        let (first, _) = queue.recv().await;
        assert_eq!(double(&first, 56).unwrap(), 10_000.0);
        assert_eq!(u64_at(&first, 44).unwrap(), 10_000);
        assert_eq!(queue.recv().await.0, button);
        let (last, _) = queue.recv().await;
        assert_eq!(double(&last, 56).unwrap(), -10_000.0);
        assert_eq!(u64_at(&last, 44).unwrap(), 20_000);
    }

    #[tokio::test]
    async fn delayed_click_and_expired_motion_ack_do_not_require_capture_rollback() {
        use crate::input_runtime::{ClockSnapshot, conservative_input_deadline};
        use viewflow_transport::ClockEstimate;
        let start_ns = 1_000_000_000;
        let delayed_ns = start_ns + 80_000_000;
        let expiry =
            sender_event_expiry(start_ns, crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS)
                .unwrap();
        assert!(
            conservative_input_deadline(
                expiry,
                Some(ClockSnapshot {
                    estimate: ClockEstimate {
                        remote_offset_ns: 0,
                        network_round_trip_ns: 0,
                        uncertainty_ns: 0
                    },
                    measured_at_local_ns: delayed_ns,
                }),
                delayed_ns
            )
            .is_ok()
        );
        for (motion, result) in [
            (false, viewflow_protocol::InputAppliedResult::Applied),
            (true, viewflow_protocol::InputAppliedResult::RejectedExpired),
        ] {
            let registry = crate::InputAckRegistry::default();
            let key = crate::InputAckKey {
                lease_generation: 2,
                target_device: Id128(2),
                event_sequence: 1,
            };
            let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
            let mut pending = registry.register(key, deadline).unwrap();
            pending.may_have_been_sent = true;
            tokio::time::sleep(Duration::from_millis(40)).await;
            registry.resolve(viewflow_protocol::InputAppliedAck {
                lease_generation: 2,
                target_device: Id128(2),
                event_sequence: 1,
                result,
            });
            assert!(await_cursor_ack(pending, deadline, motion).await.is_ok());
        }
    }

    #[test]
    fn drag_return_claims_only_two_physical_pixels_toward_shared_edge() {
        let local = rect(0, 0);
        for scale in [1., 1.25, 2., 3.] {
            let band = 2. / scale;
            let remote = rect(100_000, 0);
            let point = drag_seam_return(local, remote, scale, (103., 50.), (100.+band, 50.)).unwrap();
            assert!(contains(local, point.0, point.1));
            assert!(drag_seam_return(local, remote, scale, (104., 50.), (100.+band+0.01, 50.)).is_none());
            assert!(drag_seam_return(local, remote, scale, (100., 50.), (100.+band, 50.)).is_none());
            assert!(drag_seam_return(local, remote, scale, (103., 101.), (100., 101.)).is_none());
        }
        for (remote, previous, current) in [
            (rect(100_000, 0), (105., 40.), (75., 40.)),
            (rect(-100_000, 0), (-5., 40.), (25., 40.)),
            (rect(0, 100_000), (40., 105.), (40., 75.)),
            (rect(0, -100_000), (40., -5.), (40., 25.)),
        ] {
            assert_eq!(drag_seam_return(local, remote, 2., previous, current), Some(current));
        }
    }

    #[test]
    fn revoked_native_tail_is_discarded_without_reading_its_expired_timestamp() {
        for tag in 31..=37 {
            assert!(revoked_capture_tail(false, tag));
            assert!(!revoked_capture_tail(true, tag));
        }
        assert!(!revoked_capture_tail(false, 30)); // A new physical edge still faces freshness.
    }

    #[tokio::test]
    async fn delayed_cleanup_retains_connection_until_receipt_or_actual_failure() {
        use viewflow_protocol::{DomainControl, InputLeaseRevokedAck, InputLeaseRevokedResult};
        use viewflow_transport::{ControlSequencer, receive_control_sequenced};
        for failure in [None, Some("receiver"), Some("native")] {
            let (_client, _server, connection, remote) = crate::atlas_session::tests::pair().await;
            let writer_owner =
                crate::shared_control::SharedControlWriter::start(&connection).unwrap();
            let writer = writer_owner.sender();
            let outbound = writer.outbound();
            let key = crate::InputAckKey {
                lease_generation: 2,
                target_device: Id128(2),
                event_sequence: 708,
            };
            let expired = tokio::time::Instant::now() + Duration::from_millis(1);
            let mut pending = outbound.input_acks.register(key, expired).unwrap();
            pending.may_have_been_sent = true;
            assert!(await_applied(pending, expired).await.is_err());
            let late_ack = viewflow_protocol::InputAppliedAck {
                lease_generation: 2,
                target_device: Id128(2),
                event_sequence: 708,
                result: viewflow_protocol::InputAppliedResult::Applied,
            };
            assert!(matches!(
                outbound.input_acks.resolve(late_ack),
                crate::InputAckResolution::Late(_)
            ));
            let (commands, mut native_requests) = mpsc::channel(4);
            let config = CursorConfig {
                drag: Default::default(), reverse_drag: Default::default(), remote_scale: 2.0, position_offset: (0.0, 0.0), position_scale: (1.0, 1.0), ready_file: None,
                local: vec![rect(0, 0)],
                remote: rect(100_000, 0),
                monitor_id: 1,
                topology_generation: 1,
                owner: Id128(1),
                target: Id128(2),
                fps: 60,
            };
            let network = connection.clone();
            let work = tokio::spawn(async move {
                let result = rollback_capture(
                    &config,
                    &writer,
                    &commands,
                    2,
                    Duration::from_millis(200),
                )
                .await;
                retire_on_failure(
                    &network,
                    &result
                        .as_ref()
                        .map(|_| ())
                        .map_err(|error| anyhow::anyhow!("{error:#}")),
                );
                result
            });
            let envelope = receive_control_sequenced(&remote, &mut ControlSequencer::default())
                .await
                .unwrap();
            let DomainControl::InputLeaseRevoke(revoke) =
                DomainControl::try_from(envelope).unwrap()
            else {
                panic!("rollback must send revoke, never replay input")
            };
            assert_eq!(revoke.lease_generation, 3);
            assert!(
                native_requests.try_recv().is_err(),
                "native release must wait for receiver cleanup ACK"
            );
            tokio::time::sleep(Duration::from_millis(220)).await;
            assert!(!work.is_finished(), "elapsed cleanup target must not retire the session");
            if failure == Some("receiver") {
                outbound.lease_revoke_acks.disconnect("fixture peer disconnected");
            }
            if failure != Some("receiver") {
                assert_eq!(
                    outbound.lease_revoke_acks.resolve(InputLeaseRevokedAck {
                        operation_id: revoke.operation_id,
                        lease_generation: revoke.lease_generation,
                        owner_device: revoke.owner_device,
                        target_device: revoke.target_device,
                        state: revoke.state,
                        result: InputLeaseRevokedResult::Applied,
                    }),
                    crate::LeaseRevokeAckResolution::Delivered
                );
                let request = native_requests.recv().await.unwrap();
                assert!(matches!(
                    request.command,
                    CaptureCommand::Release {
                        generation: 2,
                        drag_target: None,
                return_position: None
                    }
                ));
                assert!(
                    !work.is_finished(),
                    "native transport enqueue is not release confirmation"
                );
                request
                    .reply
                    .send(if failure == Some("native") {
                        Err(anyhow::anyhow!("native cleanup unconfirmed"))
                    } else {
                        Ok(())
                    })
                    .unwrap();
            }
            let result = work.await.unwrap();
            assert_eq!(result.is_err(), failure.is_some());
            if failure.is_none() {
                assert_eq!(result.unwrap(), 3);
            }
            assert_eq!(connection.close_reason().is_some(), failure.is_some());
            assert!(
                matches!(
                    outbound.input_acks.resolve(late_ack),
                    crate::InputAckResolution::Late(_)
                ),
                "cleanup cannot turn a late original ACK into success"
            );
        }
    }

    #[test]
    fn original_event_expiry_reserves_clock_mapping_error_without_relaxing_horizon() {
        use crate::input_runtime::{ClockSnapshot, conservative_input_deadline};
        use viewflow_transport::ClockEstimate;
        let original = 5_000_000_000;
        let budget = 33_333_333;
        let receiver_now = original + 1_000_000;
        // Clock error may put motion beyond its performance target, which is
        // no longer a maximum allowed operation horizon.
        let snapshot = ClockSnapshot {
            estimate: ClockEstimate {
                remote_offset_ns: -2_000_000,
                network_round_trip_ns: 4_000_000,
                uncertainty_ns: 2_000_000,
            },
            measured_at_local_ns: receiver_now,
        };
        assert_eq!(
            conservative_input_deadline(original + budget, Some(snapshot), receiver_now),
            Ok(original + budget)
        );
        let shortened = sender_event_expiry(original, budget).unwrap();
        assert_eq!(shortened, original + budget - 5_500_000);
        assert!(
            conservative_input_deadline(shortened, Some(snapshot), receiver_now).unwrap()
                <= original + budget
        );
        // Both offset directions and the maximum allowed sample age still use
        // the original physical timestamp; queue delay consumes the budget.
        for offset in [-4_000_000, 4_000_000] {
            let aged = ClockSnapshot {
                estimate: ClockEstimate {
                    remote_offset_ns: offset,
                    network_round_trip_ns: 5_000_000,
                    uncertainty_ns: 2_500_000,
                },
                measured_at_local_ns: receiver_now - 3_000_000_000,
            };
            let safe = conservative_input_deadline(shortened, Some(aged), receiver_now).unwrap();
            assert!(safe <= original + budget);
            assert!(
                conservative_input_deadline(
                    shortened,
                    Some(ClockSnapshot {
                        measured_at_local_ns: safe,
                        estimate: ClockEstimate {
                            uncertainty_ns: 4_000_000,
                            ..aged.estimate
                        },
                    }),
                    safe
                )
                .is_err()
            );
        }
        assert!(sender_event_expiry(original, 5_500_000).is_err());
        assert!(sender_event_expiry(u64::MAX, budget).is_err());
        let exact = ClockSnapshot {
            estimate: ClockEstimate {
                remote_offset_ns: 0,
                network_round_trip_ns: 0,
                uncertainty_ns: 0,
            },
            measured_at_local_ns: receiver_now,
        };
        assert_eq!(
            conservative_input_deadline(
                receiver_now + crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS + 1,
                Some(exact),
                receiver_now
            ),
            Err(crate::input_runtime::InputApplyError::InvalidInput)
        );
    }

    #[tokio::test]
    async fn pipelined_acks_accept_out_of_order_completion_without_extending_deadlines() {
        for expire_first in [false, true] {
            let registry = crate::InputAckRegistry::default();
            let start = tokio::time::Instant::now();
            let first_deadline = start + Duration::from_millis(if expire_first { 5 } else { 100 });
            let second_deadline = start + Duration::from_millis(100);
            let key = |sequence| crate::InputAckKey {
                lease_generation: 2,
                target_device: Id128(2),
                event_sequence: sequence,
            };
            let first = registry.register(key(1), first_deadline).unwrap();
            let second = registry.register(key(2), second_deadline).unwrap();
            let first = tokio::spawn(await_applied(first, first_deadline));
            let second = tokio::spawn(await_applied(second, second_deadline));
            tokio::time::sleep(Duration::from_millis(10)).await;
            let ack = |sequence| viewflow_protocol::InputAppliedAck {
                lease_generation: 2,
                target_device: Id128(2),
                event_sequence: sequence,
                result: viewflow_protocol::InputAppliedResult::Applied,
            };
            assert_eq!(
                registry.resolve(ack(2)),
                crate::InputAckResolution::Delivered
            );
            assert!(second.await.unwrap().is_ok());
            if expire_first {
                assert!(first.await.unwrap().is_err());
                assert!(matches!(
                    registry.resolve(ack(1)),
                    crate::InputAckResolution::Late(_)
                ));
            } else {
                assert!(!first.is_finished());
                assert_eq!(
                    registry.resolve(ack(1)),
                    crate::InputAckResolution::Delivered
                );
                assert!(first.await.unwrap().is_ok());
            }
        }
    }

    #[tokio::test]
    async fn return_fence_waits_for_every_inflight_ack_and_never_releases_after_failure() {
        for fail in [false, true] {
            let mut applied = tokio::task::JoinSet::new();
            let (first, rx1) = oneshot::channel::<Result<()>>();
            let (second, rx2) = oneshot::channel::<Result<()>>();
            applied.spawn(async move { rx1.await? });
            applied.spawn(async move { rx2.await? });
            let release = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            let observed = release.clone();
            let fence = tokio::spawn(async move {
                drain_applied(&mut applied).await?;
                observed.store(true, std::sync::atomic::Ordering::Release);
                Ok::<_, anyhow::Error>(())
            });
            first.send(Ok(())).unwrap();
            tokio::task::yield_now().await;
            assert!(!release.load(std::sync::atomic::Ordering::Acquire));
            second
                .send(if fail {
                    Err(anyhow::anyhow!("original event deadline expired"))
                } else {
                    Ok(())
                })
                .unwrap();
            assert_eq!(fence.await.unwrap().is_err(), fail);
            assert_eq!(release.load(std::sync::atomic::Ordering::Acquire), !fail);
        }
    }

    #[tokio::test]
    async fn rejected_local_release_retries_without_replaying_drag_or_input() {
        let (commands, mut requests) = mpsc::channel(4);
        let work = tokio::spawn(async move {
            release_capture_locally(&commands, 2, Duration::from_millis(1)).await
        });
        for reject in [true, false] {
            let request = requests.recv().await.unwrap();
            assert_eq!(request.command, CaptureCommand::Release {
                generation: 2, drag_target: None, return_position: None,
            });
            tokio::time::sleep(Duration::from_millis(5)).await;
            assert!(!work.is_finished());
            request.reply.send(if reject { Err(NativeCaptureRejected.into()) } else { Ok(()) }).unwrap();
        }
        work.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn delayed_native_capture_receipt_confirms_actual_activation() {
        let mut bridge = CursorBridge::fixture();
        let (reply, receive) = oneshot::channel();
        bridge.pending = Some(NativeRequest {
            command: CaptureCommand::Activate {
                generation: 2,
                target: Id128(2).0.to_be_bytes(),
                loopback: true,
            },
            deadline: tokio::time::Instant::now() - Duration::from_millis(1),
            reply,
        });
        assert!(
            bridge
                .receipt(CaptureReceipt {
                    generation: 2,
                    command: 40,
                    applied: true
                })
                .is_ok()
        );
        assert!(receive.await.unwrap().is_ok());
    }

    #[tokio::test]
    async fn rejected_activation_keeps_dispatcher_available_for_cleanup() {
        let mut bridge = CursorBridge::fixture();
        let (reply, receive) = oneshot::channel();
        bridge.pending = Some(NativeRequest {
            command: CaptureCommand::Activate {
                generation: 2,
                target: Id128(2).0.to_be_bytes(),
                loopback: true,
            },
            deadline: tokio::time::Instant::now() + Duration::from_secs(1),
            reply,
        });
        bridge
            .receipt(CaptureReceipt {
                generation: 2,
                command: 40,
                applied: false,
            })
            .unwrap();
        assert!(receive.await.unwrap().is_err());
        assert!(!bridge.pending());
        let (reply, receive) = oneshot::channel();
        bridge.pending = Some(NativeRequest {
            command: CaptureCommand::Release {
                generation: 2,
                drag_target: None,
                return_position: None,
            },
            deadline: tokio::time::Instant::now() + Duration::from_secs(1),
            reply,
        });
        bridge
            .receipt(CaptureReceipt {
                generation: 2,
                command: 41,
                applied: true,
            })
            .unwrap();
        receive.await.unwrap().unwrap();
    }

    fn rect(x: i64, y: i64) -> DesktopRect {
        DesktopRect {
            x_millidip: x,
            y_millidip: y,
            width_millidip: 100_000,
            height_millidip: 100_000,
        }
    }
    #[test]
    fn global_return_crosses_each_seam_and_clamps_large_delta() {
        let local = rect(-100_000, -100_000);
        for (remote, point, delta) in [
            (rect(0, -100_000), (10., -50.), (-300., 0.)),
            (rect(-200_000, -100_000), (-110., -50.), (300., 0.)),
            (rect(-100_000, 0), (-50., 10.), (0., -300.)),
            (rect(-100_000, -200_000), (-50., -110.), (0., 300.)),
        ] {
            let (x, y) = advance(local, remote, point, delta);
            assert!(contains(local, x, y));
        }
    }
    #[test]
    fn motion_outside_shared_overlap_does_not_return() {
        let local = rect(0, 0);
        let remote = rect(100_000, 50_000);
        assert_eq!(
            advance(local, remote, (120., 125.), (-50., 0.)),
            (70., 125.)
        );
        let returned = advance(local, remote, (120., 75.), (-50., 0.));
        assert!(contains(local, returned.0, returned.1));
    }
    #[test]
    fn key_mapping_preserves_physical_letters_and_modifiers() {
        assert_eq!(keyboard_usage(30), Some(4));
        assert_eq!(keyboard_usage(44), Some(29));
        assert_eq!(keyboard_usage(97), Some(0xe4));
        assert_eq!(keyboard_usage(103), Some(0x52));
        assert_eq!(keyboard_usage(0xffff), None);
    }
    #[test]
    fn absolute_position_keeps_negative_global_origin() {
        assert_eq!(
            position(-12.345, 67.89).unwrap(),
            InputEventKind::DesktopPointerPosition(viewflow_protocol::DesktopPointerPosition {
                x_millidip: -12345,
                y_millidip: 67890
            })
        );
        assert!(position(f64::NAN, 0.).is_err());
    }
}
