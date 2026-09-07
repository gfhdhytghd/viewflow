//! One-shot native `HyprCapture` import.
//!
//! This deliberately imports one compositor artifact at a time.  `HyprCapture`
//! owns (and currently retains) its session artifact directory; this module
//! does not attempt a continuous-capture lifecycle or delete files it did not
//! create.

use std::{
    ffi::CString,
    fs::{self, File},
    io::{Read, Write},
    os::{
        fd::{FromRawFd, OwnedFd},
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, PermissionsExt},
        },
    },
    path::{Component, Path, PathBuf},
    process::{Command, Stdio},
    sync::atomic::{AtomicU64, Ordering},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow, bail, ensure};
use bytes::Bytes;
use serde_json::{Value, json};

use crate::{
    hyprcapture_control::{GpuStreamRequest, StreamRequest},
    hyprcapture_gpu_socket::HyprCaptureGpuSocketReceiver,
    hyprcapture_socket::{
        AcceptOutcome, GpuAcceptOutcome, HyprCaptureSocketListener, HyprCaptureSocketReceiver,
    },
};

const MAX_DIMENSION: usize = 32_768;
const MAX_ARTIFACT_BYTES: usize = 512 * 1024 * 1024;
const MAX_JSON_BYTES: usize = 8 * 1024 * 1024;
const MAX_REQUEST_BYTES: usize = 64 * 1024;
const MAX_WINDOW_ADDRESS_BYTES: usize = 4_096;
const VFBG_HEADER_BYTES: usize = 20;
static REQUEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug)]
pub struct CapturedRawFrame {
    /// A version-1 VFBG wire payload: premultiplied BGRA8, top-down rows.
    pub payload: Bytes,
    pub logical_width: f64,
    pub logical_height: f64,
    pub capture_elapsed: Duration,
}

/// An authenticated, explicitly stopped `HyprCapture` stream session.
///
/// Dropping this deliberately does not send a stop request or unlink runtime
/// paths: those are external state changes requiring `stop_stream`.
pub struct HyprCaptureStreamSession {
    request_id: String,
    request_dir: PathBuf,
    socket_path: PathBuf,
    _listener: HyprCaptureSocketListener,
    pub receiver: HyprCaptureSocketReceiver,
}

impl HyprCaptureStreamSession {
    #[must_use]
    pub fn request_id(&self) -> &str {
        &self.request_id
    }
    #[must_use]
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    #[allow(clippy::missing_errors_doc)]
    pub async fn stop_stream(self, timeout: Duration) -> Result<()> {
        tokio::task::spawn_blocking(move || self.stop_blocking(timeout))
            .await
            .context("HyprCapture stream stop worker failed")?
    }

    fn stop_blocking(self, timeout: Duration) -> Result<()> {
        if timeout.is_zero() || timeout > Duration::from_secs(30) {
            bail!("timeout must be in (0, 30 seconds]");
        }
        let deadline = Instant::now() + timeout;
        let record = StreamRequest {
            id: &self.request_id,
            window_address: "0x1",
            socket_path: self
                .socket_path
                .to_str()
                .ok_or_else(|| anyhow!("socket path is not UTF-8"))?,
            fps: 1,
        };
        let path = write_json_request(
            &self.request_dir,
            "stop",
            &serde_json::to_vec(&record.stop_record())?,
        )?;
        let expression = format!(
            "hl.plugin.hyprcapture.window_stream_stop({})",
            serde_json::to_string(&path.to_string_lossy().as_ref())
                .expect("path JSON encoding cannot fail")
        );
        invoke_hyprctl(&expression, deadline)?;
        let response = read_private_file(&self.request_dir, &path, 4096)?;
        record
            .validate_stopped(&response)
            .context("validate HyprCapture stream stop response")
    }
}

/// Authenticated, explicitly stopped HCGF GPU stream session.
///
/// Dropping this neither emits HCGR nor stops the producer. If a frame cannot
/// prove native source reads/encoding, retire the GPU receiver/session instead
/// of releasing the source allocation.
pub struct GpuStreamSession {
    independent_provider: bool,
    request_id: String,
    request_dir: PathBuf,
    socket_path: PathBuf,
    _listener: HyprCaptureSocketListener,
    pub receiver: HyprCaptureGpuSocketReceiver,
}

/// Exact producer stop authority retained separately while an atlas owns the
/// authenticated receiver. Dropping this is not a confirmed producer stop.
pub struct GpuStreamControl {
    independent_provider: bool,
    request_id: String,
    request_dir: PathBuf,
    socket_path: PathBuf,
    _listener: HyprCaptureSocketListener,
}

impl GpuStreamSession {
    /// Move the receiver into a shared atlas without losing the exact producer
    /// identity needed for checked shutdown. Keep the control until shutdown;
    /// do not send stop while a GPU reader is still using an allocation.
    #[must_use]
    pub fn into_parts(self) -> (HyprCaptureGpuSocketReceiver, GpuStreamControl) {
        let Self {
            independent_provider,
            request_id,
            request_dir,
            socket_path,
            _listener: listener,
            receiver,
        } = self;
        (
            receiver,
            GpuStreamControl {
                independent_provider,
                request_id,
                request_dir,
                socket_path,
                _listener: listener,
            },
        )
    }

    #[must_use]
    pub fn request_id(&self) -> &str {
        &self.request_id
    }

    #[must_use]
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    #[allow(clippy::missing_errors_doc)]
    pub async fn stop_stream(self, timeout: Duration) -> Result<()> {
        let (receiver, control) = self.into_parts();
        // Keep the receiver inside the worker, including when its async waiter
        // is cancelled. The producer must not observe an early socket close.
        tokio::task::spawn_blocking(move || {
            let result = control.stop_blocking(timeout, &mut invoke_hyprctl);
            drop(receiver);
            result
        })
        .await
        .context("HyprCapture GPU stream stop worker failed")?
    }
}

impl GpuStreamControl {
    #[must_use]
    pub fn request_id(&self) -> &str {
        &self.request_id
    }

    /// # Errors
    /// Requires an exact positive stop response from this producer. This does
    /// not emit HCGR or assert that any outstanding GPU read completed.
    pub async fn stop_stream(self, timeout: Duration) -> Result<()> {
        Self::begin_stop(self, timeout)
            .await
            .context("HyprCapture GPU stream stop worker failed")?
    }

    pub(crate) fn begin_stop(self, timeout: Duration) -> tokio::task::JoinHandle<Result<()>> {
        tokio::task::spawn_blocking(move || self.stop_blocking(timeout, &mut invoke_hyprctl))
    }

    fn stop_blocking(
        self,
        timeout: Duration,
        invoke: &mut impl FnMut(&str, Instant) -> Result<()>,
    ) -> Result<()> {
        if timeout.is_zero() || timeout > Duration::from_secs(30) {
            bail!("timeout must be in (0, 30 seconds]");
        }
        let record = GpuStreamRequest {
            id: &self.request_id,
            window_address: "0x1",
            socket_path: self
                .socket_path
                .to_str()
                .ok_or_else(|| anyhow!("socket path is not UTF-8"))?,
            fps: 1,
        };
        request_gpu_stream_stop(
            &self.request_dir,
            &record,
            Instant::now() + timeout,
            &mut |expression, deadline| {
                let expression = provider_expression(expression, self.independent_provider);
                invoke(&expression, deadline)
            },
        )
    }
}

