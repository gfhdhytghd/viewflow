//! Send a bounded sequence of staged or freshly captured raw-BGRA frames.
//!
//! This is deliberately a bounded bring-up tool, not a window-streaming
//! service. It uses mutual TLS, QUIC datagrams for the frame, and one reliable
//! bidirectional stream for a clock exchange and frame-tagged receipts.

use std::{
    env,
    fs::File,
    io::Read,
    net::SocketAddr,
    pin::Pin,
    task::{Context as TaskContext, Poll},
    time::{Duration, Instant},
};

#[cfg(windows)]
use std::{
    collections::VecDeque,
    io::{BufRead, BufReader, Write},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread::{self, JoinHandle},
};
#[cfg(windows)]
use tokio::sync::oneshot;

use anyhow::{Context, Result, bail};
use bytes::Bytes;
use quinn::{Endpoint, RecvStream, SendStream};
use tokio::io::{AsyncRead, ReadBuf};
#[cfg(any(windows, test))]
use viewflow_core::FrameQueueConfig;
use viewflow_protocol::Id128;
#[cfg(any(windows, test))]
use viewflow_transport::MediaDatagram;
#[cfg(windows)]
use viewflow_transport::build_server_config;
use viewflow_transport::{
    ClockEstimate, MediaPlane, MediaPlaneFrame, PeerIdentity, RawBgraPayload, build_client_config,
};
#[cfg(any(windows, test))]
use viewflowd::raw_session::{
    RawWindowSession, RawWindowSessionConfig, RawWindowSessionDrop, RawWindowSessionOutcome,
};

const WINDOW_ID: Id128 = Id128(1);
const INITIAL_GEOMETRY_EPOCH: u64 = 1;
const FIRST_FRAME_ID: u64 = 1;
const DEFAULT_MAX_BYTES: usize = 4 * 1024 * 1024;
const DEFAULT_TIMEOUT_MS: u64 = 10_000;
const DEFAULT_VISIBLE_MS: u64 = 2_000;
const MAX_VISIBLE_MS: u64 = 60_000;
const DEFAULT_FRAME_COUNT: u16 = 1;
const MAX_FRAME_COUNT: u16 = 300;
// Receiver media collection remains bounded to one diagnostic frame interval;
// a separate reliable control wait leaves room for its terminal receipt to
// traverse QUIC after that bounded result has been produced.
#[cfg_attr(not(windows), allow(dead_code))]
const PER_FRAME_WAIT: Duration = Duration::from_millis(100);
const CONTROL_RECEIPT_WAIT: Duration = Duration::from_secs(1);

const CLOCK_PROBE: u8 = 1;
const CLOCK_REPLY: u8 = 2;
const CLOCK_ESTIMATE: u8 = 3;
const COMPLETION: u8 = 4;
const RECEIVER_READY: u8 = 5;
const LOGICAL_SIZE: u8 = 7;
const FRAME_COUNT: u8 = 8;
// Resize is deliberately a reliable, frame-boundary control exchange.  A
// sender must not place media from the advertised epoch on the unordered
// datagram plane before its matching acknowledgement arrives.
const GEOMETRY: u8 = 9;
const GEOMETRY_ACK: u8 = 10;

#[derive(Clone, Copy, Debug, PartialEq)]
struct LogicalSize {
    width: f64,
    height: f64,
}

impl LogicalSize {
    fn checked(width: f64, height: f64) -> Result<Self> {
        if !width.is_finite()
            || !height.is_finite()
            || width <= 0.0
            || height <= 0.0
            || width > 100_000.0
            || height > 100_000.0
        {
            bail!("invalid logical frame dimensions");
        }
        Ok(Self { width, height })
    }

    fn encode(self) -> [u8; 16] {
        let mut bytes = [0; 16];
        bytes[..8].copy_from_slice(&self.width.to_be_bytes());
        bytes[8..].copy_from_slice(&self.height.to_be_bytes());
        bytes
    }

    #[cfg(any(windows, test))]
    fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() != 16 {
            bail!("invalid logical size record length");
        }
        Self::checked(
            f64::from_be_bytes(bytes[..8].try_into()?),
            f64::from_be_bytes(bytes[8..].try_into()?),
        )
    }
}

/// A deliberately explicit diagnostic blur rectangle.  This is not inferred
/// from source alpha and is bounded against the negotiated initial geometry.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct CompositionBlurRect {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
}

impl CompositionBlurRect {
    fn parse(value: &str) -> Result<Self> {
        let parts: Vec<_> = value.split(',').collect();
        if parts.len() != 4 {
            bail!("--composition-blur-rect must be x,y,w,h");
        }
        let x = parts[0].parse().context("invalid composition blur x")?;
        let y = parts[1].parse().context("invalid composition blur y")?;
        let width: u32 = parts[2].parse().context("invalid composition blur width")?;
        let height: u32 = parts[3]
            .parse()
            .context("invalid composition blur height")?;
        if width == 0 || height == 0 {
            bail!("--composition-blur-rect width and height must be positive");
        }
        Ok(Self {
            x,
            y,
            width,
            height,
        })
    }

    #[cfg(any(windows, test))]
    fn validate_for(self, size: LogicalSize) -> Result<()> {
        let right = f64::from(self.x) + f64::from(self.width);
        let bottom = f64::from(self.y) + f64::from(self.height);
        if right > size.width || bottom > size.height {
            bail!(
                "--composition-blur-rect {},{},{},{} exceeds initial logical geometry {}x{}",
                self.x,
                self.y,
                self.width,
                self.height,
                size.width,
                size.height
            );
        }
        Ok(())
    }

