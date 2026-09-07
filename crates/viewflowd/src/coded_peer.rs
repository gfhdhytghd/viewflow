//! Native compressed-window runtime shared by process entry points.
//!
//! Linux is the producer: it imports authenticated HCSF straight RGBA frames
//! from `HyprCapture` and uses `CompatibleEncoder` to make a H.264/VFAR pair.
//! Windows is the consumer: it admits the pair before writing one VFGP record
//! to an explicitly selected GPU presenter subprocess.  This is deliberately
//! a one-in-flight diagnostic; a VFGP write/submission acknowledgement is not
//! a compositor scanout acknowledgement.

#[cfg(any(windows, test))]
use std::sync::atomic::AtomicU8;
#[cfg(windows)]
use std::sync::atomic::AtomicU64;
#[cfg(any(windows, test))]
use std::sync::{
    Condvar, Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::{
    collections::BTreeMap,
    future::Future,
    net::SocketAddr,
    pin::Pin,
    task::Poll,
    time::{Duration, Instant},
};

/// Wait for one already-created control operation while giving the capture
/// source regular opportunities to release frames it will not encode.  The
/// operation is pinned once: rebuilding a `RecvStream` future after a drain
/// tick could lose partially consumed control bytes.
async fn poll_with_drain<T, F, D>(
    operation: F,
    deadline: Instant,
    timeout_message: &'static str,
    mut drain: D,
) -> Result<T>
where
    F: Future<Output = Result<T>>,
    D: FnMut() -> Result<()>,
{
    tokio::pin!(operation);
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|duration| !duration.is_zero())
            .ok_or_else(|| anyhow::anyhow!(timeout_message))?;
        tokio::select! {
            result = &mut operation => {
                // A ready operation may win a coalesced timer wake after the
                // absolute deadline. Completion does not refresh admission.
                if Instant::now() >= deadline {
                    bail!(timeout_message);
                }
                return result;
            },
            () = tokio::time::sleep(remaining.min(Duration::from_millis(1))) => drain()?,
        }
    }
}

use crate::alpha_reference::{ALPHA_REFERENCE_BYTES, AlphaReferenceCache};
use anyhow::{Context, Result, bail};
#[cfg(any(windows, test))]
use bytes::Bytes;
#[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
use quinn::SendDatagramError;
use quinn::{Endpoint, RecvStream, SendStream};
use tokio::io::{AsyncRead, ReadBuf};
use viewflow_protocol::Id128;
use viewflow_transport::ClockEstimate;
#[cfg(any(windows, test))]
use viewflow_transport::FrameCodecMetadata;
#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
use viewflow_transport::build_client_config;
use viewflow_transport::{CODEC_DESCRIPTOR_BYTES, FRAME_CODEC_METADATA_BYTES, PeerIdentity};
#[cfg(windows)]
use viewflow_transport::{
    CodecDescriptor, CodecResourceLimits, CodecSession, MediaAssembler, MediaAssemblerConfig,
    MediaDatagram, MediaPlane, MediaPlaneFrame, build_server_config,
};
#[cfg(all(test, not(windows)))]
use viewflow_transport::{
    MediaAssembler, MediaAssemblerConfig, MediaDatagram, MediaPlane, MediaPlaneFrame,
};

const WINDOW: Id128 = Id128(1);
#[cfg(any(windows, test, all(target_os = "linux", feature = "native-nvenc")))]
const DEADLINE_NS: u64 = 33_333_333;
#[cfg(any(windows, test))]
const PRESENTER_ACK_WAIT: Duration = Duration::from_nanos(DEADLINE_NS);
// This is only a bounded wait for an authoritative no-bind disposition after
// the already fixed source freshness deadline. It never makes a Presented
// frame fresh or extends the native QPC deadline encoded in VFGP v4.
#[cfg(any(windows, test))]
const EXPIRED_DISPOSITION_GRACE: Duration = Duration::from_millis(100);
#[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
const CONTROL_RESPONSE_WAIT: Duration = Duration::from_secs(1);
const DEFAULT_MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;
#[cfg(windows)]
// Device/Composition cold initialization happens before READY and before
// media admission. This bounded startup allowance is not a frame deadline;
// the enclosing session timeout still caps it.
const PRESENTER_STARTUP_WAIT: Duration = Duration::from_secs(5);
// Independent of decode-only warmup and live frame freshness. On the Intel
// guest a bounded standalone MTA cold start measured 7.99 seconds (r33).
#[cfg(any(windows, test))]
const PRESENTER_COLD_START_WAIT: Duration = Duration::from_secs(15);
const CLOCK_PROBE: u8 = 1;
const CLOCK_REPLY: u8 = 2;
const CLOCK_ESTIMATE: u8 = 3;
const LOGICAL_GEOMETRY: u8 = 4;
const BLUR_RECT: u8 = 5;
const DESCRIPTORS: u8 = 6;
const FRAME_META: u8 = 7;
const READY: u8 = 8;
const PRESENTER_ACK: u8 = 9;
const REJECT: u8 = 10;
const BLUR_RADIUS: u8 = 11;
// Startup-only records travel on the authenticated reliable stream. They are
// intentionally disjoint from live frame control and are consumed exactly once
// before READY opens media admission.
const WARMUP_META: u8 = 12;
const WARMUP_COLOR: u8 = 13;
const WARMUP_ALPHA: u8 = 14;
const WARMUP_ACK: u8 = 15;
// Three-frame startup is deliberately a separate, explicit negotiation.  The
// legacy one-frame flow sends neither record and remains wire-compatible.
const WARMUP_PLAN: u8 = 16;
const WARMUP_PLAN_ACK: u8 = 17;
// Optional alpha reuse is separately negotiated before any warmup capture.
// Its live form owns one complete metadata slot, so an old reference cannot
// remain pending and accidentally attach to a later frame.
const ALPHA_REUSE_PLAN: u8 = 18;
const ALPHA_REUSE_PLAN_ACK: u8 = 19;
const FRAME_META_ALPHA_REFERENCE: u8 = 20;
const DEFAULT_WARMUP_FRAMES: u8 = 1;
const MULTI_FRAME_WARMUP_FRAMES: u8 = 3;
const MAX_WARMUP_CONTROL_CHUNK: usize = 60 * 1024;
const WARMUP_META_BYTES: usize = 40 + FRAME_CODEC_METADATA_BYTES * 2 + 16;
const FRAME_META_BYTES: usize = 40 + FRAME_CODEC_METADATA_BYTES * 2;
const ALPHA_REUSE_PLAN_PAYLOAD: [u8; 1] = [1];

fn validate_alpha_reuse_plan(enabled: bool, wire: &[u8]) -> Result<()> {
    if !enabled || wire != ALPHA_REUSE_PLAN_PAYLOAD {
        bail!("alpha reuse plan does not exactly match local configuration")
    }
    Ok(())
}

#[cfg(any(windows, test))]
fn parse_frame_meta_record(
    kind: u8,
    payload: &[u8],
    alpha_reuse_enabled: bool,
) -> Result<(&[u8], Option<&[u8]>)> {
    match kind {
        FRAME_META if payload.len() == FRAME_META_BYTES => Ok((payload, None)),
        FRAME_META_ALPHA_REFERENCE
            if alpha_reuse_enabled && payload.len() == FRAME_META_BYTES + ALPHA_REFERENCE_BYTES =>
        {
            Ok((
                &payload[..FRAME_META_BYTES],
                Some(&payload[FRAME_META_BYTES..]),
            ))
        }
        FRAME_META_ALPHA_REFERENCE if !alpha_reuse_enabled => {
            bail!("received alpha reference without negotiated opt-in")
        }
        FRAME_META | FRAME_META_ALPHA_REFERENCE => bail!("invalid coded metadata"),
        _ => bail!("unexpected reliable record"),
    }
}

#[cfg(any(windows, test))]
fn current_alpha_plane_from_reference(
    window_id: Id128,
    frame_id: u64,
    geometry_epoch: u64,
    source_submitted_ns: u64,
    payload: Bytes,
) -> MediaPlaneFrame {
    // Cache payload is old only as an immutable lossless bitstream. Every
    // identity and timestamp field belongs to the just-assembled color frame.
    MediaPlaneFrame {
        window_id,
        frame_id,
        geometry_epoch,
        plane: MediaPlane::Alpha,
        source_submitted_ns,
        payload,
    }
}

#[cfg(any(windows, test))]
fn validate_reference_packet_plane(alpha_referenced: bool, plane: MediaPlane) -> Result<()> {
    if alpha_referenced && plane == MediaPlane::Alpha {
        bail!("alpha datagram is forbidden for referenced alpha frame")
    }
    Ok(())
}

#[cfg(any(windows, test))]
fn decode_warmup_tail(meta: &[u8]) -> Result<(u64, usize, usize)> {
    if meta.len() != WARMUP_META_BYTES {
        bail!("invalid warmup metadata length")
    }
    // The timestamp begins immediately after the two codec metadata records.
    // It is already mapped once into the sender's session clock and is never
    // used for warmup freshness admission.
    let base = 40 + FRAME_CODEC_METADATA_BYTES * 2;
    let source_submitted_ns = u64::from_be_bytes(meta[base..base + 8].try_into()?);
    let color_len = usize::try_from(u32::from_be_bytes(meta[base + 8..base + 12].try_into()?))?;
    let alpha_len = usize::try_from(u32::from_be_bytes(meta[base + 12..base + 16].try_into()?))?;
    Ok((source_submitted_ns, color_len, alpha_len))
}

fn warmup_frame_count(value: &str) -> Result<u8> {
    match value {
        "1" => Ok(DEFAULT_WARMUP_FRAMES),
        "3" => Ok(MULTI_FRAME_WARMUP_FRAMES),
        _ => bail!("--warmup-frames must be exactly 1 or 3"),
    }
}

fn requires_warmup_plan(frames: u8) -> bool {
    frames == MULTI_FRAME_WARMUP_FRAMES
}

fn validate_warmup_plan(frames: u8, peer_plan: &[u8]) -> Result<()> {
    if !requires_warmup_plan(frames) || peer_plan != [frames] {
        bail!("warmup plan does not exactly match local configuration")
    }
    Ok(())
}

fn validate_warmup_reference(
    ordinal: usize,
    keyframe: bool,
    lineage: (u64, u64),
    expected_lineage: Option<(u64, u64)>,
) -> Result<Option<(u64, u64)>> {
    if let Some(expected) = expected_lineage {
        if lineage != expected {
            bail!("warmup geometry/config changed within reference chain")
        }
    }
    if ordinal == 0 {
        if !keyframe {
            bail!("first warmup frame must be an IDR/keyframe")
        }
    } else if keyframe {
        // This fixed low-latency H.264 encoder has no B pictures.  Metadata
        // proves only non-keyframe here; do not overstate that for other encoders.
        bail!("multi-frame warmup must retain non-keyframe references")
    }
    Ok(expected_lineage.or(Some(lineage)))
}

fn validate_warmup_ack(expected: FrameIdentity, wire: &[u8]) -> Result<()> {
    if FrameIdentity::decode(wire)? != expected {
        bail!("receiver warmup ACK identity mismatch")
    }
    Ok(())
}

#[cfg(any(windows, test))]
fn validate_warmup_metadata(
    tag: FrameIdentity,
    color: FrameCodecMetadata,
    alpha: FrameCodecMetadata,
) -> Result<()> {
    // H.264 color carries the inter-frame reference chain while VFAR alpha is
    // independently lossless and therefore keyframe-marked on every frame.
    // Both planes must still bind to the tag's one config generation.
    if tag.config != color.config_generation || tag.config != alpha.config_generation {
        bail!("warmup metadata does not match its frame identity")
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct LogicalSize {
    width: f64,
    height: f64,
}
impl LogicalSize {
    fn checked(width: f64, height: f64) -> Result<Self> {
        if !width.is_finite() || !height.is_finite() || width <= 0.0 || height <= 0.0 {
            bail!("logical dimensions must be positive finite values")
        }
        Ok(Self { width, height })
    }
    fn encode(self) -> [u8; 16] {
        let mut b = [0; 16];
        b[..8].copy_from_slice(&self.width.to_be_bytes());
        b[8..].copy_from_slice(&self.height.to_be_bytes());
        b
    }
    #[cfg(windows)]
    fn decode(b: &[u8]) -> Result<Self> {
        if b.len() != 16 {
            bail!("invalid logical geometry")
        }
        Self::checked(
            f64::from_be_bytes(b[..8].try_into()?),
            f64::from_be_bytes(b[8..].try_into()?),
        )
    }
}

#[derive(Clone, Copy, Debug)]
struct BlurRect {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
}
impl BlurRect {
    fn parse(s: &str) -> Result<Self> {
        let p: Vec<_> = s.split(',').collect();
        if p.len() != 4 {
            bail!("--composition-blur-rect is x,y,w,h")
        }
        let r = Self {
            x: p[0].parse()?,
            y: p[1].parse()?,
            width: p[2].parse()?,
            height: p[3].parse()?,
        };
        if r.width == 0 || r.height == 0 {
            bail!("blur rectangle must be nonempty")
        }
        Ok(r)
    }
    fn encode(self) -> [u8; 16] {
        let mut b = [0; 16];
        for (i, v) in [self.x, self.y, self.width, self.height]
            .into_iter()
            .enumerate()
        {
            b[i * 4..i * 4 + 4].copy_from_slice(&v.to_be_bytes());
        }
        b
    }
    #[cfg(windows)]
    fn decode(b: &[u8]) -> Result<Self> {
        if b.len() != 16 {
            bail!("invalid blur rectangle")
        }
        let r = Self {
            x: u32::from_be_bytes(b[..4].try_into()?),
            y: u32::from_be_bytes(b[4..8].try_into()?),
            width: u32::from_be_bytes(b[8..12].try_into()?),
            height: u32::from_be_bytes(b[12..].try_into()?),
        };
        if r.width == 0 || r.height == 0 {
            bail!("blur rectangle must be nonempty")
        }
        Ok(r)
    }
    fn validate(self, s: LogicalSize) -> Result<()> {
        if f64::from(self.x) + f64::from(self.width) > s.width
            || f64::from(self.y) + f64::from(self.height) > s.height
        {
            bail!("blur rectangle exceeds initial logical geometry")
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct FrameIdentity {
    window: Id128,
    frame: u64,
    epoch: u64,
    config: u64,
}
impl FrameIdentity {
    fn encode(self) -> [u8; 40] {
        let mut b = [0; 40];
        b[..16].copy_from_slice(&self.window.0.to_be_bytes());
        for (i, v) in [self.frame, self.epoch, self.config]
            .into_iter()
            .enumerate()
        {
            b[16 + i * 8..24 + i * 8].copy_from_slice(&v.to_be_bytes());
        }
        b
    }
    fn decode(b: &[u8]) -> Result<Self> {
        if b.len() != 40 {
            bail!("invalid coded ACK identity")
        }
        Ok(Self {
            window: Id128(u128::from_be_bytes(b[..16].try_into()?)),
            frame: u64::from_be_bytes(b[16..24].try_into()?),
            epoch: u64::from_be_bytes(b[24..32].try_into()?),
            config: u64::from_be_bytes(b[32..].try_into()?),
        })
    }
}

#[allow(clippy::struct_excessive_bools)] // Explicit CLI capability gates.
#[derive(Clone)]
struct Options {
    role: String,
    cert: String,
    key: String,
    ca: String,
    remote: Option<SocketAddr>,
    #[cfg_attr(not(windows), allow(dead_code))]
    listen: Option<SocketAddr>,
    server_name: Option<String>,
    capture_stream: Option<String>,
    warmup_alpha_output: Option<String>,
    /// Use the HCGF DMA-BUF source and native GPU encoder.  CPU HCSF remains
    /// the default so existing invocations retain their exact behavior.
    capture_gpu: bool,
    compositor_pid: Option<u32>,
    logical: Option<LogicalSize>,
    blur: Option<BlurRect>,
    blur_radius: Option<f64>,
    #[cfg_attr(not(windows), allow(dead_code))]
    presenter: Option<String>,
    #[cfg_attr(not(windows), allow(dead_code))]
    require_deadline_v4: bool,
    #[cfg_attr(not(windows), allow(dead_code))]
    recover_expired_v4: bool,
    /// Hold back this much of an otherwise fresh source budget from the VFGP
    /// v4 QPC deadline. This does not alter freshness or ACK deadlines.
    #[cfg_attr(not(windows), allow(dead_code))]
    presentation_reserve: Duration,
    #[cfg_attr(not(windows), allow(dead_code))]
    emit_pointer_motion: bool,
    #[cfg_attr(not(windows), allow(dead_code))]
    forward_pointer_motion: Option<PointerForwarding>,
    #[cfg_attr(not(windows), allow(dead_code))]
    forward_pointer_buttons: bool,
    #[cfg_attr(
        not(all(target_os = "linux", feature = "native-nvenc")),
        allow(dead_code)
    )]
    authorize_pointer_motion: Option<PointerForwarding>,
    #[cfg_attr(
        not(all(target_os = "linux", feature = "native-nvenc")),
        allow(dead_code)
    )]
    authorize_pointer_buttons: bool,
    #[cfg_attr(
        not(all(target_os = "linux", feature = "native-nvenc")),
        allow(dead_code)
    )]
    pointer_native_socket: Option<String>,
    warmup_frames: u8,
    alpha_reuse_warmup: bool,
    max_frame_bytes: usize,
    timeout: Duration,
    persistent: bool,
    reconnect: bool,
}

#[derive(Clone, Copy)]
enum MediaLifetime {
    Bounded(Instant),
    Persistent { operation_timeout: Duration },
}

impl From<Instant> for MediaLifetime {
    fn from(deadline: Instant) -> Self {
        Self::Bounded(deadline)
    }
}

impl MediaLifetime {
    fn live(persistent: bool, deadline: Instant, operation_timeout: Duration) -> Self {
        if persistent {
            Self::Persistent { operation_timeout }
        } else {
            Self::Bounded(deadline)
        }
    }

    fn budget(self, now: Instant) -> Option<Duration> {
        match self {
            Self::Bounded(deadline) => deadline.checked_duration_since(now),
            Self::Persistent { operation_timeout } => Some(operation_timeout),
        }
        .filter(|remaining| !remaining.is_zero())
    }

    #[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
    fn active(self, now: Instant) -> bool {
        self.budget(now).is_some()
    }

    #[cfg(any(windows, test))]
    fn frame_deadline(self, now: Instant, maximum: Duration) -> Result<Instant> {
        let budget = self.budget(now).context("media session deadline elapsed")?;
        now.checked_add(budget.min(maximum))
            .context("media frame deadline overflow")
    }
}

