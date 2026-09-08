//! Source-side immutable desktop geometry derived only from admitted HCGF frames.
//!
//! This module deliberately knows neither a remote socket address nor a window
//! manager command.  A supervisor supplies locally configured candidates and
//! starts capture; this module decides whether an *already captured* window is
//! inside the configured remote viewport and builds the exact frame-bound
//! desktop record for the encoder.

use anyhow::{Context, Result, ensure};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::time::Instant;
use viewflow_protocol::{AtlasDesktopLayout, AtlasWindowPlacement, DesktopRect, Id128, WindowId};

use crate::gpu_atlas_sender::AtlasCaptureLease;

/// A local-only candidate identity. `native_address` is parsed from the local
/// configuration and feeds the source input allowlist only after enrollment.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct DesktopCandidate {
    pub(crate) window: WindowId,
    pub(crate) address: String,
    pub(crate) native_address: u64,
    /// The local Hyprland stable ID is mandatory for discovered windows. It
    /// is rechecked after HCGI arrives, so an address reuse cannot turn a
    /// briefly visible, unrelated client into an input target.
    pub(crate) stable_id: Option<String>,
    /// Candidate configuration pins the application PID, including the
    /// initial source selected by the launcher probe.
    pub(crate) expected_pid: Option<u32>,
}

/// Fixed remote logical viewport. Coordinates use millidips to avoid silently
/// inventing a second pixel coordinate system for mixed-scale Linux monitors.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct DesktopViewport {
    pub(crate) topology_generation: u64,
    pub(crate) bounds: DesktopRect,
}

/// Bounded local enrollment state. Closed sources leave only after their exact
/// producer stop is confirmed; publication and input are withdrawn earlier at
/// an idle GPU boundary. A retired identity cannot enroll again this session.
pub(crate) struct DesktopSourceLane {
    viewport: DesktopViewport,
    candidates: BTreeMap<WindowId, DesktopCandidate>,
    enrolled: BTreeSet<WindowId>,
    bindings: BTreeMap<WindowId, NativeBinding>,
    max_enrolled: usize,
    z_order: BTreeMap<WindowId, u32>,
    active_window: Option<WindowId>,
    raise_serial: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct NativeBinding {
    pub(crate) address: u64,
    pub(crate) pid: u32,
    pub(crate) surface: u64,
}

pub(crate) type SharedDesktopSourceLane = Arc<Mutex<DesktopSourceLane>>;

struct ProbedCandidate {
    candidate: DesktopCandidate,
    stream: crate::hyprcapture_runtime::GpuStreamSession,
    frame: crate::hyprcapture_gpu_wire::HcgfFrame,
}

type EnrollmentTask = tokio::task::JoinHandle<Result<Option<ProbedCandidate>>>;

impl DesktopSourceLane {
    pub(crate) fn new(
        viewport: DesktopViewport,
        candidates: Vec<DesktopCandidate>,
        initially_enrolled: impl IntoIterator<Item = WindowId>,
        max_enrolled: usize,
    ) -> Result<Self> {
        viewport
            .bounds
            .validate()
            .map_err(|error| anyhow::anyhow!("invalid configured desktop viewport: {error:?}"))?;
        ensure!(
            viewport.topology_generation > 0 && (1..=8).contains(&max_enrolled),
            "invalid desktop source enrollment bound"
        );
        let count = candidates.len();
        let candidates: BTreeMap<_, _> = candidates
            .into_iter()
            .map(|candidate| (candidate.window, candidate))
            .collect();
        ensure!(
            candidates.len() == count
                && candidates.values().all(|candidate| {
                    candidate.window.0 != 0
                        && candidate.native_address != 0
                        && !candidate.address.is_empty()
                }),
            "invalid desktop source candidate"
        );
        let enrolled: BTreeSet<_> = initially_enrolled.into_iter().collect();
        ensure!(
            enrolled.len() <= max_enrolled
                && enrolled
                    .iter()
                    .all(|window| candidates.contains_key(window)),
            "invalid desktop initial enrollment"
        );
        Ok(Self {
            viewport,
            candidates,
            enrolled,
            bindings: BTreeMap::new(),
            z_order: BTreeMap::new(),
            active_window: None,
            raise_serial: 0,
            max_enrolled,
        })
    }

    pub(crate) fn is_enrolled(&self, window: WindowId) -> bool {
        self.enrolled.contains(&window)
    }

    fn enrollment_capacity_remaining(&self) -> bool {
        self.enrolled.len() < self.max_enrolled
    }

    /// Decide eligibility from the HCGF currently held by the capture lease.
    /// It does not read Hyprland state, so the decision and later wire metadata
    /// describe the same captured surface.
    pub(crate) fn intersects_remote_viewport(
        &self,
        frame: &crate::hyprcapture_gpu_wire::HcgfFrame,
    ) -> Result<bool> {
        Ok(intersects(self.viewport.bounds, hcgf_bounds(frame)?))
    }

    /// A dynamic identity reaches the lane only after a local `j/clients`
    /// observation and an HCGI validation. It is then reserved atomically
    /// with the actual HCGF viewport decision.
    fn add_and_reserve_if_eligible(
        &mut self,
        candidate: DesktopCandidate,
        frame: &crate::hyprcapture_gpu_wire::HcgfFrame,
    ) -> Result<bool> {
        if self.enrolled.contains(&candidate.window) {
            return Ok(false);
        }
        ensure!(
            self.enrollment_capacity_remaining(),
            "desktop source enrollment capacity exhausted"
        );
        if let Some(existing) = self.candidates.get(&candidate.window) {
            ensure!(
                existing == &candidate,
                "desktop candidate identity collision"
            );
        } else {
            self.candidates.insert(candidate.window, candidate.clone());
        }
        if !self.intersects_remote_viewport(frame)? {
            // Do not retain an address merely because it was briefly local.
            // The next local discovery must establish it again.
            self.candidates.remove(&candidate.window);
            return Ok(false);
        }
        self.enrolled.insert(candidate.window);
        Ok(true)
    }

    pub(crate) fn unreserve(&mut self, window: WindowId) {
        self.enrolled.remove(&window);
    }

    pub(crate) fn shared(self) -> SharedDesktopSourceLane {
        Arc::new(Mutex::new(self))
    }

    /// Build one immutable desktop record from exactly the source leases about
    /// to be encoded. A missing candidate is terminal: it would otherwise turn
    /// a discovered address into an implicit input/window-management grant.
    pub(crate) fn layout_for_admitted(
        &mut self,
        sources: &[AtlasCaptureLease],
    ) -> Result<AtlasDesktopLayout> {
        let mut windows = Vec::with_capacity(sources.len());
        for source in sources {
            ensure!(
                self.enrolled.contains(&source.window),
                "desktop frame contains an unenrolled source"
            );
            let candidate = self
                .candidates
                .get(&source.window)
                .context("desktop frame source is not locally configured")?;
            let binding = binding_for(candidate, &source.frame)?;
            if let Some(current) = self.bindings.get(&source.window) {
                ensure!(*current == binding, "desktop source native binding changed");
            } else {
                self.bindings.insert(source.window, binding);
            }
            windows.push(AtlasWindowPlacement {
                window_id: candidate.window,
                bounds: hcgf_bounds(source.frame.metadata())?,
                movable: true,
                z_order: self.z_order.get(&candidate.window).copied().unwrap_or(0),
                raise_serial: if self.active_window == Some(candidate.window) {
                    self.raise_serial
                } else {
                    0
                },
            });
        }
        windows.sort_by_key(|window| window.window_id);
        let layout = AtlasDesktopLayout {
            topology_generation: self.viewport.topology_generation,
            viewport: self.viewport.bounds,
            windows,
        };
        layout
            .validate()
            .map_err(|error| anyhow::anyhow!("invalid captured desktop layout: {error:?}"))?;
        Ok(layout)
    }