    #[cfg(windows)]
    fn argument(self) -> String {
        format!("{},{},{},{}", self.x, self.y, self.width, self.height)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct GeometryUpdate {
    sequence: u64,
    epoch: u64,
    size: LogicalSize,
}

impl GeometryUpdate {
    const ENCODED_LEN: usize = 32;

    fn encode(self) -> [u8; Self::ENCODED_LEN] {
        let mut bytes = [0; Self::ENCODED_LEN];
        bytes[..8].copy_from_slice(&self.sequence.to_be_bytes());
        bytes[8..16].copy_from_slice(&self.epoch.to_be_bytes());
        bytes[16..].copy_from_slice(&self.size.encode());
        bytes
    }

    #[cfg(any(windows, test))]
    fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() != Self::ENCODED_LEN {
            bail!("invalid geometry update length {}", bytes.len());
        }
        Ok(Self {
            sequence: u64::from_be_bytes(bytes[..8].try_into().expect("fixed geometry")),
            epoch: u64::from_be_bytes(bytes[8..16].try_into().expect("fixed geometry")),
            size: LogicalSize::decode(&bytes[16..])?,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct GeometryAck {
    sequence: u64,
    epoch: u64,
}

fn same_logical_size(left: LogicalSize, right: LogicalSize) -> bool {
    (left.width - right.width).abs() <= 0.001 && (left.height - right.height).abs() <= 0.001
}

impl GeometryAck {
    const ENCODED_LEN: usize = 16;

    #[cfg(any(windows, test))]
    fn encode(self) -> [u8; Self::ENCODED_LEN] {
        let mut bytes = [0; Self::ENCODED_LEN];
        bytes[..8].copy_from_slice(&self.sequence.to_be_bytes());
        bytes[8..].copy_from_slice(&self.epoch.to_be_bytes());
        bytes
    }

    fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() != Self::ENCODED_LEN {
            bail!("invalid geometry acknowledgement length {}", bytes.len());
        }
        Ok(Self {
            sequence: u64::from_be_bytes(bytes[..8].try_into().expect("fixed geometry ack")),
            epoch: u64::from_be_bytes(bytes[8..].try_into().expect("fixed geometry ack")),
        })
    }
}

#[cfg(windows)]
struct LogicalPresenter {
    proxy: viewflow_platform::windows_proxy::WindowsProxy,
    size: LogicalSize,
}

#[cfg(windows)]
impl LogicalPresenter {
    fn set_size(&mut self, size: LogicalSize) {
        self.size = size;
    }
}

#[cfg(windows)]
impl viewflowd::pixel_runtime::PixelPresenter for LogicalPresenter {
    fn present_pixels(
        &mut self,
        frame: &viewflow_platform::windows_proxy::BgraFrame,
    ) -> Result<(), viewflow_platform::windows_proxy::ProxyError> {
        self.proxy
            .present_logical(frame, self.size.width, self.size.height)
    }
}

/// One latest-frame slot feeding the isolated composition diagnostic.  The
/// Tokio receive loop never writes a child pipe: a wedged child can only block
/// this dedicated worker, and a newly completed frame replaces an older queued
/// frame rather than growing memory or delaying QUIC admission.
#[cfg(windows)]
struct CompositionPresenter {
    state: Arc<CompositionState>,
    child: Arc<Mutex<Child>>,
    writer: Option<JoinHandle<()>>,
    stdout: Option<JoinHandle<()>>,
    stderr: Option<JoinHandle<()>>,
    completions: Mutex<VecDeque<oneshot::Receiver<std::result::Result<u64, String>>>>,
}

#[cfg(windows)]
struct CompositionState {
    latest: Mutex<Option<QueuedCompositionFrame>>,
    ready: Condvar,
    closed: AtomicBool,
    failed: Mutex<Option<String>>,
    queued: AtomicU64,
    native_submitted: AtomicU64,
    native_submission_ns: AtomicU64,
    submitted_changed: Condvar,
    in_flight: AtomicBool,
}

#[cfg(windows)]
struct QueuedCompositionFrame {
    record: Vec<u8>,
    completion: oneshot::Sender<std::result::Result<u64, String>>,
}

#[cfg(windows)]
impl CompositionState {
    fn fail(&self, error: impl Into<String>) {
        let mut failed = self.failed.lock().expect("composition failure lock");
        if failed.is_none() {
            *failed = Some(error.into());
        }
        self.closed.store(true, Ordering::Release);
        self.ready.notify_all();
        self.submitted_changed.notify_all();
    }

    fn failure(&self) -> Option<String> {
        self.failed
            .lock()
            .expect("composition failure lock")
            .clone()
    }
}

#[cfg(windows)]
impl CompositionPresenter {
    fn spawn(
        path: &str,
        logical_size: LogicalSize,
        blur_rect: CompositionBlurRect,
        blur_radius: f64,
        visible: Duration,
        clock: MonotonicClock,
    ) -> Result<Self> {
        blur_rect.validate_for(logical_size)?;
        let logical_width = logical_size.width.to_string();
        let logical_height = logical_size.height.to_string();
        let blur_rect = blur_rect.argument();
        let blur_radius = blur_radius.to_string();
        let visible_ms = visible.as_millis().to_string();
        let mut child = Command::new(path)
            .args([
                "--stdin-frames",
                "--logical-width",
                &logical_width,
                "--logical-height",
                &logical_height,
                "--blur-rect",
                &blur_rect,
                "--radius",
                &blur_radius,
                "--visible-ms",
                &visible_ms,
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("start composition presenter {path}"))?;
        let stdin = child
            .stdin
            .take()
            .context("composition presenter has no stdin")?;
        let stdout = child
            .stdout
            .take()
            .context("composition presenter has no stdout")?;
        let stderr = child
            .stderr
            .take()
            .context("composition presenter has no stderr")?;
        let child = Arc::new(Mutex::new(child));
        let state = Arc::new(CompositionState {
            latest: Mutex::new(None),
            ready: Condvar::new(),
            closed: AtomicBool::new(false),
            failed: Mutex::new(None),
            queued: AtomicU64::new(0),
            native_submitted: AtomicU64::new(0),
            native_submission_ns: AtomicU64::new(0),
            submitted_changed: Condvar::new(),
            in_flight: AtomicBool::new(false),
        });
        let writer = Some(composition_writer(state.clone(), child.clone(), stdin));
        let stdout_state = state.clone();
        let stdout = Some(thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                match line {
                    Ok(line) => {
                        if let Some(count) = composition_submission_count(&line) {
                            // Use the waiter's mutex to avoid a notification
                            // between its predicate check and Condvar::wait.
                            let submission_guard = stdout_state
                                .failed
                                .lock()
                                .expect("composition acknowledgement lock");
                            stdout_state
                                .native_submission_ns
                                .store(clock.now_ns(), Ordering::Release);
                            stdout_state
                                .native_submitted
                                .store(count, Ordering::Release);
                            stdout_state.submitted_changed.notify_all();
                            drop(submission_guard);
                            eprintln!("composition presenter: {line}");
                        } else {
                            eprintln!("composition presenter: {line}");
                        }
                    }
                    Err(error) => {
                        stdout_state.fail(format!("read composition presenter stdout: {error}"));
                        return;
                    }
                }
            }
            if !stdout_state.closed.load(Ordering::Acquire) {
                stdout_state.fail("composition presenter stdout reached EOF");
            }
        }));
        let stderr_state = state.clone();
        let stderr = Some(thread::spawn(move || {
            for line in BufReader::new(stderr).lines() {
                match line {
                    Ok(line) => eprintln!("composition presenter stderr: {line}"),
                    Err(error) => {
                        stderr_state.fail(format!("read composition presenter stderr: {error}"));
                        return;
                    }
                }
            }
        }));
        Ok(Self {
            state,
            child,
            writer,
            stdout,
            stderr,
            completions: Mutex::new(VecDeque::new()),
        })
    }

    fn queue(
        &self,
        frame: &viewflow_platform::windows_proxy::BgraFrame,
    ) -> Result<(), viewflow_platform::windows_proxy::ProxyError> {
        if self.state.closed.load(Ordering::Acquire) {
            return Err(
                viewflow_platform::windows_proxy::ProxyError::NativeCallFailed(
                    "composition presenter is closed",
                ),
            );
        }
        if self.state.failure().is_some() {
            return Err(
                viewflow_platform::windows_proxy::ProxyError::NativeCallFailed(
                    "composition presenter failed",
                ),
            );
        }
        let mut record = Vec::with_capacity(20 + frame.pixels().len());
        record.extend_from_slice(b"VFBG\x01\x01\0\0");
        record.extend_from_slice(&frame.width().to_be_bytes());
        record.extend_from_slice(&frame.height().to_be_bytes());
        let stride = u32::try_from(frame.stride())
            .map_err(|_| viewflow_platform::windows_proxy::ProxyError::FrameSizeOverflow)?;
        record.extend_from_slice(&stride.to_be_bytes());
        record.extend_from_slice(frame.pixels());
        let mut latest = self.state.latest.lock().expect("composition latest lock");
        if self.state.closed.load(Ordering::Acquire) || self.state.failure().is_some() {
            return Err(
                viewflow_platform::windows_proxy::ProxyError::NativeCallFailed(
                    "composition presenter failed",
                ),
            );
        }
        if latest.is_some() || self.state.in_flight.swap(true, Ordering::AcqRel) {
            return Err(
                viewflow_platform::windows_proxy::ProxyError::NativeCallFailed(
                    "composition presenter already has one native submission in flight",
                ),
            );
        }
        let (completion, received_submission) = oneshot::channel();
        *latest = Some(QueuedCompositionFrame { record, completion });
        self.completions
            .lock()
            .expect("composition completion lock")
            .push_back(received_submission);
        let queued = self.state.queued.fetch_add(1, Ordering::AcqRel) + 1;
        let submitted = self.state.native_submitted.load(Ordering::Acquire);
        eprintln!(
            "composition frame queued={queued}; native_submitted={submitted} (queued is not GPU submission)"
        );
        self.state.ready.notify_one();
        Ok(())
    }

    async fn wait_for_submission(&self) -> Result<u64> {
        let completion = self
            .completions
            .lock()
            .expect("composition completion lock")
            .pop_front()
            .context("composition submission completion missing")?;
        match tokio::time::timeout(CONTROL_RECEIPT_WAIT, completion).await {
            Ok(Ok(Ok(submitted_ns))) => Ok(submitted_ns),
            Ok(Ok(Err(error))) => bail!("composition native submission failed: {error}"),
            Ok(Err(_)) => bail!("composition submission worker stopped before acknowledgement"),
            Err(_) => bail!("composition native submission acknowledgement timed out"),
        }
    }
}

#[cfg(windows)]
fn composition_writer(
    state: Arc<CompositionState>,
    child: Arc<Mutex<Child>>,
    mut stdin: ChildStdin,
) -> JoinHandle<()> {
    thread::spawn(move || {
        loop {
            let record = {
                let mut latest = state.latest.lock().expect("composition latest lock");
                while latest.is_none() && !state.closed.load(Ordering::Acquire) {
                    latest = state.ready.wait(latest).expect("composition latest wait");
                }
                latest.take()
            };
            let Some(QueuedCompositionFrame { record, completion }) = record else {
                break;
            };
            match child.lock().expect("composition child lock").try_wait() {
                Ok(Some(status)) => {
                    let error =
                        format!("composition presenter exited before frame write: {status}");
                    let _ = completion.send(Err(error.clone()));
                    state.fail(error);
                    break;
                }
                Ok(None) => {}
                Err(error) => {
                    let error = format!("query composition presenter: {error}");
                    let _ = completion.send(Err(error.clone()));
                    state.fail(error);
                    break;
                }
            }
            // Snapshot before the write: the child can submit and its stdout
            // reader can advance the count before this worker regains CPU.
            let target = state
                .native_submitted
                .load(Ordering::Acquire)
                .saturating_add(1);
            if let Err(error) = stdin.write_all(&record).and_then(|()| stdin.flush()) {
                let error = format!("write composition presenter stdin: {error}");
                let _ = completion.send(Err(error.clone()));
                state.fail(error);
                break;
            }
            let mut failed = state.failed.lock().expect("composition failure lock");
            while state.native_submitted.load(Ordering::Acquire) < target
                && !state.closed.load(Ordering::Acquire)
                && failed.is_none()
            {
                failed = state
                    .submitted_changed
                    .wait(failed)
                    .expect("composition submission wait");
            }
            let result = if state.native_submitted.load(Ordering::Acquire) >= target {
                Ok(state.native_submission_ns.load(Ordering::Acquire))
            } else {
                Err(failed.clone().unwrap_or_else(|| {
                    "composition presenter closed before native submission".to_owned()
                }))
            };
            drop(failed);
            let failed_result = result.clone().err();
            let _ = completion.send(result);
            state.in_flight.store(false, Ordering::Release);
            if let Some(error) = failed_result {
                state.fail(error);
                break;
            }
        }
    })
}

#[cfg(windows)]
fn composition_submission_count(line: &str) -> Option<u64> {
    let prefix = "submitted_frames=";
    let start = line.find(prefix)? + prefix.len();
    line[start..]
        .split_whitespace()
        .next()?
        .trim_end_matches(';')
        .parse()
        .ok()
}

#[cfg(windows)]
impl viewflowd::pixel_runtime::PixelPresenter for CompositionPresenter {
    fn present_pixels(
        &mut self,
        frame: &viewflow_platform::windows_proxy::BgraFrame,
    ) -> Result<(), viewflow_platform::windows_proxy::ProxyError> {
        self.queue(frame)
    }
}

#[cfg(windows)]
impl Drop for CompositionPresenter {
    fn drop(&mut self) {
        self.state.fail("composition presenter shutting down");
        // A blocked anonymous-pipe write must not keep shutdown alive. The
        // child handle remains outside the writer precisely for this cleanup.
        if let Ok(mut child) = self.child.lock() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
        if let Some(stdout) = self.stdout.take() {
            let _ = stdout.join();
        }
        if let Some(stderr) = self.stderr.take() {
            let _ = stderr.join();
        }
    }
}

#[cfg(windows)]
enum ReceiverPresenter {
    Gdi(LogicalPresenter),
    Composition(CompositionPresenter),
}

#[cfg(windows)]
impl ReceiverPresenter {
    fn set_size(&mut self, size: LogicalSize) -> Result<()> {
        match self {
            Self::Gdi(presenter) => {
                presenter.set_size(size);
                Ok(())
            }
            Self::Composition(_) => bail!(
                "composition presenter uses fixed diagnostic logical geometry/blur rectangle; refusing resize to {}x{}",
                size.width,
                size.height
            ),
        }
    }

    fn pump_events(&mut self) -> Result<bool> {
        match self {
            Self::Gdi(presenter) => presenter
                .proxy
                .pump_events()
                .context("pump native proxy events"),
            // Its own UI thread pumps messages; the receiver must stay free to
            // read QUIC media rather than synchronize on native presentation.
            Self::Composition(_) => Ok(true),
        }
    }

    async fn wait_for_submission(&mut self) -> Result<Option<u64>> {
        match self {
            Self::Gdi(_) => Ok(None),
            Self::Composition(presenter) => presenter.wait_for_submission().await.map(Some),
        }
    }
}

#[cfg(windows)]
impl viewflowd::pixel_runtime::PixelPresenter for ReceiverPresenter {
    fn present_pixels(
        &mut self,
        frame: &viewflow_platform::windows_proxy::BgraFrame,
    ) -> Result<(), viewflow_platform::windows_proxy::ProxyError> {
        match self {
            Self::Gdi(presenter) => presenter.present_pixels(frame),
            Self::Composition(presenter) => presenter.present_pixels(frame),
        }
    }
}
const REJECTION: u8 = 6;
const REJECTION_RECEIPT_LEN: usize = 49;

// These codes intentionally describe only the bounded diagnostic surface; no
// pixel contents, titles, paths, or peer identity are put on the wire.
#[cfg(windows)]
const REJECTION_DATAGRAM_DECODE: u8 = 1;
#[cfg(any(windows, test))]
const REJECTION_ASSEMBLY_LATE: u8 = 2;
#[cfg(windows)]
const REJECTION_ASSEMBLY_OTHER: u8 = 3;
#[cfg(windows)]
const REJECTION_ADMISSION: u8 = 4;
#[cfg(windows)]
const REJECTION_RECEIVER: u8 = 5;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RejectionReceipt {
    frame_id: u64,
    code: u8,
    packet_count: u32,
    chunk_index: u16,
    chunk_count: u16,
    first_arrival_elapsed_ns: u64,
    last_arrival_elapsed_ns: u64,
    normalized_source_age_ns: u64,
    uncertainty_ns: u64,
}

impl RejectionReceipt {
    #[cfg(any(windows, test))]
    fn encode(self) -> [u8; REJECTION_RECEIPT_LEN] {
        let mut bytes = [0; REJECTION_RECEIPT_LEN];
        bytes[..8].copy_from_slice(&self.frame_id.to_be_bytes());
        bytes[8] = self.code;
        bytes[9..13].copy_from_slice(&self.packet_count.to_be_bytes());
        bytes[13..15].copy_from_slice(&self.chunk_index.to_be_bytes());
        bytes[15..17].copy_from_slice(&self.chunk_count.to_be_bytes());
        bytes[17..25].copy_from_slice(&self.first_arrival_elapsed_ns.to_be_bytes());
        bytes[25..33].copy_from_slice(&self.last_arrival_elapsed_ns.to_be_bytes());
        bytes[33..41].copy_from_slice(&self.normalized_source_age_ns.to_be_bytes());
        bytes[41..].copy_from_slice(&self.uncertainty_ns.to_be_bytes());
        bytes
    }

    fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() != REJECTION_RECEIPT_LEN {
            bail!("invalid rejection receipt length {}", bytes.len());
        }
        Ok(Self {
            frame_id: u64::from_be_bytes(bytes[..8].try_into().expect("fixed receipt")),
            code: bytes[8],
            packet_count: u32::from_be_bytes(bytes[9..13].try_into().expect("fixed receipt")),
            chunk_index: u16::from_be_bytes(bytes[13..15].try_into().expect("fixed receipt")),
            chunk_count: u16::from_be_bytes(bytes[15..17].try_into().expect("fixed receipt")),
            first_arrival_elapsed_ns: u64::from_be_bytes(
                bytes[17..25].try_into().expect("fixed receipt"),
            ),
            last_arrival_elapsed_ns: u64::from_be_bytes(
                bytes[25..33].try_into().expect("fixed receipt"),
            ),
            normalized_source_age_ns: u64::from_be_bytes(
                bytes[33..41].try_into().expect("fixed receipt"),
            ),
            uncertainty_ns: u64::from_be_bytes(bytes[41..].try_into().expect("fixed receipt")),
        })
    }
}

#[cfg(windows)]
#[derive(Debug)]
struct MediaDiagnostics {
    started: Instant,
    packet_count: u32,
    first_arrival_elapsed_ns: Option<u64>,
    last_arrival_elapsed_ns: u64,
    chunk_index: u16,
    chunk_count: u16,
    normalized_source_age_ns: u64,
    uncertainty_ns: u64,
}

#[cfg(windows)]
impl MediaDiagnostics {
    fn new() -> Self {
        Self {
            started: Instant::now(),
            packet_count: 0,
            first_arrival_elapsed_ns: None,
            last_arrival_elapsed_ns: 0,
            chunk_index: u16::MAX,
            chunk_count: u16::MAX,
            normalized_source_age_ns: 0,
            uncertainty_ns: 0,
        }
    }