/// Retains every producer stop authority and the actual in-flight stop worker.
/// Cancelling a shutdown wait does not start a second stop or lose its result;
/// a later call resumes that worker, then attempts the remaining producers.
/// The atlas must stop submitting GPU work before invoking this owner.
pub struct GpuStreamShutdown {
    queued: std::collections::VecDeque<GpuStreamControl>,
    pending: Option<(String, tokio::task::JoinHandle<Result<()>>)>,
    failures: Vec<String>,
    source_names: std::collections::BTreeMap<viewflow_protocol::WindowId, String>,
    retiring: std::collections::BTreeMap<
        viewflow_protocol::WindowId,
        tokio::task::JoinHandle<Result<()>>,
    >,
}

impl GpuStreamShutdown {
    #[must_use]
    pub fn new(controls: Vec<GpuStreamControl>) -> Self {
        Self {
            queued: controls.into(),
            pending: None,
            failures: Vec::new(),
            source_names: Default::default(),
            retiring: Default::default(),
        }
    }

    pub(crate) fn new_named(
        controls: Vec<(viewflow_protocol::WindowId, GpuStreamControl)>,
    ) -> Self {
        let names = controls
            .iter()
            .map(|(window, control)| (*window, control.request_id().to_owned()))
            .collect();
        let mut owner = Self::new(controls.into_iter().map(|(_, control)| control).collect());
        owner.source_names = names;
        owner
    }

    pub(crate) fn push_named(
        &mut self,
        window: viewflow_protocol::WindowId,
        control: GpuStreamControl,
    ) {
        self.source_names
            .insert(window, control.request_id().to_owned());
        self.push(control);
    }

    /// The caller has removed an idle collector slot, proving no GPU reader
    /// owns its allocation. Keep the actual worker until its exact stop result.
    pub(crate) fn begin_remove(
        &mut self,
        window: viewflow_protocol::WindowId,
        timeout: Duration,
    ) -> Result<()> {
        self.begin_remove_with(window, timeout, GpuStreamControl::begin_stop)
    }

    fn begin_remove_with(
        &mut self,
        window: viewflow_protocol::WindowId,
        timeout: Duration,
        begin: impl FnOnce(GpuStreamControl, Duration) -> tokio::task::JoinHandle<Result<()>>,
    ) -> Result<()> {
        ensure!(
            self.pending.is_none() && self.failures.is_empty(),
            "atlas shutdown already started"
        );
        ensure!(
            !timeout.is_zero() && timeout <= Duration::from_secs(30),
            "invalid GPU stop timeout"
        );
        if self.retiring.contains_key(&window) {
            return Ok(());
        }
        let name = self
            .source_names
            .get(&window)
            .context("atlas source stop identity missing")?;
        let position = self
            .queued
            .iter()
            .position(|control| control.request_id() == name)
            .context("atlas source stop authority missing")?;
        let control = self
            .queued
            .remove(position)
            .expect("located stop authority");
        self.retiring.insert(window, begin(control, timeout));
        Ok(())
    }

    pub(crate) async fn poll_removals(&mut self) -> Result<Vec<viewflow_protocol::WindowId>> {
        let completed: Vec<_> = self
            .retiring
            .iter()
            .filter(|(_, worker)| worker.is_finished())
            .map(|(window, _)| *window)
            .collect();
        for window in &completed {
            let outcome = self
                .retiring
                .get_mut(window)
                .expect("completed worker retained")
                .await;
            self.retiring.remove(window);
            self.source_names.remove(window);
            match outcome {
                Ok(Ok(())) => {}
                Ok(Err(error)) => self.failures.push(format!("{window:?}: {error:#}")),
                Err(error) => self
                    .failures
                    .push(format!("{window:?}: stop worker failed: {error}")),
            }
        }
        ensure!(
            self.failures.is_empty(),
            "GPU producer shutdown unconfirmed: {}",
            self.failures.join("; ")
        );
        Ok(completed)
    }

    /// Retain a newly enrolled producer's exact stop authority. This is only
    /// valid before shutdown starts; callers must stop an unaccepted producer
    /// themselves so an orphan cannot survive a failed enrollment.
    pub(crate) fn push(&mut self, control: GpuStreamControl) {
        debug_assert!(self.pending.is_none() && self.failures.is_empty());
        self.queued.push_back(control);
    }

    #[must_use]
    pub fn is_confirmed(&self) -> bool {
        self.queued.is_empty()
            && self.pending.is_none()
            && self.retiring.is_empty()
            && self.failures.is_empty()
    }

    /// Attempt every exact producer, even if an earlier stop fails. Timeout is
    /// per producer and does not renew a previously started stop's deadline.
    /// # Errors
    /// Invalid bounds, worker failure or any unconfirmed stop is reported. A
    /// failed stop remains recorded; repeated calls cannot erase that failure.
    pub async fn shutdown(&mut self, timeout: Duration) -> Result<()> {
        self.shutdown_with(timeout, GpuStreamControl::begin_stop)
            .await
    }

    async fn shutdown_with(
        &mut self,
        timeout: Duration,
        mut begin: impl FnMut(GpuStreamControl, Duration) -> tokio::task::JoinHandle<Result<()>>,
    ) -> Result<()> {
        anyhow::ensure!(
            !timeout.is_zero() && timeout <= Duration::from_secs(30),
            "invalid GPU stop timeout"
        );
        // These workers retain their original deadlines even if this global
        // shutdown wait is cancelled and resumed.
        while let Some(window) = self.retiring.keys().next().copied() {
            let outcome = self
                .retiring
                .get_mut(&window)
                .expect("retained removal")
                .await;
            self.retiring.remove(&window);
            self.source_names.remove(&window);
            match outcome {
                Ok(Ok(())) => {}
                Ok(Err(error)) => self.failures.push(format!("{window:?}: {error:#}")),
                Err(error) => self
                    .failures
                    .push(format!("{window:?}: stop worker failed: {error}")),
            }
        }
        loop {
            if self.pending.is_none() {
                let Some(control) = self.queued.pop_front() else {
                    break;
                };
                self.pending = Some((control.request_id().to_owned(), begin(control, timeout)));
            }
            let (_, handle) = self.pending.as_mut().context("GPU stop worker missing")?;
            let outcome = handle.await;
            let (identity, _) = self.pending.take().context("GPU stop result missing")?;
            match outcome {
                Ok(Ok(())) => (),
                Ok(Err(error)) => self.failures.push(format!("{identity}: {error:#}")),
                Err(error) => self
                    .failures
                    .push(format!("{identity}: stop worker failed: {error}")),
            }
        }
        anyhow::ensure!(
            self.failures.is_empty(),
            "GPU producer shutdown unconfirmed: {}",
            self.failures.join("; ")
        );
        Ok(())
    }
}

/// Start the opt-in `window-gpu` HCGF producer and authenticate its peer.
#[allow(clippy::missing_errors_doc)]
pub async fn start_gpu_stream(
    window_address: &str,
    fps: u16,
    compositor_pid: u32,
    timeout: Duration,
) -> Result<GpuStreamSession> {
    let window_address = window_address.to_owned();
    tokio::task::spawn_blocking(move || {
        start_gpu_stream_blocking(&window_address, fps, compositor_pid, timeout)
    })
    .await
    .context("HyprCapture GPU stream start worker failed")?
}

fn provider_expression(expression: &str, independent: bool) -> String {
    if independent {
        expression.replacen("hl.plugin.hyprcapture.", "hl.plugin.viewflow_capture.", 1)
    } else {
        expression.to_owned()
    }
}

