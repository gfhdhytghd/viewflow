//! Bounded raw-PCM capture from a private Viewflow sink monitor on Linux.
//!
//! The only supported source name is `<owned-private-sink>.monitor`; this
//! module intentionally cannot select `@DEFAULT_MONITOR@`, an arbitrary host
//! source, or a receiver playback device. `parec` is spawned only after the
//! caller proves that the sink is still owned by
//! [`PactlApplicationAudioControl`](crate::linux_application_audio::PactlApplicationAudioControl).

use std::fmt;
use std::io::{self, Read};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::thread;

use crate::application_audio::ApplicationAudioRuntime;
use crate::linux_application_audio::{PactlApplicationAudioControl, PactlCommandRunner};
use viewflow_protocol::WindowFamilyId;

#[cfg(test)]
use viewflow_protocol::Id128;

const MAX_CAPTURE_CHUNK_BYTES: usize = 1024 * 1024;
const MAX_CAPTURE_QUEUED_CHUNKS: usize = 256;
const MAX_CAPTURE_BUFFERED_BYTES: usize = 16 * 1024 * 1024;

/// `parec` emits signed little-endian 16-bit samples. Keeping this fixed makes
/// block byte accounting unambiguous; format negotiation/encoding remains a
/// later media-stage responsibility.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PcmCaptureFormat {
    pub sample_rate_hz: u32,
    pub channels: u8,
}

impl Default for PcmCaptureFormat {
    fn default() -> Self {
        Self {
            sample_rate_hz: 48_000,
            channels: 2,
        }
    }
}

impl PcmCaptureFormat {
    fn bytes_per_frame(self) -> Result<usize, CaptureError<()>> {
        if !(8_000..=192_000).contains(&self.sample_rate_hz) || !(1..=2).contains(&self.channels) {
            return Err(CaptureError::InvalidFormat);
        }
        Ok(usize::from(self.channels) * 2)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivateSinkCaptureRequest {
    pub family_id: WindowFamilyId,
    pub generation: u64,
    pub capture_sink_id: String,
    pub format: PcmCaptureFormat,
    /// A block is bounded before it enters a caller-owned encoder queue.
    pub max_frames_per_block: u32,
    /// Maximum unread worker chunks. New chunks are dropped at the producer
    /// when full rather than blocking capture or allocating unbounded memory.
    pub max_queued_chunks: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CapturedPrivateSinkPcmBlock {
    pub family_id: WindowFamilyId,
    pub generation: u64,
    pub sequence: u64,
    pub format: PcmCaptureFormat,
    pub frame_count: u32,
    pub bytes: Vec<u8>,
}

/// A non-blocking child-process handle. Implementations must retain ownership
/// of their child and kill/reap it when `stop` is called.
pub trait ParecCaptureSession {
    type Error;

    /// # Errors
    ///
    /// Returns the session error when the capture pipe fails. `Ok(None)` means
    /// no whole chunk is presently available; it does not mean capture ended.
    fn try_read_chunk(&mut self) -> Result<Option<Vec<u8>>, Self::Error>;

    /// # Errors
    ///
    /// Returns the session error when the child could not be stopped and reaped.
    fn stop(&mut self) -> Result<(), Self::Error>;
}

/// Process seam for isolated tests. Production uses `SystemParecProcess`,
/// while tests record exact argv and return fake bounded chunks.
pub trait ParecCaptureProcess {
    type Error;
    type Session: ParecCaptureSession<Error = Self::Error>;

    /// # Errors
    ///
    /// Returns the process error when the requested `parec` child cannot be
    /// started with the supplied bounded queue and chunk capacities.
    fn spawn_parec(
        &mut self,
        args: &[String],
        max_queued_chunks: usize,
        max_chunk_bytes: usize,
    ) -> Result<Self::Session, Self::Error>;
}

/// Real opt-in `parec` process owner. Construction alone does not contact an
/// audio server; [`ParecCaptureProcess::spawn_parec`] is the explicit boundary.
#[derive(Clone, Debug)]
pub struct SystemParecProcess {
    program: String,
}

impl Default for SystemParecProcess {
    fn default() -> Self {
        Self {
            program: "parec".to_owned(),
        }
    }
}

impl SystemParecProcess {
    #[must_use]
    pub fn new(program: impl Into<String>) -> Self {
        Self {
            program: program.into(),
        }
    }
}

#[derive(Debug)]
pub enum ProcessParecError {
    Io(io::Error),
    Ended,
    WorkerPanic,
    Overflow,
    InvalidBounds,
}

impl fmt::Display for ProcessParecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "parec process I/O failed: {error}"),
            Self::Ended => formatter.write_str("parec capture process ended"),
            Self::WorkerPanic => formatter.write_str("parec capture reader worker panicked"),
            Self::Overflow => {
                formatter.write_str("parec capture queue overflowed; capture was stopped")
            }
            Self::InvalidBounds => formatter.write_str("parec capture bounds must be nonzero"),
        }
    }
}
impl std::error::Error for ProcessParecError {}