    fn observe(&mut self, packet: Option<&MediaDatagram>, received_ns: u64, clock: ClockEstimate) {
        self.packet_count = self.packet_count.saturating_add(1);
        let elapsed_ns = u64::try_from(self.started.elapsed().as_nanos()).unwrap_or(u64::MAX);
        self.first_arrival_elapsed_ns.get_or_insert(elapsed_ns);
        self.last_arrival_elapsed_ns = elapsed_ns;
        self.uncertainty_ns = clock.uncertainty_ns;
        if let Some(packet) = packet {
            self.chunk_index = packet.chunk_index;
            self.chunk_count = packet.chunk_count;
            self.normalized_source_age_ns =
                clock.age_upper_bound_ns(packet.source_submitted_ns, received_ns);
        }
    }

    fn rejection(&self, frame_id: u64, code: u8) -> RejectionReceipt {
        RejectionReceipt {
            frame_id,
            code,
            packet_count: self.packet_count,
            chunk_index: self.chunk_index,
            chunk_count: self.chunk_count,
            first_arrival_elapsed_ns: self.first_arrival_elapsed_ns.unwrap_or(0),
            last_arrival_elapsed_ns: self.last_arrival_elapsed_ns,
            normalized_source_age_ns: self.normalized_source_age_ns,
            uncertainty_ns: self.uncertainty_ns,
        }
    }
}

#[cfg_attr(not(windows), allow(dead_code))]
#[derive(Clone, Debug)]
struct Options {
    role: String,
    cert: String,
    key: String,
    ca: String,
    remote: Option<SocketAddr>,
    listen: Option<SocketAddr>,
    server_name: Option<String>,
    file: Option<String>,
    capture_window: Option<String>,
    capture_stream: Option<String>,
    compositor_pid: Option<u32>,
    composition_presenter: Option<String>,
    composition_blur_rect: Option<CompositionBlurRect>,
    composition_blur_radius: Option<f64>,
    logical_size: Option<LogicalSize>,
    title: String,
    x: i32,
    y: i32,
    max_bytes: usize,
    timeout: Duration,
    visible: Duration,
    frame_count: u16,
}

fn main() -> Result<()> {
    let options = parse_options()?;
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("build current-thread Tokio runtime")?
        .block_on(run(options))
}

async fn run(options: Options) -> Result<()> {
    match options.role.as_str() {
        "send" => send(options).await,
        "receive" => receive(options).await,
        _ => bail!("role must be `send` or `receive`"),
    }
}

async fn send(options: Options) -> Result<()> {
    let logical_size = options
        .logical_size
        .context("send requires --logical-width and --logical-height from capture fullGeometry")?;
    let remote = options.remote.context("send requires --remote HOST:PORT")?;
    let server_name = options
        .server_name
        .as_deref()
        .context("send requires --server-name from the receiver certificate")?;
    let staged = match (
        options.file.as_deref(),
        options.capture_window.as_deref(),
        options.capture_stream.as_deref(),
    ) {
        (Some(file), None, None) => Some(read_raw_bgra(file, options.max_bytes)?),
        (None, Some(_), None) => {
            // Plugin artifacts are retained by this bring-up source. Bound the
            // total potential retained bytes before creating any capture.
            if options
                .max_bytes
                .checked_mul(usize::from(options.frame_count))
                .is_none_or(|bytes| bytes > 256 * 1024 * 1024)
            {
                bail!("capture run exceeds retained-artifact byte budget");
            }
            None
        }
        (None, None, Some(_)) => None,
        _ => bail!("send requires exactly one of --file, --capture-window, or --capture-stream"),
    };
    let identity = load_identity(&options)?;
    let client_bind = if remote.is_ipv4() {
        "0.0.0.0:0"
    } else {
        "[::]:0"
    };
    let mut endpoint = Endpoint::client(client_bind.parse().context("parse client bind address")?)?;
    endpoint.set_default_client_config(
        build_client_config(&identity)
            .map_err(|error| anyhow::anyhow!("build mTLS client config: {error}"))?,
    );

    let clock = MonotonicClock::new();
    // Complete bounded source startup outside the cancellable media future:
    // dropping a spawn_blocking startup could otherwise orphan its producer.
    #[cfg(target_os = "linux")]
    let mut stream = if let Some(address) = options.capture_stream.as_deref() {
        Some(
            viewflowd::hyprcapture_runtime::start_stream(
                address,
                60,
                options.max_bytes,
                options
                    .compositor_pid
                    .context("--capture-stream requires --compositor-pid")?,
                Duration::from_secs(2),
            )
            .await?,
        )
    } else {
        None
    };
    #[cfg(not(target_os = "linux"))]
    if options.capture_stream.is_some() {
        bail!("--capture-stream is only supported on Linux");
    }
    let session = async {
        let connection = endpoint
            .connect(remote, server_name)
            .context("start mTLS QUIC connection")?
            .await
            .context("complete mTLS QUIC connection")?;
        let (mut control_send, mut control_recv) =
            connection.open_bi().await.context("open clock stream")?;
        let t0 = clock.now_ns();
        write_record(&mut control_send, CLOCK_PROBE, &t0.to_be_bytes()).await?;
        let reply = read_record(&mut control_recv, CLOCK_REPLY, 16).await?;
        let t1 = u64::from_be_bytes(reply[..8].try_into().expect("fixed clock reply"));
        let t2 = u64::from_be_bytes(reply[8..].try_into().expect("fixed clock reply"));
        let t3 = clock.now_ns();
        let estimate = ClockEstimate::from_exchange(t0, t1, t2, t3)
            .context("validate four-timestamp clock exchange")?;
        let mut estimate_bytes = Vec::with_capacity(24);
        estimate_bytes.extend_from_slice(&estimate.remote_offset_ns.to_be_bytes());
        estimate_bytes.extend_from_slice(&estimate.network_round_trip_ns.to_be_bytes());
        estimate_bytes.extend_from_slice(&estimate.uncertainty_ns.to_be_bytes());
        write_record(&mut control_send, CLOCK_ESTIMATE, &estimate_bytes).await?;
        write_record(&mut control_send, LOGICAL_SIZE, &logical_size.encode()).await?;
        write_record(
            &mut control_send,
            FRAME_COUNT,
            &options.frame_count.to_be_bytes(),
        )
        .await?;
        // Native window allocation must finish before the timed media send.
        read_record(&mut control_recv, RECEIVER_READY, 0).await?;

        let datagram_limit = connection
            .max_datagram_size()
            .context("peer did not negotiate QUIC datagrams")?;
        let mut active_logical_size = logical_size;
        let mut geometry_epoch = INITIAL_GEOMETRY_EPOCH;
        let mut geometry_sequence = 0_u64;
        let mut accepted_frames = 0_u16;
        for frame_id in FIRST_FRAME_ID..FIRST_FRAME_ID + u64::from(options.frame_count) {
            // Capture-mode age includes request, readback, conversion, and
            // queue time. Never reset it after capture merely to pass admission.
            let mut source_submitted_ns = clock.now_ns();
            let (payload, captured_logical_size) = if let Some(payload) = &staged {
                (payload.clone(), None)
            } else if options.capture_stream.is_some() {
                #[cfg(target_os = "linux")]
                {
                    let session = stream.as_mut().context("missing stream session")?;
                    let (header, pixels) = loop {
                        match session.receiver.recv_latest_frame()? {
                            viewflowd::hyprcapture_socket::ReceiveOutcome::Frame(
                                header,
                                pixels,
                            ) => break (header, pixels),
                            viewflowd::hyprcapture_socket::ReceiveOutcome::WouldBlock => {
                                tokio::time::sleep(Duration::from_millis(1)).await
                            }
                            viewflowd::hyprcapture_socket::ReceiveOutcome::Disconnected => {
                                bail!("HyprCapture stream disconnected")
                            }
                        }
                    };
                    let captured_size =
                        LogicalSize::checked(header.logical_rect[2], header.logical_rect[3])?;
                    // Sample and translate before negotiating.  Waiting for a
                    // remote ACK must never make a capture look newer.
                    let sampled_monotonic = viewflowd::hyprcapture_stream::monotonic_now_ns()?;
                    let sampled_session = clock.now_ns();
                    source_submitted_ns = viewflowd::hyprcapture_stream::session_capture_timestamp(
                        header.capture_monotonic_ns,
                        sampled_monotonic,
                        sampled_session,
                    )?;
                    let payload = header
                        .into_raw_bgra(pixels, options.max_bytes)?
                        .encode(options.max_bytes)
                        .map_err(|error| anyhow::anyhow!("encode stream raw BGRA: {error}"))?;
                    (payload, Some(captured_size))
                }
                #[cfg(not(target_os = "linux"))]
                unreachable!()
            } else {
                let capture = viewflowd::hyprcapture_runtime::capture_window(
                    options
                        .capture_window
                        .as_deref()
                        .context("missing capture window")?,
                    options.max_bytes,
                    Duration::from_secs(2),
                )
                .await?;
                eprintln!(
                    "frame {frame_id}: capture_elapsed_ns={}",
                    capture.capture_elapsed.as_nanos()
                );
                (
                    capture.payload,
                    Some(LogicalSize::checked(
                        capture.logical_width,
                        capture.logical_height,
                    )?),
                )
            };
            if let Some(captured_size) = captured_logical_size
                && !same_logical_size(captured_size, active_logical_size)
            {
                geometry_sequence = geometry_sequence
                    .checked_add(1)
                    .context("geometry sequence exhausted")?;
                let next_epoch = geometry_epoch
                    .checked_add(1)
                    .context("geometry epoch exhausted")?;
                let update = GeometryUpdate {
                    sequence: geometry_sequence,
                    epoch: next_epoch,
                    size: captured_size,
                };
                write_record(&mut control_send, GEOMETRY, &update.encode()).await?;
                let ack = GeometryAck::decode(
                    &read_record(&mut control_recv, GEOMETRY_ACK, GeometryAck::ENCODED_LEN).await?,
                )?;
                if ack.sequence != update.sequence || ack.epoch != update.epoch {
                    bail!(
                        "geometry acknowledgement ({}, {}) cannot satisfy update ({}, {})",
                        ack.sequence,
                        ack.epoch,
                        update.sequence,
                        update.epoch
                    );
                }
                active_logical_size = captured_size;
                geometry_epoch = next_epoch;
            }
            let frame = MediaPlaneFrame {
                window_id: WINDOW_ID,
                frame_id,
                geometry_epoch,
                plane: MediaPlane::Color,
                source_submitted_ns,
                payload,
            };
            let send_started = Instant::now();
            let mut queued_packets = 0_u32;
            let terminal_read = read_any_record(&mut control_recv);
            tokio::pin!(terminal_read);
            let mut early_receipt = None;
            for packet in frame
                .fragment(datagram_limit)
                .context("fragment raw BGRA frame")?
            {
                tokio::select! {
                    result = connection.send_datagram_wait(packet.encode()) => {
                        result.context("pace QUIC media datagram")?;
                        queued_packets += 1;
                    }
                    receipt = &mut terminal_read => {
                        early_receipt = Some(receipt?);
                        break;
                    }
                }
                if queued_packets % 16 == 0 {
                    tokio::task::yield_now().await;
                }
            }
            let queue_elapsed_ns = send_started.elapsed().as_nanos();
            let (receipt_kind, receipt) = match early_receipt {
                Some(receipt) => receipt,
                None => tokio::time::timeout(CONTROL_RECEIPT_WAIT, terminal_read)
                    .await
                    .context("frame receipt wait elapsed")??,
            };
            let stats = connection.stats();
            match receipt_kind {
                COMPLETION if receipt.len() == 24 => {
                    let receipt_frame =
                        u64::from_be_bytes(receipt[..8].try_into().expect("fixed receipt"));
                    if receipt_frame != frame_id {
                        bail!(
                            "completion frame tag {receipt_frame} cannot satisfy expected frame {frame_id}"
                        );
                    }
                    accepted_frames += 1;
                    let received_ns =
                        u64::from_be_bytes(receipt[8..16].try_into().expect("fixed receipt"));
                    let submitted_ns =
                        u64::from_be_bytes(receipt[16..].try_into().expect("fixed receipt"));
                    println!(
                        "frame {frame_id}: receiver accepted and submitted raw BGRA pixels: receiver_received_ns={received_ns} receiver_native_submission_ns={submitted_ns}; clock_rtt_ns={} uncertainty_ns={}. This is native submission only, not physical-display or end-to-end latency proof.",
                        estimate.network_round_trip_ns, estimate.uncertainty_ns
                    );
                }
                REJECTION => {
                    let rejected = RejectionReceipt::decode(&receipt)?;
                    if rejected.frame_id != frame_id {
                        bail!(
                            "rejection frame tag {} cannot satisfy expected frame {frame_id}",
                            rejected.frame_id
                        );
                    }
                    eprintln!(
                        "frame {frame_id}: receiver rejected raw BGRA pixels: code={} packets={} chunk={}/{} first_arrival_elapsed_ns={} last_arrival_elapsed_ns={} normalized_source_age_ns={} uncertainty_ns={}; continuing bounded diagnostic",
                        rejected.code,
                        rejected.packet_count,
                        rejected.chunk_index,
                        rejected.chunk_count,
                        rejected.first_arrival_elapsed_ns,
                        rejected.last_arrival_elapsed_ns,
                        rejected.normalized_source_age_ns,
                        rejected.uncertainty_ns
                    );
                }
                _ => bail!(
                    "unexpected frame-tagged control record for frame {frame_id}: kind={receipt_kind} length={}",
                    receipt.len()
                ),
            }
            eprintln!(
                "frame {frame_id}: queued_packets={queued_packets} queue_elapsed_ns={queue_elapsed_ns} terminal_elapsed_ns={} path_rtt_ns={} cwnd={} lost_packets={} congestion_events={}",
                send_started.elapsed().as_nanos(),
                stats.path.rtt.as_nanos(),
                stats.path.cwnd,
                stats.path.lost_packets,
                stats.path.congestion_events
            );
        }
        control_send.finish().context("finish control stream")?;
        connection.close(0u32.into(), b"bounded frames complete");
        if accepted_frames == 0 {
            bail!("all frames were rejected");
        }
        Ok::<(), anyhow::Error>(())
    };
    let result = tokio::time::timeout(options.timeout, session)
        .await
        .context("bounded sender session timed out")
        .and_then(|result| result);
    endpoint.close(0u32.into(), b"bounded sender finished");
    #[cfg(target_os = "linux")]
    if let Some(stream) = stream {
        if let Err(stop_error) = stream.stop_stream(Duration::from_secs(2)).await {
            bail!("sender result={result:?}; capture stop unproven: {stop_error:#}");
        }
    }
    result
}

#[cfg(windows)]
async fn receive(options: Options) -> Result<()> {
    use viewflow_platform::windows_proxy::WindowsProxy;

    let listen = options
        .listen
        .context("receive requires --listen HOST:PORT")?;
    let identity = load_identity(&options)?;
    let endpoint = Endpoint::server(
        build_server_config(&identity)
            .map_err(|error| anyhow::anyhow!("build mTLS server config: {error}"))?,
        listen,
    )
    .context("bind mTLS QUIC listener")?;
    let clock = MonotonicClock::new();
    let session = async {
        let connecting = endpoint
            .accept()
            .await
            .context("listener closed before peer connected")?;
        let connection = connecting
            .await
            .context("complete incoming mTLS QUIC connection")?;
        let (mut control_send, mut control_recv) = connection
            .accept_bi()
            .await
            .context("accept clock stream")?;
        let probe = read_record(&mut control_recv, CLOCK_PROBE, 8).await?;
        let _t0 = u64::from_be_bytes(probe.try_into().expect("fixed clock probe"));
        let t1 = clock.now_ns();
        let t2 = clock.now_ns();
        let mut reply = Vec::with_capacity(16);
        reply.extend_from_slice(&t1.to_be_bytes());
        reply.extend_from_slice(&t2.to_be_bytes());
        write_record(&mut control_send, CLOCK_REPLY, &reply).await?;
        let encoded_estimate = read_record(&mut control_recv, CLOCK_ESTIMATE, 24).await?;
        let sender_to_receiver = ClockEstimate {
            remote_offset_ns: i64::from_be_bytes(
                encoded_estimate[..8].try_into().expect("fixed estimate"),
            ),
            network_round_trip_ns: u64::from_be_bytes(
                encoded_estimate[8..16].try_into().expect("fixed estimate"),
            ),
            uncertainty_ns: u64::from_be_bytes(
                encoded_estimate[16..].try_into().expect("fixed estimate"),
            ),
        };
        // The sender measured receiver-minus-sender. Admission needs the
        // inverse: sender-minus-receiver, since sender is remote here.
        let sender_clock = ClockEstimate {
            remote_offset_ns: sender_to_receiver
                .remote_offset_ns
                .checked_neg()
                .context("clock offset cannot be inverted")?,
            ..sender_to_receiver
        };

        let logical_size =
            LogicalSize::decode(&read_record(&mut control_recv, LOGICAL_SIZE, 16).await?)?;
        let frame_count = u16::from_be_bytes(
            read_record(&mut control_recv, FRAME_COUNT, 2)
                .await?
                .try_into()
                .expect("fixed frame count"),
        );
        validate_frame_count(frame_count)?;
        let mut receiver = RawWindowSession::new(RawWindowSessionConfig {
            receiver: viewflowd::media_runtime::MediaReceiverConfig {
                assembler: viewflow_transport::MediaAssemblerConfig {
                    deadline_ns: 33_333_333,
                    max_chunks_per_plane: 8_192,
                    max_plane_bytes: options.max_bytes.saturating_add(20),
                },
                max_windows: 1,
                max_pending_bytes: options.max_bytes.saturating_add(20),
            },
            max_presenters: 1,
            max_pixel_bytes: options.max_bytes,
        })?;
        let presenter = if let Some(path) = options.composition_presenter.as_deref() {
            ReceiverPresenter::Composition(CompositionPresenter::spawn(
                path,
                logical_size,
                options
                    .composition_blur_rect
                    .context("composition blur rectangle missing after CLI validation")?,
                options
                    .composition_blur_radius
                    .context("composition blur radius missing after CLI validation")?,
                options.visible,
                clock.clone(),
            )?)
        } else {
            // `WindowsProxy` is intentionally !Send. The GDI receive path
            // stays on this current-thread runtime so its HWND message pump
            // has its owner.
            let proxy = WindowsProxy::new(&options.title, options.x, options.y)
                .context("create native Windows proxy")?;
            ReceiverPresenter::Gdi(LogicalPresenter {
                proxy,
                size: logical_size,
            })
        };
        receiver.open(
            WINDOW_ID,
            INITIAL_GEOMETRY_EPOCH,
            FrameQueueConfig {
                refresh_millihz: 60_000,
                max_refresh_periods: 2,
                requires_alpha: false,
            },
            presenter,
        )?;
        write_record(&mut control_send, RECEIVER_READY, &[]).await?;
        let mut geometry_epoch = INITIAL_GEOMETRY_EPOCH;
        let mut geometry_sequence = 0_u64;
        // The reader owns its partial-record state for the complete media
        // sequence. A frame completion/timeout can cancel `next()` without
        // losing bytes or requiring another mutable stream borrow.
        let mut control_reader = ControlRecordReader::new(&mut control_recv);
        let mut accepted_frames = 0_u16;
        for frame_id in FIRST_FRAME_ID..FIRST_FRAME_ID + u64::from(frame_count) {
            let mut diagnostics = MediaDiagnostics::new();
            let deadline = Instant::now() + PER_FRAME_WAIT;
            let outcome = loop {
                if !receiver.presenter_mut(WINDOW_ID)?.pump_events()? {
                    bail!("native GDI proxy window was closed");
                }
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    break None;
                }
                let bytes = tokio::select! {
                    record = control_reader.next() => {
                        let (kind, bytes) = record?;
                        if kind != GEOMETRY {
                            bail!("unexpected control record while awaiting frame {frame_id}: kind={kind} length={}", bytes.len());
                        }
                        let update = GeometryUpdate::decode(&bytes)?;
                        if update.sequence <= geometry_sequence || update.epoch <= geometry_epoch {
                            bail!(
                                "stale or regressing geometry update ({}, {}) after ({}, {})",
                                update.sequence, update.epoch, geometry_sequence, geometry_epoch
                            );
                        }
                        // Validate native geometry before committing media. The
                        // composition diagnostic has one explicit initial
                        // logical geometry/blur rectangle, so it rejects any
                        // resize rather than ACKing an unsupported mapping.
                        receiver.presenter_mut(WINDOW_ID)?.set_size(update.size)?;
                        receiver.commit_geometry(WINDOW_ID, update.epoch)?;
                        geometry_sequence = update.sequence;
                        geometry_epoch = update.epoch;
                        write_record(
                            &mut control_send,
                            GEOMETRY_ACK,
                            &GeometryAck { sequence: update.sequence, epoch: update.epoch }.encode(),
                        ).await?;
                        continue;
                    }
                    result = tokio::time::timeout(
                        remaining.min(Duration::from_millis(8)),
                        connection.read_datagram(),
                    ) => match result {
                        Ok(Ok(bytes)) => bytes,
                        Ok(Err(error)) => return Err(anyhow::Error::new(error).context("read QUIC media datagram")),
                        Err(_) => continue,
                    },
                };
                let received_ns = clock.now_ns();
                let packet = match MediaDatagram::decode(bytes) {
                    Ok(packet) => packet,
                    Err(error) => {
                        diagnostics.observe(None, received_ns, sender_clock);
                        eprintln!("frame {frame_id}: ignored malformed delayed datagram: {error}");
                        continue;
                    }
                };
                // Datagram delivery is unordered. Old and future frame tags are
                // explicitly ignored; they can never complete this frame.
                if packet.window_id != WINDOW_ID
                    || packet.geometry_epoch != geometry_epoch
                    || packet.frame_id != frame_id
                {
                    continue;
                }
                diagnostics.observe(Some(&packet), received_ns, sender_clock);
                match receiver.push_remote(packet, received_ns, sender_clock) {
                    Ok(RawWindowSessionOutcome::Waiting) => {}
                    Ok(RawWindowSessionOutcome::Presented(manifest)) => break Some(Ok(manifest)),
                    Ok(RawWindowSessionOutcome::Dropped(drop)) => break Some(Err(drop)),
                    Err(error) => {
                        let receipt = diagnostics.rejection(frame_id, rejection_code(&error));
                        write_record(&mut control_send, REJECTION, &receipt.encode()).await?;
                        return Err(anyhow::Error::new(error));
                    }
                }
            };
            match outcome {
                Some(Ok(manifest)) => {
                    let submitted_ns = match receiver
                        .presenter_mut(WINDOW_ID)?
                        .wait_for_submission()
                        .await?
                    {
                        Some(native_submission_ns) => {
                            let age = sender_clock.age_upper_bound_ns(
                                manifest.source_submitted_ns,
                                native_submission_ns,
                            );
                            if age > 33_333_333 {
                                let receipt =
                                    diagnostics.rejection(frame_id, REJECTION_ASSEMBLY_LATE);
                                eprintln!(
                                    "frame {frame_id}: composition submitted after freshness deadline (native_submission_ns={native_submission_ns} normalized_age_ns={age}); rejecting receipt although the child may already have drawn it"
                                );
                                write_record(&mut control_send, REJECTION, &receipt.encode())
                                    .await?;
                                continue;
                            }
                            native_submission_ns
                        }
                        None => clock.now_ns(),
                    };
                    accepted_frames = accepted_frames.saturating_add(1);
                    eprintln!(
                        "frame {frame_id}: receiver_terminal=native_submitted elapsed_ns={}",
                        diagnostics.started.elapsed().as_nanos()
                    );
                    write_record(
                        &mut control_send,
                        COMPLETION,
                        &[
                            frame_id.to_be_bytes(),
                            manifest.received_ns.to_be_bytes(),
                            submitted_ns.to_be_bytes(),
                        ]
                        .concat(),
                    )
                    .await?;
                }
                Some(Err(drop)) => {
                    let receipt = diagnostics.rejection(frame_id, drop_rejection_code(drop));
                    eprintln!(
                        "frame {frame_id}: receiver_terminal=dropped({drop:?}) elapsed_ns={}",
                        diagnostics.started.elapsed().as_nanos()
                    );
                    write_record(&mut control_send, REJECTION, &receipt.encode()).await?;
                }
                None => {
                    let receipt = diagnostics.rejection(frame_id, REJECTION_ASSEMBLY_LATE);
                    eprintln!(
                        "frame {frame_id}: receiver_terminal=timed_out elapsed_ns={}",
                        diagnostics.started.elapsed().as_nanos()
                    );
                    write_record(&mut control_send, REJECTION, &receipt.encode()).await?;
                }
            }
        }
        control_send.finish().context("finish final receipt")?;
        // Release the stateful reader's stream borrow only after every frame
        // is terminal before the bounded final FIN/close observation below.
        drop(control_reader);
        // Bounded best effort: FIN/connection close may follow parsing the
        // final receipt; a timeout is not proof that the peer received it.
        let _ = tokio::time::timeout(Duration::from_millis(250), control_recv.read_chunk(1, true))
            .await;
        let visible_until = Instant::now() + options.visible;
        while Instant::now() < visible_until {
            if !receiver.presenter_mut(WINDOW_ID)?.pump_events()? {
                break;
            }
            tokio::time::sleep(Duration::from_millis(16)).await;
        }
        println!(
            "processed {frame_count} raw BGRA frame attempts ({accepted_frames} accepted by the selected presenter); composition queue acceptance is not GPU submission or physical-display proof"
        );
        Ok::<(), anyhow::Error>(())
    };
    // `timeout` bounds setup/media; the explicitly bounded post-submit pump
    // gets its own reserved interval so it is not cut off by that outer limit.
    let session_timeout = options.timeout.saturating_add(options.visible);
    let result = tokio::time::timeout(session_timeout, session)
        .await
        .context("one-frame receiver session timed out")?;
    endpoint.close(0u32.into(), b"one-frame receiver finished");
    result
}