    pub(crate) fn native_binding(&self, window: WindowId) -> Option<NativeBinding> {
        self.bindings.get(&window).copied()
    }
}

/// One bounded local enrollment attempt is made only between media batches.
/// Candidate addresses, PIDs and IDs originate in the local source config; no
/// remote message supplies any of them.
pub(crate) struct DesktopEnrollmentSupervisor {
    local_display: crate::desktop_config::AtlasDisplayConfig,
    lane: SharedDesktopSourceLane,
    queued: VecDeque<DesktopCandidate>,
    provider: crate::atlas_peer::AtlasCaptureProvider,
    fps: u16,
    compositor_pid: u32,
    socket: PathBuf,
    stream_id: Id128,
    /// Locally declared candidates are identity constraints, not a list of
    /// remotely selectable targets. Unlisted local clients may be discovered
    /// only when auto enrollment is explicitly enabled.
    configured: BTreeMap<String, DesktopCandidate>,
    capacity_retry: BTreeMap<WindowId, Instant>,
    auto_enroll: bool,
    next_discovery: Instant,
    discovery: Option<tokio::task::JoinHandle<Result<DesktopDiscovery>>>,
    icons: BTreeMap<WindowId, viewflow_protocol::ApplicationIcon>,
    published_icons: BTreeMap<WindowId, viewflow_protocol::ApplicationIcon>,
    retiring: BTreeSet<WindowId>,
    retired: BTreeSet<WindowId>,
    probe: Option<EnrollmentTask>,
    probing: Option<WindowId>,
    cleanup: tokio::task::JoinSet<Result<()>>,
}

impl DesktopEnrollmentSupervisor {
    pub(crate) fn new(
        lane: SharedDesktopSourceLane,
        desktop: &crate::desktop_config::AtlasSourceDesktopConfig,
        provider: crate::atlas_peer::AtlasCaptureProvider,
        fps: u16,
        compositor_pid: u32,
        stream_id: Id128,
    ) -> Self {
        Self {
            local_display: desktop.local_display,
            lane,
            queued: VecDeque::new(),
            provider,
            fps,
            compositor_pid,
            socket: desktop.hyprland_socket.clone(),
            stream_id,
            configured: desktop
                .candidates
                .iter()
                .filter(|_| !desktop.auto_enroll)
                .filter_map(|candidate| {
                    let native_address = parse_address(&candidate.address).ok()?;
                    let window = stable_window_id(&candidate.stable_id, stream_id).ok()?;
                    Some((
                        candidate.stable_id.clone(),
                        DesktopCandidate {
                            window,
                            address: candidate.address.clone(),
                            native_address,
                            stable_id: Some(candidate.stable_id.clone()),
                            expected_pid: Some(candidate.pid),
                        },
                    ))
                })
                .collect(),
            capacity_retry: BTreeMap::new(),
            auto_enroll: desktop.auto_enroll,
            next_discovery: Instant::now(),
            discovery: None,
            icons: BTreeMap::new(),
            published_icons: BTreeMap::new(),
            retiring: Default::default(),
            retired: Default::default(),
            probe: None,
            probing: None,
            cleanup: tokio::task::JoinSet::new(),
        }
    }

    /// Advance local discovery and at most one asynchronous capture enrollment
    /// without waiting on a native IPC/capture timeout in the media loop.
    /// A non-intersecting or closed client is discarded; a later local
    /// `j/clients` observation may create a new attempt.
    pub(crate) async fn poll_one(
        &mut self,
        session: &mut crate::gpu_atlas_session::GpuAtlasSession,
        mut input: Option<&mut crate::atlas_source_input::AtlasSourceInput>,
    ) -> Result<()> {
        for window in session.poll_removed().await? {
            self.retiring.remove(&window);
            let mut lane = self
                .lane
                .lock()
                .map_err(|_| anyhow::anyhow!("desktop enrollment state poisoned"))?;
            lane.enrolled.remove(&window);
            lane.candidates.remove(&window);
            lane.bindings.remove(&window);
            eprintln!("desktop source stop confirmed: window={window:?}");
        }
        for window in self.reap_discovery().await? {
            if self.retiring.insert(window) {
                ensure!(
                    self.retired.len() < 4096,
                    "desktop retired source bound exhausted"
                );
                self.retired.insert(window);
                if let Some(input) = input.as_deref_mut() {
                    input.retire_local_window(window)?;
                }
                session.remove_at_frame_boundary(window)?;
                eprintln!("desktop closed source withdrawn: window={window:?}");
            }
        }
        if let Some(input) = input.as_deref_mut() {
            let icons: Vec<_> = {
                let lane = self.lane.lock().map_err(|_| anyhow::anyhow!("desktop icon state poisoned"))?;
                self.icons.values().filter(|icon| lane.is_enrolled(icon.window_id)
                    && self.published_icons.get(&icon.window_id) != Some(*icon)).cloned().collect()
            };
            for icon in icons {
                input.publish_application_icon(icon.clone()).await?;
                self.published_icons.insert(icon.window_id, icon);
            }
        }
        if self
            .probe
            .as_ref()
            .is_some_and(tokio::task::JoinHandle::is_finished)
        {
            self.probing = None;
            match self.probe.take().expect("checked probe").await {
                Ok(Ok(Some(ProbedCandidate {
                    candidate,
                    stream,
                    frame,
                }))) => {
                    let reservation = (|| -> Result<bool> {
                        if !session.can_enroll_capture(candidate.window, &frame)? {
                            self.capacity_retry
                                .insert(candidate.window, Instant::now() + Duration::from_secs(2));
                            eprintln!(
                                "desktop candidate exceeds available atlas capacity: window={:?} capture={}x{}",
                                candidate.window, frame.crop_width, frame.crop_height
                            );
                            self.return_capacity_rejected(candidate.clone());
                            return Ok(false);
                        }
                        self.lane
                            .lock()
                            .map_err(|_| anyhow::anyhow!("desktop enrollment state poisoned"))?
                            .add_and_reserve_if_eligible(candidate.clone(), &frame)
                    })();
                    let reserved = match reservation {
                        Ok(reserved) => reserved,
                        Err(error) => {
                            self.stop_later(stream);
                            return Err(error);
                        }
                    };
                    if !reserved {
                        self.stop_later(stream);
                    } else if let Err(error) = session
                        .enroll_at_frame_boundary(candidate.window, stream)
                        .await
                    {
                        self.lane
                            .lock()
                            .map_err(|_| anyhow::anyhow!("desktop enrollment state poisoned"))?
                            .unreserve(candidate.window);
                        return Err(error);
                    } else if let Some(input) = input {
                        input.enroll_local_window(candidate.window, candidate.native_address)?;
                    }
                }
                Ok(Ok(None)) => {}
                // Recoverable candidate races return None only after checked
                // cleanup. An error here must retire the enclosing session.
                Ok(Err(error)) => return Err(error.context("desktop enrollment failed")),
                Err(error) => return Err(error).context("desktop enrollment worker stopped"),
            }
        }
        self.start_discovery_if_due()?;
        while let Some(result) = self.cleanup.try_join_next() {
            if let Err(error) = result.context("desktop discarded stream cleanup worker stopped")? {
                return Err(error.context("desktop discarded stream cleanup failed"));
            }
        }
        if self.probe.is_none() {
            while let Some(candidate) = self.queued.pop_front() {
                let (eligible, has_capacity) = {
                    let lane = self
                        .lane
                        .lock()
                        .map_err(|_| anyhow::anyhow!("desktop enrollment state poisoned"))?;
                    (!self.retired.contains(&candidate.window)
                        && !lane.is_enrolled(candidate.window),
                        lane.enrollment_capacity_remaining())
                };
                if !eligible {
                    continue;
                }
                if !has_capacity {
                    self.capacity_retry.insert(candidate.window, Instant::now() + Duration::from_secs(2));
                    self.return_capacity_rejected(candidate);
                    continue;
                }
                self.probing = Some(candidate.window);
                self.probe = Some(tokio::spawn(probe_candidate(
                    candidate,
                    self.provider,
                    self.fps,
                    self.compositor_pid,
                    self.socket.clone(),
                    self.lane.clone(),
                )));
                break;
            }
        }
        Ok(())
    }