#[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
async fn run_after_bounded_startup<F>(
    work: F,
    mut ready: tokio::sync::oneshot::Receiver<Instant>,
    deadline: Instant,
) -> Result<()>
where
    F: Future<Output = Result<()>>,
{
    tokio::pin!(work);
    tokio::select! {
        biased;
        result = &mut work => {
            result?;
            if !ready.try_recv().is_ok_and(|confirmed| confirmed < deadline) {
                bail!("media attempt completed without timely startup confirmation");
            }
            Ok(())
        }
        signal = &mut ready => {
            let confirmed = signal.context("media startup confirmation closed")?;
            if confirmed >= deadline {
                bail!("media startup confirmation arrived after deadline");
            }
            work.await
        }
        () = tokio::time::sleep_until(deadline.into()) => {
            bail!("media startup deadline elapsed");
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct PointerForwarding {
    owner: Id128,
    source: Id128,
}

fn pointer_device_id(value: &str) -> Result<Id128> {
    if value.len() != 32 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("pointer device IDs require exactly 32 hexadecimal digits");
    }
    let id = Id128(u128::from_str_radix(value, 16)?);
    if id.0 == 0 {
        bail!("pointer device ID cannot be zero");
    }
    Ok(id)
}

#[cfg(any(windows, test))]
#[cfg_attr(test, allow(dead_code))]
#[derive(Default)]
struct ReceiverStats {
    frame_started: Option<Instant>,
    frames: u64,
    reject_timeout: u64,
    reject_late: u64,
    reject_after_assembly: u64,
    reject_after_validation: u64,
    logged_rejects: u8,
}

#[cfg(any(windows, test))]
#[cfg_attr(test, allow(dead_code))]
impl ReceiverStats {
    fn reject(
        &mut self,
        reason: &str,
        tag: FrameIdentity,
        first_packet_us: Option<u128>,
        source_age_upper_ns: Option<u64>,
        color_seen_packets: u32,
        color_expected_chunks: Option<u16>,
        alpha_seen_packets: u32,
        alpha_expected_chunks: Option<u16>,
    ) {
        match reason {
            "timeout" => self.reject_timeout = self.reject_timeout.saturating_add(1),
            "late" => self.reject_late = self.reject_late.saturating_add(1),
            "after_assembly" => {
                self.reject_after_assembly = self.reject_after_assembly.saturating_add(1)
            }
            "after_validation" => {
                self.reject_after_validation = self.reject_after_validation.saturating_add(1)
            }
            _ => unreachable!("fixed receiver reject reason"),
        }
        if self.logged_rejects < 5 {
            self.logged_rejects += 1;
            let elapsed = self.frame_started.map(|start| start.elapsed());
            // Diagnostic estimate only: advance the normalized first-packet
            // age by elapsed host time. This never participates in admission.
            let estimated_age = source_age_upper_ns.and_then(|age| {
                let since_first = elapsed?.as_nanos().checked_sub(first_packet_us? * 1000)?;
                age.checked_add(u64::try_from(since_first).ok()?)
            });
            eprintln!(
                "coded receiver reject frame={} reason={} first_matching_packet_us={:?} first_source_age_upper_ns={:?} color_seen_packets={} color_expected_chunks={:?} alpha_seen_packets={} alpha_expected_chunks={:?} assembly_elapsed_us={:?} estimated_source_age_at_reject_ns={:?}",
                tag.frame,
                reason,
                first_packet_us,
                source_age_upper_ns,
                color_seen_packets,
                color_expected_chunks,
                alpha_seen_packets,
                alpha_expected_chunks,
                elapsed.map(|value| value.as_micros()),
                estimated_age,
            );
        }
    }

    fn print(&self) {
        eprintln!(
            "coded receiver summary: frames={} reject_timeout={} reject_late={} reject_after_assembly={} reject_after_validation={} reject_detail_lines={}",
            self.frames,
            self.reject_timeout,
            self.reject_late,
            self.reject_after_assembly,
            self.reject_after_validation,
            self.logged_rejects,
        );
    }
}

#[cfg(any(windows, test))]
impl Drop for ReceiverStats {
    fn drop(&mut self) {
        self.print();
    }
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
#[derive(Default)]
struct SenderStats {
    capture_received: u64,
    pre_encode_stale: u64,
    clean_encode_expired: u64,
    post_encode_stale: u64,
    idr_wait_dropped: u64,
    sent: u64,
    acknowledged: u64,
    recoverable_rejected: u64,
    datagram_too_large_dropped: u64,
    expired_dispatch: u64,
    sent_payload_bytes: u64,
    sent_color_payload_bytes: u64,
    sent_alpha_payload_bytes: u64,
    alpha_reused: u64,
    alpha_reused_bytes: u64,
    encode_samples: Vec<Duration>,
    sent_source_age_samples_ns: Vec<u64>,
    dispatch_samples: Vec<Duration>,
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
impl SenderStats {
    const MAX_ENCODE_SAMPLES: usize = 1024;

    fn observe_encode(&mut self, elapsed: Duration) {
        if self.encode_samples.len() < Self::MAX_ENCODE_SAMPLES {
            self.encode_samples.push(elapsed);
        }
    }

    fn observe_send(
        &mut self,
        color_payload_bytes: usize,
        alpha_payload_bytes: usize,
        alpha_reused_bytes: usize,
        source_age_ns: u64,
        dispatch: Duration,
    ) {
        let payload_bytes = color_payload_bytes.saturating_add(alpha_payload_bytes);
        self.sent_payload_bytes = self
            .sent_payload_bytes
            .saturating_add(u64::try_from(payload_bytes).unwrap_or(u64::MAX));
        self.sent_color_payload_bytes = self
            .sent_color_payload_bytes
            .saturating_add(u64::try_from(color_payload_bytes).unwrap_or(u64::MAX));
        self.sent_alpha_payload_bytes = self
            .sent_alpha_payload_bytes
            .saturating_add(u64::try_from(alpha_payload_bytes).unwrap_or(u64::MAX));
        if alpha_reused_bytes != 0 {
            self.alpha_reused = self.alpha_reused.saturating_add(1);
            self.alpha_reused_bytes = self
                .alpha_reused_bytes
                .saturating_add(u64::try_from(alpha_reused_bytes).unwrap_or(u64::MAX));
        }
        if self.sent_source_age_samples_ns.len() < Self::MAX_ENCODE_SAMPLES {
            self.sent_source_age_samples_ns.push(source_age_ns);
            self.dispatch_samples.push(dispatch);
        }
    }

    fn print(&mut self) {
        self.encode_samples.sort_unstable();
        self.sent_source_age_samples_ns.sort_unstable();
        self.dispatch_samples.sort_unstable();
        let dispatch_percentile = |n| {
            self.dispatch_samples
                .get(self.dispatch_samples.len().saturating_sub(1) * n / 100)
                .map_or(0, Duration::as_micros)
        };
        eprintln!(
            "transport dispatch_us_p50={} dispatch_us_p95={} samples={}",
            dispatch_percentile(50),
            dispatch_percentile(95),
            self.dispatch_samples.len()
        );
        let percentile = |numerator: usize| {
            self.encode_samples
                .get(
                    self.encode_samples
                        .len()
                        .saturating_sub(1)
                        .saturating_mul(numerator)
                        / 100,
                )
                .map_or(0_u128, Duration::as_micros)
        };
        let source_age_percentile = |numerator: usize| {
            self.sent_source_age_samples_ns
                .get(
                    self.sent_source_age_samples_ns
                        .len()
                        .saturating_sub(1)
                        .saturating_mul(numerator)
                        / 100,
                )
                .copied()
                .unwrap_or(0)
        };
        eprintln!(
            "coded summary: capture_received={} pre_encode_stale={} clean_encode_expired={} post_encode_stale={} idr_wait_dropped={} datagram_too_large_dropped={} expired_dispatch={} sent={} ACKed={} recoverable_rejected={} sent_payload_bytes={} sent_color_payload_bytes={} sent_alpha_payload_bytes={} alpha_reused={} alpha_reused_bytes={} sent_source_age_ns_p50={} sent_source_age_ns_p95={} source_age_samples={} encode_host_us_p50={} encode_host_us_p95={} encode_samples={}",
            self.capture_received,
            self.pre_encode_stale,
            self.clean_encode_expired,
            self.post_encode_stale,
            self.idr_wait_dropped,
            self.datagram_too_large_dropped,
            self.expired_dispatch,
            self.sent,
            self.acknowledged,
            self.recoverable_rejected,
            self.sent_payload_bytes,
            self.sent_color_payload_bytes,
            self.sent_alpha_payload_bytes,
            self.alpha_reused,
            self.alpha_reused_bytes,
            source_age_percentile(50),
            source_age_percentile(95),
            self.sent_source_age_samples_ns.len(),
            percentile(50),
            percentile(95),
            self.encode_samples.len()
        );
    }
}

// Keep source ownership explicit: GPU frames are single-slot allocations and
// may only be acknowledged after their native encoder has completed source
// reads.  CPU captures have no corresponding producer acknowledgement.
#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
enum CaptureSource {
    Cpu(crate::hyprcapture_runtime::HyprCaptureStreamSession),
    #[cfg(feature = "native-gpu-nvenc")]
    Gpu(crate::hyprcapture_runtime::GpuStreamSession),
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
enum CaptureFrame {
    Cpu(
        crate::hyprcapture_stream::FrameHeader,
        crate::hyprcapture_stream::ReadOnlyFrameMapping,
    ),
    #[cfg(feature = "native-gpu-nvenc")]
    Gpu(Box<crate::hyprcapture_gpu_socket::GpuFrame>),
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
impl CaptureSource {
    fn recv(&mut self) -> Result<Option<CaptureFrame>> {
        use crate::hyprcapture_socket::MappedReceiveOutcome;
        match self {
            Self::Cpu(session) => match session.receiver.recv_latest_mapped_frame()? {
                MappedReceiveOutcome::Frame(header, pixels) => {
                    Ok(Some(CaptureFrame::Cpu(header, pixels)))
                }
                MappedReceiveOutcome::WouldBlock => Ok(None),
                MappedReceiveOutcome::Disconnected => bail!("HyprCapture stream disconnected"),
            },
            #[cfg(feature = "native-gpu-nvenc")]
            Self::Gpu(session) => match session.receiver.recv_frame()? {
                crate::hyprcapture_gpu_socket::GpuReceiveOutcome::Frame(frame) => {
                    Ok(Some(CaptureFrame::Gpu(frame)))
                }
                crate::hyprcapture_gpu_socket::GpuReceiveOutcome::WouldBlock => Ok(None),
                crate::hyprcapture_gpu_socket::GpuReceiveOutcome::Disconnected => {
                    bail!("HyprCapture GPU stream disconnected")
                }
            },
        }
    }

    fn release_unencoded(&mut self, frame: &CaptureFrame) -> Result<()> {
        // Queue-floor and stale frames never enter the GPU encoder, so their
        // source reads are vacuously complete and can be released immediately.
        self.release(frame)
    }

    fn release_encoded(&mut self, frame: &CaptureFrame) -> Result<()> {
        self.release(frame)
    }

    #[allow(clippy::unnecessary_wraps)] // GPU release can fail; CPU is a no-op.
    fn release(&mut self, frame: &CaptureFrame) -> Result<()> {
        match (self, frame) {
            #[cfg(feature = "native-gpu-nvenc")]
            (Self::Gpu(session), CaptureFrame::Gpu(frame)) => {
                session.receiver.release_after_source_reads(frame)
            }
            (Self::Cpu(_), CaptureFrame::Cpu(_, _)) => Ok(()),
            #[cfg(feature = "native-gpu-nvenc")]
            _ => bail!("capture source/frame mismatch"),
        }
    }

    async fn stop(self) -> Result<()> {
        match self {
            Self::Cpu(session) => session.stop_stream(Duration::from_secs(2)).await,
            #[cfg(feature = "native-gpu-nvenc")]
            Self::Gpu(session) => session.stop_stream(Duration::from_secs(2)).await,
        }
    }
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
impl CaptureFrame {
    fn input_snapshot(&self) -> Option<crate::window_input_runtime::CapturedWindowInput> {
        match self {
            Self::Cpu(_, _) => None,
            #[cfg(feature = "native-gpu-nvenc")]
            Self::Gpu(frame) => {
                Some(crate::window_input_runtime::CapturedWindowInput::from_gpu_frame(frame))
            }
        }
    }
    fn capture_ns(&self) -> u64 {
        match self {
            Self::Cpu(header, _) => header.capture_monotonic_ns,
            #[cfg(feature = "native-gpu-nvenc")]
            Self::Gpu(frame) => frame.metadata().capture_monotonic_ns,
        }
    }
    fn sequence(&self) -> u64 {
        match self {
            Self::Cpu(header, _) => header.sequence,
            #[cfg(feature = "native-gpu-nvenc")]
            Self::Gpu(frame) => frame.metadata().sequence,
        }
    }
    fn geometry(&self) -> (u64, u32, u32) {
        match self {
            Self::Cpu(header, _) => (header.geometry_epoch, header.width, header.height),
            #[cfg(feature = "native-gpu-nvenc")]
            // The encoder imports the cropped DMA-BUF view, not the backing
            // FBO.  Descriptor geometry must therefore follow crop extent.
            Self::Gpu(frame) => {
                let m = frame.metadata();
                (m.geometry_epoch, m.crop_width, m.crop_height)
            }
        }
    }
    fn logical_size(&self) -> (f64, f64) {
        match self {
            Self::Cpu(header, _) => (header.logical_rect[2], header.logical_rect[3]),
            #[cfg(feature = "native-gpu-nvenc")]
            Self::Gpu(frame) => {
                let m = frame.metadata();
                (m.logical_width, m.logical_height)
            }
        }
    }
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
enum SenderEncoder {
    Cpu(Box<crate::compatible_encoder::CompatibleEncoder>),
    #[cfg(feature = "native-gpu-nvenc")]
    Gpu(Box<crate::gpu_compatible_encoder::GpuCompatibleEncoder>),
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
impl SenderEncoder {
    // None is exclusive to verified pre-NVENC expiry, not a queued CPU output.
    fn submit_live(
        &mut self,
        identity: crate::compatible_encoder::CodecIdentity,
        frame: &CaptureFrame,
        mapped_source_ns: u64,
        deadline: i64,
    ) -> Result<Option<Vec<crate::compatible_encoder::MediaFrame>>> {
        #[cfg(feature = "native-gpu-nvenc")]
        if let Self::Gpu(encoder) = self {
            let CaptureFrame::Gpu(frame) = frame else {
                bail!("capture encoder/source mismatch")
            };
            return encoder
                .submit_recoverable(identity, frame, mapped_source_ns, deadline)
                .map(|outcome| match outcome {
                    crate::gpu_compatible_encoder::GpuSubmitOutcome::Encoded(frames) => {
                        Some(frames)
                    }
                    crate::gpu_compatible_encoder::GpuSubmitOutcome::ExpiredClean => None,
                });
        }
        self.submit(identity, frame, mapped_source_ns, deadline)
            .map(Some)
    }
    fn descriptors(&self) -> Option<crate::compatible_encoder::DescriptorPair> {
        match self {
            Self::Cpu(encoder) => encoder.descriptors(),
            #[cfg(feature = "native-gpu-nvenc")]
            Self::Gpu(encoder) => encoder.descriptors(),
        }
    }
    fn request_keyframe(&mut self) {
        match self {
            Self::Cpu(encoder) => encoder.request_keyframe(),
            #[cfg(feature = "native-gpu-nvenc")]
            Self::Gpu(encoder) => encoder.request_keyframe(),
        }
    }
    fn submit(
        &mut self,
        identity: crate::compatible_encoder::CodecIdentity,
        frame: &CaptureFrame,
        mapped_source_ns: u64,
        deadline: i64,
    ) -> Result<Vec<crate::compatible_encoder::MediaFrame>> {
        #[cfg(not(feature = "native-gpu-nvenc"))]
        let _ = deadline;
        match (self, frame) {
            (Self::Cpu(encoder), CaptureFrame::Cpu(header, pixels)) => {
                let mut header = header.clone();
                header.capture_monotonic_ns = mapped_source_ns;
                encoder.submit_borrowed(identity, header, pixels.as_ref())
            }
            #[cfg(feature = "native-gpu-nvenc")]
            (Self::Gpu(encoder), CaptureFrame::Gpu(frame)) => {
                encoder.submit(identity, frame, mapped_source_ns, deadline)
            }
            #[cfg(feature = "native-gpu-nvenc")]
            _ => bail!("capture encoder/source mismatch"),
        }
    }
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
fn drain_unencoded_capture(source: &mut CaptureSource) -> Result<()> {
    // A GPU source has exactly one producer-owned allocation.  Reliable QUIC
    // startup can take much longer than its 500 ms ownership lease, so drain
    // every queued frame while no encode is in progress.  Never extend that
    // lease and never ACK a frame whose submit failed.
    // One per control poll prevents a continuously producing source from
    // starving the pending reliable read; the next 1 ms tick drains the next.
    if let Some(frame) = source.recv()? {
        source.release_unencoded(&frame)?;
    }
    Ok(())
}

/// Learn the true DMA-BUF crop extent before constructing the lazy native
/// context.  The probe frame is intentionally dropped without HCGR: it never
/// entered an encoder, and `stop_stream` retires this request before the real
/// session begins.  That keeps cold driver setup outside the 500 ms ownership
/// lease of the formal sender stream.
#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
async fn probe_gpu_crop_size(stream_address: &str, compositor_pid: u32) -> Result<(u32, u32)> {
    use crate::hyprcapture_gpu_socket::GpuReceiveOutcome;
    let mut session = crate::hyprcapture_runtime::start_gpu_stream(
        stream_address,
        60,
        compositor_pid,
        Duration::from_secs(2),
    )
    .await?;
    let probe = async {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if Instant::now() >= deadline {
                bail!("GPU probe timed out waiting for a capture frame")
            }
            match session.receiver.recv_frame()? {
                GpuReceiveOutcome::Frame(frame) => {
                    let metadata = frame.metadata();
                    if metadata.crop_width == 0 || metadata.crop_height == 0 {
                        bail!("GPU probe returned empty crop")
                    }
                    // Drop closes only local descriptors.  Do not call HCGR:
                    // no native source reads happened for this probe frame.
                    return Ok((metadata.crop_width, metadata.crop_height));
                }
                GpuReceiveOutcome::WouldBlock => tokio::time::sleep(Duration::from_millis(1)).await,
                GpuReceiveOutcome::Disconnected => bail!("GPU probe capture peer disconnected"),
            }
        }
    }
    .await;
    let stop = session.stop_stream(Duration::from_secs(2)).await;
    match (probe, stop) {
        (Ok(size), Ok(())) => Ok(size),
        (Err(error), Ok(())) => Err(error),
        (Ok(_), Err(stop_error)) => Err(stop_error).context("GPU probe stream stop failed"),
        (Err(error), Err(stop_error)) => {
            Err(error).context(format!("GPU probe stream stop also failed: {stop_error}"))
        }
    }
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
async fn read_record_draining(
    source: &mut CaptureSource,
    rx: &mut RecvStream,
    expected: u8,
    len: usize,
    deadline: Instant,
) -> Result<Vec<u8>> {
    poll_with_drain(
        read_record(rx, expected, len),
        deadline,
        "coded startup deadline elapsed",
        || drain_unencoded_capture(source),
    )
    .await
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
async fn read_any_record_draining(
    source: &mut CaptureSource,
    rx: &mut RecvStream,
    deadline: Instant,
) -> Result<Option<(u8, Vec<u8>)>> {
    poll_with_drain(
        read_any_record(rx),
        deadline,
        "receiver control response deadline elapsed",
        || drain_unencoded_capture(source),
    )
    .await
}

fn build_coded_runtime() -> Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(Into::into)
}

/// Per-process timer-resolution request for modern Windows (Windows 10 2004+
/// gives this request process scope).  Construction fails before runtime work;
/// a successful request is always paired by Drop, including early returns.
#[cfg(any(windows, test))]
pub(crate) struct ScopedTimerResolution<F: FnOnce() -> u32> {
    end: Option<F>,
}

#[cfg(any(windows, test))]
impl<F: FnOnce() -> u32> Drop for ScopedTimerResolution<F> {
    fn drop(&mut self) {
        if let Some(end) = self.end.take() {
            let status = end();
            if status != 0 {
                eprintln!("timeEndPeriod(1) failed with status {status}");
            }
        }
    }
}

#[cfg(any(windows, test))]
fn acquire_timer_resolution<B, E>(begin: B, end: E) -> Result<ScopedTimerResolution<E>>
where
    B: FnOnce() -> u32,
    E: FnOnce() -> u32,
{
    let status = begin();
    if status != 0 {
        bail!("timeBeginPeriod(1) failed with status {status}")
    }
    Ok(ScopedTimerResolution { end: Some(end) })
}

#[cfg(windows)]
#[allow(unsafe_code)] // Two scalar-only WinMM calls; lifetime paired by the guard.
pub(crate) fn enable_windows_timer_resolution() -> Result<ScopedTimerResolution<fn() -> u32>> {
    use windows_sys::Win32::Media::{timeBeginPeriod, timeEndPeriod};
    // This diagnostic targets modern Windows; Windows 10 2004+ was verified
    // on the intended receiver and scopes this request to this process.
    acquire_timer_resolution(
        // SAFETY: 1 is a valid millisecond request, with no pointer arguments.
        // The end closure is called exactly once only when begin succeeds.
        || unsafe { timeBeginPeriod(1) },
        || unsafe { timeEndPeriod(1) },
    )
}

/// Run one bounded native media connection from explicit process arguments.
///
/// This owns a thread-bound GPU context and creates its own Tokio runtime;
/// invoke it from the process's main thread, not from an async task. Reconnect
/// ownership and multi-window atlas orchestration belong to the caller.
///
/// # Errors
/// Invalid local configuration, transport, deadline, capture, presentation, or
/// input failures terminate this connection without retrying old input.
pub fn run_from_args<I>(args: I) -> Result<()>
where
    I: IntoIterator<Item = String>,
{
    let o = parse_options_from(args)?;
    #[cfg(windows)]
    let _timer_resolution = enable_windows_timer_resolution()?;
    // Keep `run` on the calling OS thread: GpuCompatibleEncoder owns a
    // thread-bound !Send native context.  The two workers are solely for
    // Quinn/timer progress while this direct future is synchronously busy.
    build_coded_runtime()?.block_on(run(o))
}
async fn run(o: Options) -> Result<()> {
    // Install handlers before starting any native work. Registration failure
    // must not leave a persistent process without a working stop path.
    let mut shutdown = ProcessShutdown::register()?;
    let reconnect = o.reconnect;
    let mut peer = NativeMediaPeer::from_options(o)?;
    eprintln!("native media owner stop handlers ready");
    let mut signal_error = None;
    let stop = async {
        if let Err(error) = shutdown.wait().await {
            signal_error = Some(error);
        }
    };
    let report = if reconnect {
        Box::pin(peer.run_reconnecting_until_shutdown(stop)).await
    } else {
        Box::pin(peer.run_next_until_shutdown(stop)).await
    };
    if report.shutdown_requested {
        eprintln!("native media owner stop requested; attempt retirement returned");
    }
    if let Some(error) = signal_error {
        return match report.result {
            Ok(()) => Err(error),
            Err(primary) => Err(primary).context(format!("stop signal listener failed: {error:#}")),
        };
    }
    report.result
}

struct ProcessShutdown {
    #[cfg(unix)]
    interrupt: tokio::signal::unix::Signal,
    #[cfg(unix)]
    terminate: tokio::signal::unix::Signal,
    #[cfg(windows)]
    interrupt: tokio::signal::windows::CtrlC,
    #[cfg(windows)]
    terminate: tokio::signal::windows::CtrlBreak,
}

impl ProcessShutdown {
    fn register() -> Result<Self> {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{SignalKind, signal};
            Ok(Self {
                interrupt: signal(SignalKind::interrupt()).context("register media SIGINT")?,
                terminate: signal(SignalKind::terminate()).context("register media SIGTERM")?,
            })
        }
        #[cfg(windows)]
        {
            Ok(Self {
                interrupt: tokio::signal::windows::ctrl_c().context("register media Ctrl-C")?,
                terminate: tokio::signal::windows::ctrl_break()
                    .context("register media Ctrl-Break")?,
            })
        }
    }

    async fn wait(&mut self) -> Result<()> {
        let received = tokio::select! {
            event = self.interrupt.recv() => event,
            event = self.terminate.recv() => event,
        };
        received.context("media stop signal stream closed")
    }
}

/// One locally configured media peer and one retained QUIC endpoint.
///
/// Each call to `run_next` creates fresh connection-local media, clock and
/// input state. It cannot run concurrently with another call on this owner.
/// This is a lifecycle boundary, not yet a multi-window atlas coordinator.
pub struct NativeMediaPeer {
    options: Options,
    endpoint: Endpoint,
    attempt: u64,
    runnable: bool,
    retry_delay: Option<Duration>,
}

struct NativePeerRunGuard<'a> {
    peer: &'a mut NativeMediaPeer,
    completed: bool,
}
impl Drop for NativePeerRunGuard<'_> {
    fn drop(&mut self) {
        if !self.completed {
            self.peer.runnable = false;
        }
    }
}

/// Result of one attempt driven to completion, including after local shutdown.
/// The attempt error is retained even when shutdown was requested: native
/// cleanup failures must never be converted into successful shutdown.
#[derive(Debug)]
pub struct NativeMediaAttemptReport {
    pub shutdown_requested: bool,
    pub result: Result<()>,
}

async fn finish_on_shutdown<W, S, C>(work: W, shutdown: S, close: C) -> NativeMediaAttemptReport
where
    W: std::future::Future<Output = Result<()>>,
    S: std::future::Future<Output = ()>,
    C: FnOnce(),
{
    tokio::pin!(work);
    tokio::select! {
        biased;
        result = &mut work => NativeMediaAttemptReport { shutdown_requested: false, result },
        () = shutdown => {
            close();
            // Do not cancel native ownership by dropping the attempt future.
            // Closing transport wakes its waits; checked retirement still runs.
            NativeMediaAttemptReport { shutdown_requested: true, result: work.await }
        }
    }
}

impl NativeMediaPeer {
    /// Bind a peer using explicit local policy arguments. Call within the
    /// Tokio runtime that will drive this endpoint, on the GPU-owning thread.
    /// # Errors
    /// Rejects invalid configuration, identity, unsupported role, or bind failure.
    pub fn bind_from_args<I>(args: I) -> Result<Self>
    where
        I: IntoIterator<Item = String>,
    {
        Self::from_options(parse_options_from(args)?)
    }

    fn from_options(options: Options) -> Result<Self> {
        let endpoint = bind_media_endpoint(&options)?;
        Ok(Self {
            options,
            endpoint,
            attempt: 0,
            runnable: true,
            retry_delay: None,
        })
    }

    /// The stable bound endpoint address, including across failed connections.
    /// # Errors
    /// Returns an OS error if the endpoint's local address cannot be queried.
    pub fn local_addr(&self) -> std::io::Result<SocketAddr> {
        self.endpoint.local_addr()
    }

    /// Number of connection attempts started by this owner.
    #[must_use]
    pub fn attempt(&self) -> u64 {
        self.attempt
    }

    /// Run one fresh connection without replacing the endpoint. Await its
    /// completion before retrying: source cleanup retires native input before
    /// capture resources. No old presentation receipts or events are replayed.
    /// This future must remain on the GPU-owning OS thread.
    /// # Errors
    /// Returns all admission, native and transport failures to the owner; it
    /// never silently retries an input or relaxes a deadline.
    pub async fn run_next(&mut self) -> Result<()> {
        if !self.runnable {
            bail!("previous media attempt did not complete; owner is fenced");
        }
        self.attempt = self
            .attempt
            .checked_add(1)
            .context("native media connection attempt counter exhausted")?;
        // Cancellation may drop the future before asynchronous native cleanup
        // has completed. Do not let the same owner silently start a new route.
        self.runnable = false;
        let result = match self.options.role.as_str() {
            "send" => send(self.options.clone(), &self.endpoint).await,
            "receive" => receive(self.options.clone(), &self.endpoint).await,
            _ => bail!("role must be send or receive"),
        };
        self.runnable = !result
            .as_ref()
            .is_err_and(anyhow::Error::is::<NativeCleanupFailure>);
        result
    }

    /// Run an attempt with a caller-owned shutdown signal. Shutdown permanently
    /// closes this endpoint and awaits the attempt's checked native retirement.
    /// It never aborts the attempt or silently discards its error. Inspect both
    /// fields of the report; a requested stop does not imply cleanup succeeded.
    /// Like `run_next`, this future must remain on the GPU-owning OS thread.
    /// Dropping this future still fences the owner and is not graceful shutdown.
    pub async fn run_next_until_shutdown<S>(&mut self, shutdown: S) -> NativeMediaAttemptReport
    where
        S: std::future::Future<Output = ()>,
    {
        let endpoint = self.endpoint.clone();
        let report = finish_on_shutdown(self.run_next(), shutdown, move || {
            endpoint.close(0_u32.into(), b"native media owner stopped");
        })
        .await;
        if report.shutdown_requested {
            self.runnable = false;
        }
        report
    }

    /// Retry explicitly classified transport failures after checked retirement,
    /// preserving this endpoint but rebuilding all connection-local state.
    /// Requires persistent mode. Backoff is interruptible by shutdown; cancelling
    /// this future fences the owner even between attempts. Native input failures,
    /// peer policy closes, protocol/TLS errors and cleanup failures are terminal.
    pub async fn run_reconnecting_until_shutdown<S>(
        &mut self,
        shutdown: S,
    ) -> NativeMediaAttemptReport
    where
        S: Future<Output = ()>,
    {
        let mut guard = NativePeerRunGuard {
            peer: self,
            completed: false,
        };
        let endpoint = guard.peer.endpoint.clone();
        let (stop, stopped) = tokio::sync::watch::channel(false);
        let report =
            finish_on_shutdown(guard.peer.run_reconnecting(stopped), shutdown, move || {
                stop.send_replace(true);
                endpoint.close(0_u32.into(), b"native media owner stopped");
            })
            .await;
        if report.shutdown_requested {
            guard.peer.runnable = false;
        }
        guard.completed = true;
        report
    }

    async fn run_reconnecting(
        &mut self,
        mut stopped: tokio::sync::watch::Receiver<bool>,
    ) -> Result<()> {
        if !self.options.persistent {
            bail!("reconnect requires persistent mode");
        }
        let mut delay = Duration::from_millis(250);
        loop {
            self.retry_delay = None;
            let result = self.run_next().await;
            let error = match result {
                Ok(()) => return Ok(()),
                Err(error) => error,
            };
            if !self.runnable || *stopped.borrow() || !retryable_media_transport(&error) {
                return Err(error);
            }
            self.retry_delay = Some(delay);
            eprintln!(
                "native media retry after attempt={} delay_ms={} error={error:#}",
                self.attempt,
                delay.as_millis()
            );
            tokio::select! {
                biased;
                _ = stopped.changed() => return Err(error),
                () = tokio::time::sleep(delay) => {},
            }
            if *stopped.borrow() {
                return Err(error);
            }
            delay = delay.saturating_mul(2).min(Duration::from_secs(5));
        }
    }
}

fn bind_media_endpoint(o: &Options) -> Result<Endpoint> {
    match o.role.as_str() {
        #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
        "send" => bind_sender_endpoint(o),
        #[cfg(windows)]
        "receive" => bind_receiver_endpoint(o),
        _ => bail!("media role is not supported by this platform/build"),
    }
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
fn bind_sender_endpoint(o: &Options) -> Result<Endpoint> {
    let remote = o.remote.context("send requires --remote")?;
    let identity = load_identity(o)?;
    let mut endpoint = Endpoint::client(
        if remote.is_ipv4() {
            "0.0.0.0:0"
        } else {
            "[::]:0"
        }
        .parse()?,
    )?;
    let mut client_config = build_client_config(&identity)
        .map_err(|e| anyhow::anyhow!("build mTLS client config: {e}"))?;
    // Preserve the bounded unsent prefix used by the deadline-gated sender.
    let mut transport = quinn::TransportConfig::default();
    transport.datagram_send_buffer_size(64 * 1024);
    client_config.transport_config(std::sync::Arc::new(transport));
    endpoint.set_default_client_config(client_config);
    Ok(endpoint)
}

/// Close only the retiring connection, never the owner's endpoint. This also
/// runs on errors and cancellation, before a later attempt can reuse the peer.
struct RetiringConnection(quinn::Connection);
impl Drop for RetiringConnection {
    fn drop(&mut self) {
        self.0
            .close(0_u32.into(), b"native media connection retired");
    }
}

#[derive(Debug)]
struct NativeCleanupFailure;
impl std::fmt::Display for NativeCleanupFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("native media cleanup failed; owner must remain fenced")
    }
}
impl std::error::Error for NativeCleanupFailure {}

#[derive(Debug)]
struct NativeInputTaskFailure;
impl std::fmt::Display for NativeInputTaskFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("native media input task failed")
    }
}
impl std::error::Error for NativeInputTaskFailure {}

#[derive(Debug)]
struct MediaConnectTimeout;
impl std::fmt::Display for MediaConnectTimeout {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("media transport admission timed out before native setup")
    }
}
impl std::error::Error for MediaConnectTimeout {}

// Keep both typed failures: a transport error on one branch cannot authorize
// retry when the other branch failed an input invariant or native deadline.
#[derive(Debug)]
struct AccompanyingMediaFailure(anyhow::Error);
impl std::fmt::Display for AccompanyingMediaFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "media attempt also ended: {:#}", self.0)
    }
}

fn retryable_media_transport(error: &anyhow::Error) -> bool {
    if error.is::<NativeCleanupFailure>() || error.is::<crate::InputRecoveryUnconfirmed>() {
        return false;
    }
    let liveness_timeout = error.is::<crate::PeerLivenessTimeout>();
    if let Some(media) = error.downcast_ref::<AccompanyingMediaFailure>() {
        // The input dispatcher closes its connection when its liveness probe
        // expires. Only that typed primary cause can account for the paired
        // local media close; arbitrary local closes remain terminal. Shutdown
        // additionally fences the owner before this policy can start an attempt.
        let liveness_retirement = liveness_timeout
            && error.is::<NativeInputTaskFailure>()
            && !media.0.is::<NativeCleanupFailure>()
            && !media.0.is::<crate::InputRecoveryUnconfirmed>()
            && media.0.chain().any(|cause| {
                matches!(
                    cause.downcast_ref::<quinn::ConnectionError>(),
                    Some(quinn::ConnectionError::LocallyClosed)
                )
            });
        if !liveness_retirement && !retryable_media_transport(&media.0) {
            return false;
        }
    }
    if liveness_timeout {
        return true;
    }
    if error.is::<MediaConnectTimeout>() && !error.is::<NativeInputTaskFailure>() {
        return true;
    }
    error.chain().any(retryable_transport_cause)
}