#[cfg(windows)]
fn rejection_code(error: &viewflowd::raw_session::RawWindowSessionError) -> u8 {
    match error {
        viewflowd::raw_session::RawWindowSessionError::Receiver(
            viewflowd::media_runtime::MediaReceiverError::Assembly(
                viewflow_transport::MediaAssemblerError::Late,
            ),
        ) => REJECTION_ASSEMBLY_LATE,
        viewflowd::raw_session::RawWindowSessionError::Receiver(
            viewflowd::media_runtime::MediaReceiverError::Assembly(_),
        ) => REJECTION_ASSEMBLY_OTHER,
        _ => REJECTION_RECEIVER,
    }
}

#[cfg(windows)]
fn drop_rejection_code(drop: RawWindowSessionDrop) -> u8 {
    match drop {
        RawWindowSessionDrop::Late => REJECTION_ASSEMBLY_LATE,
        RawWindowSessionDrop::StaleFrame
        | RawWindowSessionDrop::StaleGeometry
        | RawWindowSessionDrop::FutureGeometry => REJECTION_ADMISSION,
    }
}

#[cfg(not(windows))]
async fn receive(_options: Options) -> Result<()> {
    bail!("receive requires Windows: RawBgraSink must submit to a native WindowsProxy")
}

fn read_raw_bgra(path: &str, max_bytes: usize) -> Result<Bytes> {
    let metadata = std::fs::metadata(path).with_context(|| format!("stat {path}"))?;
    if !metadata.file_type().is_file() {
        bail!("VFBG input must be a regular file")
    }
    let length =
        usize::try_from(metadata.len()).context("raw file length does not fit this platform")?;
    if length < 20 || length > max_bytes.saturating_add(20) {
        bail!(
            "VFBG file length {length} is outside bounded limit (20..={})",
            max_bytes.saturating_add(20)
        );
    }
    let mut file = File::open(path).with_context(|| format!("open {path}"))?;
    if !file
        .metadata()
        .with_context(|| format!("fstat {path}"))?
        .file_type()
        .is_file()
    {
        bail!("VFBG input changed to a non-regular file")
    }
    let mut header = [0u8; 20];
    file.read_exact(&mut header).context("read VFBG header")?;
    if &header[..4] != b"VFBG" || header[4..8] != [1, 1, 0, 0] {
        bail!("file is not a version-1 premultiplied BGRA VFBG payload")
    }
    let mut bytes = Vec::with_capacity(length);
    bytes.extend_from_slice(&header);
    let remaining = length.saturating_sub(header.len());
    file.take(u64::try_from(remaining.saturating_add(1)).unwrap_or(u64::MAX))
        .read_to_end(&mut bytes)
        .context("read bounded VFBG payload")?;
    if bytes.len() != length {
        bail!("VFBG file changed while it was read")
    }
    let encoded = Bytes::from(bytes);
    RawBgraPayload::decode(encoded.clone(), max_bytes)
        .context("validate bounded premultiplied raw BGRA payload")?;
    Ok(encoded)
}