pub struct SystemParecSession {
    child: Option<Child>,
    receiver: mpsc::Receiver<Result<Vec<u8>, ProcessParecError>>,
    worker: Option<thread::JoinHandle<()>>,
    overflowed: Arc<AtomicBool>,
}

impl ParecCaptureProcess for SystemParecProcess {
    type Error = ProcessParecError;
    type Session = SystemParecSession;

    fn spawn_parec(
        &mut self,
        args: &[String],
        max_queued_chunks: usize,
        max_chunk_bytes: usize,
    ) -> Result<Self::Session, Self::Error> {
        if max_queued_chunks == 0
            || max_queued_chunks > MAX_CAPTURE_QUEUED_CHUNKS
            || max_chunk_bytes == 0
            || max_chunk_bytes > MAX_CAPTURE_CHUNK_BYTES
            || max_queued_chunks
                .checked_mul(max_chunk_bytes)
                .is_none_or(|total| total > MAX_CAPTURE_BUFFERED_BYTES)
        {
            return Err(ProcessParecError::InvalidBounds);
        }
        let mut child = Command::new(&self.program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(ProcessParecError::Io)?;
        let stdout = child.stdout.take().ok_or_else(|| {
            let _ = child.kill();
            let _ = child.wait();
            ProcessParecError::Io(io::Error::other("parec stdout pipe was unavailable"))
        })?;
        let (sender, receiver) = mpsc::sync_channel(max_queued_chunks);
        let overflowed = Arc::new(AtomicBool::new(false));
        let worker_overflowed = Arc::clone(&overflowed);
        let worker = thread::Builder::new()
            .name("viewflow-parec-read".to_owned())
            .spawn(move || {
                let mut stdout = stdout;
                loop {
                    let mut chunk = vec![0_u8; max_chunk_bytes];
                    match stdout.read(&mut chunk) {
                        Ok(0) => break,
                        Ok(size) => {
                            chunk.truncate(size);
                            // A `read` boundary need not be PCM-frame aligned, so
                            // overflow is terminal rather than silently dropping
                            // bytes and splicing a discontinuity into a channel.
                            match sender.try_send(Ok(chunk)) {
                                Ok(()) => {}
                                Err(mpsc::TrySendError::Full(_)) => {
                                    worker_overflowed.store(true, Ordering::Release);
                                    break;
                                }
                                Err(mpsc::TrySendError::Disconnected(_)) => break,
                            }
                        }
                        Err(error) => {
                            let _ = sender.try_send(Err(ProcessParecError::Io(error)));
                            break;
                        }
                    }
                }
            })
            .map_err(|error| {
                let _ = child.kill();
                let _ = child.wait();
                ProcessParecError::Io(error)
            })?;
        Ok(SystemParecSession {
            child: Some(child),
            receiver,
            worker: Some(worker),
            overflowed,
        })
    }
}

impl ParecCaptureSession for SystemParecSession {
    type Error = ProcessParecError;