/// Start the independent Viewflow capture plugin using the same GPU wire codec.
/// # Errors
/// No fallback to `HyprCapture` is performed; start/stop use the same provider.
pub async fn start_viewflow_gpu_stream(
    window_address: &str,
    fps: u16,
    compositor_pid: u32,
    timeout: Duration,
) -> Result<GpuStreamSession> {
    let address = window_address.to_owned();
    tokio::task::spawn_blocking(move || {
        validate_arguments(&address, 1, timeout)?;
        anyhow::ensure!(compositor_pid > 0, "compositor PID is required");
        let base = private_root()?;
        let mut session = start_gpu_stream_blocking_at_root(
            &address,
            fps,
            compositor_pid,
            Instant::now() + timeout,
            &base,
            &mut |expression, deadline| {
                invoke_hyprctl(&provider_expression(expression, true), deadline)
            },
        )?;
        session.independent_provider = true;
        Ok(session)
    })
    .await
    .context("Viewflow capture startup worker failed")?
}

fn start_gpu_stream_blocking(
    window_address: &str,
    fps: u16,
    compositor_pid: u32,
    timeout: Duration,
) -> Result<GpuStreamSession> {
    validate_arguments(window_address, 1, timeout)?;
    if compositor_pid == 0 {
        bail!("compositor PID is required")
    }
    let deadline = Instant::now() + timeout;
    let base = private_root()?;
    start_gpu_stream_blocking_at_root(
        window_address,
        fps,
        compositor_pid,
        deadline,
        &base,
        &mut invoke_hyprctl,
    )
}

fn start_gpu_stream_blocking_at_root(
    window_address: &str,
    fps: u16,
    compositor_pid: u32,
    deadline: Instant,
    base: &Path,
    invoke: &mut impl FnMut(&str, Instant) -> Result<()>,
) -> Result<GpuStreamSession> {
    let request_id = format!("gpu-stream-{}", unique_id());
    let request_dir = base.join(&request_id);
    mkdir_private(&request_dir).context("create private HyprCapture GPU stream directory")?;
    let metadata = fs::symlink_metadata(&request_dir)?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != effective_uid()
        || metadata.permissions().mode() & 0o777 != 0o700
    {
        bail!("HyprCapture GPU stream directory is not owner-private")
    }
    let socket_path = request_dir.join("gpu-frames.sock");
    let socket_text = socket_path
        .to_str()
        .ok_or_else(|| anyhow!("socket path is not UTF-8"))?;
    let record = GpuStreamRequest {
        id: &request_id,
        window_address,
        socket_path: socket_text,
        fps,
    };
    let encoded_request = record.encode()?;
    let listener = HyprCaptureSocketListener::bind(&socket_path)?;
    let request_path = write_json_request(&request_dir, "gpu-start", &encoded_request)?;
    let expression = format!(
        "hl.plugin.hyprcapture.window_stream_start({})",
        serde_json::to_string(&request_path.to_string_lossy().as_ref())
            .expect("path JSON encoding cannot fail")
    );
    if let Err(error) = invoke(&expression, deadline) {
        return Err(start_gpu_failure(&request_dir, &record, &error, invoke));
    }
    let started = read_private_file(&request_dir, &request_path, 4096).and_then(|response| {
        record
            .validate_started(&response)
            .context("validate HyprCapture GPU stream start response")
    });
    if let Err(error) = started {
        return Err(start_gpu_failure(&request_dir, &record, &error, invoke));
    }
    loop {
        match listener.accept_gpu(effective_uid(), compositor_pid) {
            Err(error) => return Err(start_gpu_failure(&request_dir, &record, &error, invoke)),
            Ok(GpuAcceptOutcome::Receiver(receiver)) => {
                return Ok(GpuStreamSession {
                    independent_provider: false,
                    request_id,
                    request_dir,
                    socket_path,
                    _listener: listener,
                    receiver,
                });
            }
            Ok(GpuAcceptOutcome::WouldBlock) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(5));
            }
            Ok(GpuAcceptOutcome::WouldBlock) => {
                let cause =
                    anyhow!("HyprCapture GPU stream producer did not connect before timeout");
                return Err(start_gpu_failure(&request_dir, &record, &cause, invoke));
            }
        }
    }
}

/// A producer may still be running. Callers must not retry enrollment or
/// report a clean retirement after this failure.
#[derive(Debug)]
pub(crate) struct GpuStreamStopUnconfirmed;

impl std::fmt::Display for GpuStreamStopUnconfirmed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("explicit GPU stop unproven")
    }
}

impl std::error::Error for GpuStreamStopUnconfirmed {}

fn start_gpu_failure(
    dir: &Path,
    record: &GpuStreamRequest<'_>,
    cause: &anyhow::Error,
    invoke: &mut impl FnMut(&str, Instant) -> Result<()>,
) -> anyhow::Error {
    match request_gpu_stream_stop(dir, record, Instant::now() + Duration::from_secs(2), invoke) {
        Ok(()) => anyhow!("{cause}; explicit GPU stop confirmed"),
        Err(stop_error) => anyhow::Error::new(GpuStreamStopUnconfirmed)
            .context(format!("{cause}; explicit GPU stop unproven: {stop_error}")),
    }
}

fn request_gpu_stream_stop(
    dir: &Path,
    record: &GpuStreamRequest<'_>,
    deadline: Instant,
    invoke: &mut impl FnMut(&str, Instant) -> Result<()>,
) -> Result<()> {
    let path = write_json_request(dir, "gpu-stop", &serde_json::to_vec(&record.stop_record())?)?;
    let expression = format!(
        "hl.plugin.hyprcapture.window_stream_stop({})",
        serde_json::to_string(&path.to_string_lossy().as_ref())
            .expect("path JSON encoding cannot fail")
    );
    invoke(&expression, deadline)?;
    record.validate_stopped(&read_private_file(dir, &path, 4096)?)
}

#[allow(clippy::missing_errors_doc)]
pub async fn start_stream(
    window_address: &str,
    fps: u16,
    max_pixel_bytes: usize,
    compositor_pid: u32,
    timeout: Duration,
) -> Result<HyprCaptureStreamSession> {
    let window_address = window_address.to_owned();
    tokio::task::spawn_blocking(move || {
        start_stream_blocking(
            &window_address,
            fps,
            max_pixel_bytes,
            compositor_pid,
            timeout,
        )
    })
    .await
    .context("HyprCapture stream start worker failed")?
}

fn start_stream_blocking(
    window_address: &str,
    fps: u16,
    max_pixel_bytes: usize,
    compositor_pid: u32,
    timeout: Duration,
) -> Result<HyprCaptureStreamSession> {
    validate_arguments(window_address, max_pixel_bytes, timeout)?;
    if compositor_pid == 0 {
        bail!("compositor PID is required")
    }
    let deadline = Instant::now() + timeout;
    let base = private_root()?;
    start_stream_blocking_at_root(
        window_address,
        fps,
        max_pixel_bytes,
        compositor_pid,
        deadline,
        &base,
        &mut invoke_hyprctl,
    )
}