fn load_identity(options: &Options) -> Result<PeerIdentity> {
    PeerIdentity::from_pem(
        &std::fs::read(&options.cert)
            .with_context(|| format!("read certificate {}", options.cert))?,
        &std::fs::read(&options.key)
            .with_context(|| format!("read private key {}", options.key))?,
        &std::fs::read(&options.ca).with_context(|| format!("read CA bundle {}", options.ca))?,
    )
    .map_err(|error| anyhow::anyhow!("parse paired mTLS identity: {error}"))
}

async fn write_record(stream: &mut SendStream, kind: u8, bytes: &[u8]) -> Result<()> {
    let length = u16::try_from(bytes.len()).context("control record too large")?;
    stream
        .write_all(&[kind])
        .await
        .context("write control record kind")?;
    stream
        .write_all(&length.to_be_bytes())
        .await
        .context("write control record length")?;
    stream
        .write_all(bytes)
        .await
        .context("write control record payload")?;
    Ok(())
}

async fn read_record(
    stream: &mut RecvStream,
    expected_kind: u8,
    expected_length: usize,
) -> Result<Vec<u8>> {
    let (kind, bytes) = read_any_record(stream).await?;
    if kind != expected_kind || bytes.len() != expected_length {
        bail!(
            "unexpected control record: kind={kind} length={}",
            bytes.len()
        )
    }
    Ok(bytes)
}