    fn return_capacity_rejected(&mut self, candidate: DesktopCandidate) {
        let socket = self.socket.clone();
        let display = self.local_display;
        self.cleanup.spawn(async move {
            let result = tokio::task::spawn_blocking(move || {
                return_rejected_to_local(socket, display, &candidate)
            }).await;
            match result {
                Ok(Ok(true)) => eprintln!("desktop capacity rejected: window returned to local display"),
                Ok(Ok(false)) => eprintln!("desktop capacity rejected: local layout retained"),
                other => eprintln!("desktop capacity return failed; existing stream retained: {other:?}"),
            }
            Ok(())
        });
    }

    async fn reap_discovery(&mut self) -> Result<Vec<WindowId>> {
        let Some(task) = self.discovery.as_ref() else {
            return Ok(Vec::new());
        };
        if !task.is_finished() {
            return Ok(Vec::new());
        }
        let task = self.discovery.take().expect("checked discovery");
        match task.await {
            Ok(Ok(discovered)) => {
                self.icons = discovered.icons.clone();
                {
                    let mut lane = self
                        .lane
                        .lock()
                        .map_err(|_| anyhow::anyhow!("desktop enrollment state poisoned"))?;
                    lane.z_order = discovered.z_order.clone();
                    lane.active_window = discovered.active_window;
                    lane.raise_serial = discovered.raise_serial;
                }

                self.capacity_retry
                    .retain(|_, retry| Instant::now() < *retry);
                let closed = {
                    let lane = self
                        .lane
                        .lock()
                        .map_err(|_| anyhow::anyhow!("desktop enrollment state poisoned"))?;
                    lane.enrolled
                        .iter()
                        .filter(|window| {
                            !self.retiring.contains(window)
                                && lane.candidates.get(window).is_some_and(|candidate| {
                                    !discovered
                                        .contains_source(candidate, lane.bindings.get(window))
                                })
                        })
                        .copied()
                        .collect()
                };
                if self.auto_enroll {
                    for candidate in discovered.candidates {
                        if self
                            .capacity_retry
                            .get(&candidate.window)
                            .is_some_and(|retry| Instant::now() < *retry)
                            || self.retired.contains(&candidate.window)
                            || self.probing == Some(candidate.window)
                            || self
                                .queued
                                .iter()
                                .any(|queued| queued.window == candidate.window)
                            || self.lane.lock().is_ok_and(|lane| {
                                lane.is_enrolled(candidate.window)
                                    || lane.candidates.values().any(|existing| {
                                        lane.is_enrolled(existing.window)
                                            && existing.native_address == candidate.native_address
                                    })
                            })
                        {
                            continue;
                        }
                        if self.queued.len() < 8 {
                            self.queued.push_back(candidate);
                        }
                    }
                }
                Ok(closed)
            }
            Ok(Err(error)) => {
                eprintln!("desktop local discovery skipped: {error:#}");
                Ok(Vec::new())
            }
            Err(error) => {
                eprintln!("desktop discovery worker stopped: {error}");
                Ok(Vec::new())
            }
        }
    }

    fn start_discovery_if_due(&mut self) -> Result<()> {
        if self.discovery.is_some() || Instant::now() < self.next_discovery {
            return Ok(());
        }
        self.next_discovery = Instant::now() + Duration::from_millis(100);
        let socket = self.socket.clone();
        let configured = self.configured.clone();
        let stream_id = self.stream_id;
        let viewport = self
            .lane
            .lock()
            .map_err(|_| anyhow::anyhow!("desktop enrollment state poisoned"))?
            .viewport;
        self.discovery = Some(tokio::task::spawn_blocking(move || {
            discover_local_candidates(socket, viewport, configured, stream_id)
        }));
        Ok(())
    }

    fn stop_later(&mut self, stream: crate::hyprcapture_runtime::GpuStreamSession) {
        self.cleanup
            .spawn(async move { stream.stop_stream(Duration::from_secs(2)).await });
    }