fn start_stream_blocking_at_root(
    window_address: &str,
    fps: u16,
    max_pixel_bytes: usize,
    compositor_pid: u32,
    deadline: Instant,
    base: &Path,
    invoke: &mut impl FnMut(&str, Instant) -> Result<()>,
) -> Result<HyprCaptureStreamSession> {
    let request_id = format!("stream-{}", unique_id());
    let request_dir = base.join(&request_id);
    mkdir_private(&request_dir).context("create private HyprCapture stream directory")?;
    let metadata = fs::symlink_metadata(&request_dir)?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != effective_uid()
        || metadata.permissions().mode() & 0o777 != 0o700
    {
        bail!("HyprCapture stream directory is not owner-private")
    }
    let socket_path = request_dir.join("frames.sock");
    let socket_text = socket_path
        .to_str()
        .ok_or_else(|| anyhow!("socket path is not UTF-8"))?;
    let record = StreamRequest {
        id: &request_id,
        window_address,
        socket_path: socket_text,
        fps,
    };
    // Validate all request fields before binding any socket or invoking the plugin.
    let encoded_request = record.encode()?;
    let listener = HyprCaptureSocketListener::bind(&socket_path)?;
    let request_path = write_json_request(&request_dir, "start", &encoded_request)?;
    let expression = format!(
        "hl.plugin.hyprcapture.window_stream_start({})",
        serde_json::to_string(&request_path.to_string_lossy().as_ref())
            .expect("path JSON encoding cannot fail")
    );
    if let Err(error) = invoke(&expression, deadline) {
        return Err(start_failure(&request_dir, &record, &error, invoke));
    }
    let started = read_private_file(&request_dir, &request_path, 4096).and_then(|response| {
        record
            .validate_started(&response)
            .context("validate HyprCapture stream start response")
    });
    if let Err(error) = started {
        return Err(start_failure(&request_dir, &record, &error, invoke));
    }
    loop {
        match listener.accept(
            effective_uid(),
            compositor_pid,
            u64::try_from(max_pixel_bytes)?,
        ) {
            Err(error) => return Err(start_failure(&request_dir, &record, &error, invoke)),
            Ok(AcceptOutcome::Receiver(receiver)) => {
                return Ok(HyprCaptureStreamSession {
                    request_id,
                    request_dir,
                    socket_path,
                    _listener: listener,
                    receiver,
                });
            }
            Ok(AcceptOutcome::WouldBlock) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(5));
            }
            Ok(AcceptOutcome::WouldBlock) => {
                let cause = anyhow!("HyprCapture stream producer did not connect before timeout");
                return Err(start_failure(&request_dir, &record, &cause, invoke));
            }
        }
    }
}

fn start_failure(
    dir: &Path,
    record: &StreamRequest<'_>,
    cause: &anyhow::Error,
    invoke: &mut impl FnMut(&str, Instant) -> Result<()>,
) -> anyhow::Error {
    match request_stream_stop(dir, record, Instant::now() + Duration::from_secs(2), invoke) {
        Ok(()) => anyhow!("{cause}; explicit stop confirmed"),
        Err(stop_error) => anyhow!("{cause}; explicit stop unproven: {stop_error}"),
    }
}

fn request_stream_stop(
    dir: &Path,
    record: &StreamRequest<'_>,
    deadline: Instant,
    invoke: &mut impl FnMut(&str, Instant) -> Result<()>,
) -> Result<()> {
    let path = write_json_request(dir, "stop", &serde_json::to_vec(&record.stop_record())?)?;
    let expression = format!(
        "hl.plugin.hyprcapture.window_stream_stop({})",
        serde_json::to_string(&path.to_string_lossy().as_ref())
            .expect("path JSON encoding cannot fail")
    );
    invoke(&expression, deadline)?;
    record.validate_stopped(&read_private_file(dir, &path, 4096)?)
}

fn write_json_request(root: &Path, label: &str, data: &[u8]) -> Result<PathBuf> {
    if data.is_empty() || data.len() > MAX_REQUEST_BYTES {
        bail!("HyprCapture request exceeds its bounded request size")
    }
    let path = root.join(format!("viewflow-{label}-{}.json", unique_id()));
    create_private_file(root, &path, data)?;
    Ok(path)
}

/// Capture one compositor-rendered window image through `HyprCapture`'s private
/// request-file API.  It is intentionally not a streaming capture API.
#[allow(clippy::missing_errors_doc)]
pub async fn capture_window(
    window_address: &str,
    max_pixel_bytes: usize,
    timeout: Duration,
) -> Result<CapturedRawFrame> {
    let window_address = window_address.to_owned();
    tokio::task::spawn_blocking(move || {
        capture_window_blocking(&window_address, max_pixel_bytes, timeout)
    })
    .await
    .context("HyprCapture worker task failed")?
}

fn capture_window_blocking(
    window_address: &str,
    max_pixel_bytes: usize,
    timeout: Duration,
) -> Result<CapturedRawFrame> {
    validate_arguments(window_address, max_pixel_bytes, timeout)?;
    let started = Instant::now();
    let deadline = started + timeout;
    let root = private_root()?;
    let request_path = write_request(&root, window_address)?;
    let expression = format!(
        "hl.plugin.hyprcapture.window_capture({})",
        serde_json::to_string(&request_path.to_string_lossy().as_ref())
            .expect("path JSON encoding cannot fail"),
    );
    invoke_hyprctl(&expression, deadline)?;
    if Instant::now() >= deadline {
        bail!("HyprCapture timed out before its response could be read");
    }
    let response = read_private_file(&root, &request_path, MAX_JSON_BYTES)?;
    let metadata = parse_response(&response, window_address, max_pixel_bytes)?;
    if Instant::now() >= deadline {
        bail!("HyprCapture timed out before its artifact could be imported");
    }
    let rgba = read_private_file(&root, &metadata.artifact_path, metadata.pixel_bytes)?;
    if rgba.len() != metadata.pixel_bytes {
        bail!("HyprCapture artifact byte length does not match its dimensions");
    }
    let payload = vfb_g_payload(metadata.width, metadata.height, &rgba)?;
    Ok(CapturedRawFrame {
        payload,
        logical_width: metadata.full_width,
        logical_height: metadata.full_height,
        capture_elapsed: started.elapsed(),
    })
}

fn validate_arguments(
    window_address: &str,
    max_pixel_bytes: usize,
    timeout: Duration,
) -> Result<()> {
    if window_address.is_empty() || window_address.len() > MAX_WINDOW_ADDRESS_BYTES {
        bail!("window address is required and must be at most {MAX_WINDOW_ADDRESS_BYTES} bytes");
    }
    if max_pixel_bytes == 0 || max_pixel_bytes > MAX_ARTIFACT_BYTES {
        bail!("max_pixel_bytes must be in 1..={MAX_ARTIFACT_BYTES}");
    }
    if timeout.is_zero() || timeout > Duration::from_secs(30) {
        bail!("timeout must be in (0, 30 seconds]");
    }
    Ok(())
}

fn private_root() -> Result<PathBuf> {
    let uid = effective_uid();
    let name = format!("hyprcapture-{uid}");
    for base in [Path::new("/dev/shm"), Path::new("/tmp")] {
        let Ok(base_metadata) = fs::symlink_metadata(base) else {
            continue;
        };
        if !base_metadata.is_dir() || base_metadata.file_type().is_symlink() {
            continue;
        }
        let root = base.join(&name);
        match mkdir_private(&root) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(_) => continue,
        }
        let Ok(metadata) = fs::symlink_metadata(&root) else {
            continue;
        };
        if metadata.is_dir()
            && !metadata.file_type().is_symlink()
            && metadata.uid() == uid
            && metadata.permissions().mode() & 0o777 == 0o700
        {
            return Ok(root);
        }
    }
    bail!("unable to establish an owner-only HyprCapture runtime root")
}