async fn read_any_record<R>(stream: &mut R) -> Result<(u8, Vec<u8>)>
where
    R: AsyncRead + Unpin,
{
    let mut header = [0u8; 3];
    read_exact_async(stream, &mut header)
        .await
        .context("read control record header")?;
    let length = usize::from(u16::from_be_bytes([header[1], header[2]]));
    let mut bytes = vec![0; length];
    read_exact_async(stream, &mut bytes)
        .await
        .context("read control record payload")?;
    Ok((header[0], bytes))
}

async fn read_exact_async<R: AsyncRead + Unpin>(
    stream: &mut R,
    bytes: &mut [u8],
) -> std::io::Result<()> {
    let mut filled = 0;
    std::future::poll_fn(|context| {
        while filled < bytes.len() {
            let mut read_buf = ReadBuf::new(&mut bytes[filled..]);
            match Pin::new(&mut *stream).poll_read(context, &mut read_buf) {
                Poll::Ready(Ok(())) if read_buf.filled().is_empty() => {
                    return Poll::Ready(Err(std::io::Error::new(
                        std::io::ErrorKind::UnexpectedEof,
                        "control stream ended mid-record",
                    )));
                }
                Poll::Ready(Ok(())) => filled += read_buf.filled().len(),
                Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
                Poll::Pending => return Poll::Pending,
            }
        }
        Poll::Ready(Ok(()))
    })
    .await
}

/// A cancellation-safe bounded record reader. Partial headers and payloads
/// belong to this object, so a media select timeout cannot lose a byte already
/// consumed from the reliable stream.
#[cfg_attr(not(windows), allow(dead_code))]
struct ControlRecordReader<R> {
    stream: R,
    header: [u8; 3],
    header_filled: usize,
    payload: Vec<u8>,
    payload_filled: usize,
    payload_length: Option<usize>,
}

#[cfg_attr(not(windows), allow(dead_code))]
impl<R: AsyncRead + Unpin> ControlRecordReader<R> {
    fn new(stream: R) -> Self {
        Self {
            stream,
            header: [0; 3],
            header_filled: 0,
            payload: Vec::new(),
            payload_filled: 0,
            payload_length: None,
        }
    }

    async fn next(&mut self) -> Result<(u8, Vec<u8>)> {
        std::future::poll_fn(|context| self.poll_next(context)).await
    }

    fn poll_next(&mut self, context: &mut TaskContext<'_>) -> Poll<Result<(u8, Vec<u8>)>> {
        match poll_read_exact_part(
            &mut self.stream,
            context,
            &mut self.header,
            &mut self.header_filled,
        ) {
            Poll::Ready(Ok(())) => {}
            Poll::Ready(Err(error)) => {
                return Poll::Ready(Err(error).context("read control record header"));
            }
            Poll::Pending => return Poll::Pending,
        }
        if self.payload_length.is_none() {
            let length = usize::from(u16::from_be_bytes([self.header[1], self.header[2]]));
            self.payload = vec![0; length];
            self.payload_length = Some(length);
        }
        match poll_read_exact_part(
            &mut self.stream,
            context,
            &mut self.payload,
            &mut self.payload_filled,
        ) {
            Poll::Ready(Ok(())) => {}
            Poll::Ready(Err(error)) => {
                return Poll::Ready(Err(error).context("read control record payload"));
            }
            Poll::Pending => return Poll::Pending,
        }
        let kind = self.header[0];
        let payload = std::mem::take(&mut self.payload);
        self.header_filled = 0;
        self.payload_filled = 0;
        self.payload_length = None;
        Poll::Ready(Ok((kind, payload)))
    }
}

#[cfg_attr(not(windows), allow(dead_code))]
fn poll_read_exact_part<R: AsyncRead + Unpin>(
    stream: &mut R,
    context: &mut TaskContext<'_>,
    bytes: &mut [u8],
    filled: &mut usize,
) -> Poll<std::io::Result<()>> {
    while *filled < bytes.len() {
        let mut read_buf = ReadBuf::new(&mut bytes[*filled..]);
        match Pin::new(&mut *stream).poll_read(context, &mut read_buf) {
            Poll::Ready(Ok(())) if read_buf.filled().is_empty() => {
                return Poll::Ready(Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "control stream ended mid-record",
                )));
            }
            Poll::Ready(Ok(())) => *filled += read_buf.filled().len(),
            Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
            Poll::Pending => return Poll::Pending,
        }
    }
    Poll::Ready(Ok(()))
}

#[derive(Clone, Debug)]
struct MonotonicClock(Instant);

impl MonotonicClock {
    fn new() -> Self {
        Self(Instant::now())
    }
    fn now_ns(&self) -> u64 {
        u64::try_from(self.0.elapsed().as_nanos()).unwrap_or(u64::MAX)
    }
}

fn parse_options() -> Result<Options> {
    parse_options_from(env::args().skip(1))
}

fn parse_options_from(mut arguments: impl Iterator<Item = String>) -> Result<Options> {
    let role = arguments
        .next()
        .context("usage: raw_window_peer <send|receive> [options]")?;
    let mut values = std::collections::BTreeMap::new();
    while let Some(name) = arguments.next() {
        let name = name
            .strip_prefix("--")
            .context("options must start with --")?
            .to_owned();
        let value = arguments
            .next()
            .with_context(|| format!("--{name} needs a value"))?;
        if values.insert(name.clone(), value).is_some() {
            bail!("--{name} was specified more than once")
        }
    }
    let take = |name: &str| {
        values
            .get(name)
            .cloned()
            .with_context(|| format!("missing --{name}"))
    };
    let parse = |name: &str| {
        take(name)?
            .parse()
            .with_context(|| format!("invalid --{name}"))
    };
    let max_bytes = values
        .get("max-bytes")
        .map_or(Ok(DEFAULT_MAX_BYTES), |value| {
            value.parse().context("invalid --max-bytes")
        })?;
    if max_bytes == 0 {
        bail!("--max-bytes must be greater than zero")
    }
    let timeout_ms = values
        .get("timeout-ms")
        .map_or(Ok(DEFAULT_TIMEOUT_MS), |value| {
            value.parse().context("invalid --timeout-ms")
        })?;
    if timeout_ms == 0 {
        bail!("--timeout-ms must be greater than zero")
    }
    let visible_ms = values
        .get("visible-ms")
        .map_or(Ok(DEFAULT_VISIBLE_MS), |value| {
            value.parse().context("invalid --visible-ms")
        })?;
    if !(1..=MAX_VISIBLE_MS).contains(&visible_ms) {
        bail!("--visible-ms must be within 1..={MAX_VISIBLE_MS}")
    }
    let frame_count = values
        .get("frame-count")
        .map_or(Ok(DEFAULT_FRAME_COUNT), |value| {
            value.parse().context("invalid --frame-count")
        })?;
    validate_frame_count(frame_count)?;
    let allowed = [
        "cert",
        "key",
        "ca",
        "remote",
        "listen",
        "server-name",
        "file",
        "capture-window",
        "capture-stream",
        "compositor-pid",
        "composition-presenter",
        "composition-blur-rect",
        "composition-blur-radius",
        "title",
        "x",
        "y",
        "max-bytes",
        "timeout-ms",
        "visible-ms",
        "logical-width",
        "logical-height",
        "frame-count",
    ];
    if let Some(unknown) = values.keys().find(|name| !allowed.contains(&name.as_str())) {
        bail!("unknown option --{unknown}")
    }
    let compositor_pid: Option<u32> = values
        .get("compositor-pid")
        .map(|value| value.parse())
        .transpose()
        .context("invalid --compositor-pid")?;
    let sources = ["file", "capture-window", "capture-stream"]
        .iter()
        .filter(|name| values.contains_key(**name))
        .count();
    if role == "send" && sources != 1 {
        bail!("send requires exactly one of --file, --capture-window, or --capture-stream");
    }
    if values.contains_key("capture-stream") && compositor_pid.is_none_or(|pid| pid == 0) {
        bail!("--capture-stream requires a positive --compositor-pid");
    }
    if compositor_pid.is_some() && !values.contains_key("capture-stream") {
        bail!("--compositor-pid requires --capture-stream");
    }
    let composition_presenter = values.get("composition-presenter").cloned();
    let composition_blur_rect = values
        .get("composition-blur-rect")
        .map(|value| CompositionBlurRect::parse(value))
        .transpose()?;
    let composition_blur_radius = values
        .get("composition-blur-radius")
        .map(|value| {
            value
                .parse::<f64>()
                .context("invalid --composition-blur-radius")
        })
        .transpose()?;
    if composition_blur_radius.is_some_and(|radius| !radius.is_finite() || radius <= 0.0) {
        bail!("--composition-blur-radius must be a positive finite number");
    }
    if composition_presenter.is_some()
        != (composition_blur_rect.is_some() && composition_blur_radius.is_some())
    {
        bail!(
            "--composition-presenter requires --composition-blur-rect and --composition-blur-radius (and those options require --composition-presenter)"
        );
    }
    if composition_presenter.is_some() && role != "receive" {
        bail!("--composition-presenter is only valid for receive");
    }
    Ok(Options {
        role,
        cert: take("cert")?,
        key: take("key")?,
        ca: take("ca")?,
        remote: values
            .get("remote")
            .map(|value| value.parse())
            .transpose()
            .context("invalid --remote")?,
        listen: values
            .get("listen")
            .map(|value| value.parse())
            .transpose()
            .context("invalid --listen")?,
        server_name: values.get("server-name").cloned(),
        file: values.get("file").cloned(),
        capture_window: values.get("capture-window").cloned(),
        capture_stream: values.get("capture-stream").cloned(),
        compositor_pid,
        composition_presenter,
        composition_blur_rect,
        composition_blur_radius,
        logical_size: match (values.get("logical-width"), values.get("logical-height")) {
            (Some(width), Some(height)) => {
                Some(LogicalSize::checked(width.parse()?, height.parse()?)?)
            }
            (None, None) => None,
            _ => bail!("both logical dimensions are required"),
        },
        title: values
            .get("title")
            .cloned()
            .unwrap_or_else(|| "Viewflow raw BGRA diagnostic".to_owned()),
        x: values.get("x").map_or(Ok(0), |_| parse("x"))?,
        y: values.get("y").map_or(Ok(0), |_| parse("y"))?,
        max_bytes,
        timeout: Duration::from_millis(timeout_ms),
        visible: Duration::from_millis(visible_ms),
        frame_count,
    })
}