    fn try_read_chunk(&mut self) -> Result<Option<Vec<u8>>, Self::Error> {
        if self.overflowed.load(Ordering::Acquire) {
            self.stop()?;
            return Err(ProcessParecError::Overflow);
        }
        match self.receiver.try_recv() {
            Ok(result) => result.map(Some),
            Err(mpsc::TryRecvError::Empty) => Ok(None),
            Err(mpsc::TryRecvError::Disconnected) => {
                self.stop()?;
                Err(ProcessParecError::Ended)
            }
        }
    }

    fn stop(&mut self) -> Result<(), Self::Error> {
        if let Some(child) = self.child.as_mut() {
            if child.try_wait().map_err(ProcessParecError::Io)?.is_none() {
                child.kill().map_err(ProcessParecError::Io)?;
                child.wait().map_err(ProcessParecError::Io)?;
            }
            self.child = None;
        }
        if let Some(worker) = self.worker.take() {
            worker.join().map_err(|_| ProcessParecError::WorkerPanic)?;
        }
        Ok(())
    }
}

impl Drop for SystemParecSession {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.child = None;
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[derive(Debug)]
pub enum CaptureError<E> {
    Process(E),
    PrivateSinkNotOwned,
    InvalidFormat,
    InvalidQueueBound,
    InvalidBlockBound,
    ChunkTooLarge,
    RouteNoLongerActive,
    Stopped,
}

impl<E: fmt::Display> fmt::Display for CaptureError<E> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Process(error) => write!(formatter, "private sink PCM process failed: {error}"),
            Self::PrivateSinkNotOwned => {
                formatter.write_str("refusing to capture a sink not owned by this Viewflow runtime")
            }
            Self::InvalidFormat => {
                formatter.write_str("PCM capture format is outside the supported bounded contract")
            }
            Self::InvalidQueueBound => {
                formatter.write_str("PCM capture queue bound must be nonzero and finite")
            }
            Self::InvalidBlockBound => {
                formatter.write_str("PCM capture block frame bound must be nonzero")
            }
            Self::ChunkTooLarge => {
                formatter.write_str("PCM capture process exceeded its configured block bound")
            }
            Self::RouteNoLongerActive => {
                formatter.write_str("PCM capture route is no longer the active owned generation")
            }
            Self::Stopped => formatter.write_str("PCM capture has already been stopped"),
        }
    }
}

impl<E: fmt::Debug + fmt::Display> std::error::Error for CaptureError<E> {}

/// Explicit owner for one application-family private-monitor capture process.
#[derive(Debug)]
pub struct PrivateSinkPcmCapture<P: ParecCaptureProcess> {
    process: P,
    session: P::Session,
    request: PrivateSinkCaptureRequest,
    bytes_per_frame: usize,
    next_sequence: u64,
    remainder: Vec<u8>,
    stopped: bool,
}