fn write_request(root: &Path, window_address: &str) -> Result<PathBuf> {
    let request = json!({
        "id": unique_id(),
        "defaults": {
            "mode": "window", "fullscreenScope": "all", "windowBackground": "transparent",
            "windowBorder": "keep", "windowShadow": "keep", "recordWindowBackend": "auto",
        },
        "mode": "window",
        "targetGeometry": {"x": 0, "y": 0, "width": 1, "height": 1},
        "windowAddress": window_address,
    });
    let data = serde_json::to_vec(&request).context("serialize HyprCapture request")?;
    if data.len() > MAX_REQUEST_BYTES {
        bail!("HyprCapture request exceeds its bounded request size")
    }
    for _ in 0..16 {
        let path = root.join(format!("viewflow-window-{}.json", unique_id()));
        match create_private_file(root, &path, &data) {
            Ok(()) => return Ok(path),
            Err(error) if error.to_string().contains("already exists") => {}
            Err(error) => return Err(error),
        }
    }
    bail!("could not allocate a unique HyprCapture request path")
}

fn unique_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |value| value.as_nanos());
    format!(
        "{:x}{:x}{:x}",
        std::process::id(),
        nanos,
        REQUEST_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    )
}

fn invoke_hyprctl(expression: &str, deadline: Instant) -> Result<()> {
    let mut child = Command::new("hyprctl")
        .args(["eval", expression])
        // Do not pipe unbounded command output: it is neither protocol input
        // nor reliable status, and inherited pipes could deadlock the child.
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("start hyprctl eval for HyprCapture")?;
    loop {
        if let Some(status) = child.try_wait().context("poll hyprctl")? {
            if status.success() {
                return Ok(());
            }
            bail!("hyprctl eval rejected the HyprCapture request ({status})");
        }
        if Instant::now() >= deadline {
            // This `Child` is the exact process spawned above.  Waiting after
            // kill prevents a zombie without signaling an unrelated process.
            let _ = child.kill();
            let _ = child.wait();
            bail!("hyprctl eval timed out");
        }
        thread::sleep(Duration::from_millis(5));
    }
}

#[derive(Debug)]
struct ArtifactMetadata {
    artifact_path: PathBuf,
    width: usize,
    height: usize,
    pixel_bytes: usize,
    full_width: f64,
    full_height: f64,
}

fn parse_response(
    bytes: &[u8],
    expected_address: &str,
    max_pixel_bytes: usize,
) -> Result<ArtifactMetadata> {
    let response: Value =
        serde_json::from_slice(bytes).context("parse bounded HyprCapture response JSON")?;
    let defaults = response
        .get("defaults")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("response is missing defaults"))?;
    for (key, expected) in [
        ("mode", "window"),
        ("windowBackground", "transparent"),
        ("windowBorder", "keep"),
        ("windowShadow", "keep"),
    ] {
        if defaults.get(key).and_then(Value::as_str) != Some(expected) {
            bail!("response changed required capture policy: {key}");
        }
    }
    let windows = response
        .get("windows")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("response is missing windows"))?;
    if windows.len() != 1 {
        bail!("response must contain exactly one window")
    }
    let window = windows[0]
        .as_object()
        .ok_or_else(|| anyhow!("response window is invalid"))?;
    if window.get("address").and_then(Value::as_str) != Some(expected_address) {
        bail!("response window identity does not match the selected address");
    }
    if window.get("artifactTopDown").and_then(Value::as_bool) != Some(true) {
        bail!("only top-down HyprCapture artifacts are supported");
    }
    let artifact = window
        .get("artifactPath")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("response artifact path is invalid"))?;
    if artifact.len() > 4_096 {
        bail!("response artifact path exceeds its protocol limit");
    }
    let width = bounded_dimension(window.get("artifactWidth"), "artifactWidth")?;
    let height = bounded_dimension(window.get("artifactHeight"), "artifactHeight")?;
    let pixel_bytes = width
        .checked_mul(height)
        .and_then(|value| value.checked_mul(4))
        .ok_or_else(|| anyhow!("artifact dimensions overflow"))?;
    if pixel_bytes > max_pixel_bytes || pixel_bytes > MAX_ARTIFACT_BYTES {
        bail!("artifact exceeds max_pixel_bytes")
    }
    let visible = rect(window.get("visibleGeometry"), "visibleGeometry")?;
    let full = rect(window.get("fullGeometry"), "fullGeometry")?;
    if !full_encloses_visible(full, visible) {
        bail!("fullGeometry does not enclose visibleGeometry")
    }
    Ok(ArtifactMetadata {
        artifact_path: PathBuf::from(artifact),
        width,
        height,
        pixel_bytes,
        full_width: full.2,
        full_height: full.3,
    })
}

fn bounded_dimension(value: Option<&Value>, name: &str) -> Result<usize> {
    let value = value
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("response {name} is invalid"))?;
    let value = usize::try_from(value).context("dimension does not fit this platform")?;
    if !(1..=MAX_DIMENSION).contains(&value) {
        bail!("response {name} is outside the protocol limit")
    }
    Ok(value)
}

fn rect(value: Option<&Value>, name: &str) -> Result<(f64, f64, f64, f64)> {
    let object = value
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("response {name} is invalid"))?;
    let number = |key: &str| -> Result<f64> {
        let value = object
            .get(key)
            .and_then(Value::as_f64)
            .ok_or_else(|| anyhow!("response {name}.{key} is invalid"))?;
        if !value.is_finite() || !(-1_000_000.0..=1_000_000.0).contains(&value) {
            bail!("response {name}.{key} is outside bounds")
        }
        Ok(value)
    };
    let result = (
        number("x")?,
        number("y")?,
        number("width")?,
        number("height")?,
    );
    if result.2 < 1.0 || result.3 < 1.0 {
        bail!("response {name} dimensions are invalid")
    }
    Ok(result)
}

fn full_encloses_visible(full: (f64, f64, f64, f64), visible: (f64, f64, f64, f64)) -> bool {
    // Full geometry may include asymmetric borders and transparent shadows, so
    // equality is not required.  Permit only floating-point representation
    // noise at the shared edges.
    const EDGE_EPSILON: f64 = 0.000_001;
    let (full_x, full_y, full_width, full_height) = full;
    let (visible_x, visible_y, visible_width, visible_height) = visible;
    full_x <= visible_x + EDGE_EPSILON
        && full_y <= visible_y + EDGE_EPSILON
        && full_x + full_width + EDGE_EPSILON >= visible_x + visible_width
        && full_y + full_height + EDGE_EPSILON >= visible_y + visible_height
}

fn vfb_g_payload(width: usize, height: usize, rgba: &[u8]) -> Result<Bytes> {
    let pixels = width
        .checked_mul(height)
        .and_then(|value| value.checked_mul(4))
        .ok_or_else(|| anyhow!("artifact dimensions overflow"))?;
    if rgba.len() != pixels {
        bail!("RGBA payload does not match artifact dimensions")
    }
    let total = VFBG_HEADER_BYTES
        .checked_add(pixels)
        .ok_or_else(|| anyhow!("VFBG size overflow"))?;
    let mut output = Vec::with_capacity(total);
    output.extend_from_slice(b"VFBG\x01\x01\0\0");
    for value in [
        u32::try_from(width)?,
        u32::try_from(height)?,
        u32::try_from(
            width
                .checked_mul(4)
                .ok_or_else(|| anyhow!("stride overflow"))?,
        )?,
    ] {
        output.extend_from_slice(&value.to_be_bytes());
    }
    for pixel in rgba.chunks_exact(4) {
        let [red, green, blue, alpha] =
            <[u8; 4]>::try_from(pixel).expect("chunks_exact guarantees pixel size");
        let premultiply = |channel: u8| {
            u8::try_from((u16::from(channel) * u16::from(alpha) + 127) / 255)
                .expect("premultiplied channel fits u8")
        };
        output.extend_from_slice(&[
            premultiply(blue),
            premultiply(green),
            premultiply(red),
            alpha,
        ]);
    }
    Ok(Bytes::from(output))
}