fn validate_frame_count(frame_count: u16) -> Result<()> {
    if !(1..=MAX_FRAME_COUNT).contains(&frame_count) {
        bail!("--frame-count must be within 1..={MAX_FRAME_COUNT}")
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn stream_cli_rejects_ambiguous_sources_before_any_io() {
        let parse = |tail: &[&str]| {
            let base = [
                "send", "--cert", "unused", "--key", "unused", "--ca", "unused",
            ];
            super::parse_options_from(base.iter().chain(tail).map(|s| (*s).to_owned()))
        };
        assert!(parse(&["--capture-stream", "0x123", "--compositor-pid", "12"]).is_ok());
        assert!(parse(&["--capture-stream", "0x123"]).is_err());
        assert!(parse(&["--capture-stream", "0x123", "--compositor-pid", "0"]).is_err());
        assert!(
            parse(&[
                "--capture-stream",
                "0x123",
                "--compositor-pid",
                "12",
                "--file",
                "unused"
            ])
            .is_err()
        );
        assert!(parse(&["--file", "unused", "--capture-window", "0x123"]).is_err());
        assert!(parse(&["--file", "unused", "--compositor-pid", "12"]).is_err());
        assert!(parse(&[]).is_err());
    }

    #[test]
    fn visible_ms_is_bounded_and_defaults_to_two_seconds() {
        let parse = |tail: &[&str]| {
            let base = [
                "send", "--cert", "unused", "--key", "unused", "--ca", "unused", "--file", "unused",
            ];
            super::parse_options_from(base.iter().chain(tail).map(|s| (*s).to_owned()))
        };
        assert_eq!(parse(&[]).unwrap().visible, Duration::from_secs(2));
        assert_eq!(
            parse(&["--visible-ms", "1"]).unwrap().visible,
            Duration::from_millis(1)
        );
        assert!(parse(&["--visible-ms", "0"]).is_err());
        assert!(parse(&["--visible-ms", "60001"]).is_err());
    }

    #[test]
    fn composition_presenter_is_receiver_only_and_requires_explicit_bounded_blur() {
        let receive = |tail: &[&str]| {
            let base = [
                "receive",
                "--cert",
                "unused",
                "--key",
                "unused",
                "--ca",
                "unused",
                "--listen",
                "127.0.0.1:1",
            ];
            super::parse_options_from(base.iter().chain(tail).map(|s| (*s).to_owned()))
        };
        assert!(receive(&["--composition-presenter", "preview.exe"]).is_err());
        assert!(
            receive(&[
                "--composition-presenter",
                "preview.exe",
                "--composition-blur-rect",
                "9,9,760,626",
                "--composition-blur-radius",
                "18",
            ])
            .is_ok()
        );
        assert!(
            receive(&[
                "--composition-presenter",
                "preview.exe",
                "--composition-blur-rect",
                "9,9,0,626",
                "--composition-blur-radius",
                "18",
            ])
            .is_err()
        );
        assert!(
            receive(&[
                "--composition-presenter",
                "preview.exe",
                "--composition-blur-rect",
                "9,9,760,626",
                "--composition-blur-radius",
                "0",
            ])
            .is_err()
        );
        let send = [
            "send",
            "--cert",
            "unused",
            "--key",
            "unused",
            "--ca",
            "unused",
            "--file",
            "unused",
            "--composition-presenter",
            "preview.exe",
            "--composition-blur-rect",
            "1,1,1,1",
            "--composition-blur-radius",
            "1",
        ];
        assert!(super::parse_options_from(send.iter().map(|s| (*s).to_owned())).is_err());
    }

    #[test]
    fn composition_blur_rect_rejects_initial_logical_overflow() {
        let rect = CompositionBlurRect::parse("9,9,760,626").unwrap();
        assert!(
            rect.validate_for(LogicalSize::checked(782.0, 648.0).unwrap())
                .is_ok()
        );
        assert!(
            rect.validate_for(LogicalSize::checked(768.0, 635.0).unwrap())
                .is_err()
        );
    }
    use super::*;
    use std::{
        cell::{Cell, RefCell},
        collections::VecDeque,
        io::Write,
        rc::Rc,
    };
    use viewflow_platform::windows_proxy::{BgraFrame, ProxyError};
    use viewflowd::pixel_runtime::PixelPresenter;

    #[derive(Clone)]
    struct Recorder(Rc<RefCell<Vec<BgraFrame>>>);

    impl PixelPresenter for Recorder {
        fn present_pixels(&mut self, frame: &BgraFrame) -> Result<(), ProxyError> {
            self.0.borrow_mut().push(frame.clone());
            Ok(())
        }
    }

    struct FragmentedControlReader {
        fragments: VecDeque<Vec<u8>>,
        pause: Rc<Cell<bool>>,
        stalled_once: bool,
    }

    impl AsyncRead for FragmentedControlReader {
        fn poll_read(
            mut self: Pin<&mut Self>,
            _context: &mut TaskContext<'_>,
            buffer: &mut ReadBuf<'_>,
        ) -> Poll<std::io::Result<()>> {
            if self.pause.get() {
                return Poll::Pending;
            }
            let Some(mut fragment) = self.fragments.pop_front() else {
                return Poll::Ready(Ok(()));
            };
            let count = fragment.len().min(buffer.remaining());
            buffer.put_slice(&fragment[..count]);
            if count != fragment.len() {
                fragment.drain(..count);
                self.fragments.push_front(fragment);
            }
            // Force a pending boundary after each transport fragment.  The
            // test resumes this reader only after a simulated frame terminal.
            if !self.stalled_once {
                self.pause.set(true);
                self.stalled_once = true;
            }
            Poll::Ready(Ok(()))
        }
    }

    fn loopback_packet(frame_id: u64, epoch: u64) -> MediaDatagram {
        MediaDatagram {
            window_id: WINDOW_ID,
            frame_id,
            geometry_epoch: epoch,
            plane: MediaPlane::Color,
            chunk_index: 0,
            chunk_count: 1,
            source_submitted_ns: 100,
            payload: RawBgraPayload {
                width: 1,
                height: 1,
                stride: 4,
                pixels: Bytes::from_static(&[1, 2, 3, 255]),
            }
            .encode(4)
            .unwrap(),
        }
    }

    fn loopback_clock() -> ClockEstimate {
        ClockEstimate {
            remote_offset_ns: 0,
            network_round_trip_ns: 0,
            uncertainty_ns: 0,
        }
    }

    #[test]
    fn logical_size_wire_preserves_dips_not_capture_pixels() {
        let size = LogicalSize::checked(282.0, 131.0).unwrap();
        let decoded = LogicalSize::decode(&size.encode()).unwrap();
        assert_eq!((decoded.width, decoded.height), (282.0, 131.0));
        assert!(LogicalSize::checked(f64::NAN, 10.0).is_err());
        assert!(LogicalSize::checked(0.0, 10.0).is_err());
        assert!(LogicalSize::decode(&[0; 15]).is_err());
    }

    #[test]
    fn staged_frame_checks_limit_format_and_premultiplied_pixels() {
        let payload = RawBgraPayload {
            width: 1,
            height: 1,
            stride: 4,
            pixels: Bytes::from_static(&[10, 20, 30, 128]),
        }
        .encode(4)
        .unwrap();
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(&payload).unwrap();
        let path = file.path().to_str().unwrap();
        assert_eq!(read_raw_bgra(path, 4).unwrap(), payload);
        assert!(read_raw_bgra(path, 3).is_err());
        let mut invalid = payload.to_vec();
        invalid[20] = 255;
        std::fs::write(path, invalid).unwrap();
        assert!(read_raw_bgra(path, 4).is_err());
        std::fs::write(path, b"not a frame").unwrap();
        assert!(read_raw_bgra(path, 4).is_err());
    }

    #[test]
    fn input_directory_is_not_a_frame() {
        let directory = tempfile::tempdir().unwrap();
        assert!(read_raw_bgra(directory.path().to_str().unwrap(), 1024).is_err());
    }

    #[tokio::test]
    async fn sender_waits_for_ready_before_transmitting() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../viewflow-transport/tests/fixtures");
            let mut file = tempfile::NamedTempFile::new().unwrap();
            let payload = RawBgraPayload {
                width: 1,
                height: 1,
                stride: 4,
                pixels: Bytes::from_static(&[1, 2, 3, 255]),
            }
            .encode(4)
            .unwrap();
            file.write_all(&payload).unwrap();
            let mut options = Options {
                role: "send".into(),
                cert: fixture.join("peer.pem").display().to_string(),
                key: fixture.join("peer.key").display().to_string(),
                ca: fixture.join("ca.pem").display().to_string(),
                remote: None,
                listen: None,
                server_name: Some("localhost".into()),
                file: Some(file.path().display().to_string()),
                title: "test".into(),
                capture_window: None,
                capture_stream: None,
                compositor_pid: None,
                composition_presenter: None,
                composition_blur_rect: None,
                composition_blur_radius: None,
                x: 0,
                logical_size: Some(LogicalSize::checked(1.0, 1.0).unwrap()),
                y: 0,
                max_bytes: 4,
                timeout: Duration::from_secs(4),
                visible: Duration::from_secs(2),
                frame_count: 1,
            };
            let server = Endpoint::server(
                viewflow_transport::build_server_config(&load_identity(&options).unwrap()).unwrap(),
                "127.0.0.1:0".parse().unwrap(),
            )
            .unwrap();
            options.remote = Some(server.local_addr().unwrap());
            let peer = async {
                let connection = server.accept().await.unwrap().await.unwrap();
                let (mut tx, mut rx) = connection.accept_bi().await.unwrap();
                read_record(&mut rx, CLOCK_PROBE, 8).await.unwrap();
                // A responder with its own origin; no native window is used.
                write_record(&mut tx, CLOCK_REPLY, &[0; 16]).await.unwrap();
                read_record(&mut rx, CLOCK_ESTIMATE, 24).await.unwrap();
                read_record(&mut rx, LOGICAL_SIZE, 16).await.unwrap();
                assert_eq!(
                    read_record(&mut rx, FRAME_COUNT, 2).await.unwrap(),
                    1_u16.to_be_bytes()
                );
                assert!(
                    tokio::time::timeout(Duration::from_millis(50), connection.read_datagram())
                        .await
                        .is_err(),
                    "sender transmitted before READY"
                );
                write_record(&mut tx, RECEIVER_READY, &[]).await.unwrap();
                let bytes = connection.read_datagram().await.unwrap();
                let packet = viewflow_transport::MediaDatagram::decode(bytes).unwrap();
                assert_eq!(packet.payload, payload);
                assert_eq!(packet.window_id, WINDOW_ID);
                assert_eq!(packet.chunk_count, 1);
                // Mock receipt validates wire flow only, never native display.
                write_record(
                    &mut tx,
                    COMPLETION,
                    &[&FIRST_FRAME_ID.to_be_bytes()[..], &[0; 16][..]].concat(),
                )
                .await
                .unwrap();
                tx.finish().unwrap();
                connection.closed().await;
            };
            let (sent, ()) = tokio::join!(send(options), peer);
            sent.unwrap();
        })
        .await
        .expect("sender handshake test timed out");
    }

    #[tokio::test]
    async fn sender_loopback_three_frames_continues_after_middle_late_rejection() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../viewflow-transport/tests/fixtures");
            let mut file = tempfile::NamedTempFile::new().unwrap();
            let payload = RawBgraPayload {
                width: 1,
                height: 1,
                stride: 4,
                pixels: Bytes::from_static(&[1, 2, 3, 255]),
            }
            .encode(4)
            .unwrap();
            file.write_all(&payload).unwrap();
            let mut options = Options {
                role: "send".into(),
                cert: fixture.join("peer.pem").display().to_string(),
                key: fixture.join("peer.key").display().to_string(),
                ca: fixture.join("ca.pem").display().to_string(),
                remote: None,
                listen: None,
                server_name: Some("localhost".into()),
                file: Some(file.path().display().to_string()),
                title: "test".into(),
                x: 0,
                capture_window: None,
                capture_stream: None,
                compositor_pid: None,
                composition_presenter: None,
                composition_blur_rect: None,
                composition_blur_radius: None,
                y: 0,
                logical_size: Some(LogicalSize::checked(1.0, 1.0).unwrap()),
                max_bytes: 4,
                timeout: Duration::from_secs(4),
                visible: Duration::from_secs(2),
                frame_count: 3,
            };
            let server = Endpoint::server(
                viewflow_transport::build_server_config(&load_identity(&options).unwrap()).unwrap(),
                "127.0.0.1:0".parse().unwrap(),
            )
            .unwrap();
            options.remote = Some(server.local_addr().unwrap());
            let peer = async {
                let connection = server.accept().await.unwrap().await.unwrap();
                let (mut tx, mut rx) = connection.accept_bi().await.unwrap();
                read_record(&mut rx, CLOCK_PROBE, 8).await.unwrap();
                write_record(&mut tx, CLOCK_REPLY, &[0; 16]).await.unwrap();
                read_record(&mut rx, CLOCK_ESTIMATE, 24).await.unwrap();
                // Sender transmits logical size before it can send media.
                read_record(&mut rx, LOGICAL_SIZE, 16).await.unwrap();
                assert_eq!(
                    read_record(&mut rx, FRAME_COUNT, 2).await.unwrap(),
                    3_u16.to_be_bytes()
                );
                write_record(&mut tx, RECEIVER_READY, &[]).await.unwrap();
                let first = viewflow_transport::MediaDatagram::decode(
                    connection.read_datagram().await.unwrap(),
                )
                .unwrap();
                assert_eq!(first.frame_id, FIRST_FRAME_ID);
                write_record(
                    &mut tx,
                    COMPLETION,
                    &[&FIRST_FRAME_ID.to_be_bytes()[..], &[0; 16][..]].concat(),
                )
                .await
                .unwrap();
                let middle = viewflow_transport::MediaDatagram::decode(
                    connection.read_datagram().await.unwrap(),
                )
                .unwrap();
                assert_eq!(middle.frame_id, FIRST_FRAME_ID + 1);
                let receipt = RejectionReceipt {
                    frame_id: FIRST_FRAME_ID + 1,
                    code: REJECTION_ASSEMBLY_LATE,
                    packet_count: 1,
                    chunk_index: 0,
                    chunk_count: 1,
                    first_arrival_elapsed_ns: 12,
                    last_arrival_elapsed_ns: 12,
                    normalized_source_age_ns: 33_333_334,
                    uncertainty_ns: 7,
                };
                // The receiver's bounded media deadline may expire before
                // its reliable terminal record reaches the sender. A control
                // receipt is not media freshness, so it has its own bound.
                tokio::time::sleep(Duration::from_millis(120)).await;
                write_record(&mut tx, REJECTION, &receipt.encode())
                    .await
                    .unwrap();
                let final_packet = viewflow_transport::MediaDatagram::decode(
                    connection.read_datagram().await.unwrap(),
                )
                .unwrap();
                assert_eq!(final_packet.frame_id, FIRST_FRAME_ID + 2);
                write_record(
                    &mut tx,
                    COMPLETION,
                    &[&(FIRST_FRAME_ID + 2).to_be_bytes()[..], &[0; 16][..]].concat(),
                )
                .await
                .unwrap();
                tx.finish().unwrap();
                connection.closed().await;
            };
            let (sent, ()) = tokio::join!(send(options), peer);
            sent.expect("middle late frame is non-fatal and final frame must be delivered");
        })
        .await
        .expect("sender rejection test timed out");
    }

    #[test]
    fn default_assembler_deadline_remains_one_33ms_frame() {
        assert_eq!(
            viewflow_transport::MediaAssemblerConfig::default().deadline_ns,
            33_333_333
        );
    }

    #[test]
    fn loopback_resize_holds_new_epoch_until_ack_and_keeps_one_presenter() {
        let frames = Rc::new(RefCell::new(Vec::new()));
        let mut receiver = RawWindowSession::new(RawWindowSessionConfig {
            receiver: viewflowd::media_runtime::MediaReceiverConfig {
                assembler: viewflow_transport::MediaAssemblerConfig {
                    deadline_ns: 33_333_333,
                    max_chunks_per_plane: 8_192,
                    max_plane_bytes: 24,
                },
                max_windows: 1,
                max_pending_bytes: 24,
            },
            max_presenters: 1,
            max_pixel_bytes: 4,
        })
        .unwrap();
        receiver
            .open(
                WINDOW_ID,
                INITIAL_GEOMETRY_EPOCH,
                FrameQueueConfig {
                    refresh_millihz: 60_000,
                    max_refresh_periods: 2,
                    requires_alpha: false,
                },
                Recorder(frames.clone()),
            )
            .unwrap();
        let update = GeometryUpdate {
            sequence: 1,
            epoch: 2,
            size: LogicalSize::checked(640.0, 360.0).unwrap(),
        };
        assert_eq!(GeometryUpdate::decode(&update.encode()).unwrap(), update);
        // Before the receiver's reliable ACK, the new epoch has not been
        // committed, so its media is necessarily dropped as future geometry.
        assert!(matches!(
            receiver.push_remote(loopback_packet(1, update.epoch), 200, loopback_clock()),
            Ok(RawWindowSessionOutcome::Dropped(
                RawWindowSessionDrop::FutureGeometry
            ))
        ));
        receiver.commit_geometry(WINDOW_ID, update.epoch).unwrap();
        let ack = GeometryAck {
            sequence: update.sequence,
            epoch: update.epoch,
        };
        assert_eq!(GeometryAck::decode(&ack.encode()).unwrap(), ack);
        assert!(matches!(
            receiver.push_remote(
                loopback_packet(2, INITIAL_GEOMETRY_EPOCH),
                200,
                loopback_clock()
            ),
            Ok(RawWindowSessionOutcome::Dropped(
                RawWindowSessionDrop::StaleGeometry
            ))
        ));
        assert!(matches!(
            receiver.push_remote(loopback_packet(3, update.epoch), 200, loopback_clock()),
            Ok(RawWindowSessionOutcome::Presented(_))
        ));
        assert_eq!(receiver.registered_windows(), 1);
        assert!(Rc::ptr_eq(
            &receiver.presenter_mut(WINDOW_ID).unwrap().0,
            &frames
        ));
        assert_eq!(frames.borrow().len(), 1);
    }

    #[tokio::test]
    async fn fragmented_geometry_record_survives_a_frame_timeout_without_reparse() {
        let update = GeometryUpdate {
            sequence: 4,
            epoch: 5,
            size: LogicalSize::checked(800.0, 600.0).unwrap(),
        };
        let payload = update.encode();
        let mut wire = vec![GEOMETRY, 0, GeometryUpdate::ENCODED_LEN as u8];
        wire.extend_from_slice(&payload);
        let pause = Rc::new(Cell::new(false));
        let reader = FragmentedControlReader {
            fragments: [wire[..1].to_vec(), wire[1..].to_vec()].into(),
            pause: pause.clone(),
            stalled_once: false,
        };
        let mut control_reader = ControlRecordReader::new(reader);
        // This timeout models a frame completion/timeout select branch. The
        // next future is canceled, but the reader object retains the byte it
        // already consumed and resumes that record on the next poll.
        assert!(
            tokio::time::timeout(Duration::from_millis(1), control_reader.next())
                .await
                .is_err()
        );
        pause.set(false);
        let (kind, bytes) = control_reader.next().await.unwrap();
        assert_eq!(kind, GEOMETRY);
        assert_eq!(GeometryUpdate::decode(&bytes).unwrap(), update);
    }
}