fn retryable_transport_cause(error: &(dyn std::error::Error + 'static)) -> bool {
    if let Some(error) = error.downcast_ref::<std::io::Error>() {
        return error
            .get_ref()
            .is_some_and(|inner| retryable_transport_cause(inner));
    }
    if let Some(error) = error.downcast_ref::<quinn::ReadError>() {
        return matches!(error, quinn::ReadError::ConnectionLost(cause)
            if retryable_transport_cause(cause));
    }
    if let Some(error) = error.downcast_ref::<quinn::WriteError>() {
        return matches!(error, quinn::WriteError::ConnectionLost(cause)
            if retryable_transport_cause(cause));
    }
    matches!(
        error.downcast_ref::<quinn::ConnectionError>(),
        Some(quinn::ConnectionError::Reset | quinn::ConnectionError::TimedOut)
    )
}

async fn retire_input_task(
    task: &mut tokio::task::JoinHandle<Result<()>>,
    budget: Duration,
) -> Result<()> {
    match tokio::time::timeout(budget, &mut *task).await {
        Ok(Ok(result)) => result.context(NativeInputTaskFailure),
        Ok(Err(error)) => Err(error).context(NativeCleanupFailure),
        Err(error) => {
            task.abort();
            // Await destruction even on timeout; never leave an input owner
            // running behind a retired capture/presenter. A forced cancellation
            // cannot prove a clean task result and must fence future attempts.
            let joined = task.await;
            Err(error)
                .context(format!(
                    "input task retirement exceeded its bound; join={joined:?}"
                ))
                .context(NativeCleanupFailure)
        }
    }
}

fn finish_input_attempt(media: Result<()>, input: Result<()>) -> Result<()> {
    match (media, input) {
        (media, Ok(())) => media,
        (Ok(()), Err(input)) => Err(input),
        (Err(media), Err(input)) => Err(input).context(AccompanyingMediaFailure(media)),
    }
}

fn finish_native_attempt(result: Result<()>, cleanup: Result<()>) -> Result<()> {
    match (result, cleanup) {
        (result, Ok(())) => result,
        (Ok(()), Err(error)) => Err(error).context(NativeCleanupFailure),
        (Err(primary), Err(error)) => Err(error)
            .context(format!("media attempt also failed: {primary:#}"))
            .context(NativeCleanupFailure),
    }
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
#[allow(clippy::too_many_lines)] // One bounded diagnostic handshake is kept together for audit.
async fn send(o: Options, endpoint: &Endpoint) -> Result<()> {
    send_cpu(o, endpoint).await
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
struct SourcePointerTask {
    allow_buttons: bool,
    native: Option<viewflow_hyprland::window_pointer_socket::Connection>,
    updates: Option<tokio::sync::watch::Sender<crate::window_input_runtime::AuthorizedWindow>>,
    task: Option<tokio::task::JoinHandle<Result<()>>>,
    path: std::path::PathBuf,
    socket_identity: (u64, u64),
    generation: u64,
    expires: u64,
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
impl SourcePointerTask {
    async fn connect(path: &str, pid: u32, timeout: Duration, allow_buttons: bool) -> Result<Self> {
        use std::os::unix::fs::MetadataExt;
        let path = std::path::PathBuf::from(path);
        let listener =
            viewflow_hyprland::window_pointer_socket::Listener::bind(&path, i32::try_from(pid)?)?;
        let metadata = std::fs::symlink_metadata(&path)?;
        let mut owner = Self {
            allow_buttons,
            native: None,
            updates: None,
            task: None,
            path,
            socket_identity: (metadata.dev(), metadata.ino()),
            generation: 0,
            expires: 0,
        };
        let deadline = Instant::now() + timeout;
        loop {
            match listener.accept() {
                Ok(connection) => {
                    owner.native = Some(connection);
                    return Ok(owner);
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error.into()),
            }
            if Instant::now() >= deadline {
                bail!("native pointer plugin connection timed out");
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }

    fn presented(
        &mut self,
        snapshot: &crate::window_input_runtime::CapturedWindowInput,
        tag: FrameIdentity,
        network: &quinn::Connection,
        clock: &Clock,
        policy: PointerForwarding,
    ) -> Result<()> {
        use crate::window_input_runtime::WindowInputSession;
        use viewflow_hyprland::window_pointer_socket::Event;
        if self
            .task
            .as_ref()
            .is_some_and(tokio::task::JoinHandle::is_finished)
        {
            bail!("source pointer route ended");
        }
        let now = clock.now_ns();
        if self.generation == 0 || self.expires.saturating_sub(now) <= 1_000_000_000 {
            self.generation = self
                .generation
                .checked_add(1)
                .context("pointer generation exhausted")?;
            self.expires = now
                .checked_add(5_000_000_000)
                .context("pointer deadline overflow")?;
        }
        let authorization = snapshot.authorize(
            policy.owner,
            policy.source,
            self.generation,
            self.expires,
            viewflow_core::PresentedInputIdentity {
                window: tag.window,
                frame: tag.frame,
                geometry_epoch: tag.epoch,
            },
        )?;
        if let Some(updates) = &self.updates {
            updates
                .send(authorization)
                .context("source pointer authorization owner ended")?;
        } else {
            let mut native = self
                .native
                .take()
                .context("native pointer connection missing")?;
            let address = authorization.native_address;
            // Consume the plugin's startup snapshot before BEGIN's short ACK budget.
            for index in 0..512 {
                match native.receive() {
                    Ok(Event::Metadata(bytes)) => source_pointer_metadata(&bytes, address)?,
                    Ok(Event::CaptureReceipt(_)) => bail!("unsolicited native capture ACK"),
                    Ok(Event::Completed(_)) => bail!("unsolicited native pointer ACK"),
                    Ok(Event::Revoked { generation, reason }) => bail!(
                        "native window already revoked: generation={generation} reason={reason:?}"
                    ),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(error) => return Err(error.into()),
                }
                if index == 511 {
                    bail!("native startup metadata exceeds bounded drain");
                }
            }
            let begin = if self.allow_buttons {
                WindowInputSession::begin_buttons
            } else {
                WindowInputSession::begin
            };
            let session = begin(native, authorization.clone(), clock.0)?;
            let (updates, receiver) = tokio::sync::watch::channel(authorization);
            let network = network.clone();
            self.task = Some(tokio::spawn(async move {
                let result = session
                    .serve_authorizations(&network, receiver, move |bytes| {
                        source_pointer_metadata(&bytes, address)
                    })
                    .await;
                if let Err(error) = &result {
                    eprintln!("source pointer route ended: {error:#}");
                }
                result
            }));
            self.updates = Some(updates);
        }
        Ok(())
    }

    async fn stop(&mut self) -> Result<()> {
        self.updates.take();
        let result = if let Some(task) = &mut self.task {
            // Retain the handle in this owner across await so cancellation of
            // stop still reaches the abort-on-drop fallback.
            retire_input_task(task, Duration::from_millis(250)).await
        } else {
            Ok(())
        };
        self.task.take();
        self.native.take();
        result
    }
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
fn source_pointer_metadata(bytes: &[u8], address: u64) -> Result<()> {
    // Connection already validates VFHY framing and packet sequencing. This
    // diagnostic consumes metadata only for target retirement, not discovery UI.
    if bytes.len() < 20 {
        bail!("short native metadata");
    }
    let tag = u16::from_le_bytes(bytes[6..8].try_into()?);
    if tag == 11 {
        if bytes.len() != 28 {
            bail!("invalid native window removal");
        }
        if u64::from_le_bytes(bytes[20..28].try_into()?) == address {
            bail!("captured native window removed");
        }
    }
    Ok(())
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
impl Drop for SourcePointerTask {
    fn drop(&mut self) {
        use std::os::unix::fs::MetadataExt;
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

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
#[allow(clippy::too_many_lines)] // One bounded diagnostic handshake is kept together for audit.
async fn send_cpu(o: Options, ep: &Endpoint) -> Result<()> {
    use crate::{
        compatible_encoder::{CodecIdentity, CompatibleEncoder, Config},
        hyprcapture_stream::{monotonic_now_ns, session_capture_timestamp},
    };
    let remote = o.remote.context("send requires --remote")?;
    let name = o
        .server_name
        .as_deref()
        .context("send requires --server-name")?;
    let stream_address = o
        .capture_stream
        .as_deref()
        .context("send requires --capture-stream (real authenticated HCSF input)")?;
    let logical = o
        .logical
        .context("send requires --logical-width and --logical-height")?;
    let blur = o.blur.context("send requires --composition-blur-rect")?;
    let radius = o
        .blur_radius
        .context("send requires --composition-blur-radius")?;
    blur.validate(logical)?;
    let pid = o
        .compositor_pid
        .context("--capture-stream requires --compositor-pid")?;
    // Do not create external compositor state until all local identity and
    // QUIC setup validation has succeeded. From this point every exit below
    // explicitly consumes `source` through `stop_stream`.
    // Do not acquire a single-slot GPU frame before QUIC setup.  Handshake
    // latency is unbounded relative to its 500 ms ownership timeout.
    let mut source = None;
    let clock = Clock::new();
    let mut stats = SenderStats::default();
    let mut pointer_input = None;
    let startup_deadline = Instant::now() + o.timeout;
    let (startup_ready, startup_confirmation) = tokio::sync::oneshot::channel();
    let work = async {
        let c = tokio::time::timeout_at(startup_deadline.into(), ep.connect(remote, name)?)
            .await
            .context(MediaConnectTimeout)??;
        let _retiring_connection = RetiringConnection(c.clone());
        if o.authorize_pointer_motion.is_some() {
            pointer_input = Some(
                SourcePointerTask::connect(
                    o.pointer_native_socket
                        .as_deref()
                        .context("native pointer socket missing")?,
                    pid,
                    o.timeout,
                    o.authorize_pointer_buttons,
                )
                .await?,
            );
        }
        eprintln!(
            "coded sender datagram queue: configured_bytes=65536 initial_available_bytes={}",
            c.datagram_send_buffer_space()
        );
        let (mut tx, mut rx) = c.open_bi().await?;
        let estimate = clock_exchange_client(&mut tx, &mut rx, &clock).await?;
        write_record(&mut tx, LOGICAL_GEOMETRY, &logical.encode()).await?;
        write_record(&mut tx, BLUR_RECT, &blur.encode()).await?;
        write_record(&mut tx, BLUR_RADIUS, &radius.to_be_bytes()).await?;
        let encoder_config = Config {
            max_input_bytes: o.max_frame_bytes,
            max_color_access_unit_bytes: o.max_frame_bytes,
            max_alpha_access_unit_bytes: o.max_frame_bytes,
            max_pending_frames: 2,
        };
        // GpuCompatibleEncoder constructs its native context lazily.  Probe
        // and retire a separate source session first so `prepare_size` cannot
        // consume the formal stream's single-slot ownership interval.
        #[cfg(feature = "native-gpu-nvenc")]
        let gpu_crop_size = if o.capture_gpu {
            Some(probe_gpu_crop_size(stream_address, pid).await?)
        } else {
            None
        };
        #[cfg(not(feature = "native-gpu-nvenc"))]
        if o.capture_gpu {
            bail!("--capture-gpu requires --features native-gpu-nvenc")
        }
        let mut encoder = if o.capture_gpu {
            #[cfg(feature = "native-gpu-nvenc")]
            {
                let (width, height) =
                    gpu_crop_size.context("GPU probe did not produce crop size")?;
                let mut encoder =
                    crate::gpu_compatible_encoder::GpuCompatibleEncoder::new(encoder_config)?;
                encoder.prepare_size(width, height)?;
                SenderEncoder::Gpu(Box::new(encoder))
            }
            #[cfg(not(feature = "native-gpu-nvenc"))]
            {
                unreachable!("GPU source rejected before encoder construction")
            }
        } else {
            SenderEncoder::Cpu(Box::new(CompatibleEncoder::new(encoder_config)?))
        };
        // Native encoder cold initialization completes before HCGF allocation.
        // Otherwise it could consume the producer's fixed 500 ms lease.
        let source = source.insert(if o.capture_gpu {
            #[cfg(feature = "native-gpu-nvenc")]
            {
                CaptureSource::Gpu(
                    crate::hyprcapture_runtime::start_gpu_stream(
                        stream_address,
                        60,
                        pid,
                        Duration::from_secs(2),
                    )
                    .await?,
                )
            }
            #[cfg(not(feature = "native-gpu-nvenc"))]
            {
                bail!("--capture-gpu requires --features native-gpu-nvenc")
            }
        } else {
            CaptureSource::Cpu(
                crate::hyprcapture_runtime::start_stream(
                    stream_address,
                    60,
                    o.max_frame_bytes,
                    pid,
                    Duration::from_secs(2),
                )
                .await?,
            )
        });
        let codec_id = CodecIdentity {
            window_id: WINDOW,
            config_generation: 1,
        };
        // Decode-only warmup deliberately happens before READY: it retains the
        // session-mapped true capture timestamp but is never admitted as a
        // presentable/live frame.  Three frames are an explicit opt-in, and
        // the peer confirms that exact count before either side obtains one.
        let warmup_deadline = Instant::now() + o.timeout;
        let warmup_started = Instant::now();
        if o.alpha_reuse_warmup {
            write_startup_record(
                source,
                &mut tx,
                ALPHA_REUSE_PLAN,
                &ALPHA_REUSE_PLAN_PAYLOAD,
                warmup_deadline,
            )
            .await?;
            let plan_ack = read_record_draining(
                &mut *source,
                &mut rx,
                ALPHA_REUSE_PLAN_ACK,
                ALPHA_REUSE_PLAN_PAYLOAD.len(),
                warmup_deadline,
            )
            .await
            .context("receiver alpha reuse plan ACK timed out")?;
            validate_alpha_reuse_plan(o.alpha_reuse_warmup, &plan_ack)
                .context("receiver alpha reuse plan ACK mismatch")?;
        }
        if requires_warmup_plan(o.warmup_frames) {
            write_startup_record(
                source,
                &mut tx,
                WARMUP_PLAN,
                &[o.warmup_frames],
                warmup_deadline,
            )
            .await?;
            let plan_ack =
                read_record_draining(&mut *source, &mut rx, WARMUP_PLAN_ACK, 1, warmup_deadline)
                    .await
                    .context("receiver warmup plan ACK timed out")?;
            validate_warmup_plan(o.warmup_frames, &plan_ack)
                .context("receiver warmup plan ACK mismatch")?;
        }
        let mut warmup_lineage: Option<(u64, u64)> = None;
        let mut first_warmup_geometry = None;
        let mut warmup_descriptors = None;
        let mut alpha_reference = None;
        let mut ordinal = 0_usize;
        while ordinal < usize::from(o.warmup_frames) {
            if Instant::now() >= warmup_deadline {
                bail!("coded startup timed out before warmup capture")
            }
            let Some(capture) = source.recv()? else {
                tokio::time::sleep(Duration::from_millis(1)).await;
                continue;
            };
            #[allow(clippy::float_cmp)]
            let actual_logical = capture.logical_size();
            if actual_logical != (logical.width, logical.height) {
                source.release_unencoded(&capture)?;
                bail!(
                    "warmup logical geometry differs: capture={}x{} requested={}x{}",
                    actual_logical.0,
                    actual_logical.1,
                    logical.width,
                    logical.height,
                )
            }
            // Use the same session-clock mapping as every later live header.
            // It preserves the true capture instant; it does not restamp it
            // fresh. The raw monotonic capture value is still used only by
            // the READY queue-floor check after warmup.
            let source_ns = session_capture_timestamp(
                capture.capture_ns(),
                monotonic_now_ns()?,
                clock.now_ns(),
            )?;
            // GPU submit receives the mapped value only for transport metadata;
            // its DMA-BUF native encode retains the original capture timestamp.
            let frames = encoder.submit(
                codec_id,
                &capture,
                source_ns,
                i64::try_from(capture.capture_ns().saturating_add(2_000_000_000))?,
            )?;
            source.release_encoded(&capture)?;
            if frames.len() != 1 {
                bail!("warmup capture must produce exactly one encoded frame")
            }
            let frame = frames.into_iter().next().expect("checked exact length");
            // Preserve the legacy one-frame startup selection exactly: before
            // descriptors exist it may wait for the encoder's natural first
            // keyframe.  The explicit three-frame contract never discards an
            // encoded reference and instead rejects a broken chain.
            if ordinal == 0
                && !requires_warmup_plan(o.warmup_frames)
                && !frame.color_metadata.keyframe
            {
                continue;
            }
            let lineage = (
                frame.color.geometry_epoch,
                frame.color_metadata.config_generation,
            );
            warmup_lineage = validate_warmup_reference(
                ordinal,
                frame.color_metadata.keyframe,
                lineage,
                warmup_lineage,
            )?;
            let current_descriptors = encoder
                .descriptors()
                .context("encoder did not establish warmup descriptors")?;
            if let Some(expected) = warmup_descriptors {
                if current_descriptors != expected {
                    bail!("warmup descriptor dimensions/config changed within reference chain")
                }
            } else {
                let mut d = Vec::with_capacity(CODEC_DESCRIPTOR_BYTES * 2);
                d.extend_from_slice(&current_descriptors.color.encode()?);
                d.extend_from_slice(&current_descriptors.alpha.encode()?);
                write_startup_record(source, &mut tx, DESCRIPTORS, &d, warmup_deadline).await?;
                first_warmup_geometry = Some(frame.color.geometry_epoch);
                warmup_descriptors = Some(current_descriptors);
            }
            let descriptors = warmup_descriptors.expect("first warmup sets descriptors");
            let warmup_tag = FrameIdentity {
                window: WINDOW,
                frame: frame.color.frame_id,
                epoch: frame.color.geometry_epoch,
                config: frame.color_metadata.config_generation,
            };
            let color_len = u32::try_from(frame.color.payload.len())?;
            let alpha_len = u32::try_from(frame.alpha.payload.len())?;
            if ordinal == 0 {
                let alpha_profile = viewflow_transport::profile_alpha_rle(
                    frame.alpha.payload.clone(),
                    viewflow_transport::AlphaRleLimits {
                        max_coded_width: descriptors.alpha.coded_width,
                        max_coded_height: descriptors.alpha.coded_height,
                        max_luma_samples: u64::from(descriptors.alpha.coded_width)
                            * u64::from(descriptors.alpha.coded_height),
                        max_decoded_bytes: u64::try_from(o.max_frame_bytes)?,
                        max_encoded_bytes: o.max_frame_bytes,
                    },
                )?;
                eprintln!(
                    "warmup VFAR profile: mode={:?} decoded_bytes={} encoded_bytes={} savings_bytes={}",
                    alpha_profile.mode,
                    alpha_profile.decoded_bytes,
                    alpha_profile.encoded_bytes,
                    alpha_profile.savings_bytes,
                );
                if let Some(path) = o.warmup_alpha_output.as_deref() {
                    write_warmup_alpha_sample(path, &frame.alpha.payload)?;
                }
            }
            let mut warmup_meta = Vec::with_capacity(WARMUP_META_BYTES);
            warmup_meta.extend_from_slice(&warmup_tag.encode());
            warmup_meta.extend_from_slice(&frame.color_metadata.encode()?);
            warmup_meta.extend_from_slice(&frame.alpha_metadata.encode()?);
            warmup_meta.extend_from_slice(&frame.color.source_submitted_ns.to_be_bytes());
            warmup_meta.extend_from_slice(&color_len.to_be_bytes());
            warmup_meta.extend_from_slice(&alpha_len.to_be_bytes());
            write_startup_record(source, &mut tx, WARMUP_META, &warmup_meta, warmup_deadline)
                .await?;
            write_warmup_blob(
                source,
                &mut tx,
                WARMUP_COLOR,
                &frame.color.payload,
                warmup_deadline,
            )
            .await?;
            write_warmup_blob(
                source,
                &mut tx,
                WARMUP_ALPHA,
                &frame.alpha.payload,
                warmup_deadline,
            )
            .await?;
            let warmup_ack_deadline = warmup_deadline.min(Instant::now() + Duration::from_secs(5));
            let warmup_ack =
                read_record_draining(&mut *source, &mut rx, WARMUP_ACK, 40, warmup_ack_deadline)
                    .await
                    .context("receiver warmup ACK timed out")?;
            validate_warmup_ack(warmup_tag, &warmup_ack)?;
            // The one connection-scoped baseline is installed only after the
            // final exact decode-only ACK. Earlier warmup frames are decoder
            // references, never alpha cache candidates.
            if o.alpha_reuse_warmup && ordinal + 1 == usize::from(o.warmup_frames) {
                alpha_reference = Some(AlphaReferenceCache::new(
                    warmup_tag.encode(),
                    descriptors.alpha.coded_width,
                    descriptors.alpha.coded_height,
                    frame.alpha.payload.clone(),
                    o.max_frame_bytes,
                )?);
            }
            eprintln!(
                "decode-only warmup acknowledged frame_identity={} ordinal={} elapsed_ms={}",
                warmup_tag.frame,
                ordinal + 1,
                warmup_started.elapsed().as_millis()
            );
            ordinal += 1;
        }
        let descriptors = warmup_descriptors.expect("configured warmup count is nonzero");
        let first_warmup_geometry =
            first_warmup_geometry.expect("configured warmup count is nonzero");
        // The exact decode-only ACK proves the persistent decoder has this
        // reference picture. Keep the encoder chain: a newly captured P-frame
        // can reference it without ever presenting the warmup itself. No AU
        // is encoded while waiting for ACK/READY (captures are only drained).
        read_record_draining(&mut *source, &mut rx, READY, 0, warmup_deadline)
            .await
            .context("receiver READY timed out")?;
        let ready_capture_floor = monotonic_now_ns()?;
        let _ = startup_ready.send(Instant::now());
        let mut active_geometry: Option<(u64, u32, u32)> = Some((
            first_warmup_geometry,
            descriptors.color.coded_width,
            descriptors.color.coded_height,
        ));
        // READY's capture floor and the unchanged source-age admission still
        // apply. Any subsequently discarded encoded reference forces an IDR
        // through the recovery paths below; warmup does not bypass recovery.
        let mut awaiting_idr = false;
        let mut idr_floor = None;
        let deadline = MediaLifetime::live(o.persistent, Instant::now() + o.timeout, o.timeout);
        let mut submitted_frames = 0_u64;
        let mut input_snapshots = BTreeMap::new();
        'session: while deadline.active(Instant::now()) {
            let capture_wait_deadline = Instant::now() + o.timeout;
            let capture = loop {
                if let Some(reason) = c.close_reason() {
                    return Err(reason.into());
                }
                if o.persistent && Instant::now() >= capture_wait_deadline {
                    bail!("persistent media capture stalled");
                }
                if let Some(frame) = source.recv()? {
                    stats.capture_received = stats.capture_received.saturating_add(1);
                    if frame.capture_ns() <= ready_capture_floor {
                        // `recv_latest` may still expose a queued capture
                        // from before READY. It cannot become live media.
                        source.release_unencoded(&frame)?;
                        continue;
                    }
                    break frame;
                }
                if !deadline.active(Instant::now()) {
                    break 'session;
                }
                tokio::time::sleep(Duration::from_millis(1)).await;
            };
            // HCSF geometry is authenticated exact lineage; tolerance would silently scale.
            #[allow(clippy::float_cmp)]
            if capture.logical_size() != (logical.width, logical.height) {
                source.release_unencoded(&capture)?;
                bail!(
                    "resize is explicitly unsupported by coded diagnostic; restart with matching logical geometry"
                )
            }
            let geometry = capture.geometry();
            if let Some(active) = active_geometry {
                if active != geometry {
                    bail!(
                        "resize/geometry epoch change is explicitly unsupported by coded diagnostic"
                    )
                }
            } else {
                active_geometry = Some(geometry);
            }
            let sample_mono = monotonic_now_ns()?;
            let source_ns =
                session_capture_timestamp(capture.capture_ns(), sample_mono, clock.now_ns())?;
            // An unencoded capture has no decoder reference effect; discard it
            // rather than wasting the only 33.333 ms diagnostic budget.
            if clock.now_ns().saturating_sub(source_ns) > DEADLINE_NS {
                stats.pre_encode_stale = stats.pre_encode_stale.saturating_add(1);
                source.release_unencoded(&capture)?;
                continue;
            }
            let was_awaiting_idr = awaiting_idr;
            if pointer_input.is_some() {
                let snapshot = capture
                    .input_snapshot()
                    .context("pointer authorization requires GPU input binding")?;
                if input_snapshots.len() >= 4
                    || input_snapshots
                        .insert(snapshot.sequence(), snapshot)
                        .is_some()
                {
                    bail!("captured input lineage overflow or duplicate");
                }
            }
            let encode_started = Instant::now();
            let outcome = encoder.submit_live(
                codec_id,
                &capture,
                source_ns,
                i64::try_from(capture.capture_ns().saturating_add(DEADLINE_NS))?,
            )?;
            // A successful native submit has consumed DMA-BUF/fence reads.
            // On submit error we deliberately return before this ACK.
            source.release_encoded(&capture)?;
            stats.observe_encode(encode_started.elapsed());
            let Some(frames) = outcome else {
                if pointer_input.is_some() {
                    input_snapshots
                        .remove(&capture.sequence())
                        .context("expired encode lost captured input lineage")?;
                }
                stats.clean_encode_expired = stats.clean_encode_expired.saturating_add(1);
                // No NVENC submission: preserve reference/IDR recovery state.
                continue;
            };
            if was_awaiting_idr && idr_floor.is_none() {
                idr_floor = Some(capture.sequence());
            }
            for frame in frames {
                let input_snapshot = if pointer_input.is_some() {
                    Some(
                        input_snapshots
                            .remove(&frame.color.frame_id)
                            .context("encoded output lost captured input lineage")?,
                    )
                } else {
                    None
                };
                if !sendable_after_recovery(
                    awaiting_idr,
                    idr_floor,
                    frame.color.frame_id,
                    frame.color_metadata.keyframe,
                ) {
                    stats.idr_wait_dropped = stats.idr_wait_dropped.saturating_add(1);
                    continue;
                }
                if clock
                    .now_ns()
                    .saturating_sub(frame.color.source_submitted_ns)
                    > DEADLINE_NS
                {
                    // This AU may be a reference picture. Stop sending the
                    // chain and make a later native output prove a fresh IDR.
                    awaiting_idr = true;
                    idr_floor = None;
                    encoder.request_keyframe();
                    stats.post_encode_stale = stats.post_encode_stale.saturating_add(1);
                    continue;
                }
                if awaiting_idr {
                    awaiting_idr = false;
                    idr_floor = None;
                }
                let tag = FrameIdentity {
                    window: WINDOW,
                    frame: frame.color.frame_id,
                    epoch: frame.color.geometry_epoch,
                    config: frame.color_metadata.config_generation,
                };
                let mut meta = Vec::with_capacity(FRAME_META_BYTES);
                meta.extend_from_slice(&tag.encode());
                meta.extend_from_slice(&frame.color_metadata.encode()?);
                meta.extend_from_slice(&frame.alpha_metadata.encode()?);
                let dispatch_started = Instant::now();
                let color_payload_bytes = frame.color.payload.len();
                let alpha_reference_key = alpha_reference.as_ref().and_then(|cache| {
                    cache.reference_for(
                        tag.encode(),
                        descriptors.alpha.coded_width,
                        descriptors.alpha.coded_height,
                        &frame.alpha.payload,
                    )
                });
                let alpha_payload_bytes = if alpha_reference_key.is_some() {
                    0
                } else {
                    frame.alpha.payload.len()
                };
                let alpha_reused_bytes = if alpha_reference_key.is_some() {
                    frame.alpha.payload.len()
                } else {
                    0
                };
                let source_submitted_ns = frame.color.source_submitted_ns;
                let frame_dispatch_deadline = Instant::now()
                    .checked_add(
                        remaining_capture_dispatch_budget(source_submitted_ns, clock.now_ns())
                            .context("coded frame expired before metadata dispatch")?,
                    )
                    .context("coded frame dispatch deadline overflow")?;
                // Metadata is an admission-slot commitment; fail closed if
                // all bytes cannot leave before this frame's original capture
                // deadline.  Never refresh the budget from wall clock now.
                let (meta_kind, meta_payload) = if let Some(reference) = alpha_reference_key {
                    let mut combined = Vec::with_capacity(FRAME_META_BYTES + ALPHA_REFERENCE_BYTES);
                    combined.extend_from_slice(&meta);
                    combined.extend_from_slice(&reference);
                    (FRAME_META_ALPHA_REFERENCE, combined)
                } else {
                    (FRAME_META, meta)
                };
                poll_with_drain(
                    write_record(&mut tx, meta_kind, &meta_payload),
                    frame_dispatch_deadline,
                    "coded frame metadata write exceeded capture deadline",
                    || drain_unencoded_capture(source),
                )
                .await?;
                let source_age_ns = clock.now_ns().saturating_sub(source_submitted_ns);
                let mut datagram_too_large = false;
                let mut expired_dispatch = false;
                'planes: for plane in [
                    Some(frame.color),
                    alpha_reference_key.is_none().then_some(frame.alpha),
                ]
                .into_iter()
                .flatten()
                {
                    // Quinn documents this as a live path-MTU/peer-limit
                    // value. Fix it for this one plane: re-fragmenting after
                    // any packet has left would conflict with chunk_count.
                    let plane_datagram_budget = c
                        .max_datagram_size()
                        .context("QUIC datagrams unavailable")?;
                    for (index, packet) in plane.fragment(plane_datagram_budget)?.enumerate() {
                        // One send future is bounded by this frame's original
                        // mapped capture deadline; it is never recalculated
                        // per fragment or refreshed from wall-clock now.
                        match await_dispatch_until(
                            c.send_datagram_wait(packet.encode()),
                            frame_dispatch_deadline,
                        )
                        .await
                        {
                            Some(Ok(())) => {}
                            Some(Err(error)) if discard_incomplete_frame(&error) => {
                                datagram_too_large = true;
                                break 'planes;
                            }
                            Some(Err(error)) => return Err(error.into()),
                            None => {
                                expired_dispatch = true;
                                break 'planes;
                            }
                        }
                        // Let Quinn batch a small burst instead of forcing an
                        // executor round trip for every ~1 KiB fragment. The
                        // bounded burst still gives its driver regular turns;
                        // send_datagram_wait also yields under backpressure.
                        if (index + 1) % 16 == 0 {
                            tokio::task::yield_now().await;
                        }
                    }
                }
                if complete_datagram_dispatch(datagram_too_large, expired_dispatch) {
                    stats.sent = stats.sent.saturating_add(1);
                    stats.observe_send(
                        color_payload_bytes,
                        alpha_payload_bytes,
                        alpha_reused_bytes,
                        source_age_ns,
                        dispatch_started.elapsed(),
                    );
                } else if datagram_too_large {
                    // The receiver has the VFCF tag but cannot complete this
                    // pair. Its exact REJECT below drives IDR recovery; do
                    // not resend this frame with a different chunk layout.
                    stats.datagram_too_large_dropped =
                        stats.datagram_too_large_dropped.saturating_add(1);
                } else if expired_dispatch {
                    // Metadata was committed but only a prefix could leave.
                    // Wait for the exact REJECT below; an ACK would be a
                    // protocol violation because this pair is incomplete.
                    stats.expired_dispatch = stats.expired_dispatch.saturating_add(1);
                }
                // A late exact REJECT still proves this frame was never
                // submitted. Its bounded control wait is not an extension of
                // the ACK's source-time admission checked below.
                let control_budget = control_response_budget(deadline)
                    .context("coded sender session ended before control response")?;
                let (kind, payload) =
                    read_any_record_draining(source, &mut rx, Instant::now() + control_budget)
                        .await
                        .context("receiver control response failed")?
                        .context("receiver control stream ended before response")?;
                let frame_control =
                    admit_frame_control(kind, &payload, tag, source_submitted_ns, clock.now_ns())?;
                let quic_stats = c.stats();
                eprintln!(
                    "coded QUIC frame={} dispatch_and_control_us={} path_rtt_ns={} cwnd={} lost_packets={} congestion_events={}",
                    tag.frame,
                    dispatch_started.elapsed().as_micros(),
                    quic_stats.path.rtt.as_nanos(),
                    quic_stats.path.cwnd,
                    quic_stats.path.lost_packets,
                    quic_stats.path.congestion_events,
                );
                match frame_control {
                    FrameControl::Reject => {
                        // `REJECT` is reserved for pre-presentation late/loss
                        // recovery. Never transmit a P-chain after it: wait
                        // for a real native IDR tied to a later input frame.
                        awaiting_idr = true;
                        idr_floor = None;
                        encoder.request_keyframe();
                        stats.recoverable_rejected = stats.recoverable_rejected.saturating_add(1);
                        continue;
                    }
                    FrameControl::Ack if datagram_too_large || expired_dispatch => {
                        bail!("receiver ACKed a frame whose datagram send was incomplete")
                    }
                    FrameControl::Ack => {}
                }
                if let (Some(input), Some(snapshot), Some(policy)) = (
                    &mut pointer_input,
                    input_snapshot,
                    o.authorize_pointer_motion,
                ) {
                    input.presented(&snapshot, tag, &c, &clock, policy)?;
                }
                let _ = estimate;
                submitted_frames = submitted_frames.saturating_add(1);
                stats.acknowledged = stats.acknowledged.saturating_add(1);
            }
        }
        if submitted_frames == 0 {
            bail!("coded diagnostic ended without a fresh presenter submission")
        }
        Ok::<_, anyhow::Error>(())
    };
    let result = if o.persistent {
        run_after_bounded_startup(work, startup_confirmation, startup_deadline).await
    } else {
        tokio::time::timeout(o.timeout.saturating_add(Duration::from_secs(2)), work)
            .await
            .context("coded sender timed out")
            .and_then(|result| result)
    };
    stats.print();
    let input_result = if let Some(input) = &mut pointer_input {
        input.stop().await
    } else {
        Ok(())
    };
    let stop = match source {
        Some(source) => source.stop().await,
        None => Ok(()),
    };
    finish_native_attempt(finish_input_attempt(result, input_result), stop)
}
#[cfg(not(all(target_os = "linux", feature = "native-nvenc")))]
async fn send(_o: Options, _ep: &Endpoint) -> Result<()> {
    bail!("coded send requires Linux build with --features native-nvenc")
}

#[cfg(windows)]
use std::{
    collections::VecDeque,
    fs::File,
    io::{BufRead, BufReader, Write},
    os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle},
    process::{Child, Command, Stdio},
    sync::Arc,
    thread::{self, JoinHandle},
};
#[cfg(windows)]
use tokio::sync::oneshot;
#[cfg(all(windows, test))]
use windows_sys::Win32::Foundation::GetHandleInformation;
#[cfg(windows)]
use windows_sys::Win32::{
    Foundation::{HANDLE, HANDLE_FLAG_INHERIT, SetHandleInformation},
    Security::SECURITY_ATTRIBUTES,
    System::Pipes::CreatePipe,
};

#[cfg(windows)]
struct QueuedPresenterFrame {
    tag: FrameIdentity,
    source_submitted_ns: u64,
    record: Vec<u8>,
    decode_only: bool,
    recover_expired_v4: bool,
    completion: oneshot::Sender<std::result::Result<NativeCompletion, String>>,
}

#[cfg(windows)]
struct PresenterState {
    latest: Mutex<Option<QueuedPresenterFrame>>,
    ready: Condvar,
    startup_ready: Mutex<bool>,
    startup_changed: Condvar,
    acknowledgement: Mutex<Option<NativeCompletion>>,
    acknowledgement_changed: Condvar,
    acknowledgement_read_ns: AtomicU64,
    acknowledgement_published_ns: AtomicU64,
    pointer_motion: Mutex<PointerMotionState>,
    pointer_motion_diagnostics: AtomicU8,
    failed: Mutex<Option<String>>,
    closed: AtomicBool,
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeCompletion {
    Presented(u64),
    DecodeOnly(u64),
    Expired(u64),
}

/// A pixel coordinate reported by the native preview after a Submitted frame.
/// It is not a remotely authorized input event and is never injected here.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct PresenterPointerMotion {
    frame_identity: u64,
    x_pixels: u32,
    y_pixels: u32,
    viewport_width: u32,
    viewport_height: u32,
    not_after_qpc: u64,
    qpc_frequency: u64,
}

#[cfg(any(windows, test))]
#[derive(Debug, Default)]
struct PointerMotionState {
    // Only a native Presented completion establishes this context. Expired
    // never replaces the currently visible frame; a new Presented atomically
    // discards any pointer motion from the older frame.
    latest_presented: Option<u64>,
    latest_motion: Option<(PresenterPointerMotion, u64)>,
    published_presented: Option<FrameIdentity>,
    published_history: std::collections::VecDeque<FrameIdentity>,
    sample_sequence: u64,
    samples: Option<tokio::sync::watch::Sender<crate::window_preview_input::PreviewPointerState>>,
    events: Option<crate::window_preview_input::PreviewPointerEvents>,
    pending_events: Vec<(
        PresenterPointerMotion,
        u64,
        Option<viewflow_protocol::PointerButtonEvent>,
    )>,
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PresenterOutput {
    Completion(NativeCompletion),
    PointerMotion(PresenterPointerMotion),
    PointerButton(
        PresenterPointerMotion,
        viewflow_protocol::PointerButtonEvent,
    ),
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ExpectedNativeCompletion {
    Presented(u64),
    DecodeOnly(u64),
    PresentedOrExpired(u64),
}

#[cfg(windows)]
impl PresenterState {
    fn fail(&self, error: impl Into<String>) {
        let mut failed = self.failed.lock().expect("presenter failure lock");
        let first_failure = if failed.is_none() {
            let error = error.into();
            *failed = Some(error.clone());
            Some(error)
        } else {
            None
        };
        drop(failed);
        close_presenter_pointer_samples(&self.pointer_motion);
        // `ready.wait` checks `closed` while holding `latest`; set the
        // predicate under that same mutex so a shutdown cannot notify between
        // the check and Condvar wait. The ACK waiter has the same invariant.
        let latest = self.latest.lock().expect("presenter queue lock");
        self.closed.store(true, Ordering::Release);
        self.ready.notify_all();
        drop(latest);
        let acknowledgement = self.acknowledgement.lock().expect("presenter ACK lock");
        self.acknowledgement_changed.notify_all();
        drop(acknowledgement);
        let startup = self.startup_ready.lock().expect("presenter startup lock");
        self.startup_changed.notify_all();
        drop(startup);
        // Only after closing the input owners and waking waiters: logging must
        // not defer cleanup. The generic waiter-close error is not the cause.
        if let Some(error) = first_failure {
            eprintln!("compressed presenter first failure: {error}");
        }
    }
}

#[cfg(windows)]
struct CompressedPresenter {
    state: Arc<PresenterState>,
    child: Arc<Mutex<Child>>,
    writer: Option<JoinHandle<()>>,
    stdout: Option<JoinHandle<()>>,
    stderr: Option<JoinHandle<()>>,
    completions: Mutex<VecDeque<oneshot::Receiver<std::result::Result<NativeCompletion, String>>>>,
    recover_expired_v4: bool,
    pointer_samples: tokio::sync::watch::Receiver<crate::window_preview_input::PreviewPointerState>,
    pointer_events: Mutex<Option<crate::window_preview_input::PreviewPointerEventReceiver>>,
    retirement: Option<std::result::Result<(), String>>,
}

#[cfg(windows)]
const MAX_PRESENTER_PIPE_BYTES: usize = 1024 * 1024;

/// `Stdio::piped` does not expose an anonymous-pipe buffer size. Create the
/// VFGP input explicitly so the child owns only the inheritable read end and
/// the parent retains the non-inheritable writer. Dropping that writer still
/// delivers EOF when the presenter is torn down.
#[cfg(windows)]
pub(crate) fn presenter_stdin_pipe(max_frame_bytes: usize) -> Result<(Stdio, File)> {
    let (read, write) = create_presenter_pipe(max_frame_bytes)?;
    Ok((Stdio::from(read), write))
}

#[cfg(windows)]
fn presenter_pipe_buffer_bytes(max_frame_bytes: usize) -> u32 {
    u32::try_from(max_frame_bytes.min(MAX_PRESENTER_PIPE_BYTES).max(1))
        .expect("one MiB fits in u32")
}

#[cfg(windows)]
#[allow(unsafe_code)] // Audited Win32 handle construction; every handle has RAII ownership.
fn create_presenter_pipe(max_frame_bytes: usize) -> Result<(File, File)> {
    let requested = presenter_pipe_buffer_bytes(max_frame_bytes);
    let attributes = SECURITY_ATTRIBUTES {
        nLength: u32::try_from(std::mem::size_of::<SECURITY_ATTRIBUTES>())
            .expect("SECURITY_ATTRIBUTES size fits u32"),
        lpSecurityDescriptor: std::ptr::null_mut(),
        bInheritHandle: 1,
    };
    let mut read: HANDLE = std::ptr::null_mut();
    let mut write: HANDLE = std::ptr::null_mut();
    // SAFETY: both output slots and the SECURITY_ATTRIBUTES value are valid
    // for this synchronous Win32 call. Ownership moves into OwnedHandle only
    // after CreatePipe reports success.
    if unsafe { CreatePipe(&mut read, &mut write, &attributes, requested) } == 0 {
        return Err(std::io::Error::last_os_error()).context("CreatePipe for VFGP stdin");
    }
    // SAFETY: successful CreatePipe returned distinct owned handles.
    let read = unsafe { OwnedHandle::from_raw_handle(read) };
    // SAFETY: successful CreatePipe returned distinct owned handles.
    let write = unsafe { OwnedHandle::from_raw_handle(write) };
    // SAFETY: `write` is a valid pipe handle. The child must not inherit this
    // end, otherwise its own copy would suppress EOF on parent shutdown.
    if unsafe { SetHandleInformation(write.as_raw_handle(), HANDLE_FLAG_INHERIT, 0) } == 0 {
        return Err(std::io::Error::last_os_error())
            .context("make VFGP stdin writer non-inheritable");
    }
    Ok((File::from(read), File::from(write)))
}

#[cfg(windows)]
impl CompressedPresenter {
    #[allow(clippy::too_many_arguments)] // Explicit diagnostic startup options.
    fn spawn(
        path: &str,
        logical: LogicalSize,
        blur: BlurRect,
        radius: f64,
        max_frame_bytes: usize,
        clock: Clock,
        estimate: ClockEstimate,
        require_deadline_v4: bool,
        recover_expired_v4: bool,
        emit_pointer_motion: bool,
        forward_pointer_buttons: bool,
        warmup_frames: u8,
    ) -> Result<Self> {
        let logical_width = logical.width.to_string();
        let logical_height = logical.height.to_string();
        let blur_rect = format!("{},{},{},{}", blur.x, blur.y, blur.width, blur.height);
        let blur_radius = radius.to_string();
        let (child_stdin, stdin) = presenter_stdin_pipe(max_frame_bytes)?;
        let max_frame_bytes = max_frame_bytes.to_string();
        let mut child = Command::new(path)
            .args([
                "--stdin-compressed",
                "--logical-width",
                &logical_width,
                "--logical-height",
                &logical_height,
                "--blur-rect",
                &blur_rect,
                "--radius",
                &blur_radius,
                "--max-frame-bytes",
                &max_frame_bytes,
            ])
            .args(if require_deadline_v4 {
                vec!["--require-deadline-v4"]
            } else {
                vec![]
            })
            .args(if recover_expired_v4 {
                vec!["--recover-expired-v4"]
            } else {
                vec![]
            })
            .args(if emit_pointer_motion {
                vec!["--emit-pointer-motion"]
            } else {
                vec![]
            })
            .args(if requires_warmup_plan(warmup_frames) {
                vec!["--warmup-frames", "3"]
            } else {
                vec![]
            })
            .args(if forward_pointer_buttons {
                vec!["--emit-pointer-buttons"]
            } else {
                vec![]
            })
            .stdin(child_stdin)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("start compressed presenter {path}"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| failed_presenter_start(&mut child, "presenter stdout unavailable"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| failed_presenter_start(&mut child, "presenter stderr unavailable"))?;
        let child = Arc::new(Mutex::new(child));
        let (pointer_samples_tx, pointer_samples) = tokio::sync::watch::channel(
            crate::window_preview_input::PreviewPointerState::default(),
        );
        let (events, pointer_events) = if forward_pointer_buttons {
            let (tx, rx) = crate::window_preview_input::PreviewPointerEvents::channel();
            (Some(tx), Some(rx))
        } else {
            (None, None)
        };
        let state = Arc::new(PresenterState {
            latest: Mutex::new(None),
            ready: Condvar::new(),
            startup_ready: Mutex::new(false),
            startup_changed: Condvar::new(),
            acknowledgement: Mutex::new(None),
            acknowledgement_changed: Condvar::new(),
            acknowledgement_read_ns: AtomicU64::new(0),
            acknowledgement_published_ns: AtomicU64::new(0),
            pointer_motion: Mutex::new(PointerMotionState {
                samples: emit_pointer_motion.then_some(pointer_samples_tx),
                events,
                ..PointerMotionState::default()
            }),
            pointer_motion_diagnostics: AtomicU8::new(0),
            failed: Mutex::new(None),
            closed: AtomicBool::new(false),
        });
        let pointer_clock = clock.clone();
        let writer = Some(compressed_presenter_writer(
            state.clone(),
            child.clone(),
            stdin,
            clock,
            estimate,
        ));
        let reader_state = state.clone();
        let stdout = Some(thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let line_read_ns = pointer_clock.now_ns();
                match line {
                    Ok(line) if line.starts_with("composition preview ready;") => {
                        *reader_state
                            .startup_ready
                            .lock()
                            .expect("presenter startup lock") = true;
                        reader_state.startup_changed.notify_all();
                        eprintln!("compressed presenter: {line}");
                    }
                    Ok(line) => match parse_presenter_output(&line) {
                        Ok(Some(PresenterOutput::Completion(completion))) => {
                            reader_state
                                .acknowledgement_read_ns
                                .store(line_read_ns, Ordering::Release);
                            record_presenter_completion(&reader_state.pointer_motion, completion);
                            let mut acknowledgement = reader_state
                                .acknowledgement
                                .lock()
                                .expect("presenter ACK lock");
                            *acknowledgement = Some(completion);
                            reader_state
                                .acknowledgement_published_ns
                                .store(pointer_clock.now_ns(), Ordering::Release);
                            reader_state.acknowledgement_changed.notify_all();
                        }
                        Ok(Some(
                            output @ (PresenterOutput::PointerMotion(_)
                            | PresenterOutput::PointerButton(_, _)),
                        )) => {
                            let (motion, button) = match output {
                                PresenterOutput::PointerMotion(motion) => (motion, None),
                                PresenterOutput::PointerButton(motion, button) => {
                                    (motion, Some(button))
                                }
                                _ => unreachable!(),
                            };
                            if button.is_some() && !forward_pointer_buttons {
                                reader_state.fail("unexpected disabled pointer button".to_owned());
                                return;
                            }
                            if !emit_pointer_motion {
                                reader_state.fail("unexpected disabled pointer motion".to_owned());
                                return;
                            }
                            // Process time first, QPC second: sampling latency
                            // can only shrink the original native event budget.
                            let local_now = pointer_clock.now_ns();
                            let (ticks, frequency) = match native_qpc_sample() {
                                Ok(sample) => sample,
                                Err(error) => {
                                    reader_state.fail(error.to_string());
                                    return;
                                }
                            };
                            let deadline = match presenter_pointer_deadline(
                                motion, local_now, ticks, frequency,
                            ) {
                                Ok(Some(deadline)) => deadline,
                                Ok(None) => {
                                    if button.is_some() {
                                        reader_state.fail(
                                            "native button deadline expired in stdout".to_owned(),
                                        );
                                        return;
                                    }
                                    continue;
                                }
                                Err(error) => {
                                    reader_state.fail(error);
                                    return;
                                }
                            };
                            if let Err(error) = record_presenter_pointer_event(
                                emit_pointer_motion,
                                &reader_state.pointer_motion,
                                motion,
                                deadline,
                                button,
                            ) {
                                reader_state.fail(error);
                                return;
                            }
                            if take_pointer_motion_diagnostic_slot(
                                &reader_state.pointer_motion_diagnostics,
                            ) {
                                eprintln!(
                                    "compressed presenter pointer-motion frame_identity={} x_pixels={} y_pixels={} viewport_width={} viewport_height={}",
                                    motion.frame_identity,
                                    motion.x_pixels,
                                    motion.y_pixels,
                                    motion.viewport_width,
                                    motion.viewport_height,
                                );
                            }
                        }
                        Ok(None) => eprintln!("compressed presenter: {line}"), // startup/diagnostic line; never an ACK.
                        Err(error) => {
                            reader_state.fail(error);
                            return;
                        }
                    },
                    Err(error) => {
                        reader_state.fail(format!("read compressed presenter stdout: {error}"));
                        return;
                    }
                }
            }
            if !reader_state.closed.load(Ordering::Acquire) {
                reader_state.fail("compressed presenter stdout reached EOF");
            }
        }));
        let stderr_state = state.clone();
        let stderr = Some(thread::spawn(move || {
            for line in BufReader::new(stderr).lines() {
                match line {
                    Ok(line) => eprintln!("compressed presenter stderr: {line}"),
                    Err(error) => {
                        stderr_state.fail(format!("read compressed presenter stderr: {error}"));
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
            recover_expired_v4,
            pointer_samples,
            pointer_events: Mutex::new(pointer_events),
            retirement: None,
        })
    }

    fn queue(&self, tag: FrameIdentity, source_submitted_ns: u64, record: Vec<u8>) -> Result<()> {
        self.queue_inner(
            tag,
            source_submitted_ns,
            record,
            false,
            self.recover_expired_v4,
        )
    }

    fn queue_decode_only(&self, tag: FrameIdentity, record: Vec<u8>) -> Result<()> {
        self.queue_inner(tag, 0, record, true, false)
    }

    fn queue_inner(
        &self,
        tag: FrameIdentity,
        source_submitted_ns: u64,
        record: Vec<u8>,
        decode_only: bool,
        recover_expired_v4: bool,
    ) -> Result<()> {
        let mut latest = self.state.latest.lock().expect("presenter queue lock");
        if latest.is_some() || self.state.closed.load(Ordering::Acquire) {
            bail!("compressed presenter is busy or closed")
        }
        let (completion, receiver) = oneshot::channel();
        *latest = Some(QueuedPresenterFrame {
            tag,
            source_submitted_ns,
            record,
            decode_only,
            recover_expired_v4,
            completion,
        });
        self.completions
            .lock()
            .expect("presenter completion lock")
            .push_back(receiver);
        self.state.ready.notify_one();
        Ok(())
    }

    async fn wait_for_submission(&self) -> Result<NativeCompletion> {
        let completion = self
            .completions
            .lock()
            .expect("presenter completion lock")
            .pop_front()
            .context("presenter completion missing")?;
        let wait = if self.recover_expired_v4 {
            PRESENTER_ACK_WAIT + EXPIRED_DISPOSITION_GRACE
        } else {
            PRESENTER_ACK_WAIT
        };
        match tokio::time::timeout(wait, completion).await {
            Ok(Ok(Ok(completion))) => Ok(completion),
            Ok(Ok(Err(error))) => bail!("compressed presenter failed: {error}"),
            Ok(Err(_)) => bail!("compressed presenter worker stopped"),
            Err(_) => bail!("compressed presenter ACK timed out"),
        }
    }

    async fn wait_for_decode_only(&self) -> Result<()> {
        let completion = self
            .completions
            .lock()
            .expect("presenter completion lock")
            .pop_front()
            .context("warmup completion missing")?;
        match tokio::time::timeout(PRESENTER_COLD_START_WAIT, completion).await {
            Ok(Ok(Ok(NativeCompletion::DecodeOnly(_)))) => Ok(()),
            Ok(Ok(Ok(other))) => bail!("compressed warmup returned {other:?}"),
            Ok(Ok(Err(error))) => bail!("compressed warmup failed: {error}"),
            Ok(Err(_)) => bail!("compressed warmup worker stopped"),
            Err(_) => bail!("compressed warmup completion timed out"),
        }
    }

    async fn wait_until_ready(&self) -> Result<()> {
        let state = self.state.clone();
        tokio::task::spawn_blocking(move || {
            let startup = state.startup_ready.lock().expect("presenter startup lock");
            let (startup, timed) = state
                .startup_changed
                .wait_timeout_while(startup, PRESENTER_COLD_START_WAIT, |ready| {
                    !*ready && !state.closed.load(Ordering::Acquire)
                })
                .expect("presenter startup wait");
            if *startup {
                Ok(())
            } else if timed.timed_out() {
                Err(anyhow::anyhow!("compressed presenter readiness timed out"))
            } else {
                Err(anyhow::anyhow!(
                    "compressed presenter closed before readiness"
                ))
            }
        })
        .await
        .context("presenter readiness worker stopped")?
    }
}

#[cfg(windows)]
fn compressed_presenter_writer(
    state: Arc<PresenterState>,
    child: Arc<Mutex<Child>>,
    mut stdin: File,
    clock: Clock,
    estimate: ClockEstimate,
) -> JoinHandle<()> {
    thread::spawn(move || {
        loop {
            let queued = take_presenter_slot(&state.latest, &state.ready, &state.closed);
            let Some(QueuedPresenterFrame {
                tag,
                source_submitted_ns,
                record,
                decode_only,
                recover_expired_v4,
                completion,
            }) = queued
            else {
                break;
            };
            let started = Instant::now();
            let budget_before =
                remaining_freshness_budget(source_submitted_ns, estimate, clock.now_ns());
            let mut write_elapsed = None;
            let mut write_started_ns = 0;
            let mut completion_observed_ns = 0;
            let mut result = (|| -> std::result::Result<NativeCompletion, String> {
                match child.lock().expect("presenter child lock").try_wait() {
                    Ok(Some(status)) => {
                        return Err(format!(
                            "compressed presenter exited before VFGP write: {status}"
                        ));
                    }
                    Ok(None) => {}
                    Err(error) => return Err(format!("query compressed presenter: {error}")),
                }
                // Fix both absolute waits before any pipe byte can leave. The
                // disposition grace is not a presentation deadline: only an
                // exact Expired outcome may use it.
                let freshness_deadline = if decode_only {
                    None
                } else {
                    let Some(remaining) =
                        remaining_freshness_budget(source_submitted_ns, estimate, clock.now_ns())
                    else {
                        if recover_expired_v4 {
                            return Ok(NativeCompletion::Expired(tag.frame));
                        }
                        return Err("coded frame became late before VFGP write".to_owned());
                    };
                    Some(
                        Instant::now()
                            .checked_add(remaining)
                            .ok_or_else(|| "coded frame deadline overflow".to_owned())?,
                    )
                };
                let disposition_deadline = freshness_deadline
                    .map(|deadline| {
                        if recover_expired_v4 {
                            deadline
                                .checked_add(EXPIRED_DISPOSITION_GRACE)
                                .ok_or_else(|| "expired disposition deadline overflow".to_owned())
                        } else {
                            Ok(deadline)
                        }
                    })
                    .transpose()?;
                if let Some(deadline) = freshness_deadline {
                    if Instant::now() >= deadline {
                        // No VFGP bytes have been written; the unbound local
                        // slot can truthfully use the same recovery outcome.
                        if recover_expired_v4 {
                            return Ok(NativeCompletion::Expired(tag.frame));
                        }
                        return Err("coded frame became late before VFGP write".to_owned());
                    }
                }
                *state.acknowledgement.lock().expect("presenter ACK lock") = None;
                state.acknowledgement_read_ns.store(0, Ordering::Release);
                state
                    .acknowledgement_published_ns
                    .store(0, Ordering::Release);
                let write_started = Instant::now();
                write_started_ns = clock.now_ns();
                let written = stdin.write_all(&record).and_then(|()| stdin.flush());
                write_elapsed = Some(write_started.elapsed());
                if let Err(error) = written {
                    return Err(format!("write compressed presenter stdin: {error}"));
                }
                let expected = if decode_only {
                    ExpectedNativeCompletion::DecodeOnly(tag.frame)
                } else if recover_expired_v4 {
                    ExpectedNativeCompletion::PresentedOrExpired(tag.frame)
                } else {
                    ExpectedNativeCompletion::Presented(tag.frame)
                };
                let native_completion = wait_for_presenter_completion(
                    &state.acknowledgement,
                    &state.acknowledgement_changed,
                    &state.closed,
                    expected,
                    if decode_only {
                        Instant::now() + PRESENTER_STARTUP_WAIT
                    } else {
                        disposition_deadline.expect("live frame fixed deadline")
                    },
                );
                completion_observed_ns = clock.now_ns();
                let native_completion = native_completion?;
                if let Some(freshness_deadline) = freshness_deadline {
                    return validate_live_native_completion(
                        native_completion,
                        tag.frame,
                        freshness_deadline,
                    );
                }
                Ok(native_completion)
            })();
            if let Ok(disposition) = result {
                if let Err(error) =
                    publish_presenter_input_frame(&state.pointer_motion, tag, disposition)
                {
                    result = Err(error);
                }
            }
            let failed = result.clone().err();
            let _ = completion.send(result);
            if let Some(error) = failed {
                // Failure-only evidence: successful live frames incur no log I/O.
                eprintln!(
                    "presenter failure timing frame={} decode_only={} budget_before_us={:?} write_us={:?} total_us={} write_to_stdout_us={:?} stdout_to_notify_us={:?} notify_to_resume_us={:?}",
                    tag.frame,
                    decode_only,
                    budget_before.map(|v| v.as_micros()),
                    write_elapsed.map(|v| v.as_micros()),
                    started.elapsed().as_micros(),
                    diagnostic_elapsed_us(
                        write_started_ns,
                        state.acknowledgement_read_ns.load(Ordering::Acquire)
                    ),
                    diagnostic_elapsed_us(
                        state.acknowledgement_read_ns.load(Ordering::Acquire),
                        state.acknowledgement_published_ns.load(Ordering::Acquire)
                    ),
                    diagnostic_elapsed_us(
                        state.acknowledgement_published_ns.load(Ordering::Acquire),
                        completion_observed_ns
                    ),
                );
                state.fail(error);
                break;
            }
        }
    })
}

// Diagnostic-only intervals never contribute to deadline admission. Missing
// samples and impossible ordering remain unavailable, not a fabricated zero.
#[cfg(any(windows, test))]
fn diagnostic_elapsed_us(start: u64, end: u64) -> Option<u64> {
    (start != 0 && end != 0).then_some(())?;
    end.checked_sub(start).map(|elapsed| elapsed / 1000)
}

/// Parses only the exact native acknowledgement grammar. In particular,
/// `frame_identity=10` cannot satisfy expected identity 1 by prefix.
#[cfg(any(windows, test))]
fn parse_presenter_completion(line: &str) -> std::result::Result<Option<NativeCompletion>, String> {
    if let Some(rest) = line.strip_prefix("rejected frame_identity=") {
        let identity = rest
            .strip_suffix(" reason=expired")
            .ok_or_else(|| "malformed expired completion".to_owned())?;
        if identity.is_empty()
            || !identity.bytes().all(|byte| byte.is_ascii_digit())
            || identity
                .parse::<u64>()
                .map_or(true, |value| value.to_string() != identity)
        {
            return Err("malformed expired completion".to_owned());
        }
        return Ok(Some(NativeCompletion::Expired(
            identity.parse().expect("checked u64"),
        )));
    }
    if let Some(rest) = line.strip_prefix("decode-only completed frame_identity=") {
        let mut fields = rest.split_whitespace();
        let identity = fields
            .next()
            .ok_or_else(|| "decode-only completion has no identity".to_owned())?
            .parse()
            .map_err(|_| "decode-only identity is not u64".to_owned())?;
        for expected in ["width=", "height="] {
            let field = fields
                .next()
                .ok_or_else(|| "decode-only completion lacks geometry".to_owned())?;
            if field
                .strip_prefix(expected)
                .and_then(|n| n.parse::<u32>().ok())
                .is_none()
            {
                return Err("malformed decode-only completion".to_owned());
            }
        }
        if fields.next().is_some() {
            return Err("malformed decode-only completion".to_owned());
        }
        return Ok(Some(NativeCompletion::DecodeOnly(identity)));
    }
    let Some(rest) = line.strip_prefix("submitted frame_identity=") else {
        return Ok(None);
    };
    let mut fields = rest.split_whitespace();
    let identity = fields
        .next()
        .ok_or_else(|| "presenter ACK has no identity".to_owned())?
        .parse()
        .map_err(|_| "presenter ACK identity is not u64".to_owned())?;
    let submitted = fields
        .next()
        .ok_or_else(|| "presenter ACK lacks submitted_frames".to_owned())?;
    let width = fields
        .next()
        .ok_or_else(|| "presenter ACK lacks width".to_owned())?;
    let height = fields
        .next()
        .ok_or_else(|| "presenter ACK lacks height".to_owned())?;
    if submitted
        .strip_prefix("submitted_frames=")
        .and_then(|value| value.parse::<u64>().ok())
        .is_none()
        || width
            .strip_prefix("width=")
            .and_then(|value| value.parse::<u32>().ok())
            .is_none()
        || height
            .strip_prefix("height=")
            .and_then(|value| value.parse::<u32>().ok())
            .is_none()
        || fields.next().is_some()
    {
        return Err("malformed presenter ACK".to_owned());
    }
    Ok(Some(NativeCompletion::Presented(identity)))
}

#[cfg(any(windows, test))]
fn parse_canonical_u64(value: &str, field: &str) -> std::result::Result<u64, String> {
    if value.is_empty()
        || !value.bytes().all(|byte| byte.is_ascii_digit())
        || (value.len() > 1 && value.starts_with('0'))
    {
        return Err(format!("malformed pointer-motion {field}"));
    }
    value
        .parse::<u64>()
        .map_err(|_| format!("malformed pointer-motion {field}"))
}

#[cfg(any(windows, test))]
fn parse_presenter_pointer_motion(
    line: &str,
) -> std::result::Result<Option<PresenterPointerMotion>, String> {
    if !line.starts_with("pointer-motion") {
        return Ok(None);
    }
    // Split on literal spaces, not Unicode/general whitespace: the native
    // diagnostic grammar is exact so malformed output cannot activate capture.
    let fields = line.split(' ').collect::<Vec<_>>();
    if fields.len() != 8
        || fields.iter().any(|field| field.is_empty())
        || fields[0] != "pointer-motion"
    {
        return Err("malformed pointer-motion".to_owned());
    }
    let value = |index: usize, prefix: &str| {
        fields[index]
            .strip_prefix(prefix)
            .ok_or_else(|| "malformed pointer-motion".to_owned())
    };
    let frame_identity = parse_canonical_u64(value(1, "frame_identity=")?, "frame_identity")?;
    let x_pixels = u32::try_from(parse_canonical_u64(value(2, "x_pixels=")?, "x_pixels")?)
        .map_err(|_| "pointer-motion x_pixels exceeds u32".to_owned())?;
    let y_pixels = u32::try_from(parse_canonical_u64(value(3, "y_pixels=")?, "y_pixels")?)
        .map_err(|_| "pointer-motion y_pixels exceeds u32".to_owned())?;
    let viewport_width = u32::try_from(parse_canonical_u64(
        value(4, "viewport_width=")?,
        "viewport_width",
    )?)
    .map_err(|_| "pointer-motion viewport_width exceeds u32".to_owned())?;
    let viewport_height = u32::try_from(parse_canonical_u64(
        value(5, "viewport_height=")?,
        "viewport_height",
    )?)
    .map_err(|_| "pointer-motion viewport_height exceeds u32".to_owned())?;
    let not_after_qpc = parse_canonical_u64(value(6, "not_after_qpc=")?, "not_after_qpc")?;
    let qpc_frequency = parse_canonical_u64(value(7, "qpc_frequency=")?, "qpc_frequency")?;
    if frame_identity == 0
        || viewport_width == 0
        || viewport_height == 0
        || x_pixels >= viewport_width
        || y_pixels >= viewport_height
        || not_after_qpc == 0
        || qpc_frequency == 0
    {
        return Err("pointer-motion coordinate outside viewport".to_owned());
    }
    Ok(Some(PresenterPointerMotion {
        frame_identity,
        x_pixels,
        y_pixels,
        viewport_width,
        viewport_height,
        not_after_qpc,
        qpc_frequency,
    }))
}

#[cfg(any(windows, test))]
fn presenter_pointer_deadline(
    motion: PresenterPointerMotion,
    local_sample_ns: u64,
    qpc_now: u64,
    qpc_frequency: u64,
) -> std::result::Result<Option<u64>, String> {
    if qpc_frequency == 0 || qpc_frequency != motion.qpc_frequency {
        return Err("pointer motion QPC domain mismatch".to_owned());
    }
    let Some(remaining_ticks) = motion.not_after_qpc.checked_sub(qpc_now) else {
        return Ok(None);
    };
    let remaining_ns = u128::from(remaining_ticks) * 1_000_000_000 / u128::from(qpc_frequency);
    if remaining_ns == 0 {
        return Ok(None);
    }
    if remaining_ns > u128::from(DEADLINE_NS) {
        return Err("pointer motion deadline exceeds capture budget".to_owned());
    }
    local_sample_ns
        .checked_add(
            u64::try_from(remaining_ns).map_err(|_| "pointer deadline overflow".to_owned())?,
        )
        .map(Some)
        .ok_or_else(|| "pointer deadline overflow".to_owned())
}

#[cfg(any(windows, test))]
fn parse_presenter_output(line: &str) -> std::result::Result<Option<PresenterOutput>, String> {
    if line.starts_with("pointer-input-ended") {
        if let Some(reason) = line.strip_prefix("pointer-input-ended reason=") {
            if !reason.is_empty()
                && reason.len() <= 64
                && reason
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte == b'-')
            {
                return Err(format!("native pointer input retired: {reason}"));
            }
        }
        return Err("native pointer input retired".to_owned());
    }
    if line.starts_with("pointer-button") {
        use viewflow_protocol::{InputSwitchState, PointerButton, PointerButtonEvent};
        let fields: Vec<_> = line.split(' ').collect();
        if fields.len() != 10 || fields[0] != "pointer-button" {
            return Err("malformed pointer-button".to_owned());
        }
        let motion_line = format!("pointer-motion {}", fields[1..8].join(" "));
        let motion =
            parse_presenter_pointer_motion(&motion_line)?.ok_or("missing button position")?;
        let code = fields[8].strip_prefix("button=").ok_or("missing button")?;
        let state = fields[9]
            .strip_prefix("state=")
            .ok_or("missing button state")?;
        let button = match code {
            "1" => PointerButton::Left,
            "2" => PointerButton::Middle,
            "3" => PointerButton::Right,
            "4" => PointerButton::Back,
            "5" => PointerButton::Forward,
            _ => return Err("invalid button".to_owned()),
        };
        let state = match state {
            "1" => InputSwitchState::Pressed,
            "2" => InputSwitchState::Released,
            _ => return Err("invalid button state".to_owned()),
        };
        return Ok(Some(PresenterOutput::PointerButton(
            motion,
            PointerButtonEvent { button, state },
        )));
    }
    if let Some(motion) = parse_presenter_pointer_motion(line)? {
        return Ok(Some(PresenterOutput::PointerMotion(motion)));
    }
    Ok(parse_presenter_completion(line)?.map(PresenterOutput::Completion))
}

#[cfg(any(windows, test))]
fn record_presenter_completion(state: &Mutex<PointerMotionState>, completion: NativeCompletion) {
    if let NativeCompletion::Presented(identity) = completion {
        let mut state = state.lock().expect("pointer motion lock");
        if !state.pending_events.is_empty() && state.latest_presented != Some(identity) {
            // Never silently lose queued button transitions on replacement.
            state.events.take();
            state.samples.take();
            state.pending_events.clear();
        }
        state.latest_presented = Some(identity);
        state.latest_motion = None;
        // The visual changed, but its full authenticated video tag has not yet
        // passed the writer's submission/deadline validation. Stop old input.
        state.published_presented = None;
        if let Some(samples) = &state.samples {
            samples.send_replace(crate::window_preview_input::PreviewPointerState::default());
        }
    }
}

#[cfg(any(windows, test))]
fn close_presenter_pointer_samples(state: &Mutex<PointerMotionState>) {
    let mut state = state.lock().expect("pointer motion lock");
    state.published_presented = None;
    state.published_history.clear();
    state.pending_events.clear();
    state.latest_motion = None;
    state.samples.take();
    state.events.take();
}

#[cfg(any(windows, test))]
fn publish_presenter_input_frame(
    state: &Mutex<PointerMotionState>,
    tag: FrameIdentity,
    completion: NativeCompletion,
) -> std::result::Result<(), String> {
    let NativeCompletion::Presented(identity) = completion else {
        return Ok(());
    };
    let mut state = state.lock().expect("pointer motion lock");
    if tag.window.0 == 0
        || tag.epoch == 0
        || tag.frame == 0
        || identity != tag.frame
        || state.latest_presented != Some(identity)
    {
        return Err("native presentation has no matching validated video identity".to_owned());
    }
    if let Some(previous) = state.published_history.back() {
        if previous.window != tag.window || previous.epoch != tag.epoch {
            state.published_history.clear();
        } else if tag.frame <= previous.frame {
            return Err("validated presentation history regressed".to_owned());
        }
    }
    state.published_history.push_back(tag);
    if state.published_history.len() > 32 {
        state.published_history.pop_front();
    }
    state.published_presented = Some(tag);
    if let Some(samples) = &state.samples {
        samples.send_replace(crate::window_preview_input::PreviewPointerState {
            presented: Some(viewflow_core::PresentedInputIdentity {
                window: tag.window,
                geometry_epoch: tag.epoch,
                frame: tag.frame,
            }),
            motion: None,
        });
    }
    let pending = std::mem::take(&mut state.pending_events);
    for (motion, deadline, button) in pending {
        record_presenter_pointer_event_locked(&mut state, motion, deadline, button)?;
    }
    Ok(())
}

#[cfg(test)]
fn record_presenter_pointer_motion(
    enabled: bool,
    state: &Mutex<PointerMotionState>,
    motion: PresenterPointerMotion,
    sender_not_after_ns: u64,
) -> std::result::Result<(), String> {
    record_presenter_pointer_event(enabled, state, motion, sender_not_after_ns, None)
}

#[cfg(any(windows, test))]
fn record_presenter_pointer_event(
    enabled: bool,
    state: &Mutex<PointerMotionState>,
    motion: PresenterPointerMotion,
    sender_not_after_ns: u64,
    button: Option<viewflow_protocol::PointerButtonEvent>,
) -> std::result::Result<(), String> {
    if !enabled {
        return Err(
            "native pointer-motion received while --emit-pointer-motion is disabled".to_owned(),
        );
    }
    if sender_not_after_ns == 0 {
        return Err("pointer motion has no native deadline".to_owned());
    }
    let mut state = state.lock().expect("pointer motion lock");
    record_presenter_pointer_event_locked(&mut state, motion, sender_not_after_ns, button)
}

#[cfg(any(windows, test))]
fn record_presenter_pointer_event_locked(
    state: &mut PointerMotionState,
    motion: PresenterPointerMotion,
    sender_not_after_ns: u64,
    button: Option<viewflow_protocol::PointerButtonEvent>,
) -> std::result::Result<(), String> {
    if state.events.is_some()
        && state.published_presented.is_none()
        && state.latest_presented == Some(motion.frame_identity)
    {
        if state.pending_events.len() >= 64 {
            return Err("pending validated-frame input queue exhausted".to_owned());
        }
        state
            .pending_events
            .push((motion, sender_not_after_ns, button));
        return Ok(());
    }
    if button.is_some() && (state.events.is_none() || state.published_presented.is_none()) {
        return Err(format!(
            "button has no ordered route or published frame: event_frame={} latest_presented={:?} published_frame={:?} ordered_route={} retained_event={} pending_motion_frame={:?}",
            motion.frame_identity,
            state.latest_presented,
            state.published_presented.map(|tag| tag.frame),
            state.events.is_some(),
            state
                .published_history
                .iter()
                .any(|tag| tag.frame == motion.frame_identity),
            state.latest_motion.map(|(sample, _)| sample.frame_identity),
        ));
    }
    let retained = state
        .published_history
        .iter()
        .find(|tag| tag.frame == motion.frame_identity)
        .copied();
    if state.latest_presented != Some(motion.frame_identity)
        && (retained.is_none() || state.published_presented.is_none())
    {
        return Err(format!(
            "pointer-motion frame_identity={} does not match latest submitted frame {:?}",
            motion.frame_identity, state.latest_presented
        ));
    }
    // Deliberately bounded: newer motion supersedes older motion for the same
    // currently presented frame; it is not an input queue.
    state.latest_motion = Some((motion, sender_not_after_ns));
    if let Some(tag) = retained.or(state.published_presented) {
        if tag.frame != motion.frame_identity {
            return Err("pointer sample does not match published video identity".to_owned());
        }
        state.sample_sequence = state
            .sample_sequence
            .checked_add(1)
            .ok_or_else(|| "native pointer sample sequence exhausted".to_owned())?;
        let presented = viewflow_core::PresentedInputIdentity {
            window: tag.window,
            geometry_epoch: tag.epoch,
            frame: tag.frame,
        };
        let sample = crate::window_preview_input::PreviewPointerSample {
            sample_sequence: state.sample_sequence,
            presented,
            sender_not_after_ns,
            x_pixels: motion.x_pixels,
            y_pixels: motion.y_pixels,
            viewport_width: motion.viewport_width,
            viewport_height: motion.viewport_height,
        };
        if let Some(events) = &state.events {
            events
                .push(crate::window_preview_input::PreviewPointerEvent {
                    key: None,
                    sample,
                    button,
                    wheel: None,
                })
                .map_err(|error| error.to_string())?;
        }
        if let Some(samples) = &state.samples {
            let current =
                state
                    .published_presented
                    .map(|tag| viewflow_core::PresentedInputIdentity {
                        window: tag.window,
                        geometry_epoch: tag.epoch,
                        frame: tag.frame,
                    });
            samples.send_replace(crate::window_preview_input::PreviewPointerState {
                presented: current,
                motion: if state.events.is_some() {
                    None
                } else {
                    Some(sample)
                },
            });
        }
    }
    Ok(())
}

/// Claims one of the fixed first-32 diagnostics without wrapping after 255.
#[cfg(any(windows, test))]
fn take_pointer_motion_diagnostic_slot(counter: &AtomicU8) -> bool {
    counter
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
            (current < 32).then_some(current + 1)
        })
        .is_ok()
}

#[cfg(any(windows, test))]
fn retire_presenter_child(child: &mut std::process::Child) -> std::io::Result<()> {
    if child.try_wait()?.is_none() {
        if let Err(error) = child.kill() {
            // A natural exit can race kill. Only a positive exit observation
            // permits treating that race as successful retirement.
            if child.try_wait()?.is_none() {
                return Err(error);
            }
        }
    }
    child.wait()?;
    Ok(())
}

#[cfg(windows)]
fn failed_presenter_start(child: &mut Child, message: &'static str) -> anyhow::Error {
    match retire_presenter_child(child) {
        Ok(()) => anyhow::anyhow!(message),
        Err(error) => anyhow::Error::from(error)
            .context(message)
            .context(NativeCleanupFailure),
    }
}

#[cfg(any(windows, test))]
fn join_presenter_worker(
    name: &str,
    worker: &mut Option<std::thread::JoinHandle<()>>,
) -> Result<()> {
    if worker.take().is_some_and(|worker| worker.join().is_err()) {
        bail!("presenter {name} worker panicked during retirement");
    }
    Ok(())
}

#[cfg(windows)]
impl CompressedPresenter {
    fn shutdown(&mut self) -> Result<()> {
        if let Some(result) = &self.retirement {
            return result.clone().map_err(anyhow::Error::msg);
        }
        self.state.fail("compressed presenter shutting down");
        let mut failures = Vec::new();
        let child_retired = {
            let mut child = match self.child.lock() {
                Ok(child) => child,
                Err(poisoned) => {
                    failures.push("presenter child lock was poisoned".to_owned());
                    poisoned.into_inner()
                }
            };
            match retire_presenter_child(&mut child) {
                Ok(()) => true,
                Err(error) => {
                    failures.push(format!("presenter process did not retire: {error}"));
                    false
                }
            }
        };
        // Without a verified child exit, joining a pipe reader can block
        // indefinitely. Preserve the failure and fence the media owner.
        if child_retired {
            for (name, worker) in [
                ("writer", &mut self.writer),
                ("stdout", &mut self.stdout),
                ("stderr", &mut self.stderr),
            ] {
                if let Err(error) = join_presenter_worker(name, worker) {
                    failures.push(error.to_string());
                }
            }
        }
        let result = if failures.is_empty() {
            Ok(())
        } else {
            Err(failures.join("; "))
        };
        self.retirement = Some(result.clone());
        result.map_err(anyhow::Error::msg)
    }
}

#[cfg(windows)]
impl Drop for CompressedPresenter {
    fn drop(&mut self) {
        if let Err(error) = self.shutdown() {
            eprintln!("compressed presenter cleanup failed: {error:#}");
        }
    }
}

#[cfg(windows)]
struct PointerInputTask {
    task: tokio::task::JoinHandle<Result<()>>,
    connection: quinn::Connection,
    // The receiver loop owns the ACK consumer for exactly this preview lifetime.
    acknowledgements: tokio::sync::watch::Receiver<Option<viewflow_protocol::WindowPointerAck>>,
    reported_acknowledgements: u8,
    receipts: Arc<crate::window_preview_input::WindowPointerReceiptCounts>,
    reported_button_receipts: (u64, u64),
}

#[cfg(windows)]
struct PointerReceiptReport(Arc<crate::window_preview_input::WindowPointerReceiptCounts>);

#[cfg(windows)]
impl Drop for PointerReceiptReport {
    fn drop(&mut self) {
        let (motion, down, up) = self.0.snapshot();
        eprintln!("preview pointer confirmed totals motion={motion} down={down} up={up}");
    }
}

#[cfg(windows)]
impl PointerInputTask {
    async fn stop(&mut self) -> Result<()> {
        self.connection
            .close(0_u32.into(), b"preview input retiring");
        retire_input_task(&mut self.task, Duration::from_millis(250)).await
    }

    fn start(
        connection: &quinn::Connection,
        presenter: &CompressedPresenter,
        clock: &Clock,
        forwarding: PointerForwarding,
    ) -> Result<Self> {
        let (acks, acknowledgements) = tokio::sync::watch::channel(None);
        let input = crate::window_preview_input::WindowPreviewInput::new(
            forwarding.owner,
            forwarding.source,
            WINDOW,
            clock.0,
            presenter.pointer_samples.clone(),
            acks,
        )?;
        let input = if let Some(events) = presenter
            .pointer_events
            .lock()
            .expect("pointer event owner lock")
            .take()
        {
            input.with_buttons(events)?
        } else {
            input
        };
        let input_connection = connection.clone();
        let receipts = input.receipt_counts();
        let terminal_receipts = receipts.clone();
        let task = tokio::spawn(async move {
            // This guard runs inside the sole ACK owner, including cancellation;
            // an outer task-abort caller cannot race its final count snapshot.
            let _receipts = PointerReceiptReport(terminal_receipts);
            let result = input.serve(&input_connection).await;
            if let Err(error) = &result {
                eprintln!("preview input route ended: {error:#}");
            }
            result
        });
        Ok(Self {
            task,
            connection: connection.clone(),
            acknowledgements,
            reported_acknowledgements: 0,
            receipts,
            reported_button_receipts: (0, 0),
        })
    }

    fn observe_acknowledgement(&mut self) {
        let (motion, down, up) = self.receipts.snapshot();
        if (down, up) != self.reported_button_receipts {
            eprintln!("preview pointer confirmed totals motion={motion} down={down} up={up}");
            self.reported_button_receipts = (down, up);
        }
        if matches!(self.acknowledgements.has_changed(), Ok(true)) {
            if let Some(ack) = *self.acknowledgements.borrow_and_update() {
                if self.reported_acknowledgements < 32 {
                    self.reported_acknowledgements += 1;
                    eprintln!(
                        "preview pointer native ACK generation={} frame={} sequence={} result={:?}",
                        ack.lease_generation, ack.presented_frame, ack.event_sequence, ack.result
                    );
                }
            }
        }
    }
}

#[cfg(windows)]
impl Drop for PointerInputTask {
    fn drop(&mut self) {
        self.connection
            .close(0_u32.into(), b"coded preview input owner ended");
        self.task.abort();
    }
}

#[cfg(windows)]
fn bind_receiver_endpoint(o: &Options) -> Result<Endpoint> {
    let listen = o.listen.context("receive requires --listen")?;
    let identity = load_identity(o)?;
    let server_config = build_server_config(&identity)
        .map_err(|e| anyhow::anyhow!("build mTLS server config: {e}"))?;
    let socket = std::net::UdpSocket::bind(listen)
        .with_context(|| format!("bind coded receiver UDP endpoint {listen}"))?;
    let socket_ref = socket2::SockRef::from(&socket);
    let before_receive = socket_ref.recv_buffer_size()?;
    let before_send = socket_ref.send_buffer_size()?;
    socket_ref.set_recv_buffer_size(4 * 1024 * 1024)?;
    let after_receive = socket_ref.recv_buffer_size()?;
    let after_send = socket_ref.send_buffer_size()?;
    eprintln!(
        "coded receiver UDP buffers: before_recv_bytes={} before_send_bytes={} requested_recv_bytes=4194304 after_recv_bytes={} after_send_bytes={}",
        before_receive, before_send, after_receive, after_send,
    );
    let ep = Endpoint::new(
        Default::default(),
        Some(server_config),
        socket,
        std::sync::Arc::new(quinn::TokioRuntime),
    )?;
    Ok(ep)
}

#[cfg(windows)]
async fn receive(o: Options, ep: &Endpoint) -> Result<()> {
    let session_deadline = Instant::now() + o.timeout;
    let presenter = o
        .presenter
        .as_deref()
        .context("receive requires --stdin-compressed <presenter.exe>")?;
    let c: quinn::Connection = tokio::time::timeout(remaining_session(session_deadline)?, async {
        ep.accept()
            .await
            .context("no incoming connection")?
            .await
            .context("accept mTLS connection")
    })
    .await
    .context(MediaConnectTimeout)??;
    let _retiring_connection = RetiringConnection(c.clone());
    let (mut tx, mut rx) =
        tokio::time::timeout(remaining_session(session_deadline)?, c.accept_bi())
            .await
            .context("coded receiver session timed out accepting control stream")??;
    let clock = Clock::new();
    let estimate = tokio::time::timeout(
        remaining_session(session_deadline)?,
        clock_exchange_server(&mut tx, &mut rx, &clock),
    )
    .await
    .context("coded receiver session timed out during clock exchange")??;
    let logical = LogicalSize::decode(
        &tokio::time::timeout(
            remaining_session(session_deadline)?,
            read_record(&mut rx, LOGICAL_GEOMETRY, 16),
        )
        .await
        .context("coded receiver session timed out reading logical geometry")??,
    )?;
    let blur = BlurRect::decode(
        &tokio::time::timeout(
            remaining_session(session_deadline)?,
            read_record(&mut rx, BLUR_RECT, 16),
        )
        .await
        .context("coded receiver session timed out reading blur rectangle")??,
    )?;
    let radius = f64::from_be_bytes(
        tokio::time::timeout(
            remaining_session(session_deadline)?,
            read_record(&mut rx, BLUR_RADIUS, 8),
        )
        .await
        .context("coded receiver session timed out reading blur radius")??
        .as_slice()
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid blur radius bytes"))?,
    );
    if !radius.is_finite() || radius <= 0.0 {
        bail!("invalid blur radius")
    };
    blur.validate(logical)?;
    let mut presenter = CompressedPresenter::spawn(
        presenter,
        logical,
        blur,
        radius,
        o.max_frame_bytes,
        clock.clone(),
        estimate,
        o.require_deadline_v4,
        o.recover_expired_v4,
        o.emit_pointer_motion,
        o.forward_pointer_buttons,
        o.warmup_frames,
    )?;
    let mut pointer_input: Option<PointerInputTask> = None;
    let attempt_result = async {
    tokio::time::timeout(
        remaining_session(session_deadline)?,
        presenter.wait_until_ready(),
    )
    .await
    .context("coded receiver session timed out waiting for presenter readiness")??;
    if o.alpha_reuse_warmup {
        let plan = tokio::time::timeout(
            remaining_session(session_deadline)?,
            read_record(&mut rx, ALPHA_REUSE_PLAN, ALPHA_REUSE_PLAN_PAYLOAD.len()),
        )
        .await
        .context("coded receiver session timed out reading alpha reuse plan")??;
        validate_alpha_reuse_plan(o.alpha_reuse_warmup, &plan)
            .context("sender alpha reuse plan does not match receiver configuration")?;
        tokio::time::timeout(
            remaining_session(session_deadline)?,
            write_record(&mut tx, ALPHA_REUSE_PLAN_ACK, &plan),
        )
        .await
        .context("coded receiver session timed out writing alpha reuse plan ACK")??;
    }
    if requires_warmup_plan(o.warmup_frames) {
        let plan = tokio::time::timeout(
            remaining_session(session_deadline)?,
            read_record(&mut rx, WARMUP_PLAN, 1),
        )
        .await
        .context("coded receiver session timed out reading warmup plan")??;
        validate_warmup_plan(o.warmup_frames, &plan)
            .context("sender warmup plan does not match receiver configuration")?;
        tokio::time::timeout(
            remaining_session(session_deadline)?,
            write_record(&mut tx, WARMUP_PLAN_ACK, &plan),
        )
        .await
        .context("coded receiver session timed out writing warmup plan ACK")??;
    }
    let descriptors = tokio::time::timeout(
        remaining_session(session_deadline)?,
        read_record(&mut rx, DESCRIPTORS, CODEC_DESCRIPTOR_BYTES * 2),
    )
    .await
    .context("coded receiver session timed out reading descriptors")??;
    let color = CodecDescriptor::decode(Bytes::copy_from_slice(
        &descriptors[..CODEC_DESCRIPTOR_BYTES],
    ))?;
    let alpha = CodecDescriptor::decode(Bytes::copy_from_slice(
        &descriptors[CODEC_DESCRIPTOR_BYTES..],
    ))?;
    let mut session = CodecSession::new(Default::default());
    session.accept_descriptors(
        color,
        alpha,
        limits(o.max_frame_bytes, color.coded_width, color.coded_height),
    )?;
    // Reliable startup warmup. It intentionally bypasses live source-age
    // admission: its already session-mapped timestamp travels only for codec
    // lineage and cannot be displayed or ACKed as a presenter frame.  Each
    // exact ACK proves the same persistent presenter decoder consumed that
    // reference before the next real capture is sent.
    let warmup_started = Instant::now();
    let mut previous_warmup: Option<FrameIdentity> = None;
    let mut warmup_lineage: Option<(u64, u64)> = None;
    let mut alpha_reference = None;
    for ordinal in 0..o.warmup_frames {
        let warmup_meta = tokio::time::timeout(
            remaining_session(session_deadline)?,
            read_record(&mut rx, WARMUP_META, WARMUP_META_BYTES),
        )
        .await
        .context("coded receiver session timed out reading warmup metadata")??;
        let warmup_tag = FrameIdentity::decode(&warmup_meta[..40])?;
        if let Some(previous) = previous_warmup {
            if warmup_tag.frame <= previous.frame {
                bail!("warmup frame identities must strictly increase")
            }
        }
        let warmup_cm = FrameCodecMetadata::decode(Bytes::copy_from_slice(
            &warmup_meta[40..40 + FRAME_CODEC_METADATA_BYTES],
        ))?;
        let warmup_am = FrameCodecMetadata::decode(Bytes::copy_from_slice(
            &warmup_meta[40 + FRAME_CODEC_METADATA_BYTES..40 + FRAME_CODEC_METADATA_BYTES * 2],
        ))?;
        validate_warmup_metadata(warmup_tag, warmup_cm, warmup_am)?;
        warmup_lineage = validate_warmup_reference(
            usize::from(ordinal),
            warmup_cm.keyframe,
            (warmup_tag.epoch, warmup_tag.config),
            warmup_lineage,
        )?;
        let (warmup_source_submitted_ns, color_len, alpha_len) = decode_warmup_tail(&warmup_meta)?;
        let warmup_color = tokio::time::timeout(
            remaining_session(session_deadline)?,
            read_warmup_blob(&mut rx, WARMUP_COLOR, color_len, o.max_frame_bytes),
        )
        .await
        .context("coded receiver session timed out reading warmup color")??;
        let warmup_alpha = Bytes::from(
            tokio::time::timeout(
                remaining_session(session_deadline)?,
                read_warmup_blob(&mut rx, WARMUP_ALPHA, alpha_len, o.max_frame_bytes),
            )
            .await
            .context("coded receiver session timed out reading warmup alpha")??,
        );
        session.accept_frame(
            &MediaPlaneFrame {
                window_id: warmup_tag.window,
                frame_id: warmup_tag.frame,
                geometry_epoch: warmup_tag.epoch,
                plane: MediaPlane::Color,
                source_submitted_ns: warmup_source_submitted_ns,
                payload: Bytes::from(warmup_color.clone()),
            },
            warmup_cm,
            Some((
                &MediaPlaneFrame {
                    window_id: warmup_tag.window,
                    frame_id: warmup_tag.frame,
                    geometry_epoch: warmup_tag.epoch,
                    plane: MediaPlane::Alpha,
                    source_submitted_ns: warmup_source_submitted_ns,
                    payload: warmup_alpha.clone(),
                },
                warmup_am,
            )),
        )?;
        let warmup_record = crate::gpu_presenter_pipe::encode_compressed_alpha_decode_only_record(
            warmup_tag.frame,
            color.coded_width,
            color.coded_height,
            &warmup_color,
            &warmup_alpha,
            o.max_frame_bytes,
        )?;
        presenter.queue_decode_only(warmup_tag, warmup_record)?;
        tokio::time::timeout(
            remaining_session(session_deadline)?,
            presenter.wait_for_decode_only(),
        )
        .await
        .context("coded receiver session timed out waiting for decode-only completion")??;
        tokio::time::timeout(
            remaining_session(session_deadline)?,
            write_record(&mut tx, WARMUP_ACK, &warmup_tag.encode()),
        )
        .await
        .context("coded receiver session timed out writing warmup ACK")??;
        if o.alpha_reuse_warmup && ordinal + 1 == o.warmup_frames {
            alpha_reference = Some(AlphaReferenceCache::new(
                warmup_tag.encode(),
                alpha.coded_width,
                alpha.coded_height,
                warmup_alpha,
                o.max_frame_bytes,
            )?);
        }
        eprintln!(
            "decode-only warmup completed frame_identity={} ordinal={} elapsed_ms={}",
            warmup_tag.frame,
            ordinal + 1,
            warmup_started.elapsed().as_millis()
        );
        previous_warmup = Some(warmup_tag);
    }
    // Only actual decode-only output unlocks capture/media admission. The
    // first live source picture is captured after this READY; it may reference
    // the warmup already decoded by this same presenter child.
    tokio::time::timeout(
        remaining_session(session_deadline)?,
        write_record(&mut tx, READY, &[]),
    )
    .await
    .context("coded receiver session timed out writing READY")??;
    let session_deadline = MediaLifetime::live(o.persistent, session_deadline, o.timeout);
    let mut assembler = MediaAssembler::new(MediaAssemblerConfig {
        deadline_ns: DEADLINE_NS,
        max_chunks_per_plane: 8192,
        max_plane_bytes: o.max_frame_bytes,
    });
    let mut receiver_stats = ReceiverStats::default();
    'frames: loop {
        if let Some(input) = &mut pointer_input {
            input.observe_acknowledgement();
        }
        if pointer_input
            .as_ref()
            .is_some_and(|input| input.task.is_finished())
        {
            bail!("preview input worker ended");
        }
        let (kind, payload) = match tokio::time::timeout(
            remaining_session(session_deadline)?,
            read_any_record(&mut rx),
        )
        .await
        .context("coded receiver session timed out waiting for control")??
        {
            Some(record) => record,
            None => break, // Clean EOF only; a partial record is an error above.
        };
        let (meta, alpha_reference_key) =
            parse_frame_meta_record(kind, &payload, o.alpha_reuse_warmup)?;
        let tag = FrameIdentity::decode(&meta[..40])?;
        receiver_stats.frames = receiver_stats.frames.saturating_add(1);
        let cm = FrameCodecMetadata::decode(Bytes::copy_from_slice(
            &meta[40..40 + FRAME_CODEC_METADATA_BYTES],
        ))?;
        let am = FrameCodecMetadata::decode(Bytes::copy_from_slice(
            &meta[40 + FRAME_CODEC_METADATA_BYTES..],
        ))?;
        let alpha_reference_payload = alpha_reference_key
            .map(|reference| {
                alpha_reference
                    .as_ref()
                    .context("alpha reference arrived before successful final warmup")?
                    .resolve(
                        reference,
                        tag.encode(),
                        alpha.coded_width,
                        alpha.coded_height,
                    )
            })
            .transpose()?;
        let (mut color_plane, mut alpha_plane) = (None, None);
        let assembly_started = Instant::now();
        receiver_stats.frame_started = Some(assembly_started);
        let mut first_packet_us = None;
        let mut first_source_age_upper_ns = None;
        // These are matching packet counts, not unique chunk counts.  No
        // per-frame chunk set is allocated by this diagnostic.
        let mut color_seen_packets = 0_u32;
        let mut alpha_seen_packets = 0_u32;
        let mut color_expected_chunks = None;
        let mut alpha_expected_chunks = None;
        let frame_deadline = session_deadline.frame_deadline(Instant::now(), PRESENTER_ACK_WAIT)?;
        while color_plane.is_none() || (alpha_reference_payload.is_none() && alpha_plane.is_none())
        {
            let Some(remaining) = frame_datagram_budget(frame_deadline) else {
                receiver_stats.reject(
                    "timeout",
                    tag,
                    first_packet_us,
                    first_source_age_upper_ns,
                    color_seen_packets,
                    color_expected_chunks,
                    alpha_seen_packets,
                    alpha_expected_chunks,
                );
                write_record(&mut tx, REJECT, &tag.encode()).await?;
                continue 'frames;
            };
            let datagram = match tokio::time::timeout(remaining, c.read_datagram()).await {
                Ok(Ok(datagram)) => datagram,
                Ok(Err(error)) => return Err(error.into()),
                Err(_) => {
                    receiver_stats.reject(
                        "timeout",
                        tag,
                        first_packet_us,
                        first_source_age_upper_ns,
                        color_seen_packets,
                        color_expected_chunks,
                        alpha_seen_packets,
                        alpha_expected_chunks,
                    );
                    write_record(&mut tx, REJECT, &tag.encode()).await?;
                    continue 'frames;
                }
            };
            let packet = MediaDatagram::decode(datagram)?;
            // Datagram transport can retain a rejected frame's tail. It can
            // never be admitted for a later reliable metadata record.
            if !datagram_matches_frame(&packet, tag) {
                continue;
            }
            if packet.chunk_count > 8192 {
                bail!("receiver datagram chunk count exceeds configured bound")
            }
            first_packet_us.get_or_insert_with(|| assembly_started.elapsed().as_micros());
            first_source_age_upper_ns.get_or_insert_with(|| {
                estimate.age_upper_bound_ns(packet.source_submitted_ns, clock.now_ns())
            });
            match packet.plane {
                MediaPlane::Color => {
                    color_seen_packets = color_seen_packets.saturating_add(1);
                    color_expected_chunks.get_or_insert(packet.chunk_count);
                }
                MediaPlane::Alpha => {
                    validate_reference_packet_plane(
                        alpha_reference_payload.is_some(),
                        packet.plane,
                    )?;
                    alpha_seen_packets = alpha_seen_packets.saturating_add(1);
                    alpha_expected_chunks.get_or_insert(packet.chunk_count);
                }
                _ => unreachable!("matching filter admits only color/alpha"),
            }
            let completed = match assembler.push_any_remote(packet, clock.now_ns(), estimate) {
                Ok(completed) => completed,
                Err(viewflow_transport::MediaAssemblerError::Late) => {
                    receiver_stats.reject(
                        "late",
                        tag,
                        first_packet_us,
                        first_source_age_upper_ns,
                        color_seen_packets,
                        color_expected_chunks,
                        alpha_seen_packets,
                        alpha_expected_chunks,
                    );
                    write_record(&mut tx, REJECT, &tag.encode()).await?;
                    continue 'frames;
                }
                Err(error) => return Err(error.into()),
            };
            if let Some(p) = completed {
                match p.plane {
                    MediaPlane::Color => color_plane = Some(p),
                    MediaPlane::Alpha => alpha_plane = Some(p),
                    _ => bail!("unexpected media plane"),
                }
            }
        }
        let cp = color_plane.unwrap();
        let ap = if let Some(payload) = alpha_reference_payload {
            // Only the immutable VFAR bytes originate at warmup. The alpha
            // plane's identity and capture timestamp remain those of the
            // completed current color plane.
            current_alpha_plane_from_reference(
                cp.window_id,
                cp.frame_id,
                cp.geometry_epoch,
                cp.source_submitted_ns,
                payload,
            )
        } else {
            let ap = alpha_plane.expect("loop completes both normal planes");
            MediaPlaneFrame {
                window_id: ap.window_id,
                frame_id: ap.frame_id,
                geometry_epoch: ap.geometry_epoch,
                plane: ap.plane,
                source_submitted_ns: ap.source_submitted_ns,
                payload: ap.payload,
            }
        };
        let assembly_us = assembly_started.elapsed().as_micros();
        let validation_started = Instant::now();
        let assembly_budget =
            remaining_freshness_budget(cp.source_submitted_ns, estimate, clock.now_ns());
        if tag.window != cp.window_id
            || tag.frame != cp.frame_id
            || tag.epoch != cp.geometry_epoch
            || tag.window != ap.window_id
            || tag.frame != ap.frame_id
            || tag.epoch != ap.geometry_epoch
            || cp.source_submitted_ns != ap.source_submitted_ns
        {
            bail!("coded color/alpha identity mismatch")
        };
        // Reject before codec admission when the completed pair has crossed
        // the source-time bound. A later IDR can safely establish a new
        // decodable point; no expired frame reaches the child process.
        if !fresh(cp.source_submitted_ns, estimate, clock.now_ns()) {
            receiver_stats.reject(
                "after_assembly",
                tag,
                first_packet_us,
                first_source_age_upper_ns,
                color_seen_packets,
                color_expected_chunks,
                alpha_seen_packets,
                alpha_expected_chunks,
            );
            write_record(&mut tx, REJECT, &tag.encode()).await?;
            continue 'frames;
        };
        session.accept_frame(
            &MediaPlaneFrame {
                window_id: cp.window_id,
                frame_id: cp.frame_id,
                geometry_epoch: cp.geometry_epoch,
                plane: cp.plane,
                source_submitted_ns: cp.source_submitted_ns,
                payload: cp.payload.clone(),
            },
            cm,
            Some((
                &MediaPlaneFrame {
                    window_id: ap.window_id,
                    frame_id: ap.frame_id,
                    geometry_epoch: ap.geometry_epoch,
                    plane: ap.plane,
                    source_submitted_ns: ap.source_submitted_ns,
                    payload: ap.payload.clone(),
                },
                am,
            )),
        )?;
        let record = if o.require_deadline_v4 {
            // QPC is sampled first. Computing remaining source budget afterwards
            // only shortens the deadline; pipe/queue/decoder time cannot reset it.
            let (ticks, frequency) = native_qpc_sample()?;
            let remaining =
                remaining_freshness_budget(cp.source_submitted_ns, estimate, clock.now_ns());
            let Some(remaining) = remaining.and_then(|remaining| {
                native_deadline_budget_after_presentation_reserve(remaining, o.presentation_reserve)
            }) else {
                if !o.presentation_reserve.is_zero() {
                    // This occurs before a VFGP record exists, so the native
                    // child cannot have bound the frame. Keep recovery in the
                    // existing exact REJECT path rather than restamping it.
                    receiver_stats.reject(
                        "after_validation",
                        tag,
                        first_packet_us,
                        first_source_age_upper_ns,
                        color_seen_packets,
                        color_expected_chunks,
                        alpha_seen_packets,
                        alpha_expected_chunks,
                    );
                    tokio::time::timeout(
                        remaining_session(session_deadline)?,
                        write_record(&mut tx, REJECT, &tag.encode()),
                    )
                    .await
                    .context("coded receiver session timed out writing reserved-budget REJECT")??;
                    continue 'frames;
                }
                bail!("coded frame expired before native deadline derivation")
            };
            let deadline =
                crate::gpu_presenter_pipe::NativePresentationDeadline::from_remaining_budget(
                    ticks,
                    frequency,
                    u64::try_from(remaining.as_nanos())?,
                )?;
            crate::gpu_presenter_pipe::encode_deadline_alpha_record(
                tag.frame,
                color.coded_width,
                color.coded_height,
                &cp.payload,
                &ap.payload,
                deadline,
                o.max_frame_bytes,
            )?
        } else {
            crate::gpu_presenter_pipe::encode_compressed_alpha_record(
                tag.frame,
                color.coded_width,
                color.coded_height,
                &cp.payload,
                &ap.payload,
                o.max_frame_bytes,
            )?
        };
        if !fresh(cp.source_submitted_ns, estimate, clock.now_ns()) {
            receiver_stats.reject(
                "after_validation",
                tag,
                first_packet_us,
                first_source_age_upper_ns,
                color_seen_packets,
                color_expected_chunks,
                alpha_seen_packets,
                alpha_expected_chunks,
            );
            write_record(&mut tx, REJECT, &tag.encode()).await?;
            continue 'frames;
        };
        presenter.queue(tag, cp.source_submitted_ns, record)?;
        let validation_us = validation_started.elapsed().as_micros();
        let disposition = match presenter.wait_for_submission().await {
            Ok(disposition) => disposition,
            Err(error) => {
                eprintln!(
                    "media failure timing frame={} first_packet_us={:?} assembly_us={} budget_after_assembly_us={:?} validation_queue_us={}",
                    tag.frame,
                    first_packet_us,
                    assembly_us,
                    assembly_budget.map(|v| v.as_micros()),
                    validation_us
                );
                return Err(error);
            }
        };
        if disposition == NativeCompletion::Expired(tag.frame) {
            // The child (or the pre-write no-byte path) proved this frame was
            // never visual-bound. Existing exact REJECT recovery requests a
            // fresh IDR; no old color or timestamp is replayed.
            tokio::time::timeout(
                remaining_session(session_deadline)?,
                write_record(&mut tx, REJECT, &tag.encode()),
            )
            .await
            .context("coded receiver session timed out writing expired REJECT")??;
            continue 'frames;
        }
        if disposition != NativeCompletion::Presented(tag.frame) {
            bail!("unexpected non-presenter live disposition")
        }
        if !fresh(cp.source_submitted_ns, estimate, clock.now_ns()) {
            bail!("coded frame became late after presenter submission ACK")
        };
        write_record(&mut tx, PRESENTER_ACK, &tag.encode()).await?;
        // The source cannot authorize a captured frame until this exact video
        // receipt arrives. Start its shared-UNI input exchange only now, not
        // during codec warmup, while the existing video bi-stream stays owned
        // by this loop. Neither reader can accept the other's stream type.
        if pointer_input.is_none() {
            if let Some(forwarding) = o.forward_pointer_motion {
                pointer_input = Some(PointerInputTask::start(&c, &presenter, &clock, forwarding)?);
            }
        }
    }
    Ok(())
    }.await;
    c.close(0_u32.into(), b"media attempt retiring");
    let input_cleanup = if let Some(input) = &mut pointer_input {
        input.stop().await
    } else {
        Ok(())
    };
    let presenter_cleanup = presenter.shutdown();
    finish_native_attempt(
        finish_input_attempt(attempt_result, input_cleanup),
        presenter_cleanup,
    )
}
#[cfg(not(windows))]
async fn receive(_o: Options, _ep: &Endpoint) -> Result<()> {
    std::future::ready(()).await;
    bail!("coded receive requires Windows GPU presenter")
}

#[cfg(windows)]
fn limits(max: usize, w: u32, h: u32) -> CodecResourceLimits {
    CodecResourceLimits {
        max_coded_width: w,
        max_coded_height: h,
        max_luma_samples: u64::from(w) * u64::from(h),
        max_decoded_bytes: u64::try_from(max).unwrap_or(u64::MAX),
    }
}
fn load_identity(o: &Options) -> Result<PeerIdentity> {
    PeerIdentity::from_pem(
        &std::fs::read(&o.cert).context("read paired certificate")?,
        &std::fs::read(&o.key).context("read paired private key")?,
        &std::fs::read(&o.ca).context("read paired CA certificate")?,
    )
    .map_err(|e| anyhow::anyhow!("parse paired mTLS identity: {e}"))
}
#[derive(Clone)]
struct Clock(Instant);
impl Clock {
    fn new() -> Self {
        Self(Instant::now())
    }
    fn now_ns(&self) -> u64 {
        u64::try_from(self.0.elapsed().as_nanos()).unwrap_or(u64::MAX)
    }
}
#[cfg(any(windows, test))]
fn fresh(source_submitted_ns: u64, estimate: ClockEstimate, now_ns: u64) -> bool {
    now_ns
        .saturating_add(estimate.uncertainty_ns)
        .saturating_sub(source_submitted_ns)
        <= DEADLINE_NS
}

/// A discarded encoded picture can be a decoder reference. After a recovery
/// request, delayed output stays internally matched but only the requested
/// input generation's actual IDR may resume network transmission.
fn sendable_after_recovery(
    awaiting_idr: bool,
    idr_floor: Option<u64>,
    frame_id: u64,
    keyframe: bool,
) -> bool {
    !awaiting_idr || (idr_floor.is_some_and(|floor| frame_id >= floor) && keyframe)
}

#[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FrameControl {
    Reject,
    Ack,
}

/// Both replies are authenticated by QUIC and exact frame identity. A REJECT
/// reports no submission, so it remains recoverable even after that source
/// timestamp expires; an ACK must be freshness-checked by its caller.
#[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
fn classify_frame_control(kind: u8, payload: &[u8], tag: FrameIdentity) -> Result<FrameControl> {
    if FrameIdentity::decode(payload)? != tag {
        bail!("receiver control response did not exactly match window/frame/epoch/config")
    }
    match kind {
        REJECT => Ok(FrameControl::Reject),
        PRESENTER_ACK => Ok(FrameControl::Ack),
        _ => bail!("unexpected receiver control response"),
    }
}

#[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
fn admit_frame_control(
    kind: u8,
    payload: &[u8],
    tag: FrameIdentity,
    source_submitted_ns: u64,
    now_ns: u64,
) -> Result<FrameControl> {
    let control = classify_frame_control(kind, payload, tag)?;
    if control == FrameControl::Ack
        && source_submitted_ns
            .checked_add(DEADLINE_NS)
            .is_none_or(|deadline| now_ns >= deadline)
    {
        bail!("presenter ACK arrived after source freshness deadline")
    }
    Ok(control)
}

#[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
fn control_response_budget(session_deadline: impl Into<MediaLifetime>) -> Option<Duration> {
    session_deadline
        .into()
        .budget(Instant::now())
        .map(|remaining| remaining.min(CONTROL_RESPONSE_WAIT))
}

/// The sender's session clock is the authoritative live-media freshness
/// domain.  This deliberately derives remaining dispatch time from the
/// already-mapped capture timestamp, never from a new 33 ms wall-clock span.
#[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
fn remaining_capture_dispatch_budget(source_submitted_ns: u64, now_ns: u64) -> Option<Duration> {
    source_submitted_ns
        .checked_add(DEADLINE_NS)?
        .checked_sub(now_ns)
        .filter(|remaining| *remaining > 0)
        .map(Duration::from_nanos)
}

/// Await one outbound operation only while its already-established absolute
/// frame deadline remains valid.  `None` means it was expired before polling
/// or elapsed while pending; a completed future is checked again so a ready
/// result observed after the deadline cannot be counted as dispatchable.
#[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
async fn await_dispatch_until<T, F>(operation: F, deadline: Instant) -> Option<T>
where
    F: Future<Output = T>,
{
    if Instant::now() >= deadline {
        return None;
    }
    let result = tokio::time::timeout_at(tokio::time::Instant::from_std(deadline), operation)
        .await
        .ok()?;
    (Instant::now() < deadline).then_some(result)
}

#[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
fn complete_datagram_dispatch(datagram_too_large: bool, expired_dispatch: bool) -> bool {
    !datagram_too_large && !expired_dispatch
}

/// A `TooLarge` result means Quinn's current path/peer datagram budget no
/// longer accepts this fixed fragment layout. The VFCF tag is already in the
/// reliable stream, so stop this pair and wait for its exact REJECT rather
/// than emitting conflicting chunk counts by re-fragmenting in place.
#[cfg(any(test, all(target_os = "linux", feature = "native-nvenc")))]
fn discard_incomplete_frame(error: &SendDatagramError) -> bool {
    matches!(error, SendDatagramError::TooLarge)
}

/// A reliable VFCF record owns one receiver admission slot. Old datagram tails
/// may consume network bandwidth but cannot satisfy a later slot.
#[cfg(any(windows, test))]
fn datagram_matches_frame(packet: &MediaDatagram, tag: FrameIdentity) -> bool {
    packet.window_id == tag.window
        && packet.frame_id == tag.frame
        && packet.geometry_epoch == tag.epoch
        && matches!(packet.plane, MediaPlane::Color | MediaPlane::Alpha)
}

/// The per-frame read must not inherit the full session allowance. `None`
/// maps to a recoverable exact `REJECT`; session expiry itself remains fatal.
#[cfg(any(windows, test))]
fn frame_datagram_budget(deadline: Instant) -> Option<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|remaining| !remaining.is_zero())
}

#[cfg(any(windows, test))]
fn remaining_session(deadline: impl Into<MediaLifetime>) -> Result<Duration> {
    deadline
        .into()
        .budget(Instant::now())
        .context("coded receiver session deadline elapsed")
}

/// A presentation reserve is deliberately applied only while deriving the
/// native QPC deadline. It cannot make a frame fresh, change its ACK deadline,
/// or extend the post-freshness Expired disposition grace.
#[cfg(any(windows, test))]
fn native_deadline_budget_after_presentation_reserve(
    remaining: Duration,
    reserve: Duration,
) -> Option<Duration> {
    remaining
        .checked_sub(reserve)
        .filter(|budget| !budget.is_zero())
}

/// Remaining wall-clock budget from the source timestamp, after reserving the
/// clock estimate's uncertainty. `source_submitted_ns` is already mapped to
/// this receiver's monotonic epoch by `MediaAssembler::push_any_remote`.
#[cfg(windows)]
fn remaining_freshness_budget(
    source_submitted_ns: u64,
    estimate: ClockEstimate,
    now_ns: u64,
) -> Option<Duration> {
    source_submitted_ns
        .checked_add(DEADLINE_NS)?
        .checked_sub(estimate.uncertainty_ns)?
        .checked_sub(now_ns)
        .map(Duration::from_nanos)
}

/// Wait for precisely one native disposition. The caller owns the fixed
/// freshness/disposition deadlines; this helper never derives a new one.
#[cfg(any(windows, test))]
fn wait_for_presenter_completion(
    acknowledgement: &Mutex<Option<NativeCompletion>>,
    changed: &Condvar,
    closed: &AtomicBool,
    expected: ExpectedNativeCompletion,
    deadline: Instant,
) -> std::result::Result<NativeCompletion, String> {
    let mut acknowledgement = acknowledgement.lock().expect("presenter ACK lock");
    while acknowledgement.is_none() && !closed.load(Ordering::Acquire) {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| "compressed presenter disposition timed out".to_owned())?;
        let (next, result) = changed
            .wait_timeout(acknowledgement, remaining)
            .expect("presenter ACK wait");
        acknowledgement = next;
        if result.timed_out() && acknowledgement.is_none() {
            return Err("compressed presenter disposition timed out".to_owned());
        }
    }
    let got = acknowledgement
        .take()
        .ok_or_else(|| "compressed presenter closed before disposition".to_owned())?;
    // A wakeup or an already-populated slot is not evidence it arrived within
    // the fixed grace. Consume nothing after that absolute deadline.
    if Instant::now() >= deadline {
        return Err("compressed presenter disposition timed out".to_owned());
    }
    let matches = matches!(
        (expected, got),
        (ExpectedNativeCompletion::Presented(expected), NativeCompletion::Presented(actual))
            | (ExpectedNativeCompletion::DecodeOnly(expected), NativeCompletion::DecodeOnly(actual))
            | (ExpectedNativeCompletion::PresentedOrExpired(expected), NativeCompletion::Presented(actual))
            | (ExpectedNativeCompletion::PresentedOrExpired(expected), NativeCompletion::Expired(actual))
            if expected == actual
    );
    if !matches {
        return Err(format!(
            "native completion {got:?} cannot satisfy {expected:?}"
        ));
    }
    Ok(got)
}

#[cfg(any(windows, test))]
fn validate_live_native_completion(
    completion: NativeCompletion,
    identity: u64,
    freshness_deadline: Instant,
) -> std::result::Result<NativeCompletion, String> {
    match completion {
        NativeCompletion::Expired(actual) if actual == identity => Ok(completion),
        NativeCompletion::Presented(actual) if actual == identity => {
            if Instant::now() >= freshness_deadline {
                Err("coded frame became late after presenter ACK".to_owned())
            } else {
                Ok(completion)
            }
        }
        _ => Err(format!(
            "native completion {completion:?} cannot satisfy live frame {identity}"
        )),
    }
}

/// Wait for the one-slot worker queue using the queue mutex as the shutdown
/// predicate mutex. This is intentionally generic so the idle-shutdown rule is
/// exercised without a Windows child process.
#[cfg(any(windows, test))]
fn take_presenter_slot<T>(
    latest: &Mutex<Option<T>>,
    ready: &Condvar,
    closed: &AtomicBool,
) -> Option<T> {
    let mut latest = latest.lock().expect("presenter queue lock");
    while latest.is_none() && !closed.load(Ordering::Acquire) {
        latest = ready.wait(latest).expect("presenter queue wait");
    }
    latest.take()
}
async fn clock_exchange_client(
    tx: &mut SendStream,
    rx: &mut RecvStream,
    clock: &Clock,
) -> Result<ClockEstimate> {
    let t0 = clock.now_ns();
    write_record(tx, CLOCK_PROBE, &t0.to_be_bytes()).await?;
    let r = read_record(rx, CLOCK_REPLY, 16).await?;
    let t3 = clock.now_ns();
    let e = ClockEstimate::from_exchange(
        t0,
        u64::from_be_bytes(r[..8].try_into()?),
        u64::from_be_bytes(r[8..].try_into()?),
        t3,
    )?;
    eprintln!(
        "clock estimate network_rtt_us={} uncertainty_us={}",
        e.network_round_trip_ns / 1000,
        e.uncertainty_ns / 1000
    );
    let mut b = Vec::new();
    b.extend_from_slice(&e.remote_offset_ns.to_be_bytes());
    b.extend_from_slice(&e.network_round_trip_ns.to_be_bytes());
    b.extend_from_slice(&e.uncertainty_ns.to_be_bytes());
    write_record(tx, CLOCK_ESTIMATE, &b).await?;
    Ok(e)
}
#[cfg(windows)]
async fn clock_exchange_server(
    tx: &mut SendStream,
    rx: &mut RecvStream,
    clock: &Clock,
) -> Result<ClockEstimate> {
    let _p = read_record(rx, CLOCK_PROBE, 8).await?;
    let t1 = clock.now_ns();
    let t2 = clock.now_ns();
    let mut r = Vec::new();
    r.extend_from_slice(&t1.to_be_bytes());
    r.extend_from_slice(&t2.to_be_bytes());
    write_record(tx, CLOCK_REPLY, &r).await?;
    let b = read_record(rx, CLOCK_ESTIMATE, 24).await?;
    let sender_to_receiver = ClockEstimate {
        remote_offset_ns: i64::from_be_bytes(b[..8].try_into()?),
        network_round_trip_ns: u64::from_be_bytes(b[8..16].try_into()?),
        uncertainty_ns: u64::from_be_bytes(b[16..].try_into()?),
    };
    // The sender measured receiver-minus-sender. At this receiver the remote
    // media timestamp belongs to the sender, so normalize to sender-minus-
    // receiver before `push_any_remote` admission.
    sender_to_receiver
        .inverse()
        .map_err(|error| anyhow::anyhow!("clock offset cannot be inverted: {error}"))
}
async fn write_record(s: &mut SendStream, k: u8, b: &[u8]) -> Result<()> {
    let n = u16::try_from(b.len())?;
    s.write_all(&[k]).await?;
    s.write_all(&n.to_be_bytes()).await?;
    s.write_all(b).await?;
    Ok(())
}
/// A warmup AU can exceed the live datagram MTU and the control record's u16
/// length. Chunking is reliable, bounded, ordered, and startup-only.
#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
async fn write_warmup_blob(
    source: &mut CaptureSource,
    s: &mut SendStream,
    kind: u8,
    blob: &[u8],
    startup_deadline: Instant,
) -> Result<()> {
    if blob.is_empty() {
        bail!("empty warmup plane")
    }
    for chunk in blob.chunks(MAX_WARMUP_CONTROL_CHUNK) {
        write_startup_record(source, s, kind, chunk, startup_deadline).await?;
    }
    Ok(())
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
async fn write_startup_record(
    source: &mut CaptureSource,
    s: &mut SendStream,
    kind: u8,
    payload: &[u8],
    startup_deadline: Instant,
) -> Result<()> {
    poll_with_drain(
        write_record(s, kind, payload),
        startup_deadline,
        "coded startup deadline elapsed before control write",
        || drain_unencoded_capture(source),
    )
    .await
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
fn write_warmup_alpha_sample(path: &str, payload: &bytes::Bytes) -> Result<()> {
    use std::{fs::OpenOptions, io::Write, os::unix::fs::OpenOptionsExt};
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("create warmup alpha sample {path}"))?;
    output.write_all(payload)?;
    output.flush()?;
    eprintln!(
        "wrote verified warmup VFAR sample bytes={} path={path}",
        payload.len()
    );
    Ok(())
}

#[cfg(windows)]
async fn read_warmup_blob(
    s: &mut RecvStream,
    kind: u8,
    length: usize,
    max: usize,
) -> Result<Vec<u8>> {
    if length == 0 || length > max {
        bail!("invalid warmup plane length")
    }
    let mut blob = Vec::with_capacity(length);
    while blob.len() < length {
        let chunk =
            read_record(s, kind, (length - blob.len()).min(MAX_WARMUP_CONTROL_CHUNK)).await?;
        if chunk.is_empty() {
            bail!("empty warmup control chunk")
        }
        blob.extend_from_slice(&chunk);
    }
    Ok(blob)
}
async fn read_record(s: &mut RecvStream, k: u8, n: usize) -> Result<Vec<u8>> {
    let (got, b) = read_any_record(s)
        .await?
        .context("control stream ended before required record")?;
    if got != k || b.len() != n {
        bail!("unexpected control record")
    }
    Ok(b)
}
async fn read_any_record(s: &mut RecvStream) -> Result<Option<(u8, Vec<u8>)>> {
    let Some(kind) = read_first_byte(s).await? else {
        return Ok(None);
    };
    let mut h = [0; 2];
    read_exact(s, &mut h)
        .await
        .context("truncated control header")?;
    let mut b = vec![0; usize::from(u16::from_be_bytes(h))];
    read_exact(s, &mut b)
        .await
        .context("truncated control payload")?;
    Ok(Some((kind, b)))
}
async fn read_first_byte<R: AsyncRead + Unpin>(s: &mut R) -> std::io::Result<Option<u8>> {
    let mut byte = [0; 1];
    std::future::poll_fn(|cx| {
        let mut read_buf = ReadBuf::new(&mut byte);
        match Pin::new(&mut *s).poll_read(cx, &mut read_buf) {
            Poll::Ready(Ok(())) if read_buf.filled().is_empty() => Poll::Ready(Ok(None)),
            Poll::Ready(Ok(())) => Poll::Ready(Ok(Some(byte[0]))),
            Poll::Ready(Err(error)) => Poll::Ready(Err(error)),
            Poll::Pending => Poll::Pending,
        }
    })
    .await
}
async fn read_exact<R: AsyncRead + Unpin>(s: &mut R, b: &mut [u8]) -> std::io::Result<()> {
    let mut filled = 0;
    std::future::poll_fn(|cx| {
        while filled < b.len() {
            let mut rb = ReadBuf::new(&mut b[filled..]);
            match Pin::new(&mut *s).poll_read(cx, &mut rb) {
                Poll::Ready(Ok(())) if rb.filled().is_empty() => {
                    return Poll::Ready(Err(std::io::Error::new(
                        std::io::ErrorKind::UnexpectedEof,
                        "control stream ended",
                    )));
                }
                Poll::Ready(Ok(())) => filled += rb.filled().len(),
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending => return Poll::Pending,
            }
        }
        Poll::Ready(Ok(()))
    })
    .await
}

#[cfg(windows)]
#[allow(unsafe_code)] // Win32 only writes the two valid local i64 output slots.
fn native_qpc_sample() -> Result<(u64, u64)> {
    use windows_sys::Win32::System::Performance::{
        QueryPerformanceCounter, QueryPerformanceFrequency,
    };
    let mut frequency = 0_i64;
    let mut ticks = 0_i64;
    // SAFETY: the APIs synchronously fill valid pointers and retain neither.
    if unsafe { QueryPerformanceFrequency(&raw mut frequency) } == 0 || frequency <= 0 {
        bail!("native QPC frequency unavailable");
    }
    if unsafe { QueryPerformanceCounter(&raw mut ticks) } == 0 || ticks < 0 {
        bail!("native QPC counter unavailable");
    }
    Ok((u64::try_from(ticks)?, u64::try_from(frequency)?))
}

fn presentation_reserve_us(value: &str) -> Result<Duration> {
    // Keep this wire-visible operator input canonical: an ASCII decimal zero
    // or a nonzero decimal without a leading zero. That avoids accepting a
    // value the native CLI contract would render differently in diagnostics.
    if value.is_empty()
        || !value.bytes().all(|byte| byte.is_ascii_digit())
        || (value.len() > 1 && value.starts_with('0'))
    {
        bail!("--presentation-reserve-us must be a canonical integer 0..10000")
    }
    let micros: u64 = value
        .parse()
        .context("--presentation-reserve-us must be a canonical integer 0..10000")?;
    if micros > 10_000 {
        bail!("--presentation-reserve-us must be in 0..10000")
    }
    Ok(Duration::from_micros(micros))
}

#[allow(clippy::too_many_lines)] // Validation is intentionally co-located with CLI parsing.
fn parse_options_from<I>(args: I) -> Result<Options>
where
    I: IntoIterator<Item = String>,
{
    let mut a = args.into_iter();
    let role = a
        .next()
        .context("usage: coded_window_peer <send|receive> [options]")?;
    let mut v = BTreeMap::new();
    while let Some(k) = a.next() {
        let k = k.strip_prefix("--").context("options start --")?.to_owned();
        let x = if k == "capture-gpu"
            || k == "require-deadline-v4"
            || k == "recover-expired-v4"
            || k == "emit-pointer-motion"
            || k == "forward-pointer-motion"
            || k == "forward-pointer-buttons"
            || k == "authorize-pointer-motion"
            || k == "authorize-pointer-buttons"
            || k == "alpha-reuse-warmup"
            || k == "persistent"
            || k == "reconnect"
        {
            "true".to_owned()
        } else {
            a.next().with_context(|| format!("--{k} needs a value"))?
        };
        if v.insert(k, x).is_some() {
            bail!("duplicate option")
        }
    }
    let req = |k: &str| v.get(k).cloned().with_context(|| format!("missing --{k}"));
    let persistent = v.contains_key("persistent");
    let reconnect = v.contains_key("reconnect");
    if reconnect && !persistent {
        bail!("--reconnect requires --persistent");
    }
    if persistent && v.contains_key("warmup-alpha-output") {
        bail!("--persistent cannot own a one-shot --warmup-alpha-output artifact");
    }
    let timeout = Duration::from_millis(v.get("timeout-ms").map_or(Ok(10000), |x| x.parse())?);
    if timeout.is_zero() {
        bail!("--timeout-ms must be positive");
    }
    let logical = match (v.get("logical-width"), v.get("logical-height")) {
        (Some(w), Some(h)) => Some(LogicalSize::checked(w.parse()?, h.parse()?)?),
        (None, None) => None,
        _ => bail!("both logical dimensions required"),
    };
    let max_frame_bytes = v
        .get("max-frame-bytes")
        .map_or(Ok(DEFAULT_MAX_FRAME_BYTES), |x| x.parse())?;
    if max_frame_bytes == 0 {
        bail!("--max-frame-bytes must be positive")
    }
    let blur_radius = v
        .get("composition-blur-radius")
        .map(|x| x.parse::<f64>())
        .transpose()?;
    if blur_radius.is_some_and(|x| !x.is_finite() || x <= 0.0) {
        bail!("--composition-blur-radius must be positive finite")
    }
    if v.contains_key("warmup-alpha-output") && role != "send" {
        bail!("--warmup-alpha-output is valid only with send")
    }
    if v.contains_key("require-deadline-v4")
        && (role != "receive" || !v.contains_key("stdin-compressed"))
    {
        bail!("--require-deadline-v4 requires receive with --stdin-compressed")
    }
    if v.contains_key("recover-expired-v4")
        && (role != "receive"
            || !v.contains_key("stdin-compressed")
            || !v.contains_key("require-deadline-v4"))
    {
        bail!("--recover-expired-v4 requires receive --stdin-compressed and --require-deadline-v4")
    }
    if v.contains_key("emit-pointer-motion")
        && (role != "receive"
            || !v.contains_key("stdin-compressed")
            || !v.contains_key("require-deadline-v4"))
    {
        bail!("--emit-pointer-motion requires receive --stdin-compressed and --require-deadline-v4")
    }
    let forward_pointer_buttons = v.contains_key("forward-pointer-buttons");
    if forward_pointer_buttons && !v.contains_key("forward-pointer-motion") {
        bail!("--forward-pointer-buttons requires --forward-pointer-motion");
    }
    let forward_pointer_motion = if v.contains_key("forward-pointer-motion") {
        if role != "receive" || !v.contains_key("emit-pointer-motion") {
            bail!("--forward-pointer-motion requires receive with --emit-pointer-motion");
        }
        let owner = pointer_device_id(&req("pointer-owner-id")?)?;
        let source = pointer_device_id(&req("pointer-source-id")?)?;
        if owner == source {
            bail!("pointer owner and source must differ");
        }
        Some(PointerForwarding { owner, source })
    } else {
        if !v.contains_key("authorize-pointer-motion")
            && (v.contains_key("pointer-owner-id") || v.contains_key("pointer-source-id"))
        {
            bail!("pointer device IDs require --forward-pointer-motion");
        }
        None
    };
    let authorize_pointer_buttons = v.contains_key("authorize-pointer-buttons");
    if authorize_pointer_buttons && !v.contains_key("authorize-pointer-motion") {
        bail!("--authorize-pointer-buttons requires --authorize-pointer-motion");
    }
    let authorize_pointer_motion = if v.contains_key("authorize-pointer-motion") {
        if role != "send"
            || !v.contains_key("capture-gpu")
            || !v.contains_key("compositor-pid")
            || !v.contains_key("pointer-native-socket")
        {
            bail!(
                "--authorize-pointer-motion requires send --capture-gpu --compositor-pid --pointer-native-socket"
            );
        }
        let owner = pointer_device_id(&req("pointer-owner-id")?)?;
        let source = pointer_device_id(&req("pointer-source-id")?)?;
        if owner == source {
            bail!("pointer owner and source must differ");
        }
        Some(PointerForwarding { owner, source })
    } else {
        if v.contains_key("pointer-native-socket") {
            bail!("--pointer-native-socket requires --authorize-pointer-motion");
        }
        None
    };
    let presentation_reserve = v
        .get("presentation-reserve-us")
        .map_or(Ok(Duration::ZERO), |x| presentation_reserve_us(x))?;
    if v.contains_key("presentation-reserve-us") && role != "receive" {
        bail!("--presentation-reserve-us is valid only with receive")
    }
    if !presentation_reserve.is_zero()
        && (role != "receive"
            || !v.contains_key("stdin-compressed")
            || !v.contains_key("require-deadline-v4")
            || !v.contains_key("recover-expired-v4"))
    {
        bail!(
            "nonzero --presentation-reserve-us requires receive --stdin-compressed --require-deadline-v4 --recover-expired-v4"
        )
    }
    let warmup_frames = v
        .get("warmup-frames")
        .map_or(Ok(DEFAULT_WARMUP_FRAMES), |x| warmup_frame_count(x))?;
    if requires_warmup_plan(warmup_frames) {
        match role.as_str() {
            "send" if v.contains_key("capture-stream") && v.contains_key("capture-gpu") => {}
            "receive" if v.contains_key("stdin-compressed") => {}
            "send" => bail!("--warmup-frames 3 requires send --capture-stream and --capture-gpu"),
            "receive" => bail!("--warmup-frames 3 requires receive --stdin-compressed"),
            _ => bail!("--warmup-frames 3 requires send or receive"),
        }
    }
    if v.contains_key("alpha-reuse-warmup") {
        match role.as_str() {
            "send" if v.contains_key("capture-stream") && v.contains_key("capture-gpu") => {}
            "receive" if v.contains_key("stdin-compressed") => {}
            "send" => {
                bail!("--alpha-reuse-warmup requires send --capture-stream and --capture-gpu")
            }
            "receive" => bail!("--alpha-reuse-warmup requires receive --stdin-compressed"),
            _ => bail!("--alpha-reuse-warmup requires send or receive"),
        }
    }
    Ok(Options {
        role,
        cert: req("cert")?,
        key: req("key")?,
        ca: req("ca")?,
        remote: v.get("remote").map(|x| x.parse()).transpose()?,
        listen: v.get("listen").map(|x| x.parse()).transpose()?,
        server_name: v.get("server-name").cloned(),
        capture_stream: v.get("capture-stream").cloned(),
        warmup_alpha_output: v.get("warmup-alpha-output").cloned(),
        capture_gpu: v.contains_key("capture-gpu"),
        compositor_pid: v.get("compositor-pid").map(|x| x.parse()).transpose()?,
        logical,
        blur: v
            .get("composition-blur-rect")
            .map(|x| BlurRect::parse(x))
            .transpose()?,
        blur_radius,
        presenter: v.get("stdin-compressed").cloned(),
        require_deadline_v4: v.contains_key("require-deadline-v4"),
        recover_expired_v4: v.contains_key("recover-expired-v4"),
        presentation_reserve,
        emit_pointer_motion: v.contains_key("emit-pointer-motion"),
        forward_pointer_motion,
        forward_pointer_buttons,
        authorize_pointer_motion,
        authorize_pointer_buttons,
        pointer_native_socket: v.get("pointer-native-socket").cloned(),
        warmup_frames,
        alpha_reuse_warmup: v.contains_key("alpha-reuse-warmup"),
        max_frame_bytes,
        timeout,
        persistent,
        reconnect,
    })
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn real_quic_idle_timeout_preserves_stream_and_control_retry_causes() {
        let identity = PeerIdentity::from_pem(
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
            include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
        )
        .unwrap();
        let mut config = viewflow_transport::build_server_config(&identity).unwrap();
        std::sync::Arc::get_mut(&mut config.transport)
            .unwrap()
            .max_idle_timeout(Some(Duration::from_millis(500).try_into().unwrap()));
        let server = Endpoint::server(config, "127.0.0.1:0".parse().unwrap()).unwrap();
        let mut client = Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client
            .set_default_client_config(viewflow_transport::build_client_config(&identity).unwrap());
        tokio::time::timeout(Duration::from_secs(5), async {
            let connect = client
                .connect(server.local_addr().unwrap(), "localhost")
                .unwrap();
            let (outgoing, incoming) =
                tokio::join!(connect, async { server.accept().await.unwrap().await });
            let outgoing = outgoing.unwrap();
            let incoming = incoming.unwrap();
            let (mut writer, _reply) = outgoing.open_bi().await.unwrap();
            writer.write_all(&[1]).await.unwrap();
            let (_writer, mut reader) = incoming.accept_bi().await.unwrap();
            assert_eq!(read_first_byte(&mut reader).await.unwrap(), Some(1));
            // Keep both endpoints and streams alive; only the negotiated idle
            // timeout ends the connection, not an explicit test-harness close.
            let (stream, control) = tokio::join!(
                read_first_byte(&mut reader),
                viewflow_transport::receive_control(&incoming)
            );
            let stream = anyhow::Error::new(stream.unwrap_err()).context(NativeInputTaskFailure);
            let control = anyhow::Error::new(control.unwrap_err());
            assert!(matches!(
                incoming.close_reason(),
                Some(quinn::ConnectionError::TimedOut)
            ));
            assert!(retryable_media_transport(&stream));
            assert!(retryable_media_transport(&control));
            let combined = finish_input_attempt(Err(control), Err(stream)).unwrap_err();
            assert!(retryable_media_transport(&combined));
            assert!(!retryable_media_transport(
                &combined.context(NativeCleanupFailure)
            ));
            drop(writer);
        })
        .await
        .unwrap();
    }

    #[test]
    fn stream_retry_uses_typed_connection_loss_not_io_kind_or_stream_reset() {
        for cause in [
            quinn::ConnectionError::Reset,
            quinn::ConnectionError::TimedOut,
        ] {
            let read: std::io::Error = quinn::ReadError::ConnectionLost(cause.clone()).into();
            let write: std::io::Error = quinn::WriteError::ConnectionLost(cause).into();
            assert!(retryable_media_transport(
                &anyhow::Error::new(read).context(NativeInputTaskFailure)
            ));
            assert!(retryable_media_transport(&anyhow::Error::new(write)));
        }
        for error in [
            std::io::Error::new(std::io::ErrorKind::ConnectionReset, "native reset"),
            quinn::ReadError::Reset(0_u32.into()).into(),
            quinn::WriteError::Stopped(0_u32.into()).into(),
            quinn::ReadError::ConnectionLost(quinn::ConnectionError::LocallyClosed).into(),
        ] {
            assert!(!retryable_media_transport(&anyhow::Error::new(error)));
        }
    }

    #[test]
    fn retry_policy_never_promotes_native_cleanup_or_local_policy_failures() {
        assert!(retryable_media_transport(&anyhow::Error::new(
            MediaConnectTimeout
        )));
        for cause in [
            quinn::ConnectionError::Reset,
            quinn::ConnectionError::TimedOut,
        ] {
            assert!(retryable_media_transport(&anyhow::Error::new(
                cause.clone()
            )));
            assert!(retryable_media_transport(
                &anyhow::Error::new(cause.clone()).context(NativeInputTaskFailure)
            ));
            assert!(!retryable_media_transport(
                &anyhow::Error::new(cause).context(NativeCleanupFailure)
            ));
        }
        for cause in [
            quinn::ConnectionError::LocallyClosed,
            quinn::ConnectionError::VersionMismatch,
            quinn::ConnectionError::CidsExhausted,
        ] {
            assert!(!retryable_media_transport(&anyhow::Error::new(cause)));
        }
        assert!(!retryable_media_transport(&anyhow::anyhow!("timed out")));
    }

    #[tokio::test]
    async fn liveness_retry_requires_checked_input_retirement_and_no_independent_failure() {
        for unconfirmed in [false, true] {
            let flag = std::sync::atomic::AtomicBool::new(unconfirmed);
            let error = crate::guard_liveness_recovery(
                Err(anyhow::Error::new(crate::PeerLivenessTimeout {
                    probe_id: 1,
                })),
                &flag,
            )
            .unwrap_err()
            .context(NativeInputTaskFailure);
            let error = finish_input_attempt(
                Err(anyhow::Error::new(quinn::ConnectionError::LocallyClosed)),
                Err(error),
            )
            .unwrap_err();
            assert_eq!(retryable_media_transport(&error), !unconfirmed);
            assert_eq!(error.is::<crate::InputRecoveryUnconfirmed>(), unconfirmed);
        }
        let mut task = tokio::spawn(async {
            Err(anyhow::Error::new(crate::PeerLivenessTimeout {
                probe_id: 2,
            }))
        });
        let input = retire_input_task(&mut task, Duration::from_secs(1)).await;
        let closed: std::io::Error =
            quinn::ReadError::ConnectionLost(quinn::ConnectionError::LocallyClosed).into();
        let result = finish_input_attempt(Err(closed.into()), input).unwrap_err();
        assert!(retryable_media_transport(&result));
        assert!(!retryable_media_transport(
            &result.context(NativeCleanupFailure)
        ));
        for media in [
            anyhow::anyhow!("native frame deadline expired"),
            anyhow::Error::new(quinn::ConnectionError::LocallyClosed).context(NativeCleanupFailure),
            anyhow::Error::new(quinn::ConnectionError::LocallyClosed)
                .context(crate::InputRecoveryUnconfirmed),
            anyhow::Error::new(quinn::ConnectionError::VersionMismatch),
        ] {
            let input = anyhow::Error::new(crate::PeerLivenessTimeout { probe_id: 3 })
                .context(NativeInputTaskFailure);
            let error = finish_input_attempt(Err(media), Err(input)).unwrap_err();
            assert!(!retryable_media_transport(&error));
        }
        let local_close = || anyhow::Error::new(quinn::ConnectionError::LocallyClosed);
        assert!(!retryable_media_transport(&local_close()));
        let error = finish_input_attempt(
            Err(local_close()),
            Err(anyhow::anyhow!("clock probe 2 timed out").context(NativeInputTaskFailure)),
        )
        .unwrap_err();
        assert!(!retryable_media_transport(&error));
    }

    #[test]
    fn combined_retry_requires_both_typed_causes_to_be_transport_failures() {
        let transport = || anyhow::Error::new(quinn::ConnectionError::TimedOut);
        let combined = |media, input: anyhow::Error| {
            finish_input_attempt(Err(media), Err(input.context(NativeInputTaskFailure)))
                .unwrap_err()
        };
        let error = combined(transport(), transport());
        assert!(retryable_media_transport(&error));
        assert!(
            error
                .downcast_ref::<AccompanyingMediaFailure>()
                .unwrap()
                .0
                .is::<quinn::ConnectionError>()
        );
        assert!(!retryable_media_transport(&combined(
            anyhow::anyhow!("frame invariant failed"),
            transport()
        )));
        assert!(!retryable_media_transport(&combined(
            transport(),
            std::io::Error::new(std::io::ErrorKind::TimedOut, "native ACK").into()
        )));
        assert!(!retryable_media_transport(&combined(
            transport().context(NativeCleanupFailure),
            transport()
        )));
        assert!(!retryable_media_transport(&combined(
            transport(),
            transport().context(NativeCleanupFailure)
        )));
    }

    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    #[tokio::test]
    async fn reconnect_reuses_endpoint_and_shutdown_interrupts_backoff() {
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let mut peer = lifecycle_peer(socket.local_addr().unwrap());
        peer.options.persistent = true;
        peer.options.timeout = Duration::from_millis(20);
        let bound = peer.local_addr().unwrap();
        let report = tokio::time::timeout(
            Duration::from_secs(3),
            peer.run_reconnecting_until_shutdown(async {
                tokio::time::sleep(Duration::from_secs(2)).await;
            }),
        )
        .await
        .unwrap();
        assert!(report.shutdown_requested);
        assert!(report.result.unwrap_err().is::<MediaConnectTimeout>());
        assert!(peer.attempt() >= 2);
        assert_eq!(peer.local_addr().unwrap(), bound);
        assert!(!peer.runnable);
    }

    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    #[tokio::test]
    async fn cancelling_reconnect_during_backoff_fences_owner() {
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let mut peer = lifecycle_peer(socket.local_addr().unwrap());
        peer.options.persistent = true;
        peer.options.timeout = Duration::from_millis(10);
        assert!(
            tokio::time::timeout(
                Duration::from_millis(75),
                peer.run_reconnecting_until_shutdown(std::future::pending())
            )
            .await
            .is_err()
        );
        assert_eq!(peer.retry_delay, Some(Duration::from_millis(250)));
        assert_eq!(peer.attempt(), 1);
        assert!(!peer.runnable);
        assert!(peer.run_next().await.is_err());
    }
    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    #[tokio::test]
    async fn cancelled_source_stop_retains_the_abort_on_drop_owner() {
        struct Dropped(Option<tokio::sync::oneshot::Sender<()>>);
        impl Drop for Dropped {
            fn drop(&mut self) {
                if let Some(sender) = self.0.take() {
                    let _ = sender.send(());
                }
            }
        }
        let (sender, dropped) = tokio::sync::oneshot::channel();
        let marker = Dropped(Some(sender));
        let task = tokio::spawn(async move {
            let _marker = marker;
            std::future::pending::<()>().await;
            Ok(())
        });
        let directory = tempfile::tempdir().unwrap();
        let mut owner = SourcePointerTask {
            allow_buttons: false,
            native: None,
            updates: None,
            task: Some(task),
            path: directory.path().join("absent.sock"),
            socket_identity: (0, 0),
            generation: 0,
            expires: 0,
        };
        assert!(
            tokio::time::timeout(Duration::from_millis(1), owner.stop())
                .await
                .is_err()
        );
        assert!(owner.task.is_some());
        drop(owner);
        tokio::time::timeout(Duration::from_secs(1), dropped)
            .await
            .unwrap()
            .unwrap();
    }
    #[tokio::test]
    async fn input_task_error_survives_accompanying_media_close() {
        let mut task = tokio::spawn(async {
            tokio::task::yield_now().await;
            Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "native ACK fixture").into())
        });
        let input = retire_input_task(&mut task, Duration::from_secs(1)).await;
        let error = finish_input_attempt(Err(anyhow::anyhow!("media connection closed")), input)
            .unwrap_err();
        assert!(error.is::<NativeInputTaskFailure>());
        assert!(!error.is::<NativeCleanupFailure>());
        assert_eq!(
            error.downcast_ref::<std::io::Error>().unwrap().kind(),
            std::io::ErrorKind::TimedOut
        );
        let text = format!("{error:#}");
        assert!(text.contains("native ACK fixture"));
        assert!(text.contains("media connection closed"));
    }

    #[tokio::test]
    async fn input_task_retirement_reports_success_and_panic_separately() {
        let mut success = tokio::spawn(async { Ok(()) });
        assert!(
            retire_input_task(&mut success, Duration::from_secs(1))
                .await
                .is_ok()
        );
        let mut panic = tokio::spawn(async {
            panic!("input retirement fixture");
            #[allow(unreachable_code)]
            Ok(())
        });
        assert!(
            retire_input_task(&mut panic, Duration::from_secs(1))
                .await
                .unwrap_err()
                .is::<NativeCleanupFailure>()
        );
    }

    #[tokio::test]
    async fn input_task_timeout_awaits_drop_and_remains_cleanup_failure() {
        use std::sync::atomic::{AtomicBool, Ordering};
        struct Dropped(std::sync::Arc<AtomicBool>);
        impl Drop for Dropped {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        let dropped = std::sync::Arc::new(AtomicBool::new(false));
        let marker = Dropped(dropped.clone());
        let mut task = tokio::spawn(async move {
            let _marker = marker;
            std::future::pending::<()>().await;
            Ok(())
        });
        let error = retire_input_task(&mut task, Duration::from_millis(1))
            .await
            .unwrap_err();
        assert!(error.is::<NativeCleanupFailure>());
        assert!(dropped.load(Ordering::SeqCst));
        assert!(task.is_finished());
    }
    #[tokio::test]
    async fn shutdown_awaits_retirement_and_preserves_its_failure() {
        let (closed, observed) = tokio::sync::oneshot::channel();
        let retired = std::cell::Cell::new(false);
        let work = async {
            observed.await.unwrap();
            tokio::task::yield_now().await;
            retired.set(true);
            Err(anyhow::Error::new(NativeCleanupFailure))
        };
        let report = finish_on_shutdown(work, std::future::ready(()), || {
            closed.send(()).unwrap();
        })
        .await;
        assert!(report.shutdown_requested);
        assert!(retired.get());
        assert!(report.result.unwrap_err().is::<NativeCleanupFailure>());
    }

    #[tokio::test]
    async fn completed_attempt_does_not_close_endpoint_for_a_simultaneous_stop() {
        let closed = std::cell::Cell::new(false);
        let report = finish_on_shutdown(std::future::ready(Ok(())), std::future::ready(()), || {
            closed.set(true)
        })
        .await;
        assert!(!report.shutdown_requested);
        assert!(report.result.is_ok());
        assert!(!closed.get());
    }

    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    #[tokio::test]
    async fn requested_shutdown_wakes_handshake_and_permanently_retires_owner() {
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let mut peer = lifecycle_peer(socket.local_addr().unwrap());
        let report = tokio::time::timeout(
            Duration::from_secs(2),
            peer.run_next_until_shutdown(async {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }),
        )
        .await
        .unwrap();
        assert!(report.shutdown_requested);
        assert!(report.result.is_err());
        assert!(!report.result.unwrap_err().is::<NativeCleanupFailure>());
        assert_eq!(peer.attempt(), 1);
        assert!(!peer.runnable);
        assert!(peer.run_next().await.is_err());
        assert_eq!(peer.attempt(), 1);
    }
    #[test]
    fn persistent_lifetime_keeps_operation_and_frame_limits_without_a_total_cap() {
        let now = Instant::now();
        let expired = now - Duration::from_millis(1);
        let bounded = MediaLifetime::live(false, expired, Duration::from_secs(3));
        assert!(bounded.budget(now).is_none());
        let live = MediaLifetime::live(true, expired, Duration::from_secs(3));
        assert_eq!(
            live.budget(now + Duration::from_secs(3600)),
            Some(Duration::from_secs(3))
        );
        assert_eq!(
            live.frame_deadline(now, PRESENTER_ACK_WAIT).unwrap(),
            now + PRESENTER_ACK_WAIT
        );
        assert_eq!(control_response_budget(live), Some(CONTROL_RESPONSE_WAIT));
        assert!(remaining_capture_dispatch_budget(1, DEADLINE_NS + 1).is_none());
    }

    #[test]
    fn persistent_cli_is_explicit_and_rejects_zero_wait_or_one_shot_artifacts() {
        let base: Vec<String> = ["send", "--cert", "c", "--key", "k", "--ca", "a"]
            .into_iter()
            .map(str::to_owned)
            .collect();
        assert!(!parse_options_from(base.clone()).unwrap().persistent);
        assert!(!parse_options_from(base.clone()).unwrap().reconnect);
        let mut without_persistent = base.clone();
        without_persistent.push("--reconnect".into());
        assert!(parse_options_from(without_persistent).is_err());
        let mut live = base;
        live.push("--persistent".into());
        assert!(parse_options_from(live.clone()).unwrap().persistent);
        live.push("--reconnect".into());
        assert!(parse_options_from(live.clone()).unwrap().reconnect);
        let mut artifact = live.clone();
        artifact.extend(["--warmup-alpha-output".into(), "unused".into()]);
        assert!(parse_options_from(artifact).is_err());
        live.extend(["--timeout-ms".into(), "0".into()]);
        assert!(parse_options_from(live).is_err());
    }

    #[tokio::test]
    async fn persistent_startup_requires_timely_confirmation_but_not_timely_live_exit() {
        let now = Instant::now();
        let deadline = now - Duration::from_millis(1);
        let (ready, confirmation) = tokio::sync::oneshot::channel();
        ready.send(deadline - Duration::from_millis(1)).unwrap();
        // Live completion after the startup deadline is valid when local
        // startup confirmation actually preceded it.
        run_after_bounded_startup(async { Ok(()) }, confirmation, deadline)
            .await
            .unwrap();
        let (ready, confirmation) = tokio::sync::oneshot::channel();
        ready.send(deadline).unwrap();
        assert!(
            run_after_bounded_startup(std::future::pending(), confirmation, deadline)
                .await
                .is_err()
        );
        let (_ready, confirmation) = tokio::sync::oneshot::channel();
        assert!(
            run_after_bounded_startup(std::future::pending(), confirmation, deadline)
                .await
                .is_err()
        );
        let (ready, confirmation) = tokio::sync::oneshot::channel();
        drop(ready);
        assert!(
            run_after_bounded_startup(
                std::future::pending(),
                confirmation,
                now + Duration::from_secs(1)
            )
            .await
            .is_err()
        );
    }

    #[test]
    fn cleanup_failure_is_preserved_even_when_the_attempt_also_failed() {
        let error = finish_native_attempt(
            Err(anyhow::anyhow!("transport stopped")),
            Err(anyhow::anyhow!("child still alive")),
        )
        .unwrap_err();
        assert!(error.is::<NativeCleanupFailure>());
        let message = format!("{error:#}");
        assert!(message.contains("transport stopped"));
        assert!(message.contains("child still alive"));
        let primary =
            finish_native_attempt(Err(anyhow::anyhow!("transport stopped")), Ok(())).unwrap_err();
        assert!(!primary.is::<NativeCleanupFailure>());
        assert!(finish_native_attempt(Ok(()), Ok(())).is_ok());
    }

    #[test]
    fn presenter_child_fixture() {
        if std::env::var("VIEWFLOW_RETIREMENT_UNIT_CHILD").as_deref() == Ok("sleep") {
            std::thread::sleep(Duration::from_secs(30));
        }
    }

    #[test]
    fn process_retirement_waits_for_owned_running_and_already_exited_children() {
        let mut command = std::process::Command::new(std::env::current_exe().unwrap());
        command
            .args(["--exact", "coded_peer::tests::presenter_child_fixture"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        let mut running = command
            .env("VIEWFLOW_RETIREMENT_UNIT_CHILD", "sleep")
            .spawn()
            .unwrap();
        assert!(running.try_wait().unwrap().is_none());
        retire_presenter_child(&mut running).unwrap();
        assert!(running.try_wait().unwrap().is_some());
        retire_presenter_child(&mut running).unwrap();
        let mut exited = command
            .env_remove("VIEWFLOW_RETIREMENT_UNIT_CHILD")
            .spawn()
            .unwrap();
        assert!(exited.wait().unwrap().success());
        retire_presenter_child(&mut exited).unwrap();
    }

    #[test]
    fn worker_retirement_reports_panic_and_consumes_its_handle() {
        let mut normal = Some(std::thread::spawn(|| {}));
        join_presenter_worker("writer", &mut normal).unwrap();
        assert!(normal.is_none());
        let mut failed = Some(std::thread::spawn(|| panic!("retirement fixture")));
        assert!(
            join_presenter_worker("stdout", &mut failed)
                .unwrap_err()
                .to_string()
                .contains("stdout worker panicked")
        );
        assert!(failed.is_none());
    }

    #[cfg(windows)]
    #[test]
    fn presenter_shutdown_caches_success_and_failure_after_worker_join() {
        // The Rust test process exits on the native presenter's arguments.
        // This exercises real Windows pipe/thread retirement without a GPU/UI.
        let mut presenter = CompressedPresenter::spawn(
            std::env::current_exe().unwrap().to_str().unwrap(),
            LogicalSize::checked(100.0, 100.0).unwrap(),
            BlurRect {
                x: 0,
                y: 0,
                width: 100,
                height: 100,
            },
            1.0,
            1024,
            Clock::new(),
            ClockEstimate {
                remote_offset_ns: 0,
                network_round_trip_ns: 0,
                uncertainty_ns: 0,
            },
            false,
            false,
            false,
            false,
            1,
        )
        .unwrap();
        presenter.shutdown().unwrap();
        assert!(
            presenter
                .child
                .lock()
                .unwrap()
                .try_wait()
                .unwrap()
                .is_some()
        );
        assert!(
            presenter.writer.is_none() && presenter.stdout.is_none() && presenter.stderr.is_none()
        );
        presenter.shutdown().unwrap();
        presenter.retirement = None;
        presenter.stdout = Some(std::thread::spawn(|| panic!("retirement fixture")));
        let first = presenter.shutdown().unwrap_err().to_string();
        assert!(first.contains("stdout worker panicked"));
        assert_eq!(presenter.shutdown().unwrap_err().to_string(), first);
    }

    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    fn lifecycle_peer(remote: SocketAddr) -> NativeMediaPeer {
        let fixtures = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../viewflow-transport/tests/fixtures");
        NativeMediaPeer::bind_from_args([
            "send".into(),
            "--cert".into(),
            fixtures.join("peer.pem").to_str().unwrap().into(),
            "--key".into(),
            fixtures.join("peer.key").to_str().unwrap().into(),
            "--ca".into(),
            fixtures.join("ca.pem").to_str().unwrap().into(),
            "--remote".into(),
            remote.to_string(),
            "--server-name".into(),
            "localhost".into(),
            "--capture-stream".into(),
            "0x1".into(),
            "--compositor-pid".into(),
            "1".into(),
            "--logical-width".into(),
            "100".into(),
            "--logical-height".into(),
            "100".into(),
            "--composition-blur-rect".into(),
            "0,0,100,100".into(),
            "--composition-blur-radius".into(),
            "1".into(),
        ])
        .unwrap()
    }

    #[cfg(windows)]
    fn lifecycle_receiver() -> NativeMediaPeer {
        let fixtures = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../viewflow-transport/tests/fixtures");
        NativeMediaPeer::bind_from_args([
            "receive".into(),
            "--cert".into(),
            fixtures.join("peer.pem").to_str().unwrap().into(),
            "--key".into(),
            fixtures.join("peer.key").to_str().unwrap().into(),
            "--ca".into(),
            fixtures.join("ca.pem").to_str().unwrap().into(),
            "--listen".into(),
            "127.0.0.1:0".into(),
            "--stdin-compressed".into(),
            std::env::current_exe().unwrap().to_str().unwrap().into(),
        ])
        .unwrap()
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn receiver_automatic_retry_accepts_replacement_then_stops_on_policy_close() {
        let mut peer = lifecycle_receiver();
        peer.options.persistent = true;
        let identity = load_identity(&peer.options).unwrap();
        let mut config = viewflow_transport::build_client_config(&identity).unwrap();
        let mut transport = quinn::TransportConfig::default();
        transport.max_idle_timeout(Some(Duration::from_millis(500).try_into().unwrap()));
        config.transport_config(std::sync::Arc::new(transport));
        let mut client = Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(config);
        let bound = peer.local_addr().unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            let producer = async {
                let first = client.connect(bound, "localhost").unwrap().await.unwrap();
                let (mut send, _receive) = first.open_bi().await.unwrap();
                send.write_all(&[1]).await.unwrap();
                assert!(matches!(
                    first.closed().await,
                    quinn::ConnectionError::TimedOut
                ));
                let second = client.connect(bound, "localhost").unwrap().await.unwrap();
                assert_ne!(first.stable_id(), second.stable_id());
                second.close(42_u32.into(), b"explicit policy rejection");
            };
            let owner = peer.run_reconnecting_until_shutdown(std::future::pending());
            let ((), report) = tokio::join!(producer, owner);
            assert!(!report.shutdown_requested);
            let error = report.result.unwrap_err();
            assert!(!retryable_media_transport(&error));
            assert!(error.chain().any(|cause| matches!(
                cause.downcast_ref::<quinn::ConnectionError>(),
                Some(quinn::ConnectionError::ApplicationClosed(_))
            )));
        })
        .await
        .unwrap();
        assert_eq!(peer.attempt(), 2);
        assert_eq!(peer.local_addr().unwrap(), bound);
        assert_eq!(peer.retry_delay, None);
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn requested_shutdown_wakes_idle_receiver_without_starting_presenter() {
        let mut peer = lifecycle_receiver();
        let report = tokio::time::timeout(
            Duration::from_secs(2),
            peer.run_next_until_shutdown(async {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }),
        )
        .await
        .unwrap();
        assert!(report.shutdown_requested);
        assert!(report.result.is_err());
        assert!(!report.result.unwrap_err().is::<NativeCleanupFailure>());
        assert!(!peer.runnable);
        assert_eq!(peer.attempt(), 1);
        assert!(peer.run_next().await.is_err());
        assert_eq!(peer.attempt(), 1);
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn receiver_reuses_endpoint_after_verified_presenter_failure_cleanup() {
        let mut peer = lifecycle_receiver();
        let identity = load_identity(&peer.options).unwrap();
        let mut client = Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client
            .set_default_client_config(viewflow_transport::build_client_config(&identity).unwrap());
        let bound = peer.local_addr().unwrap();
        tokio::time::timeout(Duration::from_secs(10), async {
            let producer = async {
                for _ in 0..2 {
                    let connection = client.connect(bound, "localhost").unwrap().await.unwrap();
                    let (mut send, mut receive) = connection.open_bi().await.unwrap();
                    clock_exchange_client(&mut send, &mut receive, &Clock::new())
                        .await
                        .unwrap();
                    write_record(
                        &mut send,
                        LOGICAL_GEOMETRY,
                        &LogicalSize::checked(100.0, 100.0).unwrap().encode(),
                    )
                    .await
                    .unwrap();
                    write_record(
                        &mut send,
                        BLUR_RECT,
                        &BlurRect::parse("0,0,100,100").unwrap().encode(),
                    )
                    .await
                    .unwrap();
                    write_record(&mut send, BLUR_RADIUS, &1.0_f64.to_be_bytes())
                        .await
                        .unwrap();
                    let _ = connection.closed().await;
                }
            };
            let receiver = async {
                for expected in 1..=2 {
                    let error = peer.run_next().await.unwrap_err();
                    assert!(format!("{error:#}").contains("presenter"));
                    assert!(!error.is::<NativeCleanupFailure>());
                    assert!(peer.runnable);
                    assert_eq!(peer.attempt(), expected);
                    assert_eq!(peer.local_addr().unwrap(), bound);
                }
            };
            tokio::join!(producer, receiver);
        })
        .await
        .unwrap();
    }

    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    #[tokio::test]
    async fn automatic_retry_replaces_established_connection_but_stops_on_policy_close() {
        let identity = PeerIdentity::from_pem(
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
            include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
        )
        .unwrap();
        let mut config = viewflow_transport::build_server_config(&identity).unwrap();
        std::sync::Arc::get_mut(&mut config.transport)
            .unwrap()
            .max_idle_timeout(Some(Duration::from_millis(500).try_into().unwrap()));
        let server = Endpoint::server(config, "127.0.0.1:0".parse().unwrap()).unwrap();
        let mut peer = lifecycle_peer(server.local_addr().unwrap());
        peer.options.persistent = true;
        let bound = peer.local_addr().unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            let observer = async {
                let first = server.accept().await.unwrap().await.unwrap();
                assert_eq!(first.remote_address().port(), bound.port());
                let (_reply, mut request) = first.accept_bi().await.unwrap();
                assert!(read_first_byte(&mut request).await.unwrap().is_some());
                assert!(matches!(
                    first.closed().await,
                    quinn::ConnectionError::TimedOut
                ));
                let second = server.accept().await.unwrap().await.unwrap();
                assert_eq!(second.remote_address(), first.remote_address());
                assert_ne!(first.stable_id(), second.stable_id());
                // A real peer application close is terminal, not a retry loop.
                second.close(42_u32.into(), b"explicit policy rejection");
            };
            let owner = peer.run_reconnecting_until_shutdown(std::future::pending());
            let ((), report) = tokio::join!(observer, owner);
            assert!(!report.shutdown_requested);
            let error = report.result.unwrap_err();
            assert!(!retryable_media_transport(&error));
            assert!(error.chain().any(|cause| matches!(
                cause.downcast_ref::<quinn::ConnectionError>(),
                Some(quinn::ConnectionError::ApplicationClosed(_))
            )));
        })
        .await
        .unwrap();
        assert_eq!(peer.attempt(), 2);
        assert_eq!(peer.local_addr().unwrap(), bound);
        assert_eq!(peer.retry_delay, None);
    }

    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    #[tokio::test]
    async fn media_owner_reuses_endpoint_after_connection_close_without_capture() {
        let identity = PeerIdentity::from_pem(
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
            include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
        )
        .unwrap();
        let server = Endpoint::server(
            viewflow_transport::build_server_config(&identity).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let mut peer = lifecycle_peer(server.local_addr().unwrap());
        let bound = peer.local_addr().unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            let observer = async {
                let mut previous = None;
                for _ in 0..2 {
                    let connection = server.accept().await.unwrap().await.unwrap();
                    assert_eq!(connection.remote_address().port(), bound.port());
                    assert_ne!(previous, Some(connection.stable_id()));
                    previous = Some(connection.stable_id());
                    // Stop before clock/geometry admission: no native capture,
                    // presentation, or input authorization is reached here.
                    connection.close(0_u32.into(), b"media lifecycle test");
                }
            };
            let attempts = async {
                for expected in 1..=2 {
                    assert!(peer.run_next().await.is_err());
                    assert_eq!(peer.attempt(), expected);
                    assert_eq!(peer.local_addr().unwrap(), bound);
                    assert!(peer.runnable);
                }
            };
            tokio::join!(observer, attempts);
        })
        .await
        .unwrap();
    }

    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    #[tokio::test]
    async fn cancelled_media_attempt_fences_owner_without_consuming_another_attempt() {
        // Do not complete a handshake. Cancellation must fence even when no
        // native resource has yet been created; callers cannot infer cleanup.
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let mut peer = lifecycle_peer(socket.local_addr().unwrap());
        assert!(
            tokio::time::timeout(Duration::from_millis(20), peer.run_next())
                .await
                .is_err()
        );
        assert_eq!(peer.attempt(), 1);
        assert!(!peer.runnable);
        assert!(
            peer.run_next()
                .await
                .unwrap_err()
                .to_string()
                .contains("owner is fenced")
        );
        assert_eq!(peer.attempt(), 1);
    }

    #[test]
    fn completion_diagnostics_never_fabricate_missing_or_reversed_intervals() {
        assert_eq!(diagnostic_elapsed_us(10_000, 37_999), Some(27));
        assert_eq!(diagnostic_elapsed_us(10_000, 10_000), Some(0));
        assert_eq!(diagnostic_elapsed_us(0, 37_999), None);
        assert_eq!(diagnostic_elapsed_us(10_000, 0), None);
        assert_eq!(diagnostic_elapsed_us(37_999, 10_000), None);
    }

    #[test]
    fn source_pointer_authorization_requires_gpu_native_peer_and_explicit_policy() {
        let args: Vec<String> = [
            "send",
            "--cert",
            "cert",
            "--key",
            "key",
            "--ca",
            "ca",
            "--capture-gpu",
            "--compositor-pid",
            "123",
            "--authorize-pointer-motion",
            "--pointer-native-socket",
            "/private/native.sock",
            "--pointer-owner-id",
            "00000000000000000000000000000001",
            "--pointer-source-id",
            "00000000000000000000000000000002",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
        assert_eq!(
            parse_options_from(args.clone())
                .unwrap()
                .authorize_pointer_motion,
            Some(PointerForwarding {
                owner: Id128(1),
                source: Id128(2)
            })
        );
        let mut buttons = args.clone();
        buttons.push("--authorize-pointer-buttons".into());
        assert!(
            parse_options_from(buttons.clone())
                .unwrap()
                .authorize_pointer_buttons
        );
        buttons.retain(|arg| arg != "--authorize-pointer-motion");
        assert!(parse_options_from(buttons).is_err());
        assert!(
            !parse_options_from(args.clone())
                .unwrap()
                .authorize_pointer_buttons
        );
        for flag in ["--capture-gpu", "--authorize-pointer-motion"] {
            assert!(
                parse_options_from(args.iter().filter(|arg| arg.as_str() != flag).cloned())
                    .is_err()
            );
        }
        for flag in [
            "--compositor-pid",
            "--pointer-native-socket",
            "--pointer-owner-id",
            "--pointer-source-id",
        ] {
            let mut invalid = args.clone();
            let index = invalid.iter().position(|arg| arg == flag).unwrap();
            invalid.drain(index..index + 2);
            assert!(parse_options_from(invalid).is_err());
        }
        let mut wrong_role = args;
        wrong_role[0] = "receive".into();
        assert!(parse_options_from(wrong_role).is_err());
    }

    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    #[tokio::test]
    async fn source_pointer_native_wait_cleans_only_its_new_socket() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("pointer.sock");
        assert!(
            SourcePointerTask::connect(
                path.to_str().unwrap(),
                std::process::id(),
                Duration::from_millis(2),
                false
            )
            .await
            .is_err()
        );
        assert!(!path.exists());
        std::fs::write(&path, b"existing").unwrap();
        assert!(
            SourcePointerTask::connect(
                path.to_str().unwrap(),
                std::process::id(),
                Duration::from_millis(2),
                false
            )
            .await
            .is_err()
        );
        assert_eq!(std::fs::read(path).unwrap(), b"existing");
    }

    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    #[test]
    fn source_pointer_metadata_revokes_exact_removed_window() {
        let mut packet = b"VFHY\x01\x00\x0b\x00\x08\x00\x00\x00".to_vec();
        packet.extend(1_u64.to_le_bytes());
        packet.extend(123_u64.to_le_bytes());
        assert!(source_pointer_metadata(&packet, 124).is_ok());
        assert!(source_pointer_metadata(&packet, 123).is_err());
        packet.pop();
        assert!(source_pointer_metadata(&packet, 124).is_err());
    }

    #[test]
    fn pointer_forwarding_requires_explicit_identity_and_native_opt_in() {
        let base = || {
            vec![
                "receive".to_owned(),
                "--cert".into(),
                "cert".into(),
                "--key".into(),
                "key".into(),
                "--ca".into(),
                "ca".into(),
                "--stdin-compressed".into(),
                "presenter.exe".into(),
                "--require-deadline-v4".into(),
                "--emit-pointer-motion".into(),
            ]
        };
        assert!(
            parse_options_from(base())
                .unwrap()
                .forward_pointer_motion
                .is_none()
        );
        let mut args = base();
        args.extend([
            "--forward-pointer-motion".into(),
            "--pointer-owner-id".into(),
            format!("{:032x}", 1),
            "--pointer-source-id".into(),
            format!("{:032x}", 2),
        ]);
        assert_eq!(
            parse_options_from(args.clone())
                .unwrap()
                .forward_pointer_motion,
            Some(PointerForwarding {
                owner: Id128(1),
                source: Id128(2)
            })
        );
        assert!(
            !parse_options_from(args.clone())
                .unwrap()
                .forward_pointer_buttons
        );
        let mut buttons = args.clone();
        buttons.push("--forward-pointer-buttons".into());
        assert!(
            parse_options_from(buttons.clone())
                .unwrap()
                .forward_pointer_buttons
        );
        buttons.retain(|arg| arg != "--forward-pointer-motion");
        assert!(parse_options_from(buttons).is_err());
        for missing in ["--forward-pointer-motion", "--emit-pointer-motion"] {
            let invalid = args.iter().filter(|arg| arg.as_str() != missing).cloned();
            assert!(parse_options_from(invalid).is_err());
        }
        let mut wrong_role = args.clone();
        wrong_role[0] = "send".into();
        assert!(parse_options_from(wrong_role).is_err());
        *args.last_mut().unwrap() = format!("{:032x}", 1);
        assert!(parse_options_from(args).is_err());
        for invalid in [
            "",
            "1",
            "00000000000000000000000000000000",
            "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
        ] {
            assert!(pointer_device_id(invalid).is_err());
        }
    }

    #[test]
    fn native_pointer_button_parser_requires_canonical_context_and_transition() {
        let base = "pointer-button frame_identity=7 x_pixels=11 y_pixels=12 viewport_width=200 viewport_height=100 not_after_qpc=1000 qpc_frequency=10000000";
        for button in 1..=5 {
            for state in 1..=2 {
                assert!(matches!(
                    parse_presenter_output(&format!("{base} button={button} state={state}")),
                    Ok(Some(PresenterOutput::PointerButton(_, _)))
                ));
            }
        }
        for tail in [
            "",
            " button=0 state=1",
            " button=6 state=1",
            " button=1 state=0",
            " button=1 state=3",
            " button=01 state=1",
            " button=1 state=1 extra=0",
        ] {
            assert!(parse_presenter_output(&format!("{base}{tail}")).is_err());
        }
        assert!(parse_presenter_output("pointer-input-ended").is_err());
        assert_eq!(
            parse_presenter_output("pointer-input-ended reason=focus-lost").unwrap_err(),
            "native pointer input retired: focus-lost"
        );
    }

    #[test]
    fn native_pointer_buttons_and_motion_share_bounded_fifo() {
        let (events, _receiver) = crate::window_preview_input::PreviewPointerEvents::channel();
        let state = Mutex::new(PointerMotionState {
            events: Some(events),
            ..PointerMotionState::default()
        });
        let motion = parse_presenter_pointer_motion("pointer-motion frame_identity=7 x_pixels=11 y_pixels=12 viewport_width=200 viewport_height=100 not_after_qpc=1000 qpc_frequency=10000000").unwrap().unwrap();
        let button = viewflow_protocol::PointerButtonEvent {
            button: viewflow_protocol::PointerButton::Left,
            state: viewflow_protocol::InputSwitchState::Pressed,
        };
        assert!(record_presenter_pointer_event(true, &state, motion, 1000, Some(button)).is_err());
        record_presenter_completion(&state, NativeCompletion::Presented(7));
        publish_presenter_input_frame(
            &state,
            FrameIdentity {
                window: Id128(3),
                frame: 7,
                epoch: 4,
                config: 2,
            },
            NativeCompletion::Presented(7),
        )
        .unwrap();
        record_presenter_pointer_event(true, &state, motion, 1000, Some(button)).unwrap();
        for _ in 1..64 {
            record_presenter_pointer_motion(true, &state, motion, 1000).unwrap();
        }
        assert!(record_presenter_pointer_motion(true, &state, motion, 1000).is_err());
        close_presenter_pointer_samples(&state);
        assert!(record_presenter_pointer_event(true, &state, motion, 1000, Some(button)).is_err());
    }

    #[test]
    fn pending_publication_defers_ordered_events_with_original_deadlines() {
        let (events, _receiver) = crate::window_preview_input::PreviewPointerEvents::channel();
        let state = Mutex::new(PointerMotionState {
            events: Some(events),
            ..Default::default()
        });
        let motion = parse_presenter_pointer_motion("pointer-motion frame_identity=7 x_pixels=11 y_pixels=12 viewport_width=200 viewport_height=100 not_after_qpc=1000 qpc_frequency=10000000").unwrap().unwrap();
        let down = viewflow_protocol::PointerButtonEvent {
            button: viewflow_protocol::PointerButton::Left,
            state: viewflow_protocol::InputSwitchState::Pressed,
        };
        let up = viewflow_protocol::PointerButtonEvent {
            state: viewflow_protocol::InputSwitchState::Released,
            ..down
        };
        record_presenter_completion(&state, NativeCompletion::Presented(7));
        for (button, deadline) in [(Some(down), 1000), (None, 1001), (Some(up), 1002)] {
            record_presenter_pointer_event(true, &state, motion, deadline, button).unwrap();
        }
        {
            let guard = state.lock().unwrap();
            assert_eq!(guard.sample_sequence, 0); // no unvalidated forwarding
            assert_eq!(guard.pending_events.len(), 3);
            assert_eq!(guard.pending_events[0].2, Some(down));
            assert_eq!(guard.pending_events[1].2, None);
            assert_eq!(guard.pending_events[2].2, Some(up));
        }
        publish_presenter_input_frame(
            &state,
            FrameIdentity {
                window: Id128(3),
                frame: 7,
                epoch: 4,
                config: 2,
            },
            NativeCompletion::Presented(7),
        )
        .unwrap();
        let guard = state.lock().unwrap();
        assert!(guard.pending_events.is_empty());
        assert_eq!(guard.sample_sequence, 3);
        assert_eq!(guard.latest_motion.unwrap().1, 1002);
    }

    #[test]
    fn pending_publication_is_bounded_and_replacement_retires_route() {
        let (events, _receiver) = crate::window_preview_input::PreviewPointerEvents::channel();
        let state = Mutex::new(PointerMotionState {
            events: Some(events),
            ..Default::default()
        });
        let motion = parse_presenter_pointer_motion("pointer-motion frame_identity=7 x_pixels=11 y_pixels=12 viewport_width=200 viewport_height=100 not_after_qpc=1000 qpc_frequency=10000000").unwrap().unwrap();
        record_presenter_completion(&state, NativeCompletion::Presented(7));
        for _ in 0..64 {
            record_presenter_pointer_motion(true, &state, motion, 1000).unwrap();
        }
        assert!(record_presenter_pointer_motion(true, &state, motion, 1000).is_err());
        assert_eq!(state.lock().unwrap().sample_sequence, 0);
        record_presenter_completion(&state, NativeCompletion::Presented(8));
        assert!(state.lock().unwrap().events.is_none());
        assert!(state.lock().unwrap().pending_events.is_empty());
        close_presenter_pointer_samples(&state);
        assert!(state.lock().unwrap().pending_events.is_empty());
    }

    #[test]
    fn native_pointer_history_preserves_verified_frame_without_retagging() {
        let (samples, receiver) = tokio::sync::watch::channel(
            crate::window_preview_input::PreviewPointerState::default(),
        );
        let state = Mutex::new(PointerMotionState {
            samples: Some(samples),
            ..Default::default()
        });
        for frame in [7, 9] {
            record_presenter_completion(&state, NativeCompletion::Presented(frame));
            publish_presenter_input_frame(
                &state,
                FrameIdentity {
                    window: Id128(3),
                    epoch: 4,
                    frame,
                    config: 2,
                },
                NativeCompletion::Presented(frame),
            )
            .unwrap();
        }
        let motion = parse_presenter_pointer_motion("pointer-motion frame_identity=7 x_pixels=11 y_pixels=12 viewport_width=200 viewport_height=100 not_after_qpc=1000 qpc_frequency=10000000").unwrap().unwrap();
        record_presenter_pointer_motion(true, &state, motion, 5000).unwrap();
        assert_eq!(receiver.borrow().presented.unwrap().frame, 9);
        assert_eq!(receiver.borrow().motion.unwrap().presented.frame, 7);
        assert_eq!(receiver.borrow().motion.unwrap().sender_not_after_ns, 5000);
        assert!(
            record_presenter_pointer_motion(
                true,
                &state,
                PresenterPointerMotion {
                    frame_identity: 8,
                    ..motion
                },
                5000
            )
            .is_err()
        );
        for frame in 10..=41 {
            record_presenter_completion(&state, NativeCompletion::Presented(frame));
            publish_presenter_input_frame(
                &state,
                FrameIdentity {
                    window: Id128(3),
                    epoch: 4,
                    frame,
                    config: 2,
                },
                NativeCompletion::Presented(frame),
            )
            .unwrap();
        }
        assert_eq!(state.lock().unwrap().published_history.len(), 32);
        assert!(record_presenter_pointer_motion(true, &state, motion, 5000).is_err());
        record_presenter_completion(&state, NativeCompletion::Presented(42));
        publish_presenter_input_frame(
            &state,
            FrameIdentity {
                window: Id128(3),
                epoch: 5,
                frame: 42,
                config: 2,
            },
            NativeCompletion::Presented(42),
        )
        .unwrap();
        assert_eq!(state.lock().unwrap().published_history.len(), 1);
        assert!(
            record_presenter_pointer_motion(
                true,
                &state,
                PresenterPointerMotion {
                    frame_identity: 41,
                    ..motion
                },
                5000
            )
            .is_err()
        );
        close_presenter_pointer_samples(&state);
        assert!(state.lock().unwrap().published_history.is_empty());
    }

    #[test]
    fn native_pointer_watch_uses_validated_video_identity_and_original_deadline() {
        let (samples, receiver) = tokio::sync::watch::channel(
            crate::window_preview_input::PreviewPointerState::default(),
        );
        let state = Mutex::new(PointerMotionState {
            samples: Some(samples),
            ..PointerMotionState::default()
        });
        let tag = FrameIdentity {
            window: Id128((1_u128 << 110) + 1),
            frame: 7,
            epoch: 4,
            config: 2,
        };
        let motion = parse_presenter_pointer_motion("pointer-motion frame_identity=7 x_pixels=11 y_pixels=12 viewport_width=200 viewport_height=100 not_after_qpc=1000 qpc_frequency=10000000")
            .unwrap().unwrap();
        record_presenter_completion(&state, NativeCompletion::Presented(7));
        record_presenter_pointer_motion(true, &state, motion, 5000).unwrap();
        assert!(receiver.borrow().presented.is_none());
        assert!(receiver.borrow().motion.is_none());
        publish_presenter_input_frame(&state, tag, NativeCompletion::Presented(7)).unwrap();
        let identity = viewflow_core::PresentedInputIdentity {
            window: tag.window,
            geometry_epoch: tag.epoch,
            frame: tag.frame,
        };
        assert_eq!(receiver.borrow().presented, Some(identity));
        assert!(receiver.borrow().motion.is_none()); // No replay of the pre-validation movement.
        record_presenter_pointer_motion(true, &state, motion, 5000).unwrap();
        let sample = receiver.borrow().motion.unwrap();
        assert_eq!(sample.presented, identity);
        assert_eq!(sample.sample_sequence, 1);
        assert_eq!(sample.sender_not_after_ns, 5000);
        assert_eq!(
            (
                sample.x_pixels,
                sample.y_pixels,
                sample.viewport_width,
                sample.viewport_height
            ),
            (11, 12, 200, 100)
        );

        record_presenter_completion(&state, NativeCompletion::Presented(8));
        assert!(receiver.borrow().presented.is_none());
        assert!(receiver.borrow().motion.is_none());
        assert!(
            publish_presenter_input_frame(&state, tag, NativeCompletion::Presented(7)).is_err()
        );
        assert!(record_presenter_pointer_motion(true, &state, motion, 5000).is_err());
        let next = FrameIdentity {
            frame: 8,
            epoch: 5,
            ..tag
        };
        publish_presenter_input_frame(&state, next, NativeCompletion::Presented(8)).unwrap();
        record_presenter_completion(&state, NativeCompletion::Expired(9));
        publish_presenter_input_frame(
            &state,
            FrameIdentity { frame: 9, ..next },
            NativeCompletion::Expired(9),
        )
        .unwrap();
        record_presenter_completion(&state, NativeCompletion::DecodeOnly(10));
        assert_eq!(receiver.borrow().presented.unwrap().frame, 8);
        record_presenter_pointer_motion(
            true,
            &state,
            PresenterPointerMotion {
                frame_identity: 8,
                ..motion
            },
            6000,
        )
        .unwrap();
        assert_eq!(receiver.borrow().motion.unwrap().sample_sequence, 2);
        assert_eq!(
            receiver.borrow().motion.unwrap().presented.geometry_epoch,
            5
        );
        close_presenter_pointer_samples(&state);
        assert!(receiver.has_changed().is_err());
    }

    #[test]
    fn cold_start_allowance_does_not_change_live_deadline() {
        assert_eq!(
            super::PRESENTER_COLD_START_WAIT,
            std::time::Duration::from_secs(15)
        );
        assert_eq!(super::DEADLINE_NS, 33_333_333);
    }
    use super::*;
    #[test]
    fn explicit_geometry_and_ack_are_exact() {
        let s = LogicalSize::checked(282., 131.).unwrap();
        let r = BlurRect::parse("9,9,200,100").unwrap();
        r.validate(s).unwrap();
        assert!(
            BlurRect::parse("200,100,100,100")
                .unwrap()
                .validate(s)
                .is_err()
        );
        let i = FrameIdentity {
            window: WINDOW,
            frame: 7,
            epoch: 3,
            config: 2,
        };
        assert_eq!(FrameIdentity::decode(&i.encode()).unwrap(), i)
    }
    #[test]
    fn deadline_is_not_relaxed() {
        assert_eq!(
            viewflow_transport::MediaAssemblerConfig::default().deadline_ns,
            DEADLINE_NS
        )
    }

    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    #[test]
    fn sender_stats_preserve_total_and_split_successful_plane_bytes() {
        let mut stats = SenderStats::default();
        stats.observe_send(100, 25, 0, 1, Duration::ZERO);
        stats.observe_send(7, 3, 0, 2, Duration::ZERO);
        // A referenced alpha leaves no alpha datagram bytes; the avoided
        // payload is diagnostic-only and is not added to sent totals.
        stats.observe_send(10, 0, 33, 3, Duration::ZERO);
        assert_eq!(stats.sent_payload_bytes, 145);
        assert_eq!(stats.sent_color_payload_bytes, 117);
        assert_eq!(stats.sent_alpha_payload_bytes, 28);
        assert_eq!(stats.alpha_reused, 1);
        assert_eq!(stats.alpha_reused_bytes, 33);
    }

    #[test]
    fn receiver_stats_counts_rejects_and_limits_detail_logging() {
        let tag = FrameIdentity {
            window: WINDOW,
            frame: 1,
            epoch: 1,
            config: 1,
        };
        let mut stats = ReceiverStats::default();
        for _ in 0..6 {
            stats.reject("timeout", tag, Some(1), Some(2), 3, Some(4), 5, Some(6));
        }
        stats.reject("late", tag, None, None, 0, None, 0, None);
        stats.reject("after_assembly", tag, None, None, 0, None, 0, None);
        stats.reject("after_validation", tag, None, None, 0, None, 0, None);
        assert_eq!(stats.reject_timeout, 6);
        assert_eq!(stats.reject_late, 1);
        assert_eq!(stats.reject_after_assembly, 1);
        assert_eq!(stats.reject_after_validation, 1);
        assert_eq!(stats.logged_rejects, 5);
    }

    #[cfg(windows)]
    #[test]
    fn receiver_udp_socket_buffer_readback_survives_configuration_and_drop() {
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let reference = socket2::SockRef::from(&socket);
        reference.set_recv_buffer_size(4 * 1024 * 1024).unwrap();
        assert!(reference.recv_buffer_size().unwrap() >= 4 * 1024 * 1024);
        drop(reference);
        drop(socket);
    }

    #[test]
    fn dispatch_budget_uses_original_capture_deadline_and_expires_blocked_send() {
        let source = 1_000_000_u64;
        assert_eq!(
            remaining_capture_dispatch_budget(source, source + DEADLINE_NS - 7),
            Some(Duration::from_nanos(7))
        );
        assert_eq!(
            remaining_capture_dispatch_budget(source, source + DEADLINE_NS),
            None
        );
        let runtime = build_coded_runtime().unwrap();
        runtime.block_on(async {
            assert!(
                await_dispatch_until(
                    async { tokio::time::sleep(Duration::from_millis(5)).await },
                    Instant::now() + Duration::from_millis(1),
                )
                .await
                .is_none(),
                "blocked datagram send must hit frame deadline"
            );
        });
    }

    #[test]
    fn dispatch_helper_does_not_poll_expired_send_and_polls_ready_send_once() {
        use std::{cell::Cell, rc::Rc};
        let runtime = build_coded_runtime().unwrap();
        runtime.block_on(async {
            let expired_polls = Rc::new(Cell::new(0));
            let expired_counter = Rc::clone(&expired_polls);
            let expired = std::future::poll_fn(move |_| {
                expired_counter.set(expired_counter.get() + 1);
                Poll::Ready(())
            });
            assert!(
                await_dispatch_until(expired, Instant::now())
                    .await
                    .is_none()
            );
            assert_eq!(expired_polls.get(), 0);

            let ready_polls = Rc::new(Cell::new(0));
            let ready_counter = Rc::clone(&ready_polls);
            let ready = std::future::poll_fn(move |_| {
                ready_counter.set(ready_counter.get() + 1);
                Poll::Ready(7_u8)
            });
            assert_eq!(
                await_dispatch_until(ready, Instant::now() + Duration::from_secs(1)).await,
                Some(7)
            );
            assert_eq!(ready_polls.get(), 1);
        });
    }

    #[test]
    fn scoped_timer_resolution_pairs_only_successful_begin_requests() {
        use std::{cell::Cell, rc::Rc};
        let ended = Rc::new(Cell::new(0));
        {
            let ended_for_drop = Rc::clone(&ended);
            let _guard = acquire_timer_resolution(
                || 0,
                move || {
                    ended_for_drop.set(ended_for_drop.get() + 1);
                    0
                },
            )
            .unwrap();
        }
        assert_eq!(ended.get(), 1);

        let failure_ended = Rc::new(Cell::new(0));
        let failure_end = Rc::clone(&failure_ended);
        assert!(
            acquire_timer_resolution(
                || 7,
                move || {
                    failure_end.set(failure_end.get() + 1);
                    0
                }
            )
            .is_err()
        );
        assert_eq!(failure_ended.get(), 0);
    }

    #[test]
    fn scoped_timer_resolution_releases_on_early_return() {
        use std::{cell::Cell, rc::Rc};
        fn early_return(ended: Rc<Cell<u8>>) -> Result<()> {
            let _guard = acquire_timer_resolution(
                || 0,
                move || {
                    ended.set(ended.get() + 1);
                    0
                },
            )?;
            Ok(())
        }
        let ended = Rc::new(Cell::new(0));
        early_return(Rc::clone(&ended)).unwrap();
        assert_eq!(ended.get(), 1);
    }

    #[test]
    fn incomplete_dispatch_is_never_counted_as_a_complete_send() {
        assert!(complete_datagram_dispatch(false, false));
        assert!(!complete_datagram_dispatch(true, false));
        assert!(!complete_datagram_dispatch(false, true));
    }

    #[test]
    fn capture_gpu_cli_is_an_opt_in_flag_and_cpu_remains_default() {
        let common = || {
            vec!["send", "--cert", "cert", "--key", "key", "--ca", "ca"]
                .into_iter()
                .map(str::to_owned)
                .collect::<Vec<_>>()
        };
        assert!(!parse_options_from(common()).unwrap().capture_gpu);
        let mut gpu = common();
        gpu.push("--capture-gpu".to_owned());
        assert!(parse_options_from(gpu).unwrap().capture_gpu);
    }

    #[test]
    fn alpha_reuse_is_default_off_and_requires_an_exact_mutual_plan() {
        let base = || {
            vec!["send", "--cert", "cert", "--key", "key", "--ca", "ca"]
                .into_iter()
                .map(str::to_owned)
                .collect::<Vec<_>>()
        };
        assert!(!parse_options_from(base()).unwrap().alpha_reuse_warmup);
        let mut opted_in = base();
        opted_in.extend([
            "--capture-stream".to_owned(),
            "capture.sock".to_owned(),
            "--capture-gpu".to_owned(),
            "--alpha-reuse-warmup".to_owned(),
        ]);
        assert!(parse_options_from(opted_in).unwrap().alpha_reuse_warmup);
        let mut unsupported = base();
        unsupported.push("--alpha-reuse-warmup".to_owned());
        assert!(parse_options_from(unsupported).is_err());
        assert!(validate_alpha_reuse_plan(true, &ALPHA_REUSE_PLAN_PAYLOAD).is_ok());
        assert!(validate_alpha_reuse_plan(false, &ALPHA_REUSE_PLAN_PAYLOAD).is_err());
        assert!(validate_alpha_reuse_plan(true, &[]).is_err());
        assert!(validate_alpha_reuse_plan(true, &[1, 0]).is_err());
        assert!(validate_alpha_reuse_plan(true, &[0]).is_err());
    }

    #[test]
    fn alpha_reference_metadata_is_one_strict_complete_slot() {
        let meta = vec![0x55; FRAME_META_BYTES];
        assert!(matches!(
            parse_frame_meta_record(FRAME_META, &meta, false),
            Ok((decoded, None)) if decoded == meta
        ));
        let mut reference = meta.clone();
        reference.extend_from_slice(&[0x7a; ALPHA_REFERENCE_BYTES]);
        assert!(matches!(
            parse_frame_meta_record(FRAME_META_ALPHA_REFERENCE, &reference, true),
            Ok((decoded, Some(key))) if decoded == meta && key == [0x7a; ALPHA_REFERENCE_BYTES]
        ));
        assert!(parse_frame_meta_record(FRAME_META_ALPHA_REFERENCE, &reference, false).is_err());
        assert!(
            parse_frame_meta_record(
                FRAME_META_ALPHA_REFERENCE,
                &reference[..reference.len() - 1],
                true
            )
            .is_err()
        );
        assert!(parse_frame_meta_record(FRAME_META, &reference, false).is_err());
    }

    #[test]
    fn referenced_alpha_uses_current_color_identity_timestamp_and_rejects_alpha_packets() {
        let color = MediaPlaneFrame {
            window_id: WINDOW,
            frame_id: 99,
            geometry_epoch: 7,
            plane: MediaPlane::Color,
            source_submitted_ns: 123_456,
            payload: Bytes::from_static(b"current-color"),
        };
        let alpha = current_alpha_plane_from_reference(
            color.window_id,
            color.frame_id,
            color.geometry_epoch,
            color.source_submitted_ns,
            Bytes::from_static(b"old-vfar"),
        );
        assert_eq!(alpha.window_id, color.window_id);
        assert_eq!(alpha.frame_id, color.frame_id);
        assert_eq!(alpha.geometry_epoch, color.geometry_epoch);
        assert_eq!(alpha.source_submitted_ns, color.source_submitted_ns);
        assert_eq!(alpha.plane, MediaPlane::Alpha);
        assert!(validate_reference_packet_plane(true, MediaPlane::Alpha).is_err());
        assert!(validate_reference_packet_plane(true, MediaPlane::Color).is_ok());
        assert!(validate_reference_packet_plane(false, MediaPlane::Alpha).is_ok());
    }

    #[test]
    fn changed_alpha_remains_the_normal_two_datagram_path() {
        let baseline = viewflow_transport::encode_alpha_rle(2, 2, &[7; 4]).unwrap();
        let warmup = FrameIdentity {
            window: WINDOW,
            frame: 3,
            epoch: 7,
            config: 11,
        };
        let current = FrameIdentity { frame: 4, ..warmup };
        let cache = AlphaReferenceCache::new(warmup.encode(), 2, 2, baseline, 1024).unwrap();
        let changed = viewflow_transport::encode_alpha_rle(2, 2, &[7, 7, 7, 8]).unwrap();
        assert!(
            cache
                .reference_for(current.encode(), 2, 2, &changed)
                .is_none()
        );
    }

    #[test]
    fn warmup_frames_are_explicitly_bounded_and_default_to_legacy_one() {
        let base = || {
            vec!["send", "--cert", "cert", "--key", "key", "--ca", "ca"]
                .into_iter()
                .map(str::to_owned)
                .collect::<Vec<_>>()
        };
        let default = parse_options_from(base()).unwrap();
        assert_eq!(default.warmup_frames, DEFAULT_WARMUP_FRAMES);
        assert!(!requires_warmup_plan(default.warmup_frames));

        let mut three = base();
        three.extend([
            "--capture-stream".into(),
            "capture.sock".into(),
            "--capture-gpu".into(),
            "--warmup-frames".into(),
            "3".into(),
        ]);
        let configured = parse_options_from(three).unwrap();
        assert_eq!(configured.warmup_frames, MULTI_FRAME_WARMUP_FRAMES);
        assert!(requires_warmup_plan(configured.warmup_frames));

        for invalid in ["0", "2", "4", "255", "03", "+3"] {
            let mut args = base();
            args.extend(["--warmup-frames".into(), invalid.into()]);
            assert!(parse_options_from(args).is_err(), "accepted {invalid}");
        }
    }

    #[test]
    fn three_frame_warmup_requires_exact_plan_and_unbroken_idr_reference_chain() {
        assert!(validate_warmup_plan(MULTI_FRAME_WARMUP_FRAMES, &[3]).is_ok());
        assert!(validate_warmup_plan(MULTI_FRAME_WARMUP_FRAMES, &[1]).is_err());
        assert!(validate_warmup_plan(MULTI_FRAME_WARMUP_FRAMES, &[3, 0]).is_err());
        assert!(validate_warmup_plan(DEFAULT_WARMUP_FRAMES, &[1]).is_err());

        let lineage = (7, 11);
        let first = validate_warmup_reference(0, true, lineage, None).unwrap();
        let second = validate_warmup_reference(1, false, lineage, first).unwrap();
        assert_eq!(
            validate_warmup_reference(2, false, lineage, second).unwrap(),
            Some(lineage)
        );
        assert!(validate_warmup_reference(0, false, lineage, None).is_err());
        assert!(validate_warmup_reference(1, true, lineage, Some(lineage)).is_err());
        assert!(validate_warmup_reference(1, false, (8, 11), Some(lineage)).is_err());

        let expected_ack = FrameIdentity {
            window: WINDOW,
            frame: 41,
            epoch: 7,
            config: 11,
        };
        assert!(validate_warmup_ack(expected_ack, &expected_ack.encode()).is_ok());
        let wrong_ack = FrameIdentity {
            frame: 42,
            ..expected_ack
        };
        assert!(validate_warmup_ack(expected_ack, &wrong_ack.encode()).is_err());
        assert!(validate_warmup_ack(expected_ack, &expected_ack.encode()[..39]).is_err());

        // Native H.264 P references and independently encoded VFAR alpha
        // intentionally have different keyframe flags after the first IDR.
        let color_p = FrameCodecMetadata {
            config_generation: expected_ack.config,
            keyframe: false,
        };
        let alpha_independent = FrameCodecMetadata {
            config_generation: expected_ack.config,
            keyframe: true,
        };
        assert!(validate_warmup_metadata(expected_ack, color_p, alpha_independent).is_ok());
        assert!(
            validate_warmup_metadata(
                expected_ack,
                FrameCodecMetadata {
                    config_generation: expected_ack.config + 1,
                    keyframe: false,
                },
                alpha_independent,
            )
            .is_err()
        );
        assert!(
            validate_warmup_metadata(
                expected_ack,
                color_p,
                FrameCodecMetadata {
                    config_generation: expected_ack.config + 1,
                    keyframe: true,
                },
            )
            .is_err()
        );
    }

    #[test]
    fn native_deadline_cli_is_explicit_receive_only() {
        let base = |role: &str| {
            vec![
                role.to_owned(),
                "--cert".into(),
                "cert".into(),
                "--key".into(),
                "key".into(),
                "--ca".into(),
                "ca".into(),
            ]
        };
        assert!(
            !parse_options_from(base("receive"))
                .unwrap()
                .require_deadline_v4
        );
        for role in ["send", "receive"] {
            let mut args = base(role);
            args.push("--require-deadline-v4".into());
            assert!(parse_options_from(args).is_err());
        }
        let mut args = base("receive");
        args.extend([
            "--stdin-compressed".into(),
            "presenter.exe".into(),
            "--require-deadline-v4".into(),
        ]);
        assert!(
            parse_options_from(args.clone())
                .unwrap()
                .require_deadline_v4
        );
        args.push("--require-deadline-v4".into());
        assert!(parse_options_from(args).is_err());
    }

    #[test]
    fn pointer_motion_cli_is_explicit_receive_deadline_opt_in() {
        let base = |role: &str| {
            vec![
                role.to_owned(),
                "--cert".into(),
                "cert".into(),
                "--key".into(),
                "key".into(),
                "--ca".into(),
                "ca".into(),
            ]
        };
        assert!(
            !parse_options_from(base("receive"))
                .unwrap()
                .emit_pointer_motion
        );
        for role in ["send", "receive"] {
            let mut args = base(role);
            args.push("--emit-pointer-motion".into());
            assert!(parse_options_from(args).is_err());
        }
        let mut missing_deadline = base("receive");
        missing_deadline.extend([
            "--stdin-compressed".into(),
            "presenter.exe".into(),
            "--emit-pointer-motion".into(),
        ]);
        assert!(parse_options_from(missing_deadline).is_err());
        let mut valid = base("receive");
        valid.extend([
            "--stdin-compressed".into(),
            "presenter.exe".into(),
            "--require-deadline-v4".into(),
            "--emit-pointer-motion".into(),
        ]);
        assert!(parse_options_from(valid).unwrap().emit_pointer_motion);
    }

    #[test]
    fn presentation_reserve_is_canonical_opt_in_and_only_shrinks_qpc_budget() {
        let base = |role: &str| {
            vec![
                role.to_owned(),
                "--cert".into(),
                "cert".into(),
                "--key".into(),
                "key".into(),
                "--ca".into(),
                "ca".into(),
            ]
        };
        assert_eq!(
            parse_options_from(base("receive"))
                .unwrap()
                .presentation_reserve,
            Duration::ZERO
        );
        let mut explicit_zero = base("receive");
        explicit_zero.extend(["--presentation-reserve-us".into(), "0".into()]);
        assert_eq!(
            parse_options_from(explicit_zero)
                .unwrap()
                .presentation_reserve,
            Duration::ZERO
        );
        for invalid in ["01", "+1", "-1", "10001", " 1", "1 "] {
            let mut args = base("receive");
            args.extend(["--presentation-reserve-us".into(), invalid.into()]);
            assert!(parse_options_from(args).is_err(), "{invalid}");
        }
        let mut zero_on_send = base("send");
        zero_on_send.extend(["--presentation-reserve-us".into(), "0".into()]);
        assert!(parse_options_from(zero_on_send).is_err());

        let mut missing_prerequisites = base("receive");
        missing_prerequisites.extend(["--presentation-reserve-us".into(), "1".into()]);
        assert!(parse_options_from(missing_prerequisites).is_err());

        let mut valid = base("receive");
        valid.extend([
            "--stdin-compressed".into(),
            "presenter.exe".into(),
            "--require-deadline-v4".into(),
            "--recover-expired-v4".into(),
            "--presentation-reserve-us".into(),
            "10000".into(),
        ]);
        assert_eq!(
            parse_options_from(valid).unwrap().presentation_reserve,
            Duration::from_micros(10_000)
        );

        let remaining = Duration::from_micros(500);
        assert_eq!(
            native_deadline_budget_after_presentation_reserve(remaining, Duration::ZERO),
            Some(remaining)
        );
        assert_eq!(
            native_deadline_budget_after_presentation_reserve(
                remaining,
                Duration::from_micros(100),
            ),
            Some(Duration::from_micros(400))
        );
        assert_eq!(
            native_deadline_budget_after_presentation_reserve(remaining, remaining),
            None
        );
        assert_eq!(
            native_deadline_budget_after_presentation_reserve(
                remaining,
                Duration::from_micros(501),
            ),
            None
        );
    }

    #[cfg(windows)]
    #[test]
    fn native_qpc_api_samples_a_stable_monotonic_domain() {
        let (first, frequency) = native_qpc_sample().unwrap();
        let (second, second_frequency) = native_qpc_sample().unwrap();
        assert!(frequency > 0);
        assert_eq!(frequency, second_frequency);
        assert!(second >= first);
        let deadline =
            crate::gpu_presenter_pipe::NativePresentationDeadline::from_remaining_budget(
                first,
                frequency,
                DEADLINE_NS,
            )
            .unwrap();
        assert!(deadline.ticks > first);
    }

    #[test]
    fn warmup_alpha_output_is_send_only() {
        let send = vec![
            "send",
            "--cert",
            "c",
            "--key",
            "k",
            "--ca",
            "a",
            "--warmup-alpha-output",
            "/tmp/sample.vfar",
        ]
        .into_iter()
        .map(str::to_owned);
        assert_eq!(
            parse_options_from(send)
                .unwrap()
                .warmup_alpha_output
                .as_deref(),
            Some("/tmp/sample.vfar")
        );
        let receive = vec![
            "receive",
            "--cert",
            "c",
            "--key",
            "k",
            "--ca",
            "a",
            "--warmup-alpha-output",
            "/tmp/sample.vfar",
        ]
        .into_iter()
        .map(str::to_owned);
        assert!(parse_options_from(receive).is_err());
    }

    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    #[test]
    fn warmup_alpha_export_is_exact_private_and_never_overwrites_or_follows_symlinks() {
        use std::{
            fs,
            os::unix::{fs::MetadataExt, fs::symlink},
        };
        let fixture = tempfile::tempdir().unwrap();
        let sample = fixture.path().join("warmup.vfar");
        let bytes = bytes::Bytes::from_static(b"VFAR\x01\x00exact-sample");
        write_warmup_alpha_sample(sample.to_str().unwrap(), &bytes).unwrap();
        assert_eq!(fs::read(&sample).unwrap(), bytes);
        assert_eq!(fs::metadata(&sample).unwrap().mode() & 0o777, 0o600);
        assert!(write_warmup_alpha_sample(sample.to_str().unwrap(), &bytes).is_err());
        assert_eq!(fs::read(&sample).unwrap(), bytes);

        let target = fixture.path().join("target.vfar");
        fs::write(&target, b"keep-target").unwrap();
        let link = fixture.path().join("link.vfar");
        symlink(&target, &link).unwrap();
        assert!(write_warmup_alpha_sample(link.to_str().unwrap(), &bytes).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"keep-target");
    }

    #[test]
    fn coded_runtime_keeps_block_on_on_caller_while_workers_progress() {
        use std::{
            sync::{Arc, Barrier, mpsc},
            thread,
        };
        let runtime = build_coded_runtime().unwrap();
        let caller = thread::current().id();
        let rendezvous = Arc::new(Barrier::new(2));
        let worker_barrier = Arc::clone(&rendezvous);
        let (worker_started, worker_started_rx) = mpsc::sync_channel(1);
        let (worker_finished, worker_finished_rx) = mpsc::sync_channel(1);
        runtime.block_on(async move {
            assert_eq!(thread::current().id(), caller);
            tokio::spawn(async move {
                worker_started.send(()).unwrap();
                worker_barrier.wait();
                worker_finished.send(thread::current().id()).unwrap();
            });
            worker_started_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("network substitute did not start");
            // This intentionally blocks only the direct block_on caller. The
            // barrier proves a runtime worker can still make network progress.
            rendezvous.wait();
            thread::sleep(Duration::from_millis(5));
            let worker_thread = worker_finished_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("network substitute stalled behind caller");
            assert_ne!(worker_thread, caller);
            tokio::time::sleep(Duration::from_millis(1)).await;
            assert_eq!(thread::current().id(), caller);
        });
    }

    #[test]
    fn drain_polling_keeps_one_pending_operation_through_a_long_control_wait() {
        use std::{cell::Cell, rc::Rc};
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        runtime.block_on(async {
            let constructions = Rc::new(Cell::new(0));
            let constructions_for_operation = Rc::clone(&constructions);
            let operation = async move {
                constructions_for_operation.set(constructions_for_operation.get() + 1);
                tokio::time::sleep(Duration::from_millis(550)).await;
                Ok::<_, anyhow::Error>(())
            };
            let drains = Rc::new(Cell::new(0));
            let drains_for_callback = Rc::clone(&drains);
            poll_with_drain(
                operation,
                Instant::now() + Duration::from_millis(700),
                "unexpected timeout",
                move || {
                    drains_for_callback.set(drains_for_callback.get() + 1);
                    Ok(())
                },
            )
            .await
            .unwrap();
            assert_eq!(
                constructions.get(),
                1,
                "the read future must not be rebuilt"
            );
            assert!(
                drains.get() >= 2,
                "a wait longer than GPU ownership must drain repeatedly"
            );
        });
    }

    #[test]
    fn drain_polling_propagates_timeout_read_and_drain_failures() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        runtime.block_on(async {
            let timeout = poll_with_drain(
                std::future::pending::<Result<()>>(),
                Instant::now() + Duration::from_millis(3),
                "control timed out",
                || Ok(()),
            )
            .await
            .unwrap_err();
            assert!(timeout.to_string().contains("control timed out"));
            let read_failure = poll_with_drain(
                async { Err::<(), _>(anyhow::anyhow!("read failed")) },
                Instant::now() + Duration::from_secs(1),
                "unexpected timeout",
                || Ok(()),
            )
            .await
            .unwrap_err();
            assert!(read_failure.to_string().contains("read failed"));
            let drain_failure = poll_with_drain(
                // Keep the I/O pending until the drain error. Short Windows
                // timers can wake together, so a 3 ms ready I/O race does not
                // deterministically exercise the drain branch.
                std::future::pending::<Result<()>>(),
                Instant::now() + Duration::from_secs(1),
                "unexpected timeout",
                || bail!("drain failed"),
            )
            .await
            .unwrap_err();
            assert!(drain_failure.to_string().contains("drain failed"));
        });
    }

    #[test]
    fn drain_polling_rejects_ready_completion_after_absolute_deadline() {
        build_coded_runtime().unwrap().block_on(async {
            let result = poll_with_drain(
                async {
                    std::thread::sleep(Duration::from_millis(5));
                    Ok(())
                },
                Instant::now() + Duration::from_millis(1),
                "late completion",
                || Ok(()),
            )
            .await;
            assert!(result.unwrap_err().to_string().contains("late completion"));
        });
    }

    #[test]
    fn warmup_metadata_tail_uses_the_exact_serialized_offsets() {
        let mut meta = vec![0_u8; WARMUP_META_BYTES];
        let base = 40 + FRAME_CODEC_METADATA_BYTES * 2;
        meta[base..base + 8].copy_from_slice(&0x0102_0304_0506_0708_u64.to_be_bytes());
        meta[base + 8..base + 12].copy_from_slice(&61_440_u32.to_be_bytes());
        meta[base + 12..base + 16].copy_from_slice(&77_u32.to_be_bytes());
        assert_eq!(
            decode_warmup_tail(&meta).unwrap(),
            (0x0102_0304_0506_0708, 61_440, 77)
        );
        assert!(decode_warmup_tail(&meta[..meta.len() - 1]).is_err());
    }

    #[test]
    fn warmup_and_live_capture_use_one_session_clock_lineage() {
        // A warmup capture on CLOCK_MONOTONIC must not be fed to the encoder
        // beside a later session-relative live timestamp. Mapping both with
        // the same sample/session pair preserves ordering without a freshness
        // restamp and prevents the mixed-domain lineage rejection.
        let warmup =
            crate::hyprcapture_stream::session_capture_timestamp(1_000, 1_010, 500).unwrap();
        let live = crate::hyprcapture_stream::session_capture_timestamp(1_009, 1_010, 500).unwrap();
        assert_eq!(warmup, 490);
        assert_eq!(live, 499);
        assert!(warmup < live);
    }

    #[test]
    fn native_ack_requires_a_complete_exact_identity_token() {
        assert_eq!(
            parse_presenter_completion(
                "submitted frame_identity=1 submitted_frames=1 width=256 height=256"
            ),
            Ok(Some(NativeCompletion::Presented(1)))
        );
        assert_eq!(
            parse_presenter_completion(
                "submitted frame_identity=10 submitted_frames=1 width=256 height=256"
            ),
            Ok(Some(NativeCompletion::Presented(10)))
        );
        assert!(parse_presenter_completion("submitted frame_identity=1 ready").is_err());
        assert_eq!(
            parse_presenter_completion("composition preview ready"),
            Ok(None)
        );
        assert_eq!(
            parse_presenter_completion(
                "decode-only completed frame_identity=7 width=1936 height=1732"
            ),
            Ok(Some(NativeCompletion::DecodeOnly(7)))
        );
        assert_eq!(
            parse_presenter_completion("rejected frame_identity=9 reason=expired"),
            Ok(Some(NativeCompletion::Expired(9)))
        );
        assert!(
            parse_presenter_completion("rejected frame_identity=9 reason=expired extra").is_err()
        );
        assert!(parse_presenter_completion("rejected frame_identity=9 reason=late").is_err());
        for noncanonical in [
            "rejected frame_identity=09 reason=expired",
            "rejected frame_identity=+9 reason=expired",
            "rejected frame_identity=9  reason=expired",
            "rejected frame_identity=9 reason=expired ",
        ] {
            assert!(
                parse_presenter_completion(noncanonical).is_err(),
                "accepted {noncanonical}"
            );
        }
    }

    #[test]
    fn pointer_motion_is_exact_typed_bounded_and_requires_latest_presented_frame() {
        let line = "pointer-motion frame_identity=7 x_pixels=0 y_pixels=12 viewport_width=1920 viewport_height=1080 not_after_qpc=1000 qpc_frequency=10000000";
        let motion = PresenterPointerMotion {
            frame_identity: 7,
            x_pixels: 0,
            y_pixels: 12,
            viewport_width: 1920,
            viewport_height: 1080,
            not_after_qpc: 1000,
            qpc_frequency: 10_000_000,
        };
        assert_eq!(parse_presenter_pointer_motion(line), Ok(Some(motion)));
        assert_eq!(
            parse_presenter_output(line),
            Ok(Some(PresenterOutput::PointerMotion(motion)))
        );
        assert_eq!(
            parse_presenter_output(
                "submitted frame_identity=7 submitted_frames=1 width=1920 height=1080"
            ),
            Ok(Some(PresenterOutput::Completion(
                NativeCompletion::Presented(7)
            )))
        );
        for invalid in [
            "pointer-motion frame_identity=07 x_pixels=0 y_pixels=12 viewport_width=1920 viewport_height=1080",
            "pointer-motion frame_identity=7 x_pixels=4294967296 y_pixels=12 viewport_width=1920 viewport_height=1080",
            "pointer-motion frame_identity=7 x_pixels=1920 y_pixels=12 viewport_width=1920 viewport_height=1080",
            "pointer-motion frame_identity=7 x_pixels=0 y_pixels=1080 viewport_width=1920 viewport_height=1080",
            "pointer-motion frame_identity=7  x_pixels=0 y_pixels=12 viewport_width=1920 viewport_height=1080",
            "pointer-motion frame_identity=7 x_pixels=0 y_pixels=12 viewport_width=1920",
        ] {
            assert!(
                parse_presenter_pointer_motion(&format!(
                    "{invalid} not_after_qpc=1000 qpc_frequency=10000000"
                ))
                .is_err(),
                "{invalid}"
            );
        }

        let state = Mutex::new(PointerMotionState::default());
        // A disabled stream is terminal rather than implicitly enabling input.
        assert!(record_presenter_pointer_motion(false, &state, motion, 5000).is_err());
        // Decode-only warmup never establishes a visible/pointer target.
        record_presenter_completion(&state, NativeCompletion::DecodeOnly(7));
        assert!(record_presenter_pointer_motion(true, &state, motion, 5000).is_err());

        record_presenter_completion(&state, NativeCompletion::Presented(7));
        record_presenter_pointer_motion(true, &state, motion, 5000).unwrap();
        assert_eq!(state.lock().unwrap().latest_motion, Some((motion, 5000)));

        // A newer submitted frame atomically drops stale motion. An Expired
        // result does not replace this already visible context.
        record_presenter_completion(&state, NativeCompletion::Presented(8));
        assert_eq!(state.lock().unwrap().latest_motion, None);
        assert!(record_presenter_pointer_motion(true, &state, motion, 5000).is_err());
        record_presenter_completion(&state, NativeCompletion::Expired(8));
        let current = PresenterPointerMotion {
            frame_identity: 8,
            ..motion
        };
        record_presenter_pointer_motion(true, &state, current, 5000).unwrap();
        assert_eq!(state.lock().unwrap().latest_motion, Some((current, 5000)));

        assert_eq!(
            presenter_pointer_deadline(motion, 5000, 900, 10_000_000),
            Ok(Some(15000))
        );
        assert_eq!(
            presenter_pointer_deadline(motion, 7000, 920, 10_000_000),
            Ok(Some(15000)) // Delayed receipt never creates a new budget.
        );
        assert_eq!(
            presenter_pointer_deadline(motion, 15000, 1000, 10_000_000),
            Ok(None)
        );
        assert!(presenter_pointer_deadline(motion, 5000, 900, 1_000_000).is_err());
        assert!(
            presenter_pointer_deadline(
                PresenterPointerMotion {
                    not_after_qpc: u64::MAX,
                    ..motion
                },
                5000,
                900,
                10_000_000
            )
            .is_err()
        );
        for invalid in [
            line.replace("not_after_qpc=1000", "not_after_qpc=0"),
            line.replace("qpc_frequency=10000000", "qpc_frequency=0"),
        ] {
            assert!(parse_presenter_pointer_motion(&invalid).is_err());
        }

        let diagnostics = AtomicU8::new(0);
        assert_eq!(
            (0..300)
                .filter(|_| take_pointer_motion_diagnostic_slot(&diagnostics))
                .count(),
            32
        );
        assert_eq!(diagnostics.load(Ordering::Relaxed), 32);
    }

    #[test]
    fn expired_disposition_is_bounded_exact_and_never_a_warmup_completion() {
        let acknowledgement = std::sync::Arc::new(Mutex::new(None));
        let changed = std::sync::Arc::new(Condvar::new());
        let closed = AtomicBool::new(false);
        let freshness_deadline = Instant::now() + Duration::from_millis(1);
        let disposition_deadline = freshness_deadline + EXPIRED_DISPOSITION_GRACE;
        let producer = {
            let acknowledgement = acknowledgement.clone();
            let changed = changed.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(2));
                *acknowledgement.lock().unwrap() = Some(NativeCompletion::Expired(7));
                changed.notify_one();
            })
        };
        assert_eq!(
            wait_for_presenter_completion(
                &acknowledgement,
                &changed,
                &closed,
                ExpectedNativeCompletion::PresentedOrExpired(7),
                disposition_deadline,
            )
            .unwrap(),
            NativeCompletion::Expired(7)
        );
        producer.join().unwrap();
        assert!(Instant::now() >= freshness_deadline);
        assert_eq!(
            validate_live_native_completion(NativeCompletion::Expired(7), 7, freshness_deadline,)
                .unwrap(),
            NativeCompletion::Expired(7)
        );
        assert!(
            wait_for_presenter_completion(
                &Mutex::new(Some(NativeCompletion::Expired(7))),
                &Condvar::new(),
                &AtomicBool::new(false),
                ExpectedNativeCompletion::DecodeOnly(7),
                Instant::now() + Duration::from_millis(1),
            )
            .is_err()
        );
        assert!(
            wait_for_presenter_completion(
                &Mutex::new(Some(NativeCompletion::Expired(8))),
                &Condvar::new(),
                &AtomicBool::new(false),
                ExpectedNativeCompletion::PresentedOrExpired(7),
                Instant::now() + Duration::from_millis(1),
            )
            .is_err()
        );
        assert!(
            wait_for_presenter_completion(
                &Mutex::new(Some(NativeCompletion::Expired(7))),
                &Condvar::new(),
                &AtomicBool::new(false),
                ExpectedNativeCompletion::PresentedOrExpired(7),
                Instant::now(),
            )
            .unwrap_err()
            .contains("timed out")
        );
    }

    #[test]
    fn late_presented_completion_is_not_admitted_by_expiry_grace() {
        let deadline = Instant::now() + Duration::from_millis(1);
        std::thread::sleep(Duration::from_millis(2));
        assert!(
            validate_live_native_completion(NativeCompletion::Presented(7), 7, deadline)
                .unwrap_err()
                .contains("late")
        );
        assert!(
            validate_live_native_completion(
                NativeCompletion::Presented(8),
                7,
                Instant::now() + Duration::from_millis(1),
            )
            .is_err()
        );
    }

    #[test]
    fn late_ack_is_rejected_and_no_response_wait_is_bounded() {
        let estimate = ClockEstimate {
            remote_offset_ns: 0,
            network_round_trip_ns: 0,
            uncertainty_ns: 17,
        };
        assert!(fresh(100, estimate, 100 + DEADLINE_NS - 17));
        assert!(!fresh(100, estimate, 100 + DEADLINE_NS - 16));
        assert_eq!(PRESENTER_ACK_WAIT, Duration::from_nanos(33_333_333));
        let acknowledgement = Mutex::new(None);
        let changed = Condvar::new();
        let closed = AtomicBool::new(false);
        let started = Instant::now();
        assert!(
            wait_for_presenter_completion(
                &acknowledgement,
                &changed,
                &closed,
                ExpectedNativeCompletion::Presented(1),
                started + Duration::from_millis(2),
            )
            .unwrap_err()
            .contains("timed out")
        );
        assert!(started.elapsed() >= Duration::from_millis(1));

        let acknowledgement = std::sync::Arc::new(Mutex::new(None));
        let changed = std::sync::Arc::new(Condvar::new());
        let late_ack = {
            let acknowledgement = acknowledgement.clone();
            let changed = changed.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(1));
                *acknowledgement.lock().unwrap() = Some(NativeCompletion::DecodeOnly(10));
                changed.notify_one();
            })
        };
        assert!(
            wait_for_presenter_completion(
                &acknowledgement,
                &changed,
                &closed,
                ExpectedNativeCompletion::Presented(1),
                Instant::now() + Duration::from_secs(1),
            )
            .unwrap_err()
            .contains("cannot satisfy")
        );
        late_ack.join().unwrap();
    }

    #[test]
    fn late_reject_recovers_but_late_ack_is_not_admitted() {
        let tag = FrameIdentity {
            window: WINDOW,
            frame: 9,
            epoch: 2,
            config: 1,
        };
        let payload = tag.encode();
        let expired_now = DEADLINE_NS + 1;
        // Control is allowed to outlive the frame's presentation budget only
        // for a REJECT, which is proof of no submission and triggers IDR.
        assert_eq!(
            admit_frame_control(REJECT, &payload, tag, 0, expired_now).unwrap(),
            FrameControl::Reject
        );
        assert!(admit_frame_control(PRESENTER_ACK, &payload, tag, 0, expired_now).is_err());
        assert!(
            admit_frame_control(
                REJECT,
                &FrameIdentity { frame: 10, ..tag }.encode(),
                tag,
                0,
                expired_now
            )
            .is_err()
        );

        let before_session_end = Instant::now() + Duration::from_millis(2);
        assert!(
            control_response_budget(before_session_end)
                .is_some_and(|remaining| remaining <= Duration::from_millis(2))
        );
        assert!(control_response_budget(Instant::now()).is_none());
    }

    #[test]
    fn presenter_shutdown_wakes_the_bounded_ack_wait() {
        let acknowledgement = std::sync::Arc::new(Mutex::new(None));
        let changed = std::sync::Arc::new(Condvar::new());
        let closed = std::sync::Arc::new(AtomicBool::new(false));
        let waiter = {
            let acknowledgement = acknowledgement.clone();
            let changed = changed.clone();
            let closed = closed.clone();
            std::thread::spawn(move || {
                wait_for_presenter_completion(
                    &acknowledgement,
                    &changed,
                    &closed,
                    ExpectedNativeCompletion::Presented(1),
                    Instant::now() + Duration::from_secs(1),
                )
            })
        };
        std::thread::sleep(Duration::from_millis(1));
        closed.store(true, Ordering::Release);
        changed.notify_all();
        assert!(waiter.join().unwrap().unwrap_err().contains("closed"));
    }

    #[test]
    fn idle_worker_shutdown_wakes_the_queue_wait() {
        let latest = std::sync::Arc::new(Mutex::<Option<()>>::new(None));
        let ready = std::sync::Arc::new(Condvar::new());
        let closed = std::sync::Arc::new(AtomicBool::new(false));
        let worker = {
            let latest = latest.clone();
            let ready = ready.clone();
            let closed = closed.clone();
            std::thread::spawn(move || take_presenter_slot(&latest, &ready, &closed))
        };
        std::thread::sleep(Duration::from_millis(1));
        // Same lock/predicate ordering as `PresenterState::fail`.
        let guard = latest.lock().unwrap();
        closed.store(true, Ordering::Release);
        ready.notify_all();
        drop(guard);
        assert_eq!(worker.join().unwrap(), None);
    }

    #[test]
    fn delayed_p_frames_stay_gated_until_requested_idr() {
        // A delayed old P and a new P cannot re-open a stream whose prior
        // encoded reference was dropped. The first eligible actual IDR can.
        assert!(!sendable_after_recovery(true, Some(8), 7, true));
        assert!(!sendable_after_recovery(true, Some(8), 8, false));
        assert!(sendable_after_recovery(true, Some(8), 8, true));
        assert!(sendable_after_recovery(false, None, 7, false));
    }

    #[test]
    fn fixed_plane_fragment_layout_is_dropped_on_midplane_budget_shrink() {
        let plane = MediaPlaneFrame {
            window_id: WINDOW,
            frame_id: 5,
            geometry_epoch: 1,
            plane: MediaPlane::Color,
            source_submitted_ns: 1,
            payload: Bytes::from(vec![7; 120]),
        };
        let initial = plane.clone().fragment(100).unwrap().collect::<Vec<_>>();
        assert!(initial.iter().all(|packet| packet.chunk_count == 3));
        // A smaller live Quinn budget would require a different count. It is
        // intentionally not used to re-fragment the already-started plane.
        let shrunk = plane.fragment(80).unwrap().collect::<Vec<_>>();
        assert!(shrunk.iter().all(|packet| packet.chunk_count == 5));
        assert!(discard_incomplete_frame(&SendDatagramError::TooLarge));
        assert!(!discard_incomplete_frame(&SendDatagramError::Disabled));
    }

    #[test]
    fn absolute_session_and_frame_deadlines_fail_closed() {
        assert!(remaining_session(Instant::now()).is_err());
        assert!(remaining_session(Instant::now() + Duration::from_millis(1)).is_ok());
        let session = Instant::now() + Duration::from_secs(1);
        let frame = session.min(Instant::now() + PRESENTER_ACK_WAIT);
        assert!(frame <= session);
        assert!(frame <= Instant::now() + PRESENTER_ACK_WAIT + Duration::from_millis(1));
        assert!(frame_datagram_budget(Instant::now()).is_none());
        assert!(
            frame_datagram_budget(Instant::now() + PRESENTER_ACK_WAIT)
                .is_some_and(|remaining| remaining <= PRESENTER_ACK_WAIT)
        );
    }

    #[test]
    fn late_frame_rejects_but_fresh_idr_ignores_old_datagram_tails() {
        let clock = ClockEstimate {
            remote_offset_ns: 0,
            network_round_trip_ns: 0,
            uncertainty_ns: 0,
        };
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig {
            deadline_ns: DEADLINE_NS,
            max_chunks_per_plane: 2,
            max_plane_bytes: 16,
        });
        let late = MediaDatagram {
            window_id: WINDOW,
            frame_id: 1,
            geometry_epoch: 1,
            plane: MediaPlane::Color,
            chunk_index: 0,
            chunk_count: 1,
            source_submitted_ns: 0,
            payload: Bytes::from_static(b"old"),
        };
        assert_eq!(
            assembler.push_any_remote(late.clone(), DEADLINE_NS + 1, clock),
            Err(viewflow_transport::MediaAssemblerError::Late)
        );

        let tag = FrameIdentity {
            window: WINDOW,
            frame: 2,
            epoch: 1,
            config: 1,
        };
        // The reliable VFCF slot makes this rejected frame's residual packets
        // harmless; they cannot be re-labelled as the recovery IDR.
        assert!(!datagram_matches_frame(&late, tag));
        assert!(sendable_after_recovery(true, Some(2), 2, true));
        let fresh_idr = MediaDatagram {
            frame_id: tag.frame,
            source_submitted_ns: DEADLINE_NS + 2,
            payload: Bytes::from_static(b"idr"),
            ..late
        };
        assert!(datagram_matches_frame(&fresh_idr, tag));
        assert!(
            assembler
                .push_any_remote(fresh_idr, DEADLINE_NS + 2, clock)
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn receiver_inverts_nonzero_sender_clock_offsets_for_freshness() {
        let plus = ClockEstimate {
            remote_offset_ns: 9,
            network_round_trip_ns: 12,
            uncertainty_ns: 6,
        }
        .inverse()
        .unwrap();
        assert_eq!(plus.remote_offset_ns, -9);
        assert_eq!(plus.remote_to_local_ns(100), 109);
        assert_eq!(plus.age_upper_bound_ns(100, 120), 17);

        let minus = ClockEstimate {
            remote_offset_ns: -9,
            network_round_trip_ns: 12,
            uncertainty_ns: 6,
        }
        .inverse()
        .unwrap();
        assert_eq!(minus.remote_offset_ns, 9);
        assert_eq!(minus.remote_to_local_ns(100), 91);
        assert_eq!(minus.age_upper_bound_ns(100, 120), 35);

        assert!(
            ClockEstimate {
                remote_offset_ns: i64::MIN,
                network_round_trip_ns: 0,
                uncertainty_ns: 0,
            }
            .inverse()
            .is_err()
        );
    }

    #[cfg(windows)]
    #[test]
    #[allow(unsafe_code)] // Read-only Win32 queries on live fixture-owned pipe handles.
    fn presenter_pipe_is_sized_inherited_for_child_and_closes_at_writer_drop() {
        use std::io::{Read, Write};

        assert_eq!(presenter_pipe_buffer_bytes(0), 1);
        assert_eq!(presenter_pipe_buffer_bytes(4096), 4096);
        assert_eq!(
            presenter_pipe_buffer_bytes(MAX_PRESENTER_PIPE_BYTES + 1),
            u32::try_from(MAX_PRESENTER_PIPE_BYTES).unwrap()
        );
        let (mut reader, mut writer) = create_presenter_pipe(4096).unwrap();
        let mut reader_flags = 0;
        let mut writer_flags = 0;
        // SAFETY: both Files retain valid pipe handles for these queries.
        assert_ne!(
            unsafe { GetHandleInformation(reader.as_raw_handle(), &mut reader_flags) },
            0
        );
        // SAFETY: both Files retain valid pipe handles for these queries.
        assert_ne!(
            unsafe { GetHandleInformation(writer.as_raw_handle(), &mut writer_flags) },
            0
        );
        assert_ne!(reader_flags & HANDLE_FLAG_INHERIT, 0);
        assert_eq!(writer_flags & HANDLE_FLAG_INHERIT, 0);
        writer.write_all(b"VFGP2").unwrap();
        drop(writer);
        let mut received = Vec::new();
        reader.read_to_end(&mut received).unwrap();
        assert_eq!(received, b"VFGP2");
    }
}