impl<P: ParecCaptureProcess> PrivateSinkPcmCapture<P> {
    /// Starts a capture only from a sink currently owned by the provided route
    /// control. No command is issued if ownership or the configured bounds are
    /// invalid.
    ///
    /// # Errors
    ///
    /// Returns an error when ownership/bounds are invalid or the bounded
    /// `parec` child cannot be started.
    pub fn start<R>(
        runtime: &ApplicationAudioRuntime<PactlApplicationAudioControl<R>>,
        mut process: P,
        request: PrivateSinkCaptureRequest,
    ) -> Result<Self, CaptureError<P::Error>>
    where
        R: PactlCommandRunner,
    {
        let current_route = runtime.active_route(request.family_id);
        if !matches!(
            current_route,
            Some(route)
                if route.generation == request.generation
                    && route.capture_sink_id == request.capture_sink_id
        ) || !runtime
            .control()
            .owned_private_sink(&request.capture_sink_id)
        {
            return Err(CaptureError::PrivateSinkNotOwned);
        }
        let bytes_per_frame = request
            .format
            .bytes_per_frame()
            .map_err(|_| CaptureError::InvalidFormat)?;
        if request.max_frames_per_block == 0 {
            return Err(CaptureError::InvalidBlockBound);
        }
        if request.max_queued_chunks == 0 || request.max_queued_chunks > MAX_CAPTURE_QUEUED_CHUNKS {
            return Err(CaptureError::InvalidQueueBound);
        }
        let max_chunk_bytes = usize::try_from(request.max_frames_per_block)
            .ok()
            .and_then(|frames| frames.checked_mul(bytes_per_frame))
            .ok_or(CaptureError::InvalidBlockBound)?;
        if max_chunk_bytes > MAX_CAPTURE_CHUNK_BYTES
            || request
                .max_queued_chunks
                .checked_mul(max_chunk_bytes)
                .is_none_or(|total| total > MAX_CAPTURE_BUFFERED_BYTES)
        {
            return Err(CaptureError::InvalidBlockBound);
        }
        let args = parec_args(&request.capture_sink_id, request.format);
        let session = process
            .spawn_parec(&args, request.max_queued_chunks, max_chunk_bytes)
            .map_err(CaptureError::Process)?;
        Ok(Self {
            process,
            session,
            request,
            bytes_per_frame,
            next_sequence: 1,
            remainder: Vec::with_capacity(bytes_per_frame.saturating_sub(1)),
            stopped: false,
        })
    }

    /// Polls one bounded raw PCM block without waiting. The caller owns the
    /// returned bytes and must associate a source monotonic timestamp before
    /// passing metadata to an encoder/transport stage.
    ///
    /// # Errors
    ///
    /// Returns an error if the process failed, was stopped, or emitted more
    /// than one configured bounded block in a chunk.
    pub fn try_next_block<R>(
        &mut self,
        runtime: &ApplicationAudioRuntime<PactlApplicationAudioControl<R>>,
    ) -> Result<Option<CapturedPrivateSinkPcmBlock>, CaptureError<P::Error>>
    where
        R: PactlCommandRunner,
    {
        if self.stopped {
            return Err(CaptureError::Stopped);
        }
        if !runtime_matches_request(runtime, &self.request) {
            self.stop()?;
            return Err(CaptureError::RouteNoLongerActive);
        }
        let Some(chunk) = self
            .session
            .try_read_chunk()
            .map_err(CaptureError::Process)?
        else {
            return Ok(None);
        };
        let max_bytes = usize::try_from(self.request.max_frames_per_block)
            .unwrap_or(usize::MAX)
            .saturating_mul(self.bytes_per_frame);
        if chunk.len() > max_bytes {
            return Err(CaptureError::ChunkTooLarge);
        }
        self.remainder.extend_from_slice(&chunk);
        let whole_bytes = self.remainder.len() / self.bytes_per_frame * self.bytes_per_frame;
        if whole_bytes == 0 {
            return Ok(None);
        }
        let bytes = self.remainder.drain(..whole_bytes).collect::<Vec<_>>();
        let frame_count = u32::try_from(bytes.len() / self.bytes_per_frame)
            .map_err(|_| CaptureError::ChunkTooLarge)?;
        let block = CapturedPrivateSinkPcmBlock {
            family_id: self.request.family_id,
            generation: self.request.generation,
            sequence: self.next_sequence,
            format: self.request.format,
            frame_count,
            bytes,
        };
        self.next_sequence = self.next_sequence.saturating_add(1);
        Ok(Some(block))
    }

    /// Stops and reaps the owned capture child. Callers must use this explicitly
    /// to observe a cleanup failure before retiring the private sink.
    ///
    /// # Errors
    ///
    /// Returns an error when the child could not be stopped and reaped.
    pub fn stop(&mut self) -> Result<(), CaptureError<P::Error>> {
        if self.stopped {
            return Ok(());
        }
        self.session.stop().map_err(CaptureError::Process)?;
        self.stopped = true;
        self.remainder.clear();
        Ok(())
    }