    /// Join every worker that owns a local producer before the enclosing atlas
    /// shuts down its input/capture owners. No enrollment task is detached.
    pub(crate) async fn shutdown(&mut self) -> Result<()> {
        let mut failure: Option<anyhow::Error> = None;
        if let Some(discovery) = self.discovery.take() {
            match discovery
                .await
                .context("desktop discovery shutdown worker stopped")
            {
                Ok(Ok(_)) => {}
                Ok(Err(error)) => {
                    failure.get_or_insert(error);
                }
                Err(error) => {
                    failure.get_or_insert(error);
                }
            };
        }
        if let Some(probe) = self.probe.take() {
            match probe
                .await
                .context("desktop enrollment shutdown worker stopped")
            {
                Ok(Ok(Some(probed))) => self.stop_later(probed.stream),
                Ok(Ok(None)) => {}
                Ok(Err(error)) => {
                    failure.get_or_insert(error);
                }
                Err(error) => {
                    failure.get_or_insert(error);
                }
            }
        }
        while let Some(result) = self.cleanup.join_next().await {
            match result.context("desktop discarded stream shutdown worker stopped") {
                Ok(Ok(())) => {}
                Ok(Err(error)) => {
                    failure.get_or_insert(error);
                }
                Err(error) => {
                    failure.get_or_insert(error);
                }
            }
        }
        failure.map_or(Ok(()), Err)
    }
}

struct DesktopDiscovery {
    icons: BTreeMap<WindowId, viewflow_protocol::ApplicationIcon>,
    z_order: BTreeMap<WindowId, u32>,
    active_window: Option<WindowId>,
    raise_serial: u32,
    candidates: Vec<DesktopCandidate>,
    // Complete mapped inventory, before viewport/workspace eligibility filters.
    live: BTreeMap<u64, (u32, String)>,
}

impl DesktopDiscovery {
    fn contains_source(
        &self,
        candidate: &DesktopCandidate,
        binding: Option<&NativeBinding>,
    ) -> bool {
        self.live
            .get(&candidate.native_address)
            .is_some_and(|(pid, stable)| {
                candidate
                    .expected_pid
                    .or(binding.map(|binding| binding.pid))
                    .is_none_or(|expected| expected == *pid)
                    && candidate
                        .stable_id
                        .as_ref()
                        .is_none_or(|expected| expected == stable)
            })
    }
}

/// Read local Hyprland client state with a short socket timeout. This executes
/// in a blocking worker; no remote data ever reaches this function.
fn discover_local_candidates(
    socket: PathBuf,
    viewport: DesktopViewport,
    configured: BTreeMap<String, DesktopCandidate>,
    stream_id: Id128,
) -> Result<DesktopDiscovery> {
    let ipc = viewflow_hyprland::HyprIpcClient::new(socket).with_timeout(Duration::from_millis(50));
    let monitors: serde_json::Value = serde_json::from_str(&ipc.request("j/monitors")?)?;
    let active_workspaces: std::collections::BTreeSet<i64> = monitors
        .as_array()
        .context("invalid local monitor inventory")?
        .iter()
        .flat_map(|monitor| {
            [
                monitor["activeWorkspace"]["id"].as_i64(),
                monitor["specialWorkspace"]["id"].as_i64(),
            ]
        })
        .flatten()
        .filter(|id| *id != 0)
        .collect();
    let response = ipc
        .request("j/clients")
        .context("read local Hyprland clients")?;
    let raw_clients: Vec<serde_json::Value> = serde_json::from_str(&response)?;
    let mut stacking: Vec<_> = raw_clients.iter().collect();
    // Match Hyprland rendering passes, preserving actual window-state order
    // within floating groups. Focus only changes the tiled main pass.
    stacking.sort_by_key(|client| {
        (
            client["pinned"].as_bool().unwrap_or(false),
            client["workspace"]["id"].as_i64().unwrap_or(0) < 0,
            client["floating"].as_bool().unwrap_or(false),
            !client["floating"].as_bool().unwrap_or(false)
                && client["focusHistoryID"].as_i64() == Some(0),
        )
    });
    let parsed_stacking =
        viewflow_hyprland::parse_windows(&response).context("parse stacking order")?;
    // Only physical clicks raise a proxy. Focus-follows-mouse is deliberately
    // absent from this path; its focusHistoryID must never raise an HWND.
    let click: serde_json::Value = ipc
        .request("repl return hl.plugin.viewflow.capture_status()")
        .ok()
        .and_then(|r| serde_json::from_str(&r).ok())
        .unwrap_or(serde_json::Value::Null);
    let clicked_address = click["clicked_window"].as_u64().map(|a| format!("0x{a:x}"));
    let active_window = parsed_stacking
        .iter()
        .find(|w| Some(&w.address) == clicked_address.as_ref())
        .and_then(|w| stable_window_id(&w.stable_id, stream_id).ok());
    let raise_serial = click["click_serial"].as_u64().unwrap_or(0).min(0x7fffffff) as u32;
    let z_order = stacking
        .iter()
        .enumerate()
        .filter_map(|(index, client)| {
            let address = client["address"].as_str()?;
            let window = parsed_stacking.iter().find(|w| w.address == address)?;
            Some((
                stable_window_id(&window.stable_id, stream_id).ok()?,
                index as u32 + 1,
            ))
        })
        .collect();
    // Scrolling layouts can place local tiled clients beyond the monitor edge.
    // Their layout coordinates do not transfer ownership to the remote output.
    let remote_monitors: std::collections::BTreeSet<i64> = monitors
        .as_array().context("invalid local monitor inventory")?.iter()
        .filter(|monitor| {
            monitor["x"].as_i64().and_then(|x| x.checked_mul(1000)) == Some(viewport.bounds.x_millidip)
                && monitor["y"].as_i64().and_then(|y| y.checked_mul(1000)) == Some(viewport.bounds.y_millidip)
        })
        .filter_map(|monitor| monitor["id"].as_i64())
        .collect();
    let active_addresses: std::collections::BTreeSet<&str> = raw_clients
        .iter()
        .filter(|client| {
            client["floating"].as_bool() == Some(true)
                || client["monitor"].as_i64().is_some_and(|id| remote_monitors.contains(&id))
        })
        .filter(|client| {
            client["workspace"]["id"]
                .as_i64()
                .is_some_and(|id| active_workspaces.contains(&id))
        })
        .filter_map(|client| client["address"].as_str())
        .collect();
    // Stacking and membership come from the same IPC snapshot. Reuse its
    // typed records instead of parsing and allocating every window twice.
    let windows = parsed_stacking;
    let live = windows
        .iter()
        .filter(|client| client.mapped)
        .filter_map(|client| {
            Some((
                parse_address(&client.address).ok()?,
                (u32::try_from(client.pid).ok()?, client.stable_id.clone()),
            ))
        })
        .collect();
    let mut discovered = BTreeMap::new();
    let mut icons = BTreeMap::new();
    for client in windows {
        if !client.mapped
            || client.class.starts_with("ViewflowReverse-")
            || client.hidden
            || !client.visible
            || client.stable_id.is_empty()
            || !active_addresses.contains(client.address.as_str())
        {
            continue;
        }
        let native_address = match parse_address(&client.address) {
            Ok(address) => address,
            Err(_) => continue,
        };
        let Ok(pid) = u32::try_from(client.pid) else {
            continue;
        };
        if pid == 0
            || !intersects(
                viewport.bounds,
                logical_bounds(client.at[0], client.at[1], client.size[0], client.size[1])?,
            )
        {
            continue;
        }
        let window = match stable_window_id(&client.stable_id, stream_id) {
            Ok(window) => window,
            Err(_) => continue,
        };
        let locally_observed = DesktopCandidate {
            window,
            address: canonical_address(native_address),
            native_address,
            stable_id: Some(client.stable_id.clone()),
            expected_pid: Some(pid),
        };
        // A configuration entry can only tighten an already-local identity.
        // It never creates an address or PID on its own.
        if let Some(configured) = configured.get(&client.stable_id) {
            if configured.native_address != native_address || configured.expected_pid != Some(pid) {
                continue;
            }
        }
        if let Some(icon) = crate::window_icon::resolve(window, &client.class) {
            icons.insert(window, icon);
        }
        discovered.insert(client.stable_id, locally_observed);
    }
    Ok(DesktopDiscovery {
        icons,
        z_order,
        active_window,
        raise_serial,
        candidates: discovered.into_values().collect(),
        live,
    })
}

/// Own the slow capture startup and checked cleanup in a supervised task. The
/// caller only observes a completed result between media batches.
async fn probe_candidate(
    candidate: DesktopCandidate,
    provider: crate::atlas_peer::AtlasCaptureProvider,
    fps: u16,
    compositor_pid: u32,
    socket: PathBuf,
    lane: SharedDesktopSourceLane,
) -> Result<Option<ProbedCandidate>> {
    let started = match provider {
        crate::atlas_peer::AtlasCaptureProvider::Viewflow => {
            crate::hyprcapture_runtime::start_viewflow_gpu_stream(
                &candidate.address,
                fps,
                compositor_pid,
                Duration::from_millis(250),
            )
            .await
        }
        crate::atlas_peer::AtlasCaptureProvider::Hyprcapture => {
            crate::hyprcapture_runtime::start_gpu_stream(
                &candidate.address,
                fps,
                compositor_pid,
                Duration::from_millis(250),
            )
            .await
        }
    };
    let mut stream = match started {
        Ok(stream) => stream,
        // A window may close after `j/clients` and before the plugin creates
        // its stream. That is a local race, not a media-session failure.
        Err(error) => {
            if error.is::<crate::hyprcapture_runtime::GpuStreamStopUnconfirmed>() {
                return Err(error);
            }
            eprintln!("desktop candidate capture skipped: {error:#}");
            return Ok(None);
        }
    };
    let frame = match first_frame(&mut stream, Instant::now() + Duration::from_millis(250)).await {
        Ok(frame) => frame,
        Err(error) => {
            stream.stop_stream(Duration::from_secs(2)).await?;
            eprintln!("desktop candidate first frame skipped: {error:#}");
            return Ok(None);
        }
    };
    let candidate_for_check = candidate.clone();
    let eligible = async {
        verify_candidate_binding(&candidate, &frame)?;
        let current = tokio::task::spawn_blocking(move || {
            locally_observed_exact(socket, &candidate_for_check)
        })
        .await
        .context("desktop local identity worker stopped")??;
        Ok::<_, anyhow::Error>(
            current
                && lane
                    .lock()
                    .map_err(|_| anyhow::anyhow!("desktop enrollment state poisoned"))?
                    .intersects_remote_viewport(frame.metadata())?,
        )
    }
    .await;
    let metadata = frame.metadata().clone();
    // The probe deliberately does not import/read the DMA-BUF. Stop the
    // producer while its outstanding allocation remains retained, then drop
    // the frame. HCGR is never emitted for this metadata-only observation.
    let stopped = stream.stop_stream(Duration::from_secs(2)).await;
    drop(frame);
    stopped?;
    match eligible {
        Ok(true) => {}
        Ok(false) => return Ok(None),
        Err(error) => {
            eprintln!("desktop candidate validation skipped: {error:#}");
            return Ok(None);
        }
    }
    // The consumed probe allocation is never handed to the atlas. A fresh
    // producer gives the real session its first unread HCGF.
    let fresh = match provider {
        crate::atlas_peer::AtlasCaptureProvider::Viewflow => {
            crate::hyprcapture_runtime::start_viewflow_gpu_stream(
                &candidate.address,
                fps,
                compositor_pid,
                Duration::from_millis(250),
            )
            .await
        }
        crate::atlas_peer::AtlasCaptureProvider::Hyprcapture => {
            crate::hyprcapture_runtime::start_gpu_stream(
                &candidate.address,
                fps,
                compositor_pid,
                Duration::from_millis(250),
            )
            .await
        }
    };
    match fresh {
        Ok(stream) => Ok(Some(ProbedCandidate {
            candidate,
            stream,
            frame: metadata,
        })),
        Err(error) => {
            if error.is::<crate::hyprcapture_runtime::GpuStreamStopUnconfirmed>() {
                return Err(error);
            }
            eprintln!("desktop candidate fresh stream skipped: {error:#}");
            Ok(None)
        }
    }
}

/// The HCGI result must still name the same mapped, visible local client that
/// discovery saw. This closes address/PID reuse races before lane insertion.
fn return_rejected_to_local(
    socket: PathBuf,
    display: crate::desktop_config::AtlasDisplayConfig,
    candidate: &DesktopCandidate,
) -> Result<bool> {
    if !locally_observed_exact(socket.clone(), candidate)? {
        return Ok(false);
    }
    let ipc = viewflow_hyprland::HyprIpcClient::new(socket)
        .with_timeout(Duration::from_millis(250));
    let clients: serde_json::Value = serde_json::from_str(&ipc.request("j/clients")?)?;
    let client = clients.as_array().context("invalid clients")?.iter()
        .find(|c| c["address"].as_str() == Some(candidate.address.as_str()))
        .context("rejected window already closed")?;
    // A capacity decision may race with retiling. Never change the layout's
    // floating state, size, workspace, or position to recover atlas capacity.
    if client["floating"].as_bool() != Some(true) {
        return Ok(false);
    }
    let monitors: serde_json::Value = serde_json::from_str(&ipc.request("j/monitors")?)?;
    let monitor = monitors.as_array().context("invalid monitors")?.iter()
        .find(|m| m["x"].as_i64() == Some(i64::from(display.x))
            && m["y"].as_i64() == Some(i64::from(display.y)))
        .context("local display unavailable")?;
    let workspace = monitor["activeWorkspace"]["id"].as_i64().context("local workspace unavailable")?;
    let rect = display.rect()?;
    let (x, y, width, height) = capacity_return_rect(
        display.x, display.y,
        (rect.width_millidip / 1000) as i64, (rect.height_millidip / 1000) as i64,
        client["size"][0].as_i64().context("missing window width")?,
        client["size"][1].as_i64().context("missing window height")?,
        client["at"][0].as_i64().context("missing window x")?,
        client["at"][1].as_i64().context("missing window y")?,
    );
    // Only locally parsed numeric addresses/coordinates enter Lua. No focus or
    // input command is issued. A failed return must not retire other windows.
    let selector = format!("\"address:0x{:x}\"", candidate.native_address);
    let script = format!(
        "eval hl.dispatch(hl.dsp.window.float({{action=\"enable\",window={selector}}})); \
         hl.dispatch(hl.dsp.window.move({{workspace={workspace},follow=false,window={selector}}})); \
         hl.dispatch(hl.dsp.window.resize({{x={width},y={height},window={selector}}})); \
         hl.dispatch(hl.dsp.window.move({{x={x},y={y},window={selector}}}))"
    );
    let response = ipc.request(&script)?;
    ensure!(response.trim() == "ok", "local window return: {response}");
    Ok(true)
}

fn capacity_return_rect(x: i32, y: i32, screen_w: i64, screen_h: i64,
                        window_w: i64, window_h: i64,
                        window_x: i64, window_y: i64) -> (i64, i64, i64, i64) {
    // Project onto the nearest edge of the valid window-origin rectangle.
    // Outside origins already reach that boundary by clamping. For an origin
    // inside the display, select the shortest translation instead of leaving
    // the window in the interior or choosing a fixed/opposite edge.
    // Keep a small inset so decorations do not immediately cross the seam again.
    let w = window_w.max(1).min((screen_w - 96).max(1));
    let h = window_h.max(1).min((screen_h - 160).max(1));
    let inset_x = ((screen_w - w).max(0) / 2).min(16);
    let inset_y = ((screen_h - h).max(0) / 2).min(16);
    let left = i64::from(x) + inset_x;
    let top = i64::from(y) + inset_y;
    let right = (i64::from(x) + screen_w - w - inset_x).max(left);
    let bottom = (i64::from(y) + screen_h - h - inset_y).max(top);
    let mut returned_x = window_x.clamp(left, right);
    let mut returned_y = window_y.clamp(top, bottom);
    if returned_x > left && returned_x < right && returned_y > top && returned_y < bottom {
        let nearest = [
            (returned_x - left, left, returned_y),
            (right - returned_x, right, returned_y),
            (returned_y - top, returned_x, top),
            (bottom - returned_y, returned_x, bottom),
        ].into_iter().min_by_key(|edge| edge.0).expect("four edges");
        returned_x = nearest.1;
        returned_y = nearest.2;
    }
    (returned_x, returned_y, w, h)
}

fn locally_observed_exact(socket: PathBuf, candidate: &DesktopCandidate) -> Result<bool> {
    let Some(stable_id) = candidate.stable_id.as_deref() else {
        return Ok(true);
    };
    let response = viewflow_hyprland::HyprIpcClient::new(socket)
        .with_timeout(Duration::from_millis(50))
        .request("j/clients")?;
    let windows = viewflow_hyprland::parse_windows(&response)?;
    Ok(windows.iter().any(|client| {
        client.mapped
            && !client.hidden
            && client.visible
            && client.stable_id == stable_id
            && parse_address(&client.address).ok() == Some(candidate.native_address)
            && u32::try_from(client.pid).ok() == candidate.expected_pid
    }))
}

async fn first_frame(
    stream: &mut crate::hyprcapture_runtime::GpuStreamSession,
    deadline: Instant,
) -> Result<Box<crate::hyprcapture_gpu_socket::GpuFrame>> {
    loop {
        match stream.receiver.recv_frame()? {
            crate::hyprcapture_gpu_socket::GpuReceiveOutcome::Frame(frame) => return Ok(frame),
            crate::hyprcapture_gpu_socket::GpuReceiveOutcome::Disconnected => {
                anyhow::bail!("desktop candidate capture disconnected")
            }
            crate::hyprcapture_gpu_socket::GpuReceiveOutcome::WouldBlock => {
                ensure!(
                    Instant::now() < deadline,
                    "desktop candidate capture probe timed out"
                );
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        }
    }
}

/// Refresh automatic enrollment from the live compositor, never an old launcher
/// PID. An empty desktop starts a transparent atlas with no capture producers.
pub(crate) async fn refresh_automatic_seed(
    config: &mut crate::atlas_peer::AtlasSourceConfig,
) -> Result<bool> {
    let Some(desktop) = config.desktop.as_ref().filter(|d| d.auto_enroll) else {
        return Ok(true);
    };
    let stream_id = config.media.plan()?.policy.stream_id;
    let viewport = DesktopViewport {
        topology_generation: desktop.topology_generation,
        bounds: desktop.remote_display.rect()?,
    };
    let socket = desktop.hyprland_socket.clone();
    let discovered = tokio::task::spawn_blocking(move || {
        discover_local_candidates(socket, viewport, BTreeMap::new(), stream_id)
    })
    .await
    .context("desktop startup discovery worker stopped")??;
    for candidate in discovered.candidates {
        let probe = match crate::desktop_probe::probe_viewflow_desktop_window(
            &candidate.address,
            config.compositor_pid,
        )
        .await
        {
            Ok(probe) => probe,
            Err(error) => {
                if error.is::<crate::hyprcapture_runtime::GpuStreamStopUnconfirmed>() {
                    return Err(error);
                }
                eprintln!("desktop startup candidate skipped: {error:#}");
                continue;
            }
        };
        if candidate.expected_pid != Some(probe.pid)
            || candidate.stable_id.as_deref() != Some(probe.stable_id.as_str())
        {
            continue;
        }
        config.windows = vec![crate::atlas_peer::AtlasSourceWindow {
            window_id: format!("{:032x}", candidate.window.0),
            address: probe.address.clone(),
            width: probe.width,
            height: probe.height,
            geometry_epoch: probe.geometry_epoch,
        }];
        config.desktop.as_mut().expect("desktop exists").candidates =
            vec![crate::desktop_config::AtlasDesktopCandidate {
                address: probe.address,
                pid: probe.pid,
                stable_id: probe.stable_id,
            }];
        return Ok(true);
    }
    config.windows.clear();
    config.desktop.as_mut().expect("automatic desktop").candidates.clear();
    Ok(true)
}

/// Build identities for the already-selected initial sources. Dynamic clients
/// are intentionally absent: they enter this map only after local discovery,
/// HCGI validation and an HCGF viewport check in the enrollment supervisor.
pub(crate) fn lane_from_config(
    desktop: &crate::desktop_config::AtlasSourceDesktopConfig,
    initial: &[crate::atlas_peer::AtlasSourceWindow],
    stream_id: Id128,
) -> Result<SharedDesktopSourceLane> {
    let mut candidates = Vec::new();
    let mut initial_ids = Vec::new();
    for window in initial {
        let id = Id128(u128::from_str_radix(&window.window_id, 16)?);
        let native_address = parse_address(&window.address)?;
        let declared = desktop
            .candidates
            .iter()
            .find(|candidate| parse_address(&candidate.address).ok() == Some(native_address))
            .context("desktop initial source has no local PID/stable-ID declaration")?;
        initial_ids.push(id);
        candidates.push(DesktopCandidate {
            window: id,
            address: window.address.clone(),
            native_address,
            stable_id: Some(declared.stable_id.clone()),
            expected_pid: Some(declared.pid),
        });
    }
    let _ = stream_id;
    DesktopSourceLane::new(
        DesktopViewport {
            topology_generation: desktop.topology_generation,
            bounds: desktop.remote_display.rect()?,
        },
        candidates,
        initial_ids,
        desktop.max_enrolled_windows,
    )
    .map(DesktopSourceLane::shared)
}

/// Establish that each initially configured source still names the exact local
/// stable-ID/PID pair before `start_sources` asks the capture plugin to open
/// it. This is intentionally local-only and bounded by the command socket.
pub(crate) async fn prepare_lane_from_config(
    desktop: &crate::desktop_config::AtlasSourceDesktopConfig,
    initial: &[crate::atlas_peer::AtlasSourceWindow],
    stream_id: Id128,
) -> Result<SharedDesktopSourceLane> {
    let lane = lane_from_config(desktop, initial, stream_id)?;
    let socket = desktop.hyprland_socket.clone();
    let candidates = lane
        .lock()
        .map_err(|_| anyhow::anyhow!("desktop enrollment state poisoned"))?
        .candidates
        .values()
        .cloned()
        .collect::<Vec<_>>();
    let valid = tokio::task::spawn_blocking(move || {
        candidates
            .iter()
            .map(|candidate| locally_observed_exact(socket.clone(), candidate))
            .collect::<Result<Vec<_>>>()
    })
    .await
    .context("desktop initial identity worker stopped")??;
    ensure!(
        valid.iter().all(|current| *current),
        "desktop initial source no longer matches local stable ID/PID"
    );
    Ok(lane)
}

fn binding_for(
    candidate: &DesktopCandidate,
    frame: &crate::hyprcapture_gpu_socket::GpuFrame,
) -> Result<NativeBinding> {
    let input = frame
        .input_geometry()
        .context("desktop candidate HCGF has no native input binding")?;
    let pid = u32::try_from(input.pid).context("desktop candidate HCGI pid is invalid")?;
    ensure!(
        input.window == candidate.native_address
            && candidate
                .expected_pid
                .is_none_or(|expected| pid == expected)
            && input.surface != 0,
        "desktop candidate HCGI binding changed"
    );
    Ok(NativeBinding {
        address: input.window,
        pid,
        surface: input.surface,
    })
}

fn verify_candidate_binding(
    candidate: &DesktopCandidate,
    frame: &crate::hyprcapture_gpu_socket::GpuFrame,
) -> Result<()> {
    let _ = binding_for(candidate, frame)?;
    Ok(())
}

fn parse_address(value: &str) -> Result<u64> {
    let hex = value
        .strip_prefix("0x")
        .context("desktop address needs 0x")?;
    let parsed = u64::from_str_radix(hex, 16)?;
    ensure!(parsed != 0, "zero desktop address");
    Ok(parsed)
}

fn stable_window_id(value: &str, stream_id: Id128) -> Result<WindowId> {
    use sha2::{Digest, Sha256};
    // Keep the initial launcher seed and later runtime discovery in the same
    // ID namespace so the first window is not captured a second time.
    let digest = Sha256::digest(format!("viewflow-desktop-window:{value}").as_bytes());
    let mut id = Id128(u128::from_be_bytes(digest[..16].try_into()?));
    if id == stream_id {
        let digest = Sha256::digest(format!("viewflow-desktop-window:1:{value}").as_bytes());
        id = Id128(u128::from_be_bytes(digest[..16].try_into()?));
    }
    ensure!(id.0 != 0 && id != stream_id, "invalid desktop stable ID");
    Ok(id)
}

/// Exact HCGF logical bounds, converted once with checked finite millidip
/// rounding. This is intentionally not a compositor metadata lookup.
pub(crate) fn hcgf_bounds(frame: &crate::hyprcapture_gpu_wire::HcgfFrame) -> Result<DesktopRect> {
    logical_bounds(
        frame.logical_x,
        frame.logical_y,
        frame.logical_width,
        frame.logical_height,
    )
}

fn logical_bounds(x: f64, y: f64, width: f64, height: f64) -> Result<DesktopRect> {
    let to_millidip = |value: f64, label: &str| -> Result<i64> {
        ensure!(value.is_finite(), "HCGF {label} is non-finite");
        let scaled = value * 1000.0;
        ensure!(scaled.is_finite(), "HCGF {label} millidip overflow");
        let rounded = scaled.round();
        ensure!(
            rounded >= i64::MIN as f64 && rounded <= i64::MAX as f64,
            "HCGF {label} is outside millidip range"
        );
        Ok(rounded as i64)
    };
    let width = to_millidip(width, "logical width")?;
    let height = to_millidip(height, "logical height")?;
    ensure!(width > 0 && height > 0, "HCGF logical bounds are empty");
    let bounds = DesktopRect {
        x_millidip: to_millidip(x, "logical x")?,
        y_millidip: to_millidip(y, "logical y")?,
        width_millidip: u64::try_from(width)?,
        height_millidip: u64::try_from(height)?,
    };
    bounds
        .validate()
        .map_err(|error| anyhow::anyhow!("HCGF desktop bounds invalid: {error:?}"))?;
    Ok(bounds)
}

fn canonical_address(address: u64) -> String {
    format!("0x{address:x}")
}

fn intersects(a: DesktopRect, b: DesktopRect) -> bool {
    let right = |rect: DesktopRect| {
        rect.x_millidip
            .checked_add(i64::try_from(rect.width_millidip).unwrap_or(i64::MAX))
    };
    let bottom = |rect: DesktopRect| {
        rect.y_millidip
            .checked_add(i64::try_from(rect.height_millidip).unwrap_or(i64::MAX))
    };
    match (right(a), right(b), bottom(a), bottom(b)) {
        (Some(ar), Some(br), Some(ab), Some(bb)) => {
            a.x_millidip < br && b.x_millidip < ar && a.y_millidip < bb && b.y_millidip < ab
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn empty_desktop_can_start_and_reserve_later_windows() {
        let viewport = DesktopViewport { topology_generation: 1, bounds: viewflow_protocol::DesktopRect {
            x_millidip: 0, y_millidip: 0, width_millidip: 100_000, height_millidip: 100_000 } };
        let lane = DesktopSourceLane::new(viewport, vec![], [], 8).unwrap();
        assert!(lane.enrolled.is_empty());
        assert!(lane.enrollment_capacity_remaining());
    }

    #[test]
    fn capacity_return_keeps_oversized_window_inside_local_display() {
        for (sx, sy, sw, sh, ww, wh) in [
            (0, 0, 3072, 1728, 6000, 4000),
            (-1920, 390, 1920, 1200, 1030, 860),
        ] {
            let (x, y, w, h) = super::capacity_return_rect(sx, sy, sw, sh, ww, wh, i64::from(sx) + sw, i64::from(sy) + 200);
            assert!(x > i64::from(sx) && y > i64::from(sy));
            assert!(x + w < i64::from(sx) + sw);
            assert!(y + h < i64::from(sy) + sh);
            assert!(w <= ww && h <= wh);
        }
    }
    #[test]
    fn capacity_return_stays_at_crossed_edge_and_preserves_parallel_position() {
        assert_eq!(super::capacity_return_rect(0,0,3072,1728,1000,800,3100,450), (2056,450,1000,800));
        assert_eq!(super::capacity_return_rect(-1920,390,1920,1200,800,600,-2500,600), (-1904,600,800,600));
        assert_eq!(super::capacity_return_rect(0,0,1920,1200,800,600,400,-500), (400,16,800,600));
        assert_eq!(super::capacity_return_rect(0,0,1920,1200,800,600,400,1300), (400,584,800,600));
    }
    #[test]
    fn capacity_return_uses_nearest_edge_when_origin_is_already_inside() {
        for (wx, wy, expected_x, expected_y) in [
            (30, 300, 16, 300),
            (1090, 300, 1104, 300),
            (500, 30, 500, 16),
            (500, 570, 500, 584),
        ] {
            assert_eq!(super::capacity_return_rect(0, 0, 1920, 1200, 800, 600, wx, wy),
                (expected_x, expected_y, 800, 600));
            assert_eq!(super::capacity_return_rect(-1920, 390, 1920, 1200, 800, 600,
                wx - 1920, wy + 390), (expected_x - 1920, expected_y + 390, 800, 600));
        }
    }
    use super::*;

    #[test]
    fn closure_inventory_uses_native_identity_not_viewport_eligibility() {
        let candidate = DesktopCandidate {
            window: Id128(1),
            address: "0x10".into(),
            native_address: 16,
            stable_id: Some("same-window".into()),
            expected_pid: Some(20),
        };
        // Empty eligible candidate list is normal off-viewport or on another
        // workspace; the complete mapped inventory still retains this source.
        let mut discovery = DesktopDiscovery {
            icons: BTreeMap::new(),
            z_order: BTreeMap::new(),
            active_window: None,
            raise_serial: 0,
            candidates: vec![],
            live: BTreeMap::from([(16, (20, "same-window".into()))]),
        };
        assert!(discovery.contains_source(&candidate, None));
        discovery.live.insert(16, (21, "same-window".into()));
        assert!(!discovery.contains_source(&candidate, None));
        discovery.live.insert(16, (20, "new-window".into()));
        assert!(!discovery.contains_source(&candidate, None));
        discovery.live.clear();
        assert!(!discovery.contains_source(&candidate, None));
    }

    #[test]
    fn discovery_id_matches_launcher_seed_and_avoids_stream_collision() {
        let seeded = Id128(0xed20_e6d8_1af5_1ba4_c3e4_8051_b38b_c706);
        assert_eq!(
            stable_window_id("fixture-window", Id128(1)).unwrap(),
            seeded
        );
        assert_ne!(stable_window_id("fixture-window", seeded).unwrap(), seeded);
    }

    #[test]
    fn local_discovery_adds_only_visible_crossing_windows_with_pinned_identity() {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixListener;
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("clients.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let worker = std::thread::spawn(move || {
            let (mut monitors, _) = listener.accept().unwrap();
            let mut query = [0; 10];
            monitors.read_exact(&mut query).unwrap();
            assert_eq!(&query, b"j/monitors");
            monitors
                .write_all(br#"[{"id":0,"x":0,"y":0,"activeWorkspace":{"id":1},"specialWorkspace":{"id":0}},{"id":2,"x":100,"y":0,"activeWorkspace":{"id":1},"specialWorkspace":{"id":0}}]"#)
                .unwrap();
            drop(monitors);
            let (mut peer, _) = listener.accept().unwrap();
            let mut request = [0; 9];
            peer.read_exact(&mut request).unwrap();
            assert_eq!(&request, b"j/clients");
            let mut clients = Vec::new();
            for (id, x, visible, pid) in [
                ("crossing", 90, true, 10),
                ("local", 0, true, 11),
                ("hidden", 110, false, 12),
                ("reused", 110, true, 99),
                ("second", 120, true, 14),
                ("inactive-workspace", 120, true, 15),
                ("tiled-overhang", 120, true, 16),
                ("tiled-remote", 120, true, 17),
            ] {
                clients.push(serde_json::json!({
                    "address": format!("0x{pid:x}"), "mapped": true,
                    "visible": visible, "at": [x, 0], "size": [20, 20],
                    "pid": pid, "stableId": id,
                    "workspace": {"id": if pid == 15 {2} else {1}},
                    "floating": pid != 16 && pid != 17,
                    "monitor": if pid == 17 {2} else {0},
                }));
            }
            peer.write_all(&serde_json::to_vec(&clients).unwrap())
                .unwrap();
        });
        let pinned = DesktopCandidate {
            window: Id128(99),
            address: "0x63".into(),
            native_address: 99,
            stable_id: Some("reused".into()),
            expected_pid: Some(13),
        };
        let candidates = discover_local_candidates(
            socket,
            DesktopViewport {
                topology_generation: 1,
                bounds: DesktopRect {
                    x_millidip: 100_000,
                    y_millidip: 0,
                    width_millidip: 100_000,
                    height_millidip: 100_000,
                },
            },
            BTreeMap::from([("reused".into(), pinned)]),
            Id128(1),
        )
        .unwrap();
        worker.join().unwrap();
        let candidates = candidates.candidates;
        assert_eq!(candidates.len(), 3);
        assert_eq!(candidates[0].stable_id.as_deref(), Some("crossing"));
        assert_eq!(candidates[1].stable_id.as_deref(), Some("second"));
        assert_eq!(candidates[2].stable_id.as_deref(), Some("tiled-remote"));
    }

    #[test]
    fn capacity_return_does_not_mutate_a_retiled_window() {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixListener;
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("retiled.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let worker = std::thread::spawn(move || {
            // Identity validation and the immediately preceding layout check.
            // There must be no subsequent monitor lookup or mutation command.
            for _ in 0..2 {
                let (mut peer, _) = listener.accept().unwrap();
                let mut request = [0; 9];
                peer.read_exact(&mut request).unwrap();
                assert_eq!(&request, b"j/clients");
                peer.write_all(br#"[{"address":"0x10","mapped":true,"visible":true,"pid":16,"stableId":"retiled","floating":false,"at":[120,0],"size":[20,20]}]"#).unwrap();
            }
        });
        let candidate = DesktopCandidate {
            window: Id128(16), address: "0x10".into(), native_address: 16,
            stable_id: Some("retiled".into()), expected_pid: Some(16),
        };
        assert!(!return_rejected_to_local(socket,
            crate::desktop_config::AtlasDisplayConfig {x:0,y:0,width:100,height:100,scale:1.},
            &candidate).unwrap());
        worker.join().unwrap();
    }

    fn frame(x: f64, y: f64, width: f64, height: f64) -> crate::hyprcapture_gpu_wire::HcgfFrame {
        crate::hyprcapture_gpu_wire::HcgfFrame {
            sequence: 1,
            capture_monotonic_ns: 1,
            geometry_epoch: 1,
            logical_x: x,
            logical_y: y,
            logical_width: width,
            logical_height: height,
            image_width: 2,
            image_height: 2,
            fourcc: crate::hyprcapture_gpu_wire::FORMAT_ABGR8888,
            stride: 8,
            modifier: 0,
            offset: 0,
            crop_x: 0,
            crop_y: 0,
            crop_width: 2,
            crop_height: 2,
            flip_y: false,
            shadow: None,
        }
    }

    #[test]
    fn exact_hcgf_bounds_intersection_treats_touch_as_outside() {
        let viewport = DesktopRect {
            x_millidip: 0,
            y_millidip: 0,
            width_millidip: 1000,
            height_millidip: 1000,
        };
        assert!(intersects(
            viewport,
            hcgf_bounds(&frame(0.5, 0.5, 1.0, 1.0)).unwrap()
        ));
        assert!(!intersects(
            viewport,
            hcgf_bounds(&frame(1.0, 0.0, 1.0, 1.0)).unwrap()
        ));
    }
}