fn create_private_file(root: &Path, path: &Path, data: &[u8]) -> Result<()> {
    let root_fd = open_directory(root)?;
    let relative = private_relative(root, path)?;
    if relative.components().count() != 1 {
        bail!("request path must be directly inside the private root")
    }
    let file = open_at(
        &root_fd,
        relative.as_os_str(),
        libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW,
        0o600,
    )
    .with_context(|| format!("create private request {}", path.display()))?;
    let mut file = File::from(file);
    file.write_all(data)
        .context("write private HyprCapture request")?;
    file.sync_data()
        .context("flush private HyprCapture request")?;
    Ok(())
}

fn read_private_file(root: &Path, path: &Path, maximum: usize) -> Result<Vec<u8>> {
    let relative = private_relative(root, path)?;
    let mut components = relative.components().peekable();
    let mut directory = open_directory(root)?;
    while let Some(component) = components.next() {
        let Component::Normal(name) = component else {
            bail!("private path is not normalized")
        };
        if components.peek().is_some() {
            directory = open_at(
                &directory,
                name,
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW,
                0,
            )
            .context("open private artifact directory without following symlinks")?;
        } else {
            let file = open_at(&directory, name, libc::O_RDONLY | libc::O_NOFOLLOW, 0)
                .context("open private artifact without following symlinks")?;
            return read_checked_file(File::from(file), maximum);
        }
    }
    bail!("private path has no file name")
}

fn private_relative<'a>(root: &Path, path: &'a Path) -> Result<&'a Path> {
    if !path.is_absolute() {
        bail!("HyprCapture private path must be absolute")
    }
    let relative = path
        .strip_prefix(root)
        .map_err(|_| anyhow!("HyprCapture path is outside its private runtime root"))?;
    if relative.as_os_str().is_empty()
        || relative
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        bail!("HyprCapture private path is not normalized")
    }
    Ok(relative)
}

fn read_checked_file(mut file: File, maximum: usize) -> Result<Vec<u8>> {
    let before = file.metadata().context("inspect private artifact")?;
    if !before.is_file()
        || before.uid() != effective_uid()
        || before.nlink() != 1
        || before.permissions().mode() & 0o022 != 0
    {
        bail!("private artifact ownership or mode is unsafe")
    }
    let size = usize::try_from(before.len()).context("artifact size does not fit this platform")?;
    if size == 0 || size > maximum {
        bail!("private artifact size is outside its bound")
    }
    let mut data = vec![0; size];
    file.read_exact(&mut data)
        .context("read bounded private artifact")?;
    let after = file.metadata().context("reinspect private artifact")?;
    if after.dev() != before.dev() || after.ino() != before.ino() || after.len() != before.len() {
        bail!("private artifact changed while it was read")
    }
    Ok(data)
}

fn open_directory(path: &Path) -> Result<OwnedFd> {
    let native = CString::new(path.as_os_str().as_bytes()).context("runtime path contains NUL")?;
    open_native(
        &native,
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        0,
    )
}