    #[must_use]
    pub fn request(&self) -> &PrivateSinkCaptureRequest {
        &self.request
    }

    #[must_use]
    pub fn process(&self) -> &P {
        &self.process
    }
}

fn runtime_matches_request<R>(
    runtime: &ApplicationAudioRuntime<PactlApplicationAudioControl<R>>,
    request: &PrivateSinkCaptureRequest,
) -> bool
where
    R: PactlCommandRunner,
{
    matches!(
        runtime.active_route(request.family_id),
        Some(route)
            if route.generation == request.generation
                && route.capture_sink_id == request.capture_sink_id
    ) && runtime
        .control()
        .owned_private_sink(&request.capture_sink_id)
}

fn parec_args(sink_id: &str, format: PcmCaptureFormat) -> Vec<String> {
    vec![
        "--record".to_owned(),
        "--raw".to_owned(),
        format!("--device={sink_id}.monitor"),
        "--client-name=viewflow-private-sink-capture".to_owned(),
        "--stream-name=viewflow-per-application-pcm".to_owned(),
        "--format=s16le".to_owned(),
        format!("--rate={}", format.sample_rate_hz),
        format!("--channels={}", format.channels),
        "--no-remix".to_owned(),
        "--no-remap".to_owned(),
        "--latency-msec=20".to_owned(),
        "--process-time-msec=10".to_owned(),
    ]
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;
    use crate::application_audio::ApplicationAudioRuntime;
    use crate::linux_application_audio::PactlApplicationAudioControl;
    use viewflow_protocol::AudioRoute;

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct FakeError;
    impl fmt::Display for FakeError {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("fake error")
        }
    }

    #[derive(Default)]
    struct FakePactl;
    impl PactlCommandRunner for FakePactl {
        type Error = FakeError;
        fn run_pactl(&mut self, _args: &[String]) -> Result<String, Self::Error> {
            Ok("9\n".to_owned())
        }
    }

    #[derive(Debug)]
    struct FakeSession {
        chunks: VecDeque<Result<Option<Vec<u8>>, FakeError>>,
        stopped: bool,
    }
    impl ParecCaptureSession for FakeSession {
        type Error = FakeError;
        fn try_read_chunk(&mut self) -> Result<Option<Vec<u8>>, Self::Error> {
            self.chunks.pop_front().unwrap_or(Ok(None))
        }
        fn stop(&mut self) -> Result<(), Self::Error> {
            self.stopped = true;
            Ok(())
        }
    }
    #[derive(Default)]
    struct FakeProcess {
        calls: Vec<Vec<String>>,
        chunks: VecDeque<Result<Option<Vec<u8>>, FakeError>>,
    }
    impl ParecCaptureProcess for FakeProcess {
        type Error = FakeError;
        type Session = FakeSession;
        fn spawn_parec(
            &mut self,
            args: &[String],
            _queue: usize,
            _bytes: usize,
        ) -> Result<Self::Session, Self::Error> {
            self.calls.push(args.to_vec());
            Ok(FakeSession {
                chunks: std::mem::take(&mut self.chunks),
                stopped: false,
            })
        }
    }
    fn active_runtime() -> ApplicationAudioRuntime<PactlApplicationAudioControl<FakePactl>> {
        let control = PactlApplicationAudioControl::new(FakePactl);
        let mut runtime = ApplicationAudioRuntime::new(Id128(1), control);
        runtime
            .apply_route(AudioRoute {
                generation: 1,
                family_id: Id128(50),
                source_device: Id128(1),
                target_device: Id128(2),
                target_output_id: "receiver".to_owned(),
                enabled: true,
            })
            .unwrap();
        runtime
    }
    fn request() -> PrivateSinkCaptureRequest {
        PrivateSinkCaptureRequest {
            family_id: Id128(50),
            generation: 1,
            capture_sink_id:
                "viewflow.family.00000000000000000000000000000032.generation.00000000000000000001"
                    .to_owned(),
            format: PcmCaptureFormat::default(),
            max_frames_per_block: 4,
            max_queued_chunks: 2,
        }
    }
    #[test]
    fn starts_only_owned_private_monitor_and_emits_bounded_blocks() {
        let mut process = FakeProcess::default();
        process.chunks.push_back(Ok(Some(vec![1, 2, 3, 4, 5])));
        let runtime = active_runtime();
        let mut capture = PrivateSinkPcmCapture::start(&runtime, process, request()).unwrap();
        let block = capture.try_next_block(&runtime).unwrap().unwrap();
        assert_eq!(block.frame_count, 1);
        assert_eq!(block.bytes, vec![1, 2, 3, 4]);
        assert_eq!(capture.try_next_block(&runtime).unwrap(), None);
        capture.stop().unwrap();
        assert!(
            capture.process().calls[0]
                .iter()
                .any(|arg| arg.ends_with(".monitor"))
        );
        assert!(
            capture.process().calls[0]
                .iter()
                .all(|arg| !arg.contains("@DEFAULT") && !arg.contains("default.node"))
        );
    }
    #[test]
    fn rejects_unowned_sink_without_spawning() {
        let process = FakeProcess::default();
        let mut unowned = request();
        unowned.capture_sink_id = "host-speakers".to_owned();
        assert!(matches!(
            PrivateSinkPcmCapture::start(&active_runtime(), process, unowned),
            Err(CaptureError::PrivateSinkNotOwned)
        ));
    }

    #[test]
    fn poll_fences_capture_after_route_generation_changes() {
        let mut runtime = active_runtime();
        let capture =
            PrivateSinkPcmCapture::start(&runtime, FakeProcess::default(), request()).unwrap();
        runtime
            .apply_route(AudioRoute {
                generation: 2,
                family_id: Id128(50),
                source_device: Id128(1),
                target_device: Id128(2),
                target_output_id: "receiver".to_owned(),
                enabled: false,
            })
            .unwrap();
        let mut capture = capture;
        assert!(matches!(
            capture.try_next_block(&runtime),
            Err(CaptureError::RouteNoLongerActive)
        ));
    }

    #[test]
    fn system_session_stops_and_reaps_an_owned_sleep_child() {
        let mut process = SystemParecProcess::new("/usr/bin/sleep");
        let args = ["30".to_owned()];
        let mut session = process.spawn_parec(&args, 1, 4).unwrap();
        session.stop().unwrap();
        assert!(session.child.is_none());
        assert!(session.worker.is_none());
    }

    #[test]
    fn dropping_system_session_kills_and_reaps_an_owned_sleep_child() {
        let mut process = SystemParecProcess::new("/usr/bin/sleep");
        let args = ["30".to_owned()];
        let session = process.spawn_parec(&args, 1, 4).unwrap();
        let pid = session.child.as_ref().unwrap().id().to_string();
        drop(session);
        let status = Command::new("/usr/bin/kill")
            .args(["-0", &pid])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert!(!status.success());
    }

    #[test]
    fn system_process_rejects_zero_public_bounds_before_spawn() {
        let mut process = SystemParecProcess::new("/usr/bin/false");
        assert!(matches!(
            process.spawn_parec(&[], 0, 4),
            Err(ProcessParecError::InvalidBounds)
        ));
    }

    #[test]
    fn bounds_reject_oversized_block_and_public_buffer_product() {
        let mut oversized = request();
        oversized.max_frames_per_block = u32::MAX;
        assert!(matches!(
            PrivateSinkPcmCapture::start(&active_runtime(), FakeProcess::default(), oversized),
            Err(CaptureError::InvalidBlockBound)
        ));
        let mut process = SystemParecProcess::new("/usr/bin/false");
        assert!(matches!(
            process.spawn_parec(&[], MAX_CAPTURE_QUEUED_CHUNKS, MAX_CAPTURE_CHUNK_BYTES),
            Err(ProcessParecError::InvalidBounds)
        ));
    }
}