fn mkdir_private(path: &Path) -> std::io::Result<()> {
    let native = CString::new(path.as_os_str().as_bytes()).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "runtime path contains NUL",
        )
    })?;
    #[allow(unsafe_code)]
    let result = unsafe { libc::mkdir(native.as_ptr(), 0o700) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn open_at(
    directory: &OwnedFd,
    name: &std::ffi::OsStr,
    flags: i32,
    mode: libc::mode_t,
) -> Result<OwnedFd> {
    let native = CString::new(name.as_bytes()).context("private path component contains NUL")?;
    #[allow(unsafe_code)]
    let fd = unsafe {
        libc::openat(
            std::os::fd::AsRawFd::as_raw_fd(directory),
            native.as_ptr(),
            flags | libc::O_CLOEXEC,
            mode,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error()).context("openat private path");
    }
    #[allow(unsafe_code)]
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn open_native(path: &CString, flags: i32, mode: libc::mode_t) -> Result<OwnedFd> {
    #[allow(unsafe_code)]
    let fd = unsafe { libc::open(path.as_ptr(), flags, mode) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error()).context("open private runtime path");
    }
    #[allow(unsafe_code)]
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn effective_uid() -> u32 {
    #[allow(unsafe_code)]
    unsafe {
        libc::geteuid()
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn independent_provider_only_changes_the_lua_namespace() {
        let command = "hl.plugin.hyprcapture.window_stream_stop(\"/private/request.json\")";
        assert_eq!(
            super::provider_expression(command, true),
            "hl.plugin.viewflow_capture.window_stream_stop(\"/private/request.json\")"
        );
        assert_eq!(super::provider_expression(command, false), command);
    }
    fn gpu_control(root: &std::path::Path, id: &str) -> super::GpuStreamControl {
        use super::*;
        fs::set_permissions(root, fs::Permissions::from_mode(0o700)).unwrap();
        let request_dir = root.join(id);
        fs::create_dir(&request_dir).unwrap();
        fs::set_permissions(&request_dir, fs::Permissions::from_mode(0o700)).unwrap();
        let socket_path = request_dir.join("frames.sock");
        let listener = HyprCaptureSocketListener::bind(&socket_path).unwrap();
        GpuStreamControl {
            independent_provider: false,
            request_id: id.to_owned(),
            request_dir,
            socket_path,
            _listener: listener,
        }
    }

    #[tokio::test]
    async fn isolated_stop_failure_cannot_be_erased_by_later_shutdown() {
        use super::*;
        use viewflow_protocol::Id128;
        let root = tempfile::tempdir().unwrap();
        let mut owner = GpuStreamShutdown::new_named(vec![(
            Id128(1),
            gpu_control(root.path(), "failed-isolated"),
        )]);
        owner
            .begin_remove_with(Id128(1), Duration::from_millis(100), |_, _| {
                tokio::spawn(async { anyhow::bail!("exact native stop not confirmed") })
            })
            .unwrap();
        tokio::task::yield_now().await;
        assert!(
            owner
                .poll_removals()
                .await
                .unwrap_err()
                .to_string()
                .contains("not confirmed")
        );
        assert!(!owner.is_confirmed());
        assert!(
            owner
                .shutdown_with(Duration::from_millis(100), |_, _| panic!(
                    "failed authority cannot restart"
                ))
                .await
                .is_err()
        );
        assert!(!owner.is_confirmed());
    }

    #[tokio::test]
    async fn isolated_stop_retains_worker_and_leaves_other_producer_running() {
        use super::*;
        use viewflow_protocol::Id128;
        let root = tempfile::tempdir().unwrap();
        let mut owner = GpuStreamShutdown::new_named(vec![
            (Id128(1), gpu_control(root.path(), "isolated-a")),
            (Id128(2), gpu_control(root.path(), "isolated-b")),
        ]);
        let (finish, wait) = tokio::sync::oneshot::channel();
        owner
            .begin_remove_with(Id128(1), Duration::from_millis(100), |control, timeout| {
                assert_eq!(control.request_id(), "isolated-a");
                assert_eq!(timeout, Duration::from_millis(100));
                tokio::spawn(async move {
                    wait.await.unwrap();
                    drop(control);
                    Ok(())
                })
            })
            .unwrap();
        assert!(owner.poll_removals().await.unwrap().is_empty());
        assert_eq!(owner.queued.len(), 1);
        assert!(!owner.is_confirmed());
        // Repeated removal must retain the first worker/deadline.
        owner
            .begin_remove_with(Id128(1), Duration::from_secs(1), |_, _| {
                panic!("duplicate stop")
            })
            .unwrap();
        finish.send(()).unwrap();
        tokio::task::yield_now().await;
        assert_eq!(owner.poll_removals().await.unwrap(), vec![Id128(1)]);
        assert_eq!(owner.queued.front().unwrap().request_id(), "isolated-b");
        owner
            .shutdown_with(Duration::from_millis(100), |control, _| {
                assert_eq!(control.request_id(), "isolated-b");
                tokio::spawn(async { Ok(()) })
            })
            .await
            .unwrap();
        assert!(owner.is_confirmed());
    }

    #[test]
    fn split_control_requires_its_exact_positive_stop_receipt() {
        use super::*;
        let root = tempfile::tempdir().unwrap();
        for (id, returned_id, success) in [
            ("stream-a", "stream-a", true),
            ("stream-b", "foreign", false),
        ] {
            let control = gpu_control(root.path(), id);
            let mut calls = 0;
            let result = control.stop_blocking(Duration::from_secs(1), &mut |expression, _| {
                calls += 1;
                assert!(expression.starts_with("hl.plugin.hyprcapture.window_stream_stop("));
                let argument = expression.split_once('(').unwrap().1.strip_suffix(')').unwrap();
                let path: String = serde_json::from_str(argument)?;
                let request: Value = serde_json::from_slice(&fs::read(&path)?)?;
                assert_eq!(request, json!({"streamId": id}));
                fs::write(path, serde_json::to_vec(&json!({"ok": true, "version": 1, "streamId": returned_id, "stopped": true}))?)?;
                Ok(())
            });
            assert_eq!(calls, 1);
            assert_eq!(result.is_ok(), success);
        }
    }

    #[test]
    #[allow(unsafe_code)] // Test-only local Unix socketpair with checked FD ownership.
    fn split_session_keeps_receiver_independent_of_control_lifetime() {
        use super::*;
        use std::os::fd::AsRawFd;
        let root = tempfile::tempdir().unwrap();
        let control = gpu_control(root.path(), "stream-split");
        let mut fds = [-1; 2];
        // SAFETY: socketpair writes exactly two descriptors into valid storage.
        assert_eq!(
            unsafe {
                libc::socketpair(
                    libc::AF_UNIX,
                    libc::SOCK_SEQPACKET | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
                    0,
                    fds.as_mut_ptr(),
                )
            },
            0
        );
        // SAFETY: successful socketpair returned two fresh, uniquely owned FDs.
        let (receiver_fd, peer) =
            unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        let receiver =
            HyprCaptureGpuSocketReceiver::new(receiver_fd, effective_uid(), std::process::id())
                .unwrap();
        let GpuStreamControl {
            independent_provider,
            request_id,
            request_dir,
            socket_path,
            _listener: listener,
        } = control;
        let session = GpuStreamSession {
            independent_provider,
            request_id,
            request_dir,
            socket_path,
            _listener: listener,
            receiver,
        };
        let (mut receiver, control) = session.into_parts();
        assert_eq!(control.request_id(), "stream-split");
        drop(control);
        assert!(matches!(
            receiver.recv_frame().unwrap(),
            crate::hyprcapture_gpu_socket::GpuReceiveOutcome::WouldBlock
        ));
        drop(receiver);
        let mut byte = 0_u8;
        // SAFETY: the peer remains owned; recv writes at most one local byte.
        assert_eq!(
            unsafe { libc::recv(peer.as_raw_fd(), (&raw mut byte).cast(), 1, 0) },
            0
        );
    }

    #[tokio::test]
    async fn atlas_shutdown_resumes_same_worker_and_attempts_remaining_streams() {
        use super::*;
        use std::sync::{Arc, Mutex};
        let root = tempfile::tempdir().unwrap();
        let mut shutdown = GpuStreamShutdown::new(vec![
            gpu_control(root.path(), "stream-a"),
            gpu_control(root.path(), "stream-b"),
        ]);
        let calls = Arc::new(Mutex::new(Vec::new()));
        let first_calls = calls.clone();
        let (started, started_rx) = tokio::sync::oneshot::channel();
        let (release, release_rx) = tokio::sync::oneshot::channel();
        let mut first = Some((started, release_rx));
        let mut waiting = Box::pin(shutdown.shutdown_with(
            Duration::from_secs(1),
            move |control, _| {
                assert_eq!(control.request_id(), "stream-a");
                first_calls
                    .lock()
                    .unwrap()
                    .push(control.request_id().to_owned());
                let (started, release_rx) = first.take().unwrap();
                tokio::spawn(async move {
                    started.send(()).unwrap();
                    release_rx.await.unwrap();
                    drop(control);
                    bail!("unconfirmed fixture stop")
                })
            },
        ));
        tokio::select! {
            result = &mut waiting => panic!("shutdown unexpectedly returned: {result:?}"),
            result = started_rx => result.unwrap(),
        }
        drop(waiting);
        assert!(!shutdown.is_confirmed());
        release.send(()).unwrap();
        let second_calls = calls.clone();
        let error = shutdown
            .shutdown_with(Duration::from_secs(1), move |control, _| {
                assert_eq!(control.request_id(), "stream-b");
                second_calls
                    .lock()
                    .unwrap()
                    .push(control.request_id().to_owned());
                tokio::spawn(async move {
                    drop(control);
                    Ok(())
                })
            })
            .await
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("stream-a: unconfirmed fixture stop")
        );
        assert_eq!(*calls.lock().unwrap(), ["stream-a", "stream-b"]);
        assert!(!shutdown.is_confirmed());
        assert!(
            shutdown
                .shutdown_with(Duration::from_secs(1), |_, _| panic!("stop replay"))
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn atlas_shutdown_preserves_controls_on_invalid_timeout() {
        use super::*;
        let root = tempfile::tempdir().unwrap();
        let mut shutdown = GpuStreamShutdown::new(vec![gpu_control(root.path(), "stream-a")]);
        assert!(
            shutdown
                .shutdown_with(Duration::ZERO, |_, _| panic!("invalid stop dispatched"))
                .await
                .is_err()
        );
        assert!(!shutdown.is_confirmed());
        shutdown
            .shutdown_with(Duration::from_secs(1), |control, _| {
                assert_eq!(control.request_id(), "stream-a");
                tokio::spawn(async move {
                    drop(control);
                    Ok(())
                })
            })
            .await
            .unwrap();
        assert!(shutdown.is_confirmed());
        shutdown
            .shutdown_with(Duration::from_secs(1), |_, _| panic!("stop replay"))
            .await
            .unwrap();
    }

    #[test]
    fn gpu_start_timeout_stops_only_its_window_gpu_request() {
        use super::*;
        let root = tempfile::tempdir().unwrap();
        fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let mut calls = 0;
        let mut invoke = |expression: &str, _deadline: Instant| -> Result<()> {
            calls += 1;
            let quoted = expression
                .split_once('(')
                .unwrap()
                .1
                .strip_suffix(')')
                .unwrap();
            let path: String = serde_json::from_str(quoted)?;
            let request: Value = serde_json::from_slice(&fs::read(&path)?)?;
            if calls == 1 {
                assert!(expression.contains("window_stream_start"));
                assert_eq!(request["mode"], "window-gpu");
                fs::write(
                    &path,
                    serde_json::to_vec(&json!({
                        "ok": true, "version": 1, "streamId": request["id"],
                        "socketPath": request["socketPath"], "mode": "window-gpu"
                    }))?,
                )?;
            } else {
                assert_eq!(calls, 2);
                assert!(expression.contains("window_stream_stop"));
                assert_eq!(request.as_object().unwrap().len(), 1);
                assert!(
                    request["streamId"]
                        .as_str()
                        .unwrap()
                        .starts_with("gpu-stream-")
                );
                fs::write(
                    &path,
                    serde_json::to_vec(&json!({
                        "ok": true, "version": 1, "streamId": request["streamId"], "stopped": true
                    }))?,
                )?;
            }
            Ok(())
        };
        let result = start_gpu_stream_blocking_at_root(
            "0x123",
            60,
            std::process::id(),
            Instant::now(),
            root.path(),
            &mut invoke,
        );
        let error = match result {
            Ok(_) => panic!("unexpected GPU stream success"),
            Err(error) => error.to_string(),
        };
        assert_eq!(calls, 2);
        assert!(error.contains("explicit GPU stop confirmed"));
    }

    #[test]
    fn gpu_failed_start_retains_unconfirmed_cleanup_type() {
        let root = tempfile::tempdir().unwrap();
        fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let mut calls = 0;
        let result = start_gpu_stream_blocking_at_root(
            "0x123",
            60,
            std::process::id(),
            Instant::now(),
            root.path(),
            &mut |_, _| {
                calls += 1;
                if calls == 1 {
                    bail!("ambiguous GPU start");
                }
                bail!("unavailable GPU stop");
            },
        );
        let error = match result {
            Ok(_) => panic!("unexpected start success"),
            Err(error) => error,
        };
        assert_eq!(calls, 2);
        assert!(error.is::<GpuStreamStopUnconfirmed>());
        assert!(error.to_string().contains("ambiguous GPU start"));
        assert!(error.to_string().contains("unavailable GPU stop"));
    }

    #[test]
    fn malformed_start_response_still_attempts_explicit_stop() {
        use super::*;
        let root = tempfile::tempdir().unwrap();
        fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let mut calls = 0;
        let mut invoke = |expression: &str, _deadline: Instant| -> Result<()> {
            calls += 1;
            if calls == 2 {
                assert!(expression.contains("window_stream_stop"));
                bail!("fixture stop unavailable");
            }
            let quoted = expression
                .split_once('(')
                .unwrap()
                .1
                .strip_suffix(')')
                .unwrap();
            let path: String = serde_json::from_str(quoted)?;
            fs::write(path, b"{}")?;
            Ok(())
        };
        let result = start_stream_blocking_at_root(
            "0x123",
            60,
            4,
            std::process::id(),
            Instant::now() + Duration::from_secs(1),
            root.path(),
            &mut invoke,
        );
        let error = match result {
            Ok(_) => panic!("unexpected success"),
            Err(e) => e.to_string(),
        };
        assert_eq!(calls, 2);
        assert!(error.contains("validate HyprCapture stream start response"));
        assert!(error.contains("stop unproven"));
    }
    #[test]
    fn uncertain_start_attempts_stop_with_fresh_budget_and_preserves_cause() {
        use super::*;
        for confirm_stop in [false, true] {
            let root = tempfile::tempdir().unwrap();
            fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
            let mut calls = 0;
            let mut invoke = |expression: &str, deadline: Instant| -> Result<()> {
                calls += 1;
                if calls == 1 {
                    assert!(expression.contains("window_stream_start"));
                    bail!("simulated ambiguous start failure");
                }
                assert_eq!(calls, 2);
                assert!(expression.contains("window_stream_stop"));
                assert!(deadline > Instant::now() + Duration::from_secs(1));
                if !confirm_stop {
                    bail!("simulated stop failure");
                }
                let quoted = expression
                    .split_once('(')
                    .unwrap()
                    .1
                    .strip_suffix(')')
                    .unwrap();
                let path: String = serde_json::from_str(quoted)?;
                let request: Value = serde_json::from_slice(&fs::read(&path)?)?;
                fs::write(
                    &path,
                    serde_json::to_vec(&json!({
                        "ok": true, "version": 1, "streamId": request["streamId"], "stopped": true
                    }))?,
                )?;
                Ok(())
            };
            let result = start_stream_blocking_at_root(
                "0x123",
                60,
                4,
                std::process::id(),
                Instant::now(),
                root.path(),
                &mut invoke,
            );
            let error = match result {
                Ok(_) => panic!("unexpected start success"),
                Err(e) => e.to_string(),
            };
            assert_eq!(calls, 2, "{error}");
            assert!(error.contains("simulated ambiguous start failure"));
            assert!(error.contains(if confirm_stop {
                "stop confirmed"
            } else {
                "stop unproven"
            }));
        }
    }
    use super::*;

    fn response(width: u64, height: u64) -> Value {
        json!({"defaults":{"mode":"window","windowBackground":"transparent","windowBorder":"keep","windowShadow":"keep"},"windows":[{"address":"0xabc","artifactTopDown":true,"artifactPath":"/tmp/hyprcapture-1/a.rgba","artifactWidth":width,"artifactHeight":height,"visibleGeometry":{"x":0,"y":0,"width":3,"height":4},"fullGeometry":{"x":0,"y":0,"width":5,"height":6}}]})
    }

    #[test]
    fn converts_straight_rgba_to_premultiplied_vfbg() {
        let payload = vfb_g_payload(2, 1, &[100, 50, 25, 128, 1, 2, 3, 255]).unwrap();
        assert_eq!(
            &payload[..20],
            b"VFBG\x01\x01\0\0\0\0\0\x02\0\0\0\x01\0\0\0\x08"
        );
        assert_eq!(&payload[20..], &[13, 25, 50, 128, 3, 2, 1, 255]);
    }

    #[test]
    fn rejects_metadata_that_exceeds_the_caller_limit() {
        let bytes = serde_json::to_vec(&response(2, 2)).unwrap();
        assert!(parse_response(&bytes, "0xabc", 15).is_err());
    }

    #[test]
    fn rejects_metadata_identity_mismatch() {
        let bytes = serde_json::to_vec(&response(1, 1)).unwrap();
        assert!(parse_response(&bytes, "0xdef", 4).is_err());
    }

    #[test]
    fn rejects_pixel_data_that_disagrees_with_metadata() {
        assert!(vfb_g_payload(2, 1, &[0, 0, 0, 0]).is_err());
    }

    #[test]
    fn accepts_asymmetric_decoration_around_visible_content() {
        let mut value = response(1, 1);
        let window = value["windows"]
            .as_array_mut()
            .unwrap()
            .first_mut()
            .unwrap();
        window["visibleGeometry"] = json!({"x": 10, "y": 20, "width": 100, "height": 60});
        window["fullGeometry"] = json!({"x": 8, "y": 18, "width": 108, "height": 74});
        assert!(parse_response(&serde_json::to_vec(&value).unwrap(), "0xabc", 4).is_ok());
    }

    #[test]
    fn rejects_visible_content_outside_full_geometry() {
        let mut value = response(1, 1);
        let window = value["windows"]
            .as_array_mut()
            .unwrap()
            .first_mut()
            .unwrap();
        window["visibleGeometry"] = json!({"x": 10, "y": 20, "width": 101, "height": 60});
        window["fullGeometry"] = json!({"x": 8, "y": 18, "width": 102, "height": 64});
        assert!(parse_response(&serde_json::to_vec(&value).unwrap(), "0xabc", 4).is_err());
    }
}
