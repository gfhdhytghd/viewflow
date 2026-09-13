//! Explicit, connection-bound atlas startup. Use only on an authenticated paired
//! QUIC connection before handing its streams to other readers. Platform owners
//! must probe native decoder support before accepting a plan. No fallback exists.
use crate::atlas_runtime::{AtlasReceiver, AtlasReceiverPolicy};
use anyhow::{Context, Result, bail, ensure};
use prost::Message;
use quinn::Connection;
use tokio::time::{Instant, timeout_at};
use viewflow_protocol::{AtlasFrame, DomainControl, PROTOCOL_VERSION, wire};
use viewflow_transport::{
    CodecDescriptor, CodecResourceLimits, CodecSession, ControlSequencer,
    receive_control_sequenced, send_control,
};

// Opt-in diagnostics only; counters describe the whole connection, not just
// this frame. Enqueue completion is not proof that UDP packets reached the NIC.
fn trace_connection(
    connection: &Connection,
    frame: u64,
    role: &str,
    stage: &str,
    elapsed_us: u128,
) {
    if !crate::atlas_feedback::trace_frame(frame) {
        return;
    }
    let stats = connection.stats();
    crate::atlas_feedback::trace_line(format_args!(
        "atlas-quic-state role={role} frame={frame} stage={stage} elapsed_us={elapsed_us} rtt_us={} cwnd={} lost_packets={} lost_bytes={} congestion_events={} sent_packets={} udp_tx={} udp_tx_bytes={} udp_rx={} udp_rx_bytes={} send_buffer_space={}",
        stats.path.rtt.as_micros(),
        stats.path.cwnd,
        stats.path.lost_packets,
        stats.path.lost_bytes,
        stats.path.congestion_events,
        stats.path.sent_packets,
        stats.udp_tx.datagrams,
        stats.udp_tx.bytes,
        stats.udp_rx.datagrams,
        stats.udp_rx.bytes,
        connection.datagram_send_buffer_space()
    ));
}

#[derive(Default)]
struct ReceiveTrace {
    first_ns: Option<u64>,
    last_ns: Option<u64>,
    staged_ns: Option<u64>,
    datagrams: u64,
    bytes: u64,
}

const MAX_HANDSHAKE_BYTES: usize = 4096;
const MAGIC: &[u8; 4] = b"VFAS";

/// A waiting-only pump deadline; the session retains its pending reads.
#[derive(Debug)]
pub struct AtlasWaitExpired;
impl std::fmt::Display for AtlasWaitExpired {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("atlas receiver wait deadline expired")
    }
}
impl std::error::Error for AtlasWaitExpired {}

#[derive(Debug)]
struct AtlasExpiredBeforeDecode(AtlasFrame);
impl std::fmt::Display for AtlasExpiredBeforeDecode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("exact atlas frame expired before decode")
    }
}
impl std::error::Error for AtlasExpiredBeforeDecode {}

fn check_wait_deadline(deadline: Instant) -> Result<()> {
    if Instant::now() >= deadline {
        return Err(AtlasWaitExpired.into());
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AtlasSessionPlan {
    pub policy: AtlasReceiverPolicy,
    pub color: CodecDescriptor,
    pub alpha: CodecDescriptor,
    pub max_decoded_bytes: u64,
}

/// No manifest or media was queued and sender state was not mutated.
#[derive(Debug)]
pub(crate) struct AtlasFrameExpiredBeforeSend;

impl std::fmt::Display for AtlasFrameExpiredBeforeSend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("atlas frame expired before send preparation")
    }
}

impl std::error::Error for AtlasFrameExpiredBeforeSend {}

impl AtlasSessionPlan {
    pub(crate) fn validate(self) -> Result<CodecSession> {
        AtlasReceiver::new(self.policy)
            .map_err(|error| anyhow::anyhow!("invalid atlas policy: {error:?}"))?;
        for descriptor in [self.color, self.alpha] {
            ensure!(
                descriptor.coded_width <= self.policy.width
                    && descriptor.coded_height <= self.policy.height
                    && descriptor.geometry_epoch == self.policy.geometry_epoch
                    && descriptor.config_generation == self.policy.config_generation,
                "atlas policy/codec shape mismatch"
            );
        }
        let mut codec = CodecSession::new(viewflow_transport::CodecSessionPolicy::default());
        codec.accept_descriptors(
            self.color,
            self.alpha,
            CodecResourceLimits {
                max_coded_width: self.policy.width,
                max_coded_height: self.policy.height,
                max_luma_samples: u64::from(self.policy.width) * u64::from(self.policy.height),
                max_decoded_bytes: self.max_decoded_bytes,
            },
        )?;
        Ok(codec)
    }

    #[allow(clippy::cast_possible_truncation)] // Exact 128-bit ID split.
    fn message(self, connection: &Connection, accepted: bool) -> Result<wire::AtlasSession> {
        ensure!(
            connection.peer_identity().is_some(),
            "atlas requires an authenticated peer"
        );
        let mut binding = [0; 32];
        connection
            .export_keying_material(
                &mut binding,
                b"viewflow-atlas-session-v1",
                &self.policy.stream_id.0.to_be_bytes(),
            )
            .map_err(|_| anyhow::anyhow!("atlas TLS connection binding unavailable"))?;
        Ok(wire::AtlasSession {
            alpha_reference: false,
            selection_rejection_version: 1,
            sparse_patch_version: 1,
            version: 1,
            stream_id: Some(wire::Id128 {
                high: (self.policy.stream_id.0 >> 64) as u64,
                low: self.policy.stream_id.0 as u64,
            }),
            geometry_epoch: self.policy.geometry_epoch,
            config_generation: self.policy.config_generation,
            width: self.policy.width,
            height: self.policy.height,
            max_tiles: u32::try_from(self.policy.max_tiles)?,
            max_encoded_bytes: u64::try_from(self.policy.max_encoded_bytes)?,
            max_age_ns: self.policy.max_age_ns,
            max_future_ns: self.policy.max_future_ns,
            color_descriptor: self.color.encode()?.to_vec(),
            alpha_descriptor: self.alpha.encode()?.to_vec(),
            connection_binding: binding.to_vec(),
            accepted,
            max_decoded_bytes: self.max_decoded_bytes,
        })
    }
}

fn alpha_identity(frame: &AtlasFrame) -> [u8; 40] {
    let mut key = [0; 40];
    key[..16].copy_from_slice(&frame.stream_id.0.to_be_bytes());
    key[16..24].copy_from_slice(&frame.frame_id.to_be_bytes());
    key[24..32].copy_from_slice(&frame.geometry_epoch.to_be_bytes());
    key[32..40].copy_from_slice(&frame.config_generation.to_be_bytes());
    key
}

pub struct AtlasSenderSession {
    connection: Connection,
    plan: AtlasSessionPlan,
    frame_send_poisoned: bool,
    alpha_reference: bool,
    alpha_cache: Option<crate::alpha_reference::AlphaReferenceCache>,
    feedback: Option<quinn::RecvStream>,
    last_disposition: Option<crate::atlas_feedback::AtlasFrameDisposition>,
    shared_control: Option<crate::shared_control::SharedControlSender>,
    control_started: std::sync::atomic::AtomicBool,
}

pub struct AtlasReceiverSession {
    receive_traces: std::collections::BTreeMap<u64, ReceiveTrace>,
    connection: Connection,
    pub admission: AtlasReceiver,
    pub codec: CodecSession,
    policy: AtlasReceiverPolicy,
    assembler: viewflow_transport::MediaAssembler,
    staged: Option<AtlasFrame>,
    color: Option<viewflow_transport::AssembledPlane>,
    alpha: Option<viewflow_transport::AssembledPlane>,
    retired: bool,
    reference_gap: bool,
    last_coded_frame: Option<u64>,
    early: Option<EarlyAtlas>,
    control_sequence: ControlSequencer,
    control_read: Option<ControlRead>,
    // Recovery keeps input/clock controls flowing without admitting pictures.
    // The stop-and-wait sender can have at most one next manifest outstanding.
    fenced_manifest: Option<AtlasFrame>,
    pump_started: bool,
    feedback: Option<quinn::SendStream>,
    feedback_pending: Option<AtlasFrame>,
    alpha_reference: bool,
    alpha_cache: Option<crate::alpha_reference::AlphaReferenceCache>,
    shared_controls: Option<tokio::sync::mpsc::Sender<DomainControl>>,
    // Retain one ordered control when its bounded consumer is busy. Do not
    // read another reliable record until this send completes; media and an
    // already-admitted native presentation must still be allowed to progress.
    pending_shared_control: Option<SharedControlForward>,
}

type SharedControlForward = std::pin::Pin<Box<dyn std::future::Future<Output = Result<()>> + Send>>;

async fn forward_pending_control(pending: &mut Option<SharedControlForward>) -> Result<()> {
    match pending {
        Some(forward) => forward.await,
        None => std::future::pending().await,
    }
}

type ControlReadResult = (
    Result<wire::ControlEnvelope, viewflow_transport::TransportError>,
    ControlSequencer,
);
type ControlRead = std::pin::Pin<Box<dyn std::future::Future<Output = ControlReadResult> + Send>>;

enum PumpEvent {
    Control(ControlReadResult),
    ControlForwarded(Result<()>),
    DeferredManifest(AtlasFrame),
    Media(Result<bytes::Bytes, quinn::ConnectionError>),
    Deadline,
}

fn start_control_read(connection: Connection, mut sequence: ControlSequencer) -> ControlRead {
    Box::pin(async move {
        let result = receive_control_sequenced(&connection, &mut sequence).await;
        (result, sequence)
    })
}

struct EarlyPacket {
    packet: viewflow_transport::MediaDatagram,
    received_ns: u64,
}

struct EarlyAtlas {
    frame_id: u64,
    source_submitted_ns: u64,
    bytes: usize,
    packets: std::collections::BTreeMap<(u8, u16), EarlyPacket>,
}

/// # Errors
/// Requires an exact response on the same authenticated connection and stream,
/// within one absolute deadline. Timeout/error does not authorize media.
pub async fn offer_atlas(
    connection: &Connection,
    plan: AtlasSessionPlan,
    deadline: Instant,
) -> Result<AtlasSenderSession> {
    check_deadline(deadline)?;
    plan.validate()?;
    timeout_at(deadline, async {
        let offer = plan.message(connection, false)?;
        let expected = plan.message(connection, true)?;
        let (mut tx, mut rx) = connection.open_bi().await?;
        write_message(&mut tx, offer).await?;
        let accepted = read_message(&mut rx).await?;
        check_deadline(deadline)?;
        ensure!(
            accepted == expected,
            "atlas acceptance does not match this connection and plan"
        );
        Ok(AtlasSenderSession {
            connection: connection.clone(),
            plan,
            frame_send_poisoned: false,
            alpha_reference: false,
            alpha_cache: None,
            feedback: None,
            last_disposition: None,
            shared_control: None,
            control_started: std::sync::atomic::AtomicBool::new(false),
        })
    })
    .await
    .context("atlas negotiation deadline expired")?
}

/// # Errors
/// Accepts only an exact locally authorized plan. Caller must verify native
/// decoder support first; descriptor validation here does not probe hardware.
pub async fn accept_atlas(
    connection: &Connection,
    plan: AtlasSessionPlan,
    deadline: Instant,
) -> Result<AtlasReceiverSession> {
    check_deadline(deadline)?;
    let codec = plan.validate()?;
    let admission = AtlasReceiver::new(plan.policy)
        .map_err(|error| anyhow::anyhow!("invalid atlas policy: {error:?}"))?;
    timeout_at(deadline, async {
        let expected = plan.message(connection, false)?;
        let (mut tx, mut rx) = connection.accept_bi().await?;
        let offer = read_message(&mut rx).await?;
        ensure!(
            offer == expected,
            "atlas offer does not match this connection and local plan"
        );
        check_deadline(deadline)?;
        write_message(&mut tx, plan.message(connection, true)?).await?;
        check_deadline(deadline)?;
        Ok(receiver_session(connection, plan, admission, codec))
    })
    .await
    .context("atlas negotiation deadline expired")?
}

fn receiver_session(
    connection: &Connection,
    plan: AtlasSessionPlan,
    admission: AtlasReceiver,
    codec: CodecSession,
) -> AtlasReceiverSession {
    AtlasReceiverSession {
        receive_traces: std::collections::BTreeMap::new(),
        connection: connection.clone(),
        admission,
        codec,
        policy: plan.policy,
        assembler: atlas_assembler(plan.policy),
        staged: None,
        color: None,
        alpha: None,
        retired: false,
        reference_gap: true,
        last_coded_frame: None,
        early: None,
        control_sequence: ControlSequencer::default(),
        control_read: None,
        fenced_manifest: None,
        pump_started: false,
        feedback: None,
        feedback_pending: None,
        alpha_reference: false,
        alpha_cache: None,
        shared_controls: None,
        pending_shared_control: None,
    }
}

// Warmed negotiation owns a dedicated connection until acceptance. Dropping a
// partial read/write or native warmup cannot leave that connection reusable.
pub(crate) struct StartupGuard(pub(crate) Option<Connection>);
impl Drop for StartupGuard {
    fn drop(&mut self) {
        if let Some(connection) = &self.0 {
            connection.close(0_u32.into(), b"atlas startup incomplete");
        }
    }
}

pub(crate) fn warmup_limit(plan: AtlasSessionPlan) -> Result<usize> {
    // The native pipe validator also caps decoded alpha with this value. Keep
    // that allocation budget distinct from the negotiated encoded byte bound.
    let encoded = plan
        .policy
        .max_encoded_bytes
        .checked_add(40)
        .context("atlas warmup record limit overflow")?;
    Ok(encoded.max(usize::try_from(plan.max_decoded_bytes)?))
}

fn validate_warmup(
    plan: AtlasSessionPlan,
    frames: &[crate::atlas_presenter::AtlasWarmupFrame; 3],
) -> Result<()> {
    use viewflow_transport::{CodedPixelFormat, VideoCodec};
    ensure!(
        matches!(plan.color.codec, VideoCodec::H264 | VideoCodec::Av1)
            && plan.color.pixel_format == CodedPixelFormat::Nv12
            && plan.alpha.codec == VideoCodec::LosslessAlpha,
        "atlas native warmup requires H264 or AV1/NV12 and VFAR"
    );
    for (index, frame) in frames.iter().enumerate() {
        ensure!(
            frame
                .color
                .len()
                .checked_add(frame.alpha.len())
                .is_some_and(|n| n <= plan.policy.max_encoded_bytes),
            "atlas warmup encoded byte limit"
        );
        ensure!(
            (frame.width, frame.height) == (plan.color.coded_width, plan.color.coded_height),
            "atlas warmup differs from negotiated dimensions"
        );
        crate::gpu_presenter_pipe::encode_compressed_alpha_decode_only_record(
            u64::try_from(index)? + 1,
            frame.width,
            frame.height,
            &frame.color,
            &frame.alpha,
            warmup_limit(plan)?,
        )?;
    }
    Ok(())
}

/// Negotiate on a dedicated paired connection with three reliable startup
/// pictures. Success requires the peer's native warmup before acceptance;
/// it is not a presentation receipt. No cold-mode fallback is attempted.
/// # Errors
/// Failure or cancellation closes this connection, including partial startup.
pub async fn offer_warmed_atlas(
    connection: &Connection,
    plan: AtlasSessionPlan,
    frames: &[crate::atlas_presenter::AtlasWarmupFrame; 3],
    deadline: Instant,
) -> Result<AtlasSenderSession> {
    offer_warmed_atlas_mode(connection, plan, frames, deadline, false).await
}

/// Negotiate V3 stop-and-wait native disposition feedback, with no V2 fallback.
/// # Errors
/// Unsupported capability or incomplete startup closes the paired connection.
pub async fn offer_warmed_atlas_dispositions(
    connection: &Connection,
    plan: AtlasSessionPlan,
    frames: &[crate::atlas_presenter::AtlasWarmupFrame; 3],
    deadline: Instant,
) -> Result<AtlasSenderSession> {
    offer_warmed_atlas_mode(connection, plan, frames, deadline, true).await
}

async fn offer_warmed_atlas_mode(
    connection: &Connection,
    plan: AtlasSessionPlan,
    frames: &[crate::atlas_presenter::AtlasWarmupFrame; 3],
    deadline: Instant,
    dispositions: bool,
) -> Result<AtlasSenderSession> {
    let mut guard = StartupGuard(Some(connection.clone()));
    check_deadline(deadline)?;
    plan.validate()?;
    validate_warmup(plan, frames)?;
    let result = timeout_at(deadline, async {
        let mut offer = plan.message(connection, false)?;
        offer.version = if dispositions { 3 } else { 2 };
        offer.alpha_reference =
            dispositions && plan.alpha.codec == viewflow_transport::VideoCodec::LosslessAlpha;
        let payload = offer.encode_to_vec();
        ensure!(
            payload.len() <= MAX_HANDSHAKE_BYTES,
            "atlas offer too large"
        );
        let (mut tx, mut rx) = connection.open_bi().await?;
        tx.write_all(b"VFAW").await?;
        tx.write_all(&u32::try_from(payload.len())?.to_be_bytes())
            .await?;
        tx.write_all(&payload).await?;
        for frame in frames {
            tx.write_all(&u32::try_from(frame.color.len())?.to_be_bytes())
                .await?;
            tx.write_all(&u32::try_from(frame.alpha.len())?.to_be_bytes())
                .await?;
            tx.write_all(&frame.color).await?;
            tx.write_all(&frame.alpha).await?;
        }
        tx.finish()?;
        let mut expected = plan.message(connection, true)?;
        expected.version = if dispositions { 3 } else { 2 };
        let mut accepted = read_message(&mut rx).await?;
        let alpha_reference = accepted.alpha_reference;
        ensure!(
            !alpha_reference || offer.alpha_reference,
            "unsolicited atlas alpha reference capability"
        );
        accepted.alpha_reference = false;
        ensure!(accepted == expected, "atlas warmup acceptance mismatch");
        let feedback = if dispositions {
            let mut stream = connection.accept_uni().await?;
            let mut magic = [0; 4];
            stream.read_exact(&mut magic).await?;
            ensure!(&magic == b"VFA3", "atlas feedback stream magic");
            Some(stream)
        } else {
            None
        };
        check_deadline(deadline)?;
        Ok(AtlasSenderSession {
            connection: connection.clone(),
            plan,
            frame_send_poisoned: false,
            alpha_reference,
            alpha_cache: None,
            feedback,
            last_disposition: None,
            shared_control: None,
            control_started: std::sync::atomic::AtomicBool::new(false),
        })
    })
    .await
    .context("atlas warmed negotiation expired")??;
    guard.0 = None;
    Ok(result)
}

/// Accept version-2 startup only after `warmup` confirms native decode/copy of
/// all three pictures. The callback must not treat parsing as a hardware probe.
/// # Errors
/// Invalid local/remote plans, payloads, native failures and cancellation close
/// this dedicated connection. One original deadline bounds the entire exchange.
pub async fn accept_warmed_atlas<F, Fut>(
    connection: &Connection,
    plan: AtlasSessionPlan,
    deadline: Instant,
    warmup: F,
) -> Result<AtlasReceiverSession>
where
    F: FnOnce([crate::atlas_presenter::AtlasWarmupFrame; 3]) -> Fut,
    Fut: std::future::Future<Output = Result<()>>,
{
    accept_warmed_atlas_mode(connection, plan, deadline, warmup, false).await
}

/// V3 acceptance requires native disposition capability and completed warmup.
/// # Errors
/// Capability mismatch or cancellation closes the dedicated connection.
pub async fn accept_warmed_atlas_dispositions<F, Fut>(
    connection: &Connection,
    plan: AtlasSessionPlan,
    deadline: Instant,
    warmup: F,
) -> Result<AtlasReceiverSession>
where
    F: FnOnce([crate::atlas_presenter::AtlasWarmupFrame; 3]) -> Fut,
    Fut: std::future::Future<Output = Result<()>>,
{
    accept_warmed_atlas_mode(connection, plan, deadline, warmup, true).await
}

async fn accept_warmed_atlas_mode<F, Fut>(
    connection: &Connection,
    mut plan: AtlasSessionPlan,
    deadline: Instant,
    warmup: F,
    dispositions: bool,
) -> Result<AtlasReceiverSession>
where
    F: FnOnce([crate::atlas_presenter::AtlasWarmupFrame; 3]) -> Fut,
    Fut: std::future::Future<Output = Result<()>>,
{
    let mut guard = StartupGuard(Some(connection.clone()));
    check_deadline(deadline)?;
    plan.validate()?;
    let admission = AtlasReceiver::new(plan.policy)
        .map_err(|error| anyhow::anyhow!("invalid atlas policy: {error:?}"))?;
    let result = timeout_at(deadline, async {
        let (mut tx, mut rx) = connection.accept_bi().await?;
        let mut header = [0; 8];
        rx.read_exact(&mut header).await?;
        ensure!(&header[..4] == b"VFAW", "atlas warmed startup magic");
        let length = u32::from_be_bytes(header[4..].try_into()?) as usize;
        ensure!(
            length <= MAX_HANDSHAKE_BYTES,
            "atlas warmed offer too large"
        );
        let mut payload = vec![0; length];
        rx.read_exact(&mut payload).await?;
        let offer = wire::AtlasSession::decode(payload.as_slice())?;
        if plan.color.coded_width < plan.policy.width
            || plan.color.coded_height < plan.policy.height
        {
            let color = CodecDescriptor::decode(offer.color_descriptor.clone().into())?;
            for descriptor in [&mut plan.color, &mut plan.alpha] {
                descriptor.coded_width = color.coded_width;
                descriptor.coded_height = color.coded_height;
            }
        }
        let codec = plan.validate()?;
        let mut expected = plan.message(connection, false)?;
        expected.version = if dispositions { 3 } else { 2 };
        expected.alpha_reference = offer.alpha_reference;
        if offer != expected {
            // Keep pairing material out of diagnostics; show the mismatched
            // public plan so deployment/configuration failures are actionable.
            let binding_matches = offer.connection_binding == expected.connection_binding;
            let mut offered = offer.clone(); offered.connection_binding.clear();
            let mut wanted = expected.clone(); wanted.connection_binding.clear();
            bail!("atlas warmed offer mismatch binding_matches={binding_matches} offered={offered:?} expected={wanted:?}");
        }
        let frames = read_warmup_frames(&mut rx, plan).await?;
        validate_warmup(plan, &frames)?;
        check_deadline(deadline)?;
        warmup(frames).await?;
        check_deadline(deadline)?;
        let mut accepted = plan.message(connection, true)?;
        accepted.version = if dispositions { 3 } else { 2 };
        accepted.alpha_reference = offer.alpha_reference && dispositions
            && plan.alpha.codec == viewflow_transport::VideoCodec::LosslessAlpha;
        let alpha_reference = accepted.alpha_reference;
        write_message(&mut tx, accepted).await?;
        check_deadline(deadline)?;
        let mut receiver = receiver_session(connection, plan, admission, codec);
        receiver.alpha_reference = alpha_reference;
        if dispositions {
            let mut stream = connection.open_uni().await?;
            stream.write_all(b"VFA3").await?;
            receiver.feedback = Some(stream);
        }
        Ok(receiver)
    })
    .await
    .context("atlas warmed negotiation expired")??;
    guard.0 = None;
    Ok(result)
}

async fn read_warmup_frames(
    rx: &mut quinn::RecvStream,
    plan: AtlasSessionPlan,
) -> Result<[crate::atlas_presenter::AtlasWarmupFrame; 3]> {
    let mut frames = Vec::with_capacity(3);
    for _ in 0..3 {
        let mut lengths = [0; 8];
        rx.read_exact(&mut lengths).await?;
        let color = u32::from_be_bytes(lengths[..4].try_into()?) as usize;
        let alpha = u32::from_be_bytes(lengths[4..].try_into()?) as usize;
        ensure!(
            color > 0
                && alpha > 0
                && color
                    .checked_add(alpha)
                    .is_some_and(|n| n <= plan.policy.max_encoded_bytes),
            "atlas warmup payload limit"
        );
        let mut color_bytes = vec![0; color];
        let mut alpha_bytes = vec![0; alpha];
        rx.read_exact(&mut color_bytes).await?;
        rx.read_exact(&mut alpha_bytes).await?;
        frames.push(crate::atlas_presenter::AtlasWarmupFrame {
            width: plan.color.coded_width,
            height: plan.color.coded_height,
            color: color_bytes.into(),
            alpha: alpha_bytes.into(),
        });
    }
    ensure!(
        rx.read(&mut [0; 1]).await?.is_none(),
        "trailing atlas warmup bytes"
    );
    frames
        .try_into()
        .map_err(|_| anyhow::anyhow!("atlas warmup count"))
}

impl AtlasSenderSession {
    pub(crate) fn canvas_limit(&self) -> (u32, u32) {
        (self.plan.policy.width, self.plan.policy.height)
    }
    /// Attach the sole connection-wide writer before the first manifest. The
    /// frame identity stays unchanged; wire control sequences belong to writer.
    /// # Errors
    /// Rejects foreign, closed, replaced or already-started control ownership.
    pub fn attach_shared_control(
        &mut self,
        sender: crate::shared_control::SharedControlSender,
    ) -> Result<()> {
        ensure!(
            sender.belongs_to(&self.connection)
                && self.shared_control.is_none()
                && !self
                    .control_started
                    .load(std::sync::atomic::Ordering::Acquire),
            "atlas shared control must bind before first manifest on the same connection"
        );
        self.shared_control = Some(sender);
        Ok(())
    }
    #[must_use]
    pub fn last_disposition(&self) -> Option<crate::atlas_feedback::AtlasFrameDisposition> {
        self.last_disposition
    }
    /// Publish an encoder-produced pair without discarding its identity or
    /// keyframe metadata before validating it against the atlas manifest.
    /// # Errors
    /// A mismatched pair is rejected before any network enqueue.
    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    pub async fn send_coded_frame(
        &mut self,
        manifest: AtlasFrame,
        media: crate::compatible_encoder::MediaFrame,
        sequence: u64,
        deadline: Instant,
    ) -> Result<()> {
        for (plane, metadata, role, keyframe) in [
            (
                &media.color,
                media.color_metadata,
                viewflow_transport::MediaPlane::Color,
                manifest.color_keyframe,
            ),
            (
                &media.alpha,
                media.alpha_metadata,
                viewflow_transport::MediaPlane::Alpha,
                manifest.alpha_keyframe,
            ),
        ] {
            ensure!(
                plane.window_id == manifest.stream_id
                    && plane.frame_id == manifest.frame_id
                    && plane.geometry_epoch == manifest.geometry_epoch
                    && plane.source_submitted_ns == manifest.source_submitted_ns
                    && plane.plane == role
                    && metadata.config_generation == manifest.config_generation
                    && metadata.keyframe == keyframe,
                "atlas encoder pair does not match manifest"
            );
        }
        self.send_frame(
            manifest,
            media.color.payload,
            media.alpha.payload,
            sequence,
            deadline,
        )
        .await
        .context("send encoded atlas pair")
    }

    /// Enqueue both planes under the original absolute deadline. Cancellation or
    /// partial failure poisons this sender: a possibly broken reference chain
    /// must not be continued. Success is not a remote presentation receipt.
    /// # Errors
    /// Rejects oversized/empty planes, unavailable datagrams and expired work.
    pub async fn send_frame(
        &mut self,
        manifest: AtlasFrame,
        color: bytes::Bytes,
        alpha: bytes::Bytes,
        sequence: u64,
        deadline: Instant,
    ) -> Result<()> {
        ensure!(
            !self.frame_send_poisoned,
            "atlas sender requires renegotiation"
        );
        ensure!(
            self.last_disposition
                != Some(crate::atlas_feedback::AtlasFrameDisposition::ExpiredUnbound)
                || (manifest.color_keyframe && manifest.alpha_keyframe),
            "atlas feedback requires fresh paired keyframe"
        );
        if Instant::now() >= deadline {
            return Err(AtlasFrameExpiredBeforeSend.into());
        }
        let trace = crate::atlas_feedback::trace_frame(manifest.frame_id);
        let started = trace.then(Instant::now);
        trace_connection(&self.connection, manifest.frame_id, "source", "begin", 0);
        let encoded_bytes = color.len().saturating_add(alpha.len());
        // Freshness decides whether to start this frame. It must not cancel a
        // partially sent manifest/pair or terminate the stream at 33 ms.
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        ensure!(
            color
                .len()
                .checked_add(alpha.len())
                .is_some_and(|bytes| bytes <= self.plan.policy.max_encoded_bytes),
            "atlas encoded byte limit exceeded"
        );
        let full_alpha = alpha.clone();
        let alpha = if self.alpha_reference && !manifest.color_keyframe && alpha.len() > 84 {
            self.alpha_cache
                .as_ref()
                .and_then(|cache| {
                    cache.reference_for(
                        alpha_identity(&manifest),
                        manifest.width,
                        manifest.height,
                        &alpha,
                    )
                })
                .map(|key| {
                    let mut bytes = Vec::with_capacity(84);
                    bytes.extend_from_slice(b"VFAF");
                    bytes.extend_from_slice(&key);
                    bytes::Bytes::from(bytes)
                })
                .unwrap_or(alpha)
        } else {
            alpha
        };
        let alpha_referenced = alpha.starts_with(b"VFAF");
        let wire_bytes = color.len().saturating_add(alpha.len());
        let budget = self
            .connection
            .max_datagram_size()
            .context("atlas peer does not support datagrams")?;
        let plane = |payload, plane| {
            viewflow_transport::MediaPlaneFrame {
                window_id: manifest.stream_id,
                frame_id: manifest.frame_id,
                geometry_epoch: manifest.geometry_epoch,
                source_submitted_ns: manifest.source_submitted_ns,
                plane,
                payload,
            }
            .fragment(budget)
        };
        let color = plane(color, viewflow_transport::MediaPlane::Color)?;
        let alpha = plane(alpha, viewflow_transport::MediaPlane::Alpha)?;
        let packet_count = color.len().saturating_add(alpha.len());
        ensure!(
            color.len() <= usize::from(u16::MAX) && alpha.len() <= usize::from(u16::MAX),
            "atlas chunk limit exceeded"
        );
        self.frame_send_poisoned = true;
        let pending = manifest.clone();
        let fragmented = trace.then(Instant::now);
        // The internal call must bypass only the poison guard while retaining
        // all manifest validation. The flag stays set throughout every await.
        self.send_manifest_inner(manifest, sequence, deadline)
            .await?;
        let manifest_sent = trace.then(Instant::now);
        trace_connection(
            &self.connection,
            pending.frame_id,
            "source",
            "manifest_enqueued",
            started.map_or(0, |t| t.elapsed().as_micros()),
        );
        for packet in color.chain(alpha) {
            check_deadline(deadline).context("before atlas datagram enqueue")?;
            timeout_at(
                deadline,
                self.connection.send_datagram_wait(packet.encode()),
            )
            .await
            .context("atlas media send deadline expired")??;
        }
        check_deadline(deadline).context("after atlas datagram enqueue")?;
        let enqueued = trace.then(Instant::now);
        trace_connection(
            &self.connection,
            pending.frame_id,
            "source",
            "media_enqueued",
            started.map_or(0, |t| t.elapsed().as_micros()),
        );
        if let Some(feedback) = &mut self.feedback {
            let feedback_deadline = deadline + std::time::Duration::from_millis(150);
            let mut record = [0; crate::atlas_feedback::RECORD_BYTES];
            timeout_at(feedback_deadline, feedback.read_exact(&mut record))
                .await
                .context("atlas disposition feedback expired")??;
            check_deadline(feedback_deadline)?;
            self.last_disposition = Some(crate::atlas_feedback::decode(&record, &pending)?);
            trace_connection(
                &self.connection,
                pending.frame_id,
                "source",
                "feedback_received",
                started.map_or(0, |t| t.elapsed().as_micros()),
            );
        }
        if self.alpha_reference
            && !alpha_referenced
            && self.last_disposition
                == Some(crate::atlas_feedback::AtlasFrameDisposition::Committed)
        {
            self.alpha_cache = Some(crate::alpha_reference::AlphaReferenceCache::new(
                alpha_identity(&pending),
                pending.width,
                pending.height,
                full_alpha,
                warmup_limit(self.plan)?,
            )?);
        }
        if let (Some(started), Some(fragmented), Some(manifest_sent), Some(enqueued)) =
            (started, fragmented, manifest_sent, enqueued)
        {
            crate::atlas_feedback::trace_line(format_args!(
                "atlas-wire-timing frame={} encoded_bytes={encoded_bytes} wire_bytes={wire_bytes} alpha_referenced={alpha_referenced} packets={packet_count} fragment_us={} manifest_us={} enqueue_us={} feedback_us={} total_us={} disposition={:?}",
                pending.frame_id,
                fragmented.duration_since(started).as_micros(),
                manifest_sent.duration_since(fragmented).as_micros(),
                enqueued.duration_since(manifest_sent).as_micros(),
                enqueued.elapsed().as_micros(),
                started.elapsed().as_micros(),
                self.last_disposition,
            ));
        }
        self.frame_send_poisoned = false;
        Ok(())
    }

    /// Reliable enqueue only, NOT a publication/presentation acknowledgement.
    /// # Errors
    /// Rejects wrong session metadata, invalid manifests or deadline expiry.
    pub async fn send_manifest(
        &self,
        manifest: AtlasFrame,
        sequence: u64,
        deadline: Instant,
    ) -> Result<()> {
        ensure!(
            self.feedback.is_none(),
            "V3 requires complete stop-and-wait frame send"
        );
        ensure!(
            !self.frame_send_poisoned,
            "atlas sender requires renegotiation"
        );
        self.send_manifest_inner(manifest, sequence, deadline).await
    }

    async fn send_manifest_inner(
        &self,
        manifest: AtlasFrame,
        sequence: u64,
        deadline: Instant,
    ) -> Result<()> {
        check_deadline(deadline).context("before atlas manifest preparation")?;
        manifest
            .validate()
            .map_err(|error| anyhow::anyhow!("invalid atlas manifest: {error:?}"))?;
        let policy = self.plan.policy;
        ensure!(
            sequence > 0
                && manifest.stream_id == policy.stream_id
                && manifest.geometry_epoch == policy.geometry_epoch
                && manifest.config_generation == policy.config_generation
                && manifest.width <= policy.width
                && manifest.height <= policy.height
                && manifest.tiles.len() <= policy.max_tiles,
            "manifest outside negotiated atlas plan"
        );
        self.control_started
            .store(true, std::sync::atomic::Ordering::Release);
        if let Some(sender) = &self.shared_control {
            return sender
                .send(
                    wire::control_envelope::Payload::AtlasFrame(manifest.into()),
                    deadline,
                )
                .await;
        }
        let envelope = wire::ControlEnvelope {
            protocol_major: u32::from(PROTOCOL_VERSION.major),
            protocol_minor: u32::from(PROTOCOL_VERSION.minor),
            sequence,
            payload: Some(wire::control_envelope::Payload::AtlasFrame(manifest.into())),
        };
        timeout_at(deadline, send_control(&self.connection, &envelope))
            .await
            .context("atlas manifest send deadline expired")??;
        check_deadline(deadline).context("after atlas manifest enqueue")
    }
}

impl AtlasReceiverSession {
    /// Forward only receiver-side input/clock controls from the same sequenced
    /// read that receives manifests. Never start a second connection reader.
    /// # Errors
    /// Attach once before reading, with a live bounded queue of at most 256.
    pub fn attach_shared_controls(
        &mut self,
        controls: tokio::sync::mpsc::Sender<DomainControl>,
    ) -> Result<()> {
        ensure!(
            !self.retired
                && !self.pump_started
                && self.control_sequence.previous().is_none()
                && self.shared_controls.is_none()
                && !controls.is_closed()
                && controls.max_capacity() <= 256,
            "invalid atlas control dispatcher attachment"
        );
        self.shared_controls = Some(controls);
        Ok(())
    }
    /// Complete the exact admitted handoff using a validated native disposition.
    /// # Errors
    /// Missing/mismatched pending frames, cancellation and write errors retire
    /// this receiver. Never call this for ambiguous or post-binding expiry.
    pub async fn report_disposition(
        &mut self,
        frame: &AtlasFrame,
        result: crate::atlas_feedback::AtlasFrameDisposition,
        deadline: Instant,
    ) -> Result<()> {
        ensure!(
            !self.retired && self.feedback_pending.as_ref() == Some(frame),
            "atlas feedback has no exact pending handoff"
        );
        let record = crate::atlas_feedback::encode(frame, result)?;
        self.retired = true;
        let stream = self
            .feedback
            .as_mut()
            .context("atlas feedback not negotiated")?;
        timeout_at(deadline, stream.write_all(&record))
            .await
            .context("atlas feedback write expired")??;
        check_deadline(deadline)?;
        self.reference_gap = result == crate::atlas_feedback::AtlasFrameDisposition::ExpiredUnbound;
        self.feedback_pending = None;
        self.retired = false;
        Ok(())
    }
    /// Drive both inputs until one frame is admitted. The partially consumed
    /// control read lives in this session, not in this call's future: cancelling
    /// or timing out the wait cannot discard half a reliable message. Frame
    /// timestamps remain unchanged when waiting again with another call deadline.
    /// Do not mix this pump with the individual receive APIs once started.
    /// # Errors
    /// A wait deadline preserves pending reads. Protocol/media errors retire the
    /// session; successful return is still not a native presentation receipt.
    pub async fn next_frame(
        &mut self,
        now: impl FnMut() -> u64,
        deadline: Instant,
    ) -> Result<crate::atlas_runtime::AdmittedAtlas> {
        self.next_frame_with_fence(now, deadline, None).await
    }

    pub(crate) async fn next_frame_with_fence(
        &mut self,
        mut now: impl FnMut() -> u64,
        deadline: Instant,
        fence: Option<&crate::atlas_receiver_presenter::AtlasInputRecoveryFence>,
    ) -> Result<crate::atlas_runtime::AdmittedAtlas> {
        ensure!(
            self.feedback_pending.is_none(),
            "atlas native handoff still pending"
        );
        ensure!(!self.retired, "atlas receiver session is retired");
        check_wait_deadline(deadline)?;
        self.pump_started = true;
        if self.control_read.is_none() {
            self.control_read = Some(start_control_read(
                self.connection.clone(),
                self.control_sequence,
            ));
        }
        loop {
            // Quinn 0.11 removes a datagram only on Poll::Ready. The reliable
            // read can consume partial bytes, so its boxed future is retained.
            let receive = async {
                Ok(if let Some(manifest) = self.fenced_manifest.take() {
                    PumpEvent::DeferredManifest(manifest)
                } else {
                    let reader = self
                        .control_read
                        .as_mut()
                        .ok_or_else(|| anyhow::anyhow!("missing atlas control reader"))?;
                    tokio::select! {
                        control = reader, if self.pending_shared_control.is_none() => PumpEvent::Control(control),
                        result = forward_pending_control(&mut self.pending_shared_control) => PumpEvent::ControlForwarded(result),
                        media = self.connection.read_datagram() => PumpEvent::Media(media),
                        () = tokio::time::sleep_until(deadline) => PumpEvent::Deadline,
                    }
                })
            };
            // Only interrupt the receive wait. Disposition writes and admitted
            // native submissions must finish under their existing ownership.
            let event = match fence {
                Some(fence) => fence.wait_before_admission(receive).await?,
                None => receive.await?,
            };
            if matches!(event, PumpEvent::Deadline) {
                return Err(AtlasWaitExpired.into());
            }
            let result = self.process_event(event, now()).and_then(|frame| {
                if frame.is_some() {
                    self.finish_handoff(frame, now(), deadline)
                } else {
                    Ok(None)
                }
            });
            let frame = match result {
                Ok(frame) => frame,
                Err(error) if error.downcast_ref::<AtlasExpiredBeforeDecode>().is_some() => {
                    let expired = error.downcast::<AtlasExpiredBeforeDecode>()?.0;
                    self.feedback_pending = Some(expired.clone());
                    self.report_disposition(
                        &expired,
                        crate::atlas_feedback::AtlasFrameDisposition::ExpiredUnbound,
                        Instant::now() + std::time::Duration::from_millis(25),
                    )
                    .await?;
                    self.last_coded_frame = Some(expired.frame_id);
                    self.staged = None;
                    self.color = None;
                    self.alpha = None;
                    self.early = None;
                    self.assembler = atlas_assembler(self.policy);
                    continue;
                }
                Err(error) => {
                    self.retire_media();
                    return Err(error);
                }
            };
            if frame.is_some() {
                return frame.ok_or_else(|| anyhow::anyhow!("missing admitted atlas frame"));
            }
            // A waiting-only timeout does not retire or drop the owned read.
            check_wait_deadline(deadline)?;
        }
    }

    /// Keep the sole reliable reader alive while recovery waits for its source
    /// grant and then its media-owner request. No media datagrams are consumed,
    /// and a next manifest stays immutable until ordinary frame admission.
    /// The caller owns the recovery wait's deadline and owner-close handling.
    pub(crate) async fn with_fenced_controls<T>(
        &mut self,
        waiting: impl std::future::Future<Output = Result<T>>,
    ) -> Result<T> {
        ensure!(
            !self.retired && self.feedback_pending.is_none(),
            "recovery control pump overlaps an admitted frame"
        );
        let controls = self
            .shared_controls
            .as_ref()
            .context("recovery control pump requires shared input owner")?
            .clone();
        self.pump_started = true;
        if self.control_read.is_none() {
            self.control_read = Some(start_control_read(
                self.connection.clone(),
                self.control_sequence,
            ));
        }
        tokio::pin!(waiting);
        let result = async {
            loop {
                let reader = self.control_read.as_mut().context("recovery control reader missing")?;
                let (result, sequence) = tokio::select! {
                    result = &mut waiting => return result,
                    () = controls.closed() => anyhow::bail!("atlas recovery input control owner closed"),
                    control = reader, if self.pending_shared_control.is_none() => control,
                    result = forward_pending_control(&mut self.pending_shared_control) => {
                        self.pending_shared_control = None;
                        result?;
                        continue;
                    },
                };
                self.control_sequence = sequence;
                self.control_read = Some(start_control_read(self.connection.clone(), sequence));
                let control = DomainControl::try_from(result?)
                    .map_err(|e| anyhow::anyhow!("invalid fenced atlas control: {e:?}"))?;
                if let DomainControl::AtlasFrame(manifest) = control {
                    ensure!(self.fenced_manifest.is_none(),
                        "atlas sender advanced twice while recovery withheld frame disposition");
                    self.fenced_manifest = Some(manifest);
                } else {
                    self.process_domain_control(control, 0)?;
                }
            }
        }.await;
        if result.is_err() {
            self.retire_media();
        }
        result
    }

    /// Keep the sole reliable reader alive while the native presenter is busy.
    /// V3's sender cannot advance media before this frame's disposition.
    pub(crate) async fn with_handoff_controls<T>(
        &mut self,
        presenting: impl std::future::Future<Output = Result<T>>,
    ) -> Result<T> {
        if self.shared_controls.is_none() {
            return presenting.await;
        }
        ensure!(
            !self.retired && self.feedback_pending.is_some(),
            "no active native handoff"
        );
        tokio::pin!(presenting);
        loop {
            let reader = self
                .control_read
                .as_mut()
                .context("native handoff control reader missing")?;
            let event = tokio::select! {
                result = &mut presenting => return result,
                control = reader, if self.pending_shared_control.is_none() => PumpEvent::Control(control),
                result = forward_pending_control(&mut self.pending_shared_control) => PumpEvent::ControlForwarded(result),
            };
            let control_result = (|| {
                let (result, sequence) = match event {
                    PumpEvent::ControlForwarded(result) => {
                        self.pending_shared_control = None;
                        return result.map(|()| None);
                    }
                    PumpEvent::Control(control) => control,
                    _ => unreachable!("handoff only polls reliable controls"),
                };
                self.control_sequence = sequence;
                self.control_read = Some(start_control_read(self.connection.clone(), sequence));
                let envelope = result?;
                ensure!(
                    !matches!(
                        envelope.payload,
                        Some(wire::control_envelope::Payload::AtlasFrame(_))
                    ),
                    "atlas sender advanced before native disposition"
                );
                self.process_control(envelope, 0)
            })();
            if let Err(error) = control_result {
                // Stop input/control authority immediately, but do not cancel
                // this already-admitted native submission's bounded cleanup.
                // It may have closed the input queue while retaining the root
                // presentation error across child termination.
                self.connection
                    .close(0_u32.into(), b"atlas handoff control ended");
                return drain_handoff_after_control_error(&mut presenting, error).await;
            }
        }
    }

    fn process_event(
        &mut self,
        event: PumpEvent,
        now: u64,
    ) -> Result<Option<crate::atlas_runtime::AdmittedAtlas>> {
        match event {
            PumpEvent::ControlForwarded(result) => {
                self.pending_shared_control = None;
                result?;
                Ok(None)
            }
            // The reliable sequence was already consumed under the fence.
            // Do not rewind it or restart the retained partial control read.
            PumpEvent::DeferredManifest(manifest) => self.stage_manifest(manifest, now),
            PumpEvent::Control((result, sequence)) => {
                self.control_sequence = sequence;
                self.control_read = Some(start_control_read(self.connection.clone(), sequence));
                self.process_control(result?, now)
            }
            PumpEvent::Media(result) => {
                self.push_media(viewflow_transport::MediaDatagram::decode(result?)?, now)
            }
            PumpEvent::Deadline => anyhow::bail!("unexpected atlas deadline dispatch"),
        }
    }

    fn process_control(
        &mut self,
        envelope: wire::ControlEnvelope,
        now: u64,
    ) -> Result<Option<crate::atlas_runtime::AdmittedAtlas>> {
        let control = DomainControl::try_from(envelope)
            .map_err(|error| anyhow::anyhow!("invalid atlas control: {error:?}"))?;
        self.process_domain_control(control, now)
    }

    fn process_domain_control(
        &mut self,
        control: DomainControl,
        now: u64,
    ) -> Result<Option<crate::atlas_runtime::AdmittedAtlas>> {
        match control {
            DomainControl::AtlasFrame(manifest) => self.stage_manifest(manifest, now),
            control @ (DomainControl::ApplicationIcon(_)
            | DomainControl::InputLease(_)
            | DomainControl::InputEvent(_)
            | DomainControl::InputLeaseRevoke(_)
            | DomainControl::WindowPointerAuthorization(_)
            | DomainControl::AtlasWindowSelectionRejected(_)
            | DomainControl::AtlasWindowSelectionAccepted(_)
            | DomainControl::WindowPointerAck(_)
            | DomainControl::WindowKeyboardAuthorization(_)
            | DomainControl::WindowKeyboardAck(_)
            | DomainControl::DesktopWindowMoveAck(_)
            | DomainControl::ClockSyncProbe(_)
            | DomainControl::ClockSyncReply(_)) => {
                ensure!(
                    self.pending_shared_control.is_none(),
                    "ordered control forward still pending"
                );
                let controls = self
                    .shared_controls
                    .as_ref()
                    .context("non-atlas control requires another dispatcher")?;
                match controls.try_send(control) {
                    Ok(()) => {}
                    Err(tokio::sync::mpsc::error::TrySendError::Full(control)) => {
                        let controls = controls.clone();
                        self.pending_shared_control = Some(Box::pin(async move {
                            controls
                                .send(control)
                                .await
                                .context("atlas shared control consumer closed")
                        }));
                    }
                    Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                        anyhow::bail!("atlas shared control consumer closed");
                    }
                }
                Ok(None)
            }
            _ => anyhow::bail!("control is not allowed on atlas receiver"),
        }
    }

    /// Use only while this owner exclusively dispatches atlas control streams.
    /// `now` is sampled after receive so transport wait cannot renew freshness.
    /// Returns an admitted frame immediately if its datagrams arrived earlier;
    /// callers must forward that result just like `receive_media` output.
    /// # Errors
    /// Rejects wrong payloads, control replay and stale/inconsistent layouts.
    pub async fn receive_manifest(
        &mut self,
        sequencer: &mut ControlSequencer,
        mut now: impl FnMut() -> u64,
        deadline: Instant,
    ) -> Result<Option<crate::atlas_runtime::AdmittedAtlas>> {
        ensure!(!self.retired, "atlas receiver session is retired");
        ensure!(
            !self.pump_started,
            "individual reads cannot replace the active atlas pump"
        );
        ensure!(
            sequencer.previous().unwrap_or(0) >= self.control_sequence.previous().unwrap_or(0),
            "atlas control sequencer regressed"
        );
        check_deadline(deadline)?;
        if self.pending_shared_control.is_some() {
            timeout_at(
                deadline,
                forward_pending_control(&mut self.pending_shared_control),
            )
            .await
            .context("atlas control forward wait expired")??;
            self.pending_shared_control = None;
        }
        let envelope = timeout_at(
            deadline,
            receive_control_sequenced(&self.connection, sequencer),
        )
        .await
        .context("atlas manifest receive deadline expired")??;
        self.control_sequence = *sequencer;
        check_deadline(deadline)?;
        let frame = self.process_control(envelope, now())?;
        self.finish_handoff(frame, now(), deadline)
    }

    fn stage_manifest(
        &mut self,
        manifest: AtlasFrame,
        now: u64,
    ) -> Result<Option<crate::atlas_runtime::AdmittedAtlas>> {
        if crate::atlas_feedback::trace_frame(manifest.frame_id) {
            self.receive_traces
                .entry(manifest.frame_id)
                .or_default()
                .staged_ns = Some(now);
            self.trim_receive_traces();
            trace_connection(
                &self.connection,
                manifest.frame_id,
                "receiver",
                "manifest_staged",
                0,
            );
        }
        let expired = self
            .admission
            .stage_with_expiry(manifest.clone(), now, self.feedback.is_some())
            .map_err(|error| anyhow::anyhow!("atlas admission rejected: {error:?}"))?;
        if expired {
            return Err(AtlasExpiredBeforeDecode(manifest).into());
        }
        if self.staged.is_some()
            || self
                .last_coded_frame
                .is_some_and(|last| last.checked_add(1) != Some(manifest.frame_id))
        {
            self.reference_gap = true;
        }
        self.staged = Some(manifest);
        self.color = None;
        self.alpha = None;
        self.assembler = atlas_assembler(self.policy);
        let staged_id = self.staged.as_ref().map(|layout| layout.frame_id);
        let mut admitted = None;
        if self
            .early
            .as_ref()
            .is_some_and(|early| Some(early.frame_id) == staged_id)
        {
            let early = self
                .early
                .take()
                .ok_or_else(|| anyhow::anyhow!("missing early atlas"))?;
            for buffered in early.packets.into_values() {
                match self.push_media_inner(buffered.packet, buffered.received_ns, now) {
                    Ok(Some(frame)) => admitted = Some(frame),
                    Ok(None) => {}
                    Err(error) => {
                        if !error.is::<AtlasExpiredBeforeDecode>() {
                            self.retire_media();
                        }
                        return Err(error);
                    }
                }
            }
        } else if self
            .early
            .as_ref()
            .is_some_and(|early| staged_id.is_some_and(|id| early.frame_id < id))
        {
            self.early = None;
        }
        Ok(admitted)
    }

    /// Accept one datagram whose timestamp is already in the receiver clock.
    /// Older media is dropped; one latest early frame is buffered until its
    /// manifest arrives, without timestamp renewal. Errors retire this receiver.
    /// # Errors
    /// Rejects malformed, inconsistent, over-budget or stale completed media.
    pub fn push_media(
        &mut self,
        packet: viewflow_transport::MediaDatagram,
        now: u64,
    ) -> Result<Option<crate::atlas_runtime::AdmittedAtlas>> {
        ensure!(!self.retired, "atlas receiver session is retired");
        if packet.window_id == self.policy.stream_id
            && crate::atlas_feedback::trace_frame(packet.frame_id)
        {
            let record = self.receive_traces.entry(packet.frame_id).or_default();
            let first = record.first_ns.is_none();
            record.first_ns.get_or_insert(now);
            record.last_ns = Some(now);
            record.datagrams += 1;
            record.bytes += packet.payload.len() as u64;
            if first {
                trace_connection(
                    &self.connection,
                    packet.frame_id,
                    "receiver",
                    "first_datagram_dispatched",
                    0,
                );
            }
            self.trim_receive_traces();
        }
        let result = self.push_media_inner(packet, now, now);
        if result
            .as_ref()
            .is_err_and(|error| error.downcast_ref::<AtlasExpiredBeforeDecode>().is_none())
        {
            self.retire_media();
        }
        result
    }

    fn push_media_inner(
        &mut self,
        packet: viewflow_transport::MediaDatagram,
        received_ns: u64,
        now: u64,
    ) -> Result<Option<crate::atlas_runtime::AdmittedAtlas>> {
        ensure!(
            packet.window_id == self.policy.stream_id,
            "datagram belongs to another atlas stream"
        );
        if self
            .last_coded_frame
            .is_some_and(|last| packet.frame_id <= last)
            || self
                .staged
                .as_ref()
                .is_some_and(|layout| packet.frame_id < layout.frame_id)
        {
            return Ok(None);
        }
        if self
            .staged
            .as_ref()
            .is_none_or(|layout| packet.frame_id > layout.frame_id)
        {
            self.buffer_early(packet, received_ns)?;
            return Ok(None);
        }
        let layout = self
            .staged
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("missing current atlas"))?;
        ensure!(
            packet.geometry_epoch == layout.geometry_epoch
                && packet.source_submitted_ns == layout.source_submitted_ns,
            "atlas datagram metadata mismatch"
        );
        let assembled = if self.feedback.is_some() {
            self.assembler.push_latest(packet, received_ns)?
        } else {
            match self.assembler.push(packet, received_ns) {
                Ok(plane) => plane,
                Err(viewflow_transport::MediaAssemblerError::Late) => return Ok(None),
                Err(error) => return Err(error.into()),
            }
        };
        let Some(plane) = assembled else {
            return Ok(None);
        };
        match plane.ready.plane {
            viewflow_protocol::FramePlane::Color => self.color = Some(plane),
            viewflow_protocol::FramePlane::Alpha => self.alpha = Some(plane),
        }
        self.finish_pair(now)
    }

    fn finish_pair(&mut self, now: u64) -> Result<Option<crate::atlas_runtime::AdmittedAtlas>> {
        use viewflow_transport::{FrameCodecMetadata, MediaPlane, MediaPlaneFrame};
        let layout = self
            .staged
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("missing current atlas"))?;
        if self.color.is_none() || self.alpha.is_none() {
            return Ok(None);
        }
        let color = self
            .color
            .take()
            .ok_or_else(|| anyhow::anyhow!("missing atlas color"))?;
        let alpha = self
            .alpha
            .take()
            .ok_or_else(|| anyhow::anyhow!("missing atlas alpha"))?;
        let referenced = alpha.payload.starts_with(b"VFAF");
        let alpha_payload = if referenced {
            ensure!(
                self.alpha_reference && !layout.color_keyframe,
                "unnegotiated or keyframe atlas alpha reference"
            );
            self.alpha_cache
                .as_ref()
                .context("atlas alpha reference has no baseline")?
                .resolve(
                    &alpha.payload[4..],
                    alpha_identity(layout),
                    layout.width,
                    layout.height,
                )?
        } else {
            alpha.payload
        };
        ensure!(
            color
                .payload
                .len()
                .checked_add(alpha_payload.len())
                .is_some_and(|size| size <= self.policy.max_encoded_bytes),
            "atlas encoded pair exceeds negotiated bound"
        );
        let frame = |plane, payload| MediaPlaneFrame {
            window_id: layout.stream_id,
            frame_id: layout.frame_id,
            geometry_epoch: layout.geometry_epoch,
            plane,
            source_submitted_ns: layout.source_submitted_ns,
            payload,
        };
        let color = frame(MediaPlane::Color, color.payload);
        let alpha = frame(MediaPlane::Alpha, alpha_payload);
        ensure!(
            !self.reference_gap || (layout.color_keyframe && layout.alpha_keyframe),
            "atlas reference gap requires a paired keyframe"
        );
        let codec = self.codec.accept_frame(
            &color,
            FrameCodecMetadata {
                config_generation: layout.config_generation,
                keyframe: layout.color_keyframe,
            },
            Some((
                &alpha,
                FrameCodecMetadata {
                    config_generation: layout.config_generation,
                    keyframe: layout.alpha_keyframe,
                },
            )),
        )?;
        let media = crate::media_runtime::EncodedFrame {
            manifest: viewflow_protocol::FrameManifest {
                window_id: layout.stream_id,
                frame_id: layout.frame_id,
                geometry_epoch: layout.geometry_epoch,
                source_submitted_ns: layout.source_submitted_ns,
                received_ns: now,
            },
            color: color.payload,
            alpha: Some(alpha.payload),
        };
        let admitted = self
            .admission
            .admit(media, codec, now)
            .map_err(|error| anyhow::anyhow!("atlas paired admission failed: {error:?}"))?;
        if self.alpha_reference && !referenced {
            self.alpha_cache = Some(crate::alpha_reference::AlphaReferenceCache::new(
                alpha_identity(&admitted.layout),
                admitted.layout.width,
                admitted.layout.height,
                admitted
                    .media
                    .alpha
                    .clone()
                    .context("admitted atlas alpha missing")?,
                self.policy.max_encoded_bytes.max(usize::try_from(
                    u64::from(self.policy.width) * u64::from(self.policy.height),
                )?),
            )?);
        }
        if let Some(trace) = self.receive_traces.remove(&admitted.layout.frame_id) {
            crate::atlas_feedback::trace_line(format_args!(
                "atlas-receive-stages frame={} first_dispatch_ns={} last_dispatch_ns={} manifest_dispatch_ns={} complete_dispatch_ns={} datagrams={} payload_bytes={} missing_first={} missing_manifest={}",
                admitted.layout.frame_id,
                trace.first_ns.unwrap_or(0),
                trace.last_ns.unwrap_or(0),
                trace.staged_ns.unwrap_or(0),
                now,
                trace.datagrams,
                trace.bytes,
                trace.first_ns.is_none(),
                trace.staged_ns.is_none()
            ));
            trace_connection(
                &self.connection,
                admitted.layout.frame_id,
                "receiver",
                "pair_admitted",
                0,
            );
        }
        self.last_coded_frame = Some(admitted.layout.frame_id);
        self.reference_gap = false;
        self.staged = None;
        Ok(Some(admitted))
    }

    fn trim_receive_traces(&mut self) {
        // Diagnostics must stay bounded even for stale or rejected frame IDs.
        while self.receive_traces.len() > 4 {
            self.receive_traces.pop_first();
        }
    }

    fn retire_media(&mut self) {
        self.receive_traces.clear();
        self.shared_controls = None;
        self.pending_shared_control = None;
        self.retired = true;
        self.color = None;
        self.alpha = None;
        self.staged = None;
        self.early = None;
        self.control_read = None;
        self.fenced_manifest = None;
        self.assembler = atlas_assembler(self.policy);
    }

    fn finish_handoff(
        &mut self,
        frame: Option<crate::atlas_runtime::AdmittedAtlas>,
        now: u64,
        deadline: Instant,
    ) -> Result<Option<crate::atlas_runtime::AdmittedAtlas>> {
        let valid = check_deadline(deadline).and_then(|()| {
            if let Some(frame) = &frame {
                self.admission
                    .fresh_for_delivery(&frame.layout, now)
                    .map_err(|error| {
                        if self.feedback.is_some()
                            && error == crate::atlas_runtime::AtlasAdmissionError::Expired
                        {
                            // Pair admission consumed the bytes, but no decoder or
                            // native presenter has received this frame yet.
                            anyhow::Error::new(AtlasExpiredBeforeDecode(frame.layout.clone()))
                        } else {
                            anyhow::anyhow!("atlas expired during admission: {error:?}")
                        }
                    })?;
            }
            Ok(())
        });
        if let Err(error) = valid {
            if !error.is::<AtlasExpiredBeforeDecode>() {
                self.retire_media();
            }
            return Err(error);
        }
        if self.feedback.is_some() {
            if let Some(frame) = &frame {
                ensure!(
                    self.feedback_pending.is_none(),
                    "atlas feedback handoff overlap"
                );
                self.feedback_pending = Some(frame.layout.clone());
            }
        }
        if let Some(frame) = &frame {
            if crate::atlas_feedback::trace_frame(frame.layout.frame_id) {
                crate::atlas_feedback::trace_line(format_args!(
                    "atlas-receive-handoff frame={} post_process_ns={now}",
                    frame.layout.frame_id
                ));
            }
        }
        Ok(frame)
    }

    fn buffer_early(&mut self, packet: viewflow_transport::MediaDatagram, now: u64) -> Result<()> {
        use viewflow_transport::MediaPlane;
        if self
            .early
            .as_ref()
            .is_some_and(|early| packet.frame_id < early.frame_id)
        {
            return Ok(());
        }
        ensure!(
            packet.frame_id > 0
                && packet.geometry_epoch == self.policy.geometry_epoch
                && packet.source_submitted_ns > 0
                && packet.chunk_count > 0
                && packet.chunk_index < packet.chunk_count
                && !packet.payload.is_empty()
                && matches!(packet.plane, MediaPlane::Color | MediaPlane::Alpha),
            "invalid early atlas datagram"
        );
        let key = (packet.plane as u8, packet.chunk_index);
        if let Some(previous) = self
            .early
            .as_ref()
            .filter(|early| early.frame_id == packet.frame_id)
            .and_then(|early| early.packets.get(&key))
        {
            ensure!(
                previous.packet == packet,
                "conflicting early atlas duplicate"
            );
            return Ok(());
        }
        ensure!(
            packet.source_submitted_ns <= now.saturating_add(self.policy.max_future_ns),
            "early atlas datagram has future timestamp"
        );
        ensure!(
            self.feedback.is_some()
                || now.saturating_sub(packet.source_submitted_ns) < self.policy.max_age_ns,
            "early atlas datagram expired"
        );
        if self
            .early
            .as_ref()
            .is_none_or(|early| packet.frame_id > early.frame_id)
        {
            self.early = Some(EarlyAtlas {
                frame_id: packet.frame_id,
                source_submitted_ns: packet.source_submitted_ns,
                bytes: 0,
                packets: std::collections::BTreeMap::new(),
            });
        }
        let early = self
            .early
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("missing early atlas buffer"))?;
        ensure!(
            packet.source_submitted_ns == early.source_submitted_ns,
            "early atlas timestamp conflict"
        );
        if let Some(previous) = early.packets.get(&key) {
            ensure!(
                previous.packet == packet,
                "conflicting early atlas duplicate"
            );
            return Ok(());
        }
        if let Some(previous) = early
            .packets
            .values()
            .find(|previous| previous.packet.plane == packet.plane)
        {
            ensure!(
                previous.packet.chunk_count == packet.chunk_count,
                "early atlas chunk count conflict"
            );
        }
        let bytes = early
            .bytes
            .checked_add(packet.payload.len())
            .ok_or_else(|| anyhow::anyhow!("early atlas size overflow"))?;
        ensure!(
            bytes <= self.policy.max_encoded_bytes && early.packets.len() < 16384,
            "early atlas buffer bound exceeded"
        );
        early.packets.insert(
            key,
            EarlyPacket {
                packet,
                received_ns: now,
            },
        );
        early.bytes = bytes;
        Ok(())
    }

    /// Read one actual QUIC datagram. Other control reads must be dispatched by
    /// the same session owner; do not race cancellation-unsafe stream readers.
    /// # Errors
    /// Preserves the caller's absolute deadline; does not confirm presentation.
    pub async fn receive_media(
        &mut self,
        mut now: impl FnMut() -> u64,
        deadline: Instant,
    ) -> Result<Option<crate::atlas_runtime::AdmittedAtlas>> {
        check_deadline(deadline)?;
        ensure!(!self.retired, "atlas receiver session is retired");
        ensure!(
            !self.pump_started,
            "individual reads cannot replace the active atlas pump"
        );
        let bytes = timeout_at(deadline, self.connection.read_datagram())
            .await
            .context("atlas datagram deadline expired")??;
        check_deadline(deadline)?;
        let packet = viewflow_transport::MediaDatagram::decode(bytes)?;
        let frame = self.push_media(packet, now())?;
        self.finish_handoff(frame, now(), deadline)
    }
}

async fn drain_handoff_after_control_error<T>(
    presenting: impl std::future::Future<Output = Result<T>>,
    control: anyhow::Error,
) -> Result<T> {
    match tokio::time::timeout(std::time::Duration::from_secs(3), presenting).await {
        Ok(Err(native)) => {
            Err(native.context(format!("atlas handoff control also ended: {control:#}")))
        }
        Ok(Ok(_)) => Err(control),
        Err(timeout) => {
            Err(control.context(format!("atlas native cleanup wait expired: {timeout}")))
        }
    }
}

fn atlas_assembler(policy: AtlasReceiverPolicy) -> viewflow_transport::MediaAssembler {
    viewflow_transport::MediaAssembler::new(viewflow_transport::MediaAssemblerConfig {
        deadline_ns: policy.max_age_ns,
        max_chunks_per_plane: u16::MAX,
        max_plane_bytes: policy.max_encoded_bytes,
    })
}

fn check_deadline(deadline: Instant) -> Result<()> {
    ensure!(
        Instant::now() < deadline,
        "atlas operation deadline expired"
    );
    Ok(())
}

async fn write_message(stream: &mut quinn::SendStream, message: wire::AtlasSession) -> Result<()> {
    let bytes = message.encode_to_vec();
    ensure!(
        bytes.len() + MAGIC.len() <= MAX_HANDSHAKE_BYTES,
        "atlas handshake size limit"
    );
    stream.write_all(MAGIC).await?;
    stream.write_all(&bytes).await?;
    stream.finish()?;
    Ok(())
}

async fn read_message(stream: &mut quinn::RecvStream) -> Result<wire::AtlasSession> {
    let bytes = stream.read_to_end(MAX_HANDSHAKE_BYTES).await?;
    ensure!(bytes.starts_with(MAGIC), "invalid atlas handshake magic");
    Ok(wire::AtlasSession::decode(&bytes[MAGIC.len()..])?)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::time::Duration;
    use viewflow_protocol::Id128;
    use viewflow_transport::{
        AlphaInterpretation, CodedPixelFormat, Colorimetry, VideoCodec, VideoPlaneRole,
    };

    pub(crate) fn plan() -> AtlasSessionPlan {
        let color = CodecDescriptor {
            codec: VideoCodec::H264,
            plane: VideoPlaneRole::Color,
            pixel_format: CodedPixelFormat::Nv12,
            colorimetry: Colorimetry::Bt709Limited,
            alpha_interpretation: AlphaInterpretation::StraightWithExternalPlane,
            coded_width: 64,
            coded_height: 64,
            geometry_epoch: 1,
            config_generation: 1,
        };
        AtlasSessionPlan {
            policy: AtlasReceiverPolicy {
                stream_id: Id128(99),
                geometry_epoch: 1,
                config_generation: 1,
                width: 64,
                height: 64,
                max_tiles: 4,
                max_encoded_bytes: 1024,
                max_age_ns: 50,
                max_future_ns: 2,
            },
            color,
            alpha: CodecDescriptor {
                codec: VideoCodec::LosslessAlpha,
                plane: VideoPlaneRole::Alpha,
                pixel_format: CodedPixelFormat::Gray8,
                colorimetry: Colorimetry::AlphaFullRange,
                alpha_interpretation: AlphaInterpretation::AlphaPlane,
                ..color
            },
            max_decoded_bytes: 32768,
        }
    }

    pub(crate) async fn pair() -> (quinn::Endpoint, quinn::Endpoint, Connection, Connection) {
        let identity = viewflow_transport::PeerIdentity::from_pem(
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
            include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
            include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
        )
        .unwrap();
        let server = quinn::Endpoint::server(
            viewflow_transport::build_server_config(&identity).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client
            .set_default_client_config(viewflow_transport::build_client_config(&identity).unwrap());
        let connecting = client
            .connect(server.local_addr().unwrap(), "localhost")
            .unwrap();
        let (outbound, inbound) = tokio::join!(connecting, async {
            server.accept().await.unwrap().await.unwrap()
        });
        (client, server, outbound.unwrap(), inbound)
    }

    fn warmup_frames() -> [crate::atlas_presenter::AtlasWarmupFrame; 3] {
        std::array::from_fn(|_| crate::atlas_presenter::AtlasWarmupFrame {
            width: 64,
            height: 64,
            color: bytes::Bytes::from_static(&[0, 0, 1, 0x65]),
            alpha: viewflow_transport::encode_alpha_rle(64, 64, &[7; 4096]).unwrap(),
        })
    }

    #[tokio::test]
    async fn shared_writer_interleaves_atlas_and_input_without_reusing_control_sequence() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let (sender, receiver) = tokio::join!(
            offer_atlas(&outbound, plan(), deadline),
            accept_atlas(&inbound, plan(), deadline)
        );
        let mut sender = sender.unwrap();
        let _receiver = receiver.unwrap();
        let writer = crate::shared_control::SharedControlWriter::start(&outbound).unwrap();
        let shared = writer.sender();
        sender.attach_shared_control(shared.clone()).unwrap();
        assert!(sender.attach_shared_control(shared.clone()).is_err());
        let authorization = viewflow_protocol::WindowPointerAuthorization {
            lease_generation: 7,
            owner_device: Id128(1),
            target_device: Id128(2),
            target_window: Id128(3),
            geometry_epoch: 1,
            presented_frame: 4,
            source_not_after_ns: 100,
        };
        shared
            .send(
                wire::control_envelope::Payload::WindowPointerAuthorization(authorization.into()),
                deadline,
            )
            .await
            .unwrap();
        let manifest = AtlasFrame {
            patches: None,
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
        sender
            .send_manifest(manifest.clone(), 10, deadline)
            .await
            .unwrap();
        shared
            .send(
                wire::control_envelope::Payload::WindowPointerAuthorization(authorization.into()),
                deadline,
            )
            .await
            .unwrap();
        let mut sequence = ControlSequencer::default();
        for expected in 1..=3 {
            let envelope = receive_control_sequenced(&inbound, &mut sequence)
                .await
                .unwrap();
            assert_eq!(envelope.sequence, expected);
            let payload = DomainControl::try_from(envelope).unwrap();
            match (expected, payload) {
                (2, DomainControl::AtlasFrame(frame)) => assert_eq!(frame, manifest),
                (1 | 3, DomainControl::WindowPointerAuthorization(auth)) => {
                    assert_eq!(auth, authorization)
                }
                other => panic!("unexpected mixed control: {other:?}"),
            }
        }
    }

    #[tokio::test]
    async fn pre_send_expiry_preserves_sender_and_queues_no_frame() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let (sender, receiver) = tokio::join!(
            offer_atlas(&outbound, plan(), deadline),
            accept_atlas(&inbound, plan(), deadline)
        );
        let mut sender = sender.unwrap();
        let mut receiver = receiver.unwrap();
        let mut manifest = AtlasFrame {
            patches: None,
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
        let color = bytes::Bytes::from(vec![0x65; 512]);
        let alpha = viewflow_transport::encode_alpha_rle(64, 64, &[0; 4096]).unwrap();
        let error = sender
            .send_frame(
                manifest.clone(),
                color.clone(),
                alpha.clone(),
                1,
                Instant::now(),
            )
            .await
            .unwrap_err();
        assert!(error.is::<AtlasFrameExpiredBeforeSend>());
        assert!(!sender.frame_send_poisoned);
        manifest.frame_id = 2;
        sender
            .send_frame(manifest.clone(), color, alpha, 2, deadline)
            .await
            .unwrap();
        // The first received frame is 2: expiry emitted neither control nor media.
        assert_eq!(
            receiver.next_frame(|| 110, deadline).await.unwrap().layout,
            manifest
        );
    }

    #[tokio::test]
    async fn shared_pump_preserves_order_and_media_across_control_backpressure() {
        for overflow in [false, true] {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(2);
            let (sender, receiver) = tokio::join!(
                offer_atlas(&outbound, plan(), deadline),
                accept_atlas(&inbound, plan(), deadline)
            );
            let mut sender = sender.unwrap();
            let mut receiver = receiver.unwrap();
            let writer = crate::shared_control::SharedControlWriter::start(&outbound).unwrap();
            let shared = writer.sender();
            sender.attach_shared_control(shared.clone()).unwrap();
            let (controls, mut events) = tokio::sync::mpsc::channel(1);
            receiver.attach_shared_controls(controls.clone()).unwrap();
            assert!(receiver.attach_shared_controls(controls).is_err());
            let authorization = viewflow_protocol::WindowPointerAuthorization {
                lease_generation: 7,
                owner_device: Id128(1),
                target_device: Id128(2),
                target_window: Id128(3),
                geometry_epoch: 1,
                presented_frame: 4,
                source_not_after_ns: 100,
            };
            for index in 0..if overflow { 2 } else { 1 } {
                let authorization = viewflow_protocol::WindowPointerAuthorization {
                    lease_generation: authorization.lease_generation + index,
                    ..authorization
                };
                shared
                    .send(
                        wire::control_envelope::Payload::WindowPointerAuthorization(
                            authorization.into(),
                        ),
                        deadline,
                    )
                    .await
                    .unwrap();
            }
            let manifest = AtlasFrame {
                patches: None,
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
            sender
                .send_frame(
                    manifest.clone(),
                    bytes::Bytes::from(vec![0x65; 512]),
                    viewflow_transport::encode_alpha_rle(64, 64, &[0; 4096]).unwrap(),
                    1,
                    deadline,
                )
                .await
                .unwrap();
            if overflow {
                let error = receiver
                    .next_frame(|| 110, Instant::now() + Duration::from_millis(50))
                    .await
                    .err()
                    .unwrap();
                assert!(error.is::<AtlasWaitExpired>());
                assert!(!receiver.retired);
                assert!(receiver.pending_shared_control.is_some());
                assert!(inbound.close_reason().is_none());
                let DomainControl::WindowPointerAuthorization(first) = events.try_recv().unwrap()
                else {
                    panic!("expected first ordered authorization");
                };
                assert_eq!(first, authorization);
            }
            let result = receiver.next_frame(|| 110, deadline).await;
            assert_eq!(result.unwrap().layout, manifest);
            assert_eq!(
                receiver.control_sequence.previous(),
                Some(if overflow { 3 } else { 2 })
            );
            assert!(receiver.pending_shared_control.is_none());
            let DomainControl::WindowPointerAuthorization(received) = events.try_recv().unwrap()
            else {
                panic!("expected shared input control");
            };
            assert_eq!(
                received,
                viewflow_protocol::WindowPointerAuthorization {
                    lease_generation: authorization.lease_generation + u64::from(overflow),
                    ..authorization
                }
            );
            assert!(events.try_recv().is_err());
            if !overflow {
                // Deliberately bypass the writer to model a replay from a peer.
                // Input and atlas traffic share the same replay floor.
                send_control(
                    &outbound,
                    &wire::ControlEnvelope {
                        protocol_major: u32::from(PROTOCOL_VERSION.major),
                        protocol_minor: u32::from(PROTOCOL_VERSION.minor),
                        sequence: 2,
                        payload: Some(wire::control_envelope::Payload::WindowPointerAuthorization(
                            authorization.into(),
                        )),
                    },
                )
                .await
                .unwrap();
                assert!(receiver.next_frame(|| 110, deadline).await.is_err());
                assert!(receiver.retired);
                assert!(events.try_recv().is_err());
            }
        }
    }

    #[tokio::test]
    async fn desktop_move_ack_is_routed_to_the_shared_input_supervisor() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let (sender, receiver) = tokio::join!(
            offer_atlas(&outbound, plan(), deadline),
            accept_atlas(&inbound, plan(), deadline)
        );
        let mut sender = sender.unwrap();
        let mut receiver = receiver.unwrap();
        let writer = crate::shared_control::SharedControlWriter::start(&outbound).unwrap();
        sender.attach_shared_control(writer.sender()).unwrap();
        let (controls, mut events) = tokio::sync::mpsc::channel(1);
        receiver.attach_shared_controls(controls).unwrap();
        let acknowledgement = viewflow_protocol::DesktopWindowMoveAck {
            source_device: Id128(1),
            owner_device: Id128(2),
            stream_id: Id128(99),
            config_generation: 1,
            topology_generation: 2,
            window_id: Id128(3),
            drag_id: Id128(4),
            sequence: 5,
            result: viewflow_protocol::DesktopWindowMoveResult::Applied,
            actual_bounds: viewflow_protocol::DesktopRect {
                x_millidip: 0,
                y_millidip: 0,
                width_millidip: 1_000,
                height_millidip: 1_000,
            },
        };
        writer
            .sender()
            .send(
                wire::control_envelope::Payload::DesktopWindowMoveAck(acknowledgement.into()),
                deadline,
            )
            .await
            .unwrap();
        let manifest = AtlasFrame {
            patches: None,
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
        sender
            .send_frame(
                manifest.clone(),
                bytes::Bytes::from(vec![0x65; 512]),
                viewflow_transport::encode_alpha_rle(64, 64, &[0; 4096]).unwrap(),
                1,
                deadline,
            )
            .await
            .unwrap();
        assert_eq!(
            receiver.next_frame(|| 110, deadline).await.unwrap().layout,
            manifest
        );
        assert_eq!(
            events.try_recv().unwrap(),
            DomainControl::DesktopWindowMoveAck(acknowledgement)
        );
    }

    #[tokio::test]
    async fn v3_alpha_reference_reuses_confirmed_bytes_and_recovers_changed_expiry() {
        use crate::atlas_feedback::AtlasFrameDisposition::{Committed, ExpiredUnbound};
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(3);
        let frames = warmup_frames();
        let (sender, receiver) = tokio::join!(
            offer_warmed_atlas_dispositions(&outbound, plan(), &frames, deadline),
            accept_warmed_atlas_dispositions(&inbound, plan(), deadline, |_| async { Ok(()) })
        );
        let mut sender = sender.unwrap();
        let mut receiver = receiver.unwrap();
        assert!(sender.alpha_reference && receiver.alpha_reference);
        for id in 1..=6 {
            let manifest = AtlasFrame {
                patches: None,
                stream_id: Id128(99),
                frame_id: id,
                geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 0,
                width: 64,
                height: 64,
                source_submitted_ns: 100 + id,
                tiles: vec![],
                color_keyframe: id == 1 || id == 5,
                alpha_keyframe: true,
                desktop: None,
            };
            // Frames 2/3 reference baseline 1; 4 changes alpha but expires;
            // 5 must independently restore both chains; 6 references baseline 5.
            let alpha = viewflow_transport::encode_alpha_rle(
                64,
                64,
                &vec![if id < 4 { 7 } else { 93 }; 4096],
            )
            .unwrap();
            let expected_reference = matches!(id, 2 | 3 | 6);
            assert_eq!(
                sender
                    .alpha_cache
                    .as_ref()
                    .and_then(|c| c.reference_for(alpha_identity(&manifest), 64, 64, &alpha))
                    .is_some(),
                expected_reference
            );
            let outcome = if id == 4 { ExpiredUnbound } else { Committed };
            let send = sender.send_frame(
                manifest.clone(),
                frames[0].color.clone(),
                alpha.clone(),
                id,
                deadline,
            );
            let receive = async {
                let admitted = receiver.next_frame(|| 110, deadline).await.unwrap();
                assert_eq!(admitted.layout, manifest);
                assert_eq!(admitted.media.alpha.as_ref(), Some(&alpha));
                assert_eq!(admitted.media.manifest.source_submitted_ns, 100 + id);
                receiver
                    .report_disposition(&manifest, outcome, deadline)
                    .await
                    .unwrap();
            };
            let (sent, ()) = tokio::join!(send, receive);
            sent.unwrap();
            let mut future = manifest.clone();
            future.frame_id += 1;
            let key = receiver
                .alpha_cache
                .as_ref()
                .unwrap()
                .reference_for(alpha_identity(&future), 64, 64, &alpha)
                .unwrap();
            let baseline = u64::from_be_bytes(key[16..24].try_into().unwrap());
            assert_eq!(
                baseline,
                match id {
                    2 | 3 => 1,
                    6 => 5,
                    _ => id,
                }
            );
        }
    }

    #[tokio::test]
    async fn v3_feedback_blocks_sender_and_requires_idr_after_expiry() {
        use crate::atlas_feedback::AtlasFrameDisposition;
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let frames = warmup_frames();
        let (sender, receiver) = tokio::join!(
            offer_warmed_atlas_dispositions(&outbound, plan(), &frames, deadline),
            accept_warmed_atlas_dispositions(&inbound, plan(), deadline, |_| async { Ok(()) })
        );
        let mut sender = sender.unwrap();
        let mut receiver = receiver.unwrap();
        for id in 1..=2 {
            let manifest = AtlasFrame {
                patches: None,
                stream_id: Id128(99),
                frame_id: id,
                geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 0,
                width: 64,
                height: 64,
                source_submitted_ns: 100 + id,
                tiles: vec![],
                color_keyframe: true,
                alpha_keyframe: true,
                desktop: None,
            };
            if id == 2 {
                let mut p_frame = manifest.clone();
                p_frame.color_keyframe = false;
                assert!(
                    sender
                        .send_frame(
                            p_frame,
                            frames[0].color.clone(),
                            frames[0].alpha.clone(),
                            id,
                            deadline
                        )
                        .await
                        .is_err()
                );
            }
            let outcome = if id == 1 {
                AtlasFrameDisposition::ExpiredUnbound
            } else {
                AtlasFrameDisposition::Committed
            };
            let mut sent = Box::pin(sender.send_frame(
                manifest.clone(),
                frames[0].color.clone(),
                frames[0].alpha.clone(),
                id,
                deadline,
            ));
            let admitted = tokio::select! {
                result = &mut sent => panic!("send completed before native feedback: {result:?}"),
                frame = receiver.next_frame(|| 110, deadline) => frame.unwrap(),
            };
            assert_eq!(admitted.layout, manifest);
            assert!(receiver.next_frame(|| 110, deadline).await.is_err());
            tokio::select! {
                result = &mut sent => panic!("send completed while feedback withheld: {result:?}"),
                () = tokio::time::sleep(Duration::from_millis(2)) => {}
            }
            receiver
                .report_disposition(&manifest, outcome, deadline)
                .await
                .unwrap();
            sent.await.unwrap();
            assert_eq!(sender.last_disposition(), Some(outcome));
            assert!(
                receiver
                    .report_disposition(&manifest, outcome, deadline)
                    .await
                    .is_err()
            );
        }
    }

    #[tokio::test]
    async fn v3_expired_manifest_preserves_input_owner_and_recovers_keyframe() {
        expiry_preserves_input_owner_and_recovers_keyframe(false).await;
    }

    #[tokio::test]
    async fn v3_expiry_after_pair_admission_preserves_input_and_recovers_keyframe() {
        expiry_preserves_input_owner_and_recovers_keyframe(true).await;
    }

    async fn expiry_preserves_input_owner_and_recovers_keyframe(at_handoff: bool) {
        use crate::atlas_feedback::AtlasFrameDisposition;
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let frames = warmup_frames();
        let (sender, receiver) = tokio::join!(
            offer_warmed_atlas_dispositions(&outbound, plan(), &frames, deadline),
            accept_warmed_atlas_dispositions(&inbound, plan(), deadline, |_| async { Ok(()) })
        );
        let mut sender = sender.unwrap();
        let mut receiver = receiver.unwrap();
        let (controls, mut input_events) = tokio::sync::mpsc::channel(1);
        receiver.attach_shared_controls(controls).unwrap();
        assert!(
            receiver
                .push_media(early_packet(1, viewflow_transport::MediaPlane::Color), 210)
                .unwrap()
                .is_none()
        );
        assert!(receiver.early.is_some());
        receiver.early = None; // Discard this synthetic probe before sending actual encoded bytes.
        assert!(receiver.feedback_pending.is_none());
        assert!(!receiver.retired);
        let mut future = early_packet(1, viewflow_transport::MediaPlane::Color);
        future.source_submitted_ns = 213;
        assert!(
            receiver
                .buffer_early(future, 210)
                .unwrap_err()
                .to_string()
                .contains("future timestamp")
        );
        let manifest = |id, timestamp| AtlasFrame {
            patches: None,
            stream_id: Id128(99),
            frame_id: id,
            geometry_epoch: 1,
            config_generation: 1,
            layout_revision: 0,
            width: 64,
            height: 64,
            source_submitted_ns: timestamp,
            tiles: vec![],
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: None,
        };
        let fresh = manifest(2, if at_handoff { 400 } else { 200 });
        let sending = async {
            sender
                .send_frame(
                    manifest(1, if at_handoff { 200 } else { 100 }),
                    frames[0].color.clone(),
                    frames[0].alpha.clone(),
                    1,
                    deadline,
                )
                .await
                .unwrap();
            assert_eq!(
                sender.last_disposition(),
                Some(AtlasFrameDisposition::Committed)
            );
            sender
                .send_frame(
                    fresh.clone(),
                    frames[0].color.clone(),
                    frames[0].alpha.clone(),
                    2,
                    deadline,
                )
                .await
                .unwrap();
            assert_eq!(
                sender.last_disposition(),
                Some(AtlasFrameDisposition::Committed)
            );
        };
        let receiving = async {
            // The first manifest is already expired when reliable control arrives.
            // The pump must skip it and return only the subsequent fresh IDR.
            let mut samples = 0;
            let admitted = receiver
                .next_frame(
                    || {
                        samples += 1;
                        // Three fresh events: manifest and the two single-chunk planes.
                        // The fourth sample is the final, pre-decoder handoff check.
                        if at_handoff && samples >= 4 { 410 } else { 210 }
                    },
                    deadline,
                )
                .await
                .unwrap();
            assert_eq!(
                admitted.layout,
                manifest(1, if at_handoff { 200 } else { 100 })
            );
            receiver
                .report_disposition(&admitted.layout, AtlasFrameDisposition::Committed, deadline)
                .await
                .unwrap();
            let admitted = receiver
                .next_frame(|| if at_handoff { 410 } else { 210 }, deadline)
                .await
                .unwrap();
            assert_eq!(admitted.layout, fresh);
            assert!(!receiver.retired);
            assert!(receiver.shared_controls.is_some());
            assert!(!input_events.is_closed());
            assert!(input_events.try_recv().is_err());
            receiver
                .report_disposition(&fresh, AtlasFrameDisposition::Committed, deadline)
                .await
                .unwrap();
        };
        tokio::join!(sending, receiving);
    }

    #[tokio::test]
    async fn recovery_fence_dispatches_grant_after_manifest_without_admitting_or_retiming_frame() {
        for expired in [false, true] {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(2);
            let frames = warmup_frames();
            let (sender, receiver) = tokio::join!(
                offer_warmed_atlas_dispositions(&outbound, plan(), &frames, deadline),
                accept_warmed_atlas_dispositions(&inbound, plan(), deadline, |_| async { Ok(()) })
            );
            let _sender = sender.unwrap();
            let mut receiver = receiver.unwrap();
            let writer = crate::shared_control::SharedControlWriter::start(&outbound).unwrap();
            let (controls, mut events) = tokio::sync::mpsc::channel(4);
            receiver.attach_shared_controls(controls).unwrap();
            let manifest = AtlasFrame {
                patches: None,
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
            writer
                .sender()
                .send(
                    wire::control_envelope::Payload::AtlasFrame(manifest.clone().into()),
                    deadline,
                )
                .await
                .unwrap();
            let grant = viewflow_protocol::WindowPointerAuthorization {
                lease_generation: 7,
                owner_device: Id128(1),
                target_device: Id128(2),
                target_window: Id128(3),
                geometry_epoch: 1,
                presented_frame: 4,
                source_not_after_ns: 1000,
            };
            writer
                .sender()
                .send(
                    wire::control_envelope::Payload::WindowPointerAuthorization(grant.into()),
                    deadline,
                )
                .await
                .unwrap();
            // The source's new media may already be in QUIC, but only the
            // grant is delivered while recovery owns the visual-frame fence.
            for plane in [
                viewflow_transport::MediaPlane::Color,
                viewflow_transport::MediaPlane::Alpha,
            ] {
                let mut packet = early_packet(1, plane);
                if plane == viewflow_transport::MediaPlane::Alpha {
                    packet.payload = frames[0].alpha.clone();
                }
                outbound.send_datagram(packet.encode()).unwrap();
            }
            let request_after_grant = async {
                let event = tokio::time::timeout(Duration::from_secs(1), events.recv())
                    .await
                    .unwrap()
                    .unwrap();
                assert!(
                    matches!(event, DomainControl::WindowPointerAuthorization(auth) if auth == grant)
                );
                Ok(())
            };
            receiver
                .with_fenced_controls(request_after_grant)
                .await
                .unwrap();
            assert_eq!(receiver.fenced_manifest.as_ref(), Some(&manifest));
            assert!(receiver.staged.is_none() && receiver.feedback_pending.is_none());
            assert_eq!(receiver.last_coded_frame, None);
            assert_eq!(receiver.control_sequence.previous(), Some(2));
            let frame = receiver
                .next_frame(|| if expired { 200 } else { 110 }, deadline)
                .await
                .unwrap();
            assert_eq!(frame.layout, manifest);
            assert_eq!(frame.layout.source_submitted_ns, 100);
            assert_eq!(receiver.feedback_pending.as_ref(), Some(&manifest));
            assert!(receiver.fenced_manifest.is_none());
            assert_eq!(receiver.control_sequence.previous(), Some(2));
        }
    }

    #[tokio::test]
    async fn recovery_control_wait_exits_on_timeout_or_input_owner_close() {
        for close in [false, true] {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(2);
            let (sender, receiver) = tokio::join!(
                offer_atlas(&outbound, plan(), deadline),
                accept_atlas(&inbound, plan(), deadline)
            );
            let _sender = sender.unwrap();
            let mut receiver = receiver.unwrap();
            let (controls, events) = tokio::sync::mpsc::channel(4);
            receiver.attach_shared_controls(controls).unwrap();
            let _events = if close {
                drop(events);
                None
            } else {
                Some(events)
            };
            let wait = async {
                tokio::time::timeout(Duration::from_millis(20), std::future::pending::<()>())
                    .await
                    .context("test recovery request deadline expired")?;
                Ok(())
            };
            let error =
                tokio::time::timeout(Duration::from_secs(1), receiver.with_fenced_controls(wait))
                    .await
                    .unwrap()
                    .unwrap_err();
            assert!(error.to_string().contains(if close {
                "input control owner closed"
            } else {
                "deadline expired"
            }));
            assert!(
                receiver.retired
                    && receiver.control_read.is_none()
                    && receiver.fenced_manifest.is_none()
            );
        }
    }

    #[tokio::test]
    async fn recovery_fence_rejects_second_unacknowledged_manifest() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let (sender, receiver) = tokio::join!(
            offer_atlas(&outbound, plan(), deadline),
            accept_atlas(&inbound, plan(), deadline)
        );
        let _sender = sender.unwrap();
        let mut receiver = receiver.unwrap();
        let writer = crate::shared_control::SharedControlWriter::start(&outbound).unwrap();
        let (controls, _events) = tokio::sync::mpsc::channel(4);
        receiver.attach_shared_controls(controls).unwrap();
        for frame_id in [1, 2] {
            let manifest = AtlasFrame {
                patches: None,
                stream_id: Id128(99),
                frame_id,
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
            writer
                .sender()
                .send(
                    wire::control_envelope::Payload::AtlasFrame(manifest.into()),
                    deadline,
                )
                .await
                .unwrap();
        }
        let error = tokio::time::timeout(
            Duration::from_secs(1),
            receiver.with_fenced_controls(std::future::pending::<Result<()>>()),
        )
        .await
        .unwrap()
        .unwrap_err();
        assert!(error.to_string().contains("advanced twice"));
        assert!(receiver.retired && receiver.fenced_manifest.is_none());
    }

    #[tokio::test]
    async fn idle_frame_wait_yields_to_recovery_and_resumes_same_session() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let (sender, receiver) = tokio::join!(
            offer_atlas(&outbound, plan(), deadline),
            accept_atlas(&inbound, plan(), deadline)
        );
        let _sender = sender.unwrap();
        let mut receiver = receiver.unwrap();
        let fence = crate::atlas_receiver_presenter::AtlasInputRecoveryFence::default();
        let forward = fence.begin_media_forward().await.unwrap();
        let armer = {
            let fence = fence.clone();
            tokio::spawn(async move {
                tokio::task::yield_now().await;
                fence.arm().await;
            })
        };
        let error = tokio::time::timeout(
            Duration::from_millis(200),
            receiver.next_frame_with_fence(|| 110, deadline, Some(&fence)),
        )
        .await
        .unwrap()
        .err()
        .unwrap();
        assert!(error.is::<crate::atlas_receiver_presenter::AtlasMediaFenced>());
        assert!(!receiver.retired && receiver.control_read.is_some());
        assert!(receiver.feedback_pending.is_none());
        drop(forward);
        armer.await.unwrap();
        fence.retry_cancelled_selection();
        let error = receiver
            .next_frame(|| 110, Instant::now() + Duration::from_millis(10))
            .await
            .err()
            .unwrap();
        assert!(error.is::<AtlasWaitExpired>());
        assert!(!receiver.retired && inbound.close_reason().is_none());
    }

    #[tokio::test]
    async fn full_control_queue_preserves_native_completion_and_fenced_resume() {
        tokio::time::timeout(Duration::from_secs(3), async {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(2);
            let frames = warmup_frames();
            let (sender, receiver) = tokio::join!(
                offer_warmed_atlas_dispositions(&outbound, plan(), &frames, deadline),
                accept_warmed_atlas_dispositions(&inbound, plan(), deadline, |_| async { Ok(()) })
            );
            let mut sender = sender.unwrap();
            let mut receiver = receiver.unwrap();
            let (controls, mut events) = tokio::sync::mpsc::channel(1);
            receiver.attach_shared_controls(controls).unwrap();
            let manifest = AtlasFrame {
                patches: None,
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
            let sending = sender.send_frame(
                manifest.clone(),
                frames[0].color.clone(),
                frames[0].alpha.clone(),
                1,
                deadline,
            );
            let receiving = async {
                let frame = receiver.next_frame(|| 110, deadline).await.unwrap();
                for probe_id in [1, 2] {
                    receiver
                        .process_domain_control(
                            DomainControl::ClockSyncProbe(viewflow_protocol::ClockSyncProbe {
                                probe_id,
                                t0_send_ns: 100,
                            }),
                            110,
                        )
                        .unwrap();
                }
                assert!(receiver.pending_shared_control.is_some());
                // A congested input consumer cannot keep an already-admitted
                // native frame from completing and receiving its disposition.
                let completed = receiver
                    .with_handoff_controls(async {
                        tokio::time::sleep(Duration::from_millis(20)).await;
                        Ok(42)
                    })
                    .await
                    .unwrap();
                assert_eq!(completed, 42);
                assert!(receiver.pending_shared_control.is_some());
                assert!(inbound.close_reason().is_none());
                receiver
                    .report_disposition(
                        &frame.layout,
                        crate::atlas_feedback::AtlasFrameDisposition::Committed,
                        deadline,
                    )
                    .await
                    .unwrap();

                // Cancelling a subsequent recovery wait still retains exactly
                // that pending record, without consuming another reliable read.
                assert!(
                    tokio::time::timeout(
                        Duration::from_millis(20),
                        receiver.with_fenced_controls(std::future::pending::<Result<()>>())
                    )
                    .await
                    .is_err()
                );
                assert!(!receiver.retired && receiver.pending_shared_control.is_some());
                receiver
                    .with_fenced_controls(async {
                        for expected in [1, 2] {
                            let DomainControl::ClockSyncProbe(probe) = events.recv().await.unwrap()
                            else {
                                panic!("expected ordered clock control");
                            };
                            assert_eq!(probe.probe_id, expected);
                        }
                        Ok(())
                    })
                    .await
                    .unwrap();
                assert!(receiver.pending_shared_control.is_none());
                assert!(events.try_recv().is_err());
                assert!(inbound.close_reason().is_none());
            };
            let (sent, ()) = tokio::join!(sending, receiving);
            sent.unwrap();
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn handoff_dispatches_input_before_native_completion() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let frames = warmup_frames();
        let (sender, receiver) = tokio::join!(
            offer_warmed_atlas_dispositions(&outbound, plan(), &frames, deadline),
            accept_warmed_atlas_dispositions(&inbound, plan(), deadline, |_| async { Ok(()) })
        );
        let mut sender = sender.unwrap();
        let mut receiver = receiver.unwrap();
        let writer = crate::shared_control::SharedControlWriter::start(&outbound).unwrap();
        sender.attach_shared_control(writer.sender()).unwrap();
        let (controls, mut events) = tokio::sync::mpsc::channel(4);
        receiver.attach_shared_controls(controls).unwrap();
        let manifest = AtlasFrame {
            patches: None,
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
        let (in_handoff, started) = tokio::sync::oneshot::channel();
        let sending = sender.send_frame(
            manifest.clone(),
            frames[0].color.clone(),
            frames[0].alpha.clone(),
            1,
            deadline,
        );
        let receiving = async {
            let frame = receiver.next_frame(|| 110, deadline).await.unwrap();
            let (finish, finished) = tokio::sync::oneshot::channel();
            let native = async {
                in_handoff.send(()).unwrap();
                finished.await.unwrap();
                Ok(())
            };
            let observer = async {
                assert!(matches!(
                    events.recv().await.unwrap(),
                    DomainControl::ClockSyncProbe(_)
                ));
                finish.send(()).unwrap();
            };
            let (result, ()) = tokio::join!(receiver.with_handoff_controls(native), observer);
            result.unwrap();
            assert_eq!(receiver.control_sequence.previous(), Some(2));
            receiver
                .report_disposition(
                    &frame.layout,
                    crate::atlas_feedback::AtlasFrameDisposition::Committed,
                    deadline,
                )
                .await
                .unwrap();
        };
        let input = async {
            started.await.unwrap();
            writer
                .sender()
                .send(
                    wire::control_envelope::Payload::ClockSyncProbe(wire::ClockSyncProbe {
                        probe_id: 1,
                        t0_send_ns: 100,
                    }),
                    deadline,
                )
                .await
                .unwrap();
        };
        tokio::time::timeout(Duration::from_secs(1), async {
            let (sent, (), ()) = tokio::join!(sending, receiving, input);
            sent.unwrap();
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn handoff_control_close_preserves_native_cleanup_error() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let frames = warmup_frames();
        let (sender, receiver) = tokio::join!(
            offer_warmed_atlas_dispositions(&outbound, plan(), &frames, deadline),
            accept_warmed_atlas_dispositions(&inbound, plan(), deadline, |_| async { Ok(()) })
        );
        let mut sender = sender.unwrap();
        let mut receiver = receiver.unwrap();
        let writer = crate::shared_control::SharedControlWriter::start(&outbound).unwrap();
        sender.attach_shared_control(writer.sender()).unwrap();
        let (controls, _events) = tokio::sync::mpsc::channel(4);
        receiver.attach_shared_controls(controls).unwrap();
        let manifest = AtlasFrame {
            patches: None,
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
        let cleaned = std::sync::atomic::AtomicBool::new(false);
        let receiving = async {
            receiver.next_frame(|| 110, deadline).await.unwrap();
            let native = async {
                // Reproduce the input owner's close while native teardown is
                // underway but has not returned its original error yet.
                inbound.close(0_u32.into(), b"input producer ended during cleanup");
                tokio::time::sleep(Duration::from_millis(10)).await;
                cleaned.store(true, std::sync::atomic::Ordering::SeqCst);
                Err::<(), _>(std::io::Error::other("original native presentation failed").into())
            };
            receiver.with_handoff_controls(native).await.unwrap_err()
        };
        let (sent, error) = tokio::join!(
            sender.send_frame(
                manifest,
                frames[0].color.clone(),
                frames[0].alpha.clone(),
                1,
                deadline
            ),
            receiving
        );
        assert!(sent.is_err());
        assert!(cleaned.load(std::sync::atomic::Ordering::SeqCst));
        assert_eq!(
            error.downcast_ref::<std::io::Error>().unwrap().to_string(),
            "original native presentation failed"
        );
        assert!(format!("{error:#}").contains("atlas handoff control also ended"));
    }

    #[tokio::test]
    async fn v3_cannot_negotiate_with_v2_receiver() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(1);
        let frames = warmup_frames();
        let (sender, receiver) = tokio::join!(
            offer_warmed_atlas_dispositions(&outbound, plan(), &frames, deadline),
            accept_warmed_atlas(&inbound, plan(), deadline, |_| async {
                panic!("mismatch reached native")
            })
        );
        assert!(sender.is_err() && receiver.is_err());
    }

    #[cfg(windows)]
    #[tokio::test]
    #[ignore = "requires an interactive Windows desktop, native presenter and explicit H264 fixtures"]
    async fn native_warmed_quic_startup() {
        let executable =
            std::path::PathBuf::from(std::env::var_os("VIEWFLOW_ATLAS_NATIVE_EXE").unwrap());
        let fixtures =
            std::path::PathBuf::from(std::env::var_os("VIEWFLOW_ATLAS_WARMUP_FIXTURES").unwrap());
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut policy = plan();
        policy.policy.width = 1626;
        policy.policy.height = 1240;
        policy.policy.max_encoded_bytes = 8 << 20;
        policy.policy.max_age_ns = 33_333_333;
        policy.max_decoded_bytes = 64 << 20;
        for descriptor in [&mut policy.color, &mut policy.alpha] {
            descriptor.coded_width = 1626;
            descriptor.coded_height = 1240;
        }
        let alpha =
            viewflow_transport::encode_alpha_rle(1626, 1240, &vec![0; 1626 * 1240]).unwrap();
        let frames = std::array::from_fn(|i| crate::atlas_presenter::AtlasWarmupFrame {
            width: 1626,
            height: 1240,
            color: std::fs::read(fixtures.join(format!("color-{}.h264", i + 1)))
                .unwrap()
                .into(),
            alpha: alpha.clone(),
        });
        let (sender, owner) = tokio::join!(
            offer_warmed_atlas(&outbound, policy, &frames, deadline),
            crate::atlas_receiver_presenter::AtlasReceiverPresenter::accept_warmed(
                &inbound,
                policy,
                &executable,
                deadline
            )
        );
        let owner = owner.unwrap();
        assert!(sender.is_ok());
        owner.shutdown().await.unwrap();
        eprintln!("native QUIC warmup passed; no V5 records or input submitted");
    }

    #[tokio::test]
    async fn warmed_acceptance_waits_for_native_completion() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let (started, started_rx) = tokio::sync::oneshot::channel();
        let (release, release_rx) = tokio::sync::oneshot::channel();
        let frames = warmup_frames();
        let sender = async {
            let mut offer = Box::pin(offer_warmed_atlas(&outbound, plan(), &frames, deadline));
            tokio::select! {
                result = &mut offer => panic!("accepted before native completion: {}", result.is_ok()),
                result = started_rx => result.unwrap(),
            }
            assert!(
                tokio::time::timeout(Duration::from_millis(10), &mut offer)
                    .await
                    .is_err()
            );
            release.send(()).unwrap();
            offer.await.unwrap()
        };
        let receiver = accept_warmed_atlas(&inbound, plan(), deadline, |received| async move {
            for frame in received {
                assert_eq!(frame.color, warmup_frames()[0].color);
                assert_eq!(frame.alpha, warmup_frames()[0].alpha);
            }
            started.send(()).unwrap();
            release_rx.await.unwrap();
            Ok(())
        });
        let (_, received) = tokio::join!(sender, receiver);
        assert!(received.is_ok());
    }

    #[tokio::test]
    async fn native_warmup_failure_closes_both_handshake_ends() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let frames = warmup_frames();
        let (sent, received) = tokio::join!(
            offer_warmed_atlas(&outbound, plan(), &frames, deadline),
            accept_warmed_atlas(&inbound, plan(), deadline, |_| async {
                anyhow::bail!("native warmup failed")
            })
        );
        assert!(sent.is_err());
        assert!(
            received
                .err()
                .unwrap()
                .to_string()
                .contains("native warmup failed")
        );
        assert!(inbound.close_reason().is_some());
        assert!(outbound.close_reason().is_some());
    }

    #[tokio::test]
    async fn selection_rejection_capability_is_required_in_both_handshake_directions() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(1);
        let legacy_offer = async {
            let (mut tx, _rx) = outbound.open_bi().await.unwrap();
            let mut message = plan().message(&outbound, false).unwrap();
            message.selection_rejection_version = 0;
            write_message(&mut tx, message).await.unwrap();
        };
        let ((), accepted) = tokio::join!(legacy_offer, accept_atlas(&inbound, plan(), deadline));
        assert!(accepted.is_err());
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(1);
        let legacy_accept = async {
            let (mut tx, mut rx) = inbound.accept_bi().await.unwrap();
            let mut message = read_message(&mut rx).await.unwrap();
            assert_eq!(message.selection_rejection_version, 1);
            message.selection_rejection_version = 0;
            message.accepted = true;
            write_message(&mut tx, message).await.unwrap();
        };
        let (offered, ()) = tokio::join!(offer_atlas(&outbound, plan(), deadline), legacy_accept);
        assert!(offered.is_err());
    }

    #[tokio::test]
    async fn malformed_warmup_never_reaches_native() {
        for variant in 0..4 {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(2);
            let mut offer = plan().message(&outbound, false).unwrap();
            offer.version = if variant == 3 { 1 } else { 2 };
            let payload = offer.encode_to_vec();
            let mut data = b"VFAW".to_vec();
            data.extend_from_slice(&u32::try_from(payload.len()).unwrap().to_be_bytes());
            data.extend_from_slice(&payload);
            for (index, frame) in warmup_frames().into_iter().enumerate() {
                let color_length = if variant == 0 && index == 0 {
                    u32::MAX
                } else {
                    u32::try_from(frame.color.len()).unwrap()
                };
                data.extend_from_slice(&color_length.to_be_bytes());
                data.extend_from_slice(&u32::try_from(frame.alpha.len()).unwrap().to_be_bytes());
                data.extend_from_slice(&frame.color);
                data.extend_from_slice(&frame.alpha);
            }
            if variant == 1 {
                data.pop();
            }
            if variant == 2 {
                data.push(0);
            }
            let sender = async {
                let (mut tx, mut rx) = outbound.open_bi().await.unwrap();
                // Rejection may race the local writer; either outcome is valid.
                let _ = tx.write_all(&data).await;
                let _ = tx.finish();
                assert!(read_message(&mut rx).await.is_err());
            };
            let receiver = accept_warmed_atlas(&inbound, plan(), deadline, |_| async {
                panic!("malformed startup reached native warmup")
            });
            let ((), result) = tokio::join!(sender, receiver);
            assert!(result.is_err());
            assert!(inbound.close_reason().is_some());
        }
    }

    #[tokio::test]
    async fn warmup_retains_original_deadline_through_native_work() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_millis(100);
        let frames = warmup_frames();
        let (sent, received) = tokio::join!(
            offer_warmed_atlas(&outbound, plan(), &frames, deadline),
            accept_warmed_atlas(&inbound, plan(), deadline, |_| async {
                std::future::pending::<Result<()>>().await
            })
        );
        assert!(sent.is_err());
        assert!(received.is_err());
        assert!(inbound.close_reason().is_some());
        assert!(outbound.close_reason().is_some());
    }

    #[tokio::test]
    async fn cancelled_native_warmup_closes_dedicated_connection() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let frames = warmup_frames();
        let (started, started_rx) = tokio::sync::oneshot::channel();
        let mut receiver = Box::pin(accept_warmed_atlas(
            &inbound,
            plan(),
            deadline,
            |_| async move {
                started.send(()).unwrap();
                std::future::pending::<Result<()>>().await
            },
        ));
        let sender = async {
            let mut offer = Box::pin(offer_warmed_atlas(&outbound, plan(), &frames, deadline));
            tokio::select! {
                result = &mut offer => panic!("unexpected early result {}", result.is_ok()),
                result = started_rx => result.unwrap(),
            }
            drop(offer);
        };
        tokio::select! {
            result = &mut receiver => panic!("unexpected receiver result {}", result.is_ok()),
            () = sender => (),
        }
        drop(receiver);
        assert!(inbound.close_reason().is_some());
        assert!(outbound.close_reason().is_some());
    }

    #[tokio::test]
    #[cfg(target_os = "linux")]
    async fn quic_receiver_forwards_to_supervised_pipe_after_wait_timeout() {
        use crate::{
            atlas_presenter_child::AtlasPresenterChild,
            atlas_receiver_presenter::{AtlasReceiverPresenter, QpcSample},
        };
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut policy = plan();
        policy.policy.max_age_ns = 1_000_000_000;
        let color = bytes::Bytes::from_static(&[0, 0, 1, 0x65]);
        let alpha = viewflow_transport::encode_alpha_rle(64, 64, &vec![7; 4096]).unwrap();
        let record_size = 112 + color.len() + alpha.len();
        let warmup_size = 40 + color.len() + alpha.len();
        let mut command = tokio::process::Command::new("/bin/sh");
        command.args(["-c", &format!("printf 'atlas-native-ready input_enabled=false\\n'; for i in 1 2 3; do head -c {warmup_size} >/dev/null; printf 'atlas-warmup-completed identity=%s width=64 height=64\\n' \"$i\"; done; head -c {record_size} >/dev/null; printf 'atlas-submitted frame_identity=1 tile_count=0 physical_present_receipt=false\\n'; read line")]);
        let child = AtlasPresenterChild::spawn_command(command, deadline)
            .await
            .unwrap();
        let frames = warmup_frames();
        let (sender, receiver) = tokio::join!(
            offer_warmed_atlas(&outbound, policy, &frames, deadline),
            AtlasReceiverPresenter::accept_with_child(&inbound, policy, child, deadline)
        );
        let mut sender = sender.unwrap();
        let mut owner = receiver.unwrap();
        let waiting = owner
            .forward_next_with_clock(
                || 110,
                || panic!("no admitted frame to clock"),
                Instant::now() + Duration::from_millis(10),
                1 << 20,
            )
            .await;
        assert!(
            waiting
                .unwrap_err()
                .downcast_ref::<AtlasWaitExpired>()
                .is_some()
        );
        let manifest = AtlasFrame {
            patches: None,
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
        let (sent, submitted) = tokio::join!(
            sender.send_frame(manifest, color, alpha, 1, deadline),
            owner.forward_next_with_clock(
                || 110,
                || Ok(QpcSample {
                    ticks: 1000,
                    frequency: 10_000_000
                }),
                deadline,
                1 << 20
            )
        );
        sent.unwrap();
        let submitted = submitted.unwrap();
        assert_eq!(submitted.frame_id, 1);
        assert_eq!(submitted.tile_count, 0);
        owner.shutdown().await.unwrap();
    }

    #[tokio::test]
    #[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
    async fn unprepared_batch_retires_owner_before_gpu_submission() {
        use crate::gpu_atlas_sender::{AtlasBatch, GpuAtlasSender};
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let (sender, receiver) = tokio::join!(
            offer_atlas(&outbound, plan(), deadline),
            accept_atlas(&inbound, plan(), deadline)
        );
        let _receiver = receiver.unwrap();
        // Construction is CPU-only; no prepare_size or GPU import is invoked.
        let encoder = crate::gpu_compatible_encoder::GpuAtlasCompatibleEncoder::new(
            crate::compatible_encoder::Config {
                max_input_bytes: 16384,
                max_color_access_unit_bytes: 16384,
                max_alpha_access_unit_bytes: 16384,
                max_pending_frames: 1,
            },
        )
        .unwrap();
        let mut owner = GpuAtlasSender::new(encoder, sender.unwrap());
        let batch = || AtlasBatch {
            codec: crate::compatible_encoder::CodecIdentity {
                window_id: Id128(99),
                config_generation: 1,
            },
            layout: viewflow_core::AtlasSnapshot {
                revision: 0,
                width: 64,
                height: 64,
                placements: vec![],
            },
            identity: crate::gpu_nvenc_runtime::GpuAtlasIdentity {
                frame_id: 1,
                capture_monotonic_ns: 100,
                geometry_epoch: 1,
            },
            mapped_source_ns: 100,
            deadline_monotonic_ns: 1000,
            sources: vec![],
            desktop: None,
        };
        let result = owner.submit_batch(batch(), 1, Instant::now()).await;
        assert!(
            result
                .err()
                .unwrap()
                .to_string()
                .contains("atlas GPU size must be prepared")
        );
        assert!(owner.is_retired());
        let retry = owner.submit_batch(batch(), 1, deadline).await;
        assert!(retry.err().unwrap().to_string().contains("retired"));
    }

    #[tokio::test]
    #[cfg(all(target_os = "linux", feature = "native-nvenc"))]
    async fn sender_planes_reach_unified_receiver() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let (sender, receiver) = tokio::join!(
            offer_atlas(&outbound, plan(), deadline),
            accept_atlas(&inbound, plan(), deadline)
        );
        let mut sender = sender.unwrap();
        let mut receiver = receiver.unwrap();
        let manifest = AtlasFrame {
            patches: None,
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: None,
            stream_id: Id128(99),
            frame_id: 1,
            geometry_epoch: 1,
            config_generation: 1,
            layout_revision: 0,
            width: 64,
            height: 64,
            source_submitted_ns: 100,
            tiles: vec![],
        };
        let color = bytes::Bytes::from(vec![0x65; 512]);
        let alpha = viewflow_transport::encode_alpha_rle(64, 64, &vec![0; 4096]).unwrap();
        // Local preflight failures do not consume or poison a session.
        assert!(
            sender
                .send_frame(
                    manifest.clone(),
                    bytes::Bytes::new(),
                    alpha.clone(),
                    1,
                    deadline
                )
                .await
                .is_err()
        );
        assert!(!sender.frame_send_poisoned);
        let plane = |payload, plane| viewflow_transport::MediaPlaneFrame {
            window_id: manifest.stream_id,
            frame_id: manifest.frame_id,
            geometry_epoch: manifest.geometry_epoch,
            source_submitted_ns: manifest.source_submitted_ns,
            plane,
            payload,
        };
        let metadata = viewflow_transport::FrameCodecMetadata {
            config_generation: 1,
            keyframe: true,
        };
        let coded = crate::compatible_encoder::MediaFrame {
            color: plane(color.clone(), viewflow_transport::MediaPlane::Color),
            alpha: plane(alpha.clone(), viewflow_transport::MediaPlane::Alpha),
            color_metadata: metadata,
            alpha_metadata: metadata,
        };
        for mismatch in 0..7 {
            let mut invalid = coded.clone();
            match mismatch {
                0 => invalid.color.window_id = Id128(100),
                1 => invalid.alpha.frame_id += 1,
                2 => invalid.color.geometry_epoch += 1,
                3 => invalid.alpha.source_submitted_ns += 1,
                4 => invalid.color.plane = viewflow_transport::MediaPlane::Alpha,
                5 => invalid.alpha_metadata.config_generation += 1,
                _ => invalid.color_metadata.keyframe = false,
            }
            assert!(
                sender
                    .send_coded_frame(manifest.clone(), invalid, 1, deadline)
                    .await
                    .is_err()
            );
            assert!(!sender.frame_send_poisoned);
        }
        let (sent, received) = tokio::join!(
            sender.send_coded_frame(manifest.clone(), coded, 1, deadline),
            receiver.next_frame(|| 110, deadline)
        );
        sent.unwrap();
        let received = received.unwrap();
        assert_eq!(received.layout, manifest);
        assert_eq!(received.media.color, color);
        assert_eq!(received.media.alpha, Some(alpha));
        assert!(!sender.frame_send_poisoned);
    }

    #[tokio::test]
    async fn mtls_negotiation_then_reliable_manifest_reaches_admission() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(2);
            let (sender, receiver) = tokio::join!(
                offer_atlas(&outbound, plan(), deadline),
                accept_atlas(&inbound, plan(), deadline)
            );
            let sender = sender.unwrap();
            let mut receiver = receiver.unwrap();
            let manifest = AtlasFrame {
                patches: None,
                color_keyframe: true,
                alpha_keyframe: true,
                desktop: None,
                stream_id: Id128(99),
                frame_id: 1,
                geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 0,
                width: 64,
                height: 64,
                source_submitted_ns: 100,
                tiles: vec![],
            };
            let mut sequence = ControlSequencer::default();
            let (sent, received) = tokio::join!(
                sender.send_manifest(manifest.clone(), 1, deadline),
                receiver.receive_manifest(&mut sequence, || 110, deadline)
            );
            sent.unwrap();
            received.unwrap();
            assert_eq!(sequence.previous(), Some(1));
            // Actual fragmented QUIC datagrams and codec admission. Synthetic
            // color bytes are not a native decoder/presentation proof.
            let color = bytes::Bytes::from(vec![0x65; 512]);
            let alpha = viewflow_transport::encode_alpha_rle(64, 64, &vec![0; 4096]).unwrap();
            let mut packets = Vec::new();
            for (plane, payload) in [
                (viewflow_transport::MediaPlane::Color, color.clone()),
                (viewflow_transport::MediaPlane::Alpha, alpha.clone()),
            ] {
                packets.extend(
                    viewflow_transport::MediaPlaneFrame {
                        window_id: Id128(99),
                        frame_id: 1,
                        geometry_epoch: 1,
                        plane,
                        source_submitted_ns: 100,
                        payload,
                    }
                    .fragment(160)
                    .unwrap(),
                );
            }
            packets.reverse();
            let mut admitted = None;
            for packet in packets {
                outbound.send_datagram(packet.encode()).unwrap();
                if let Some(frame) = receiver.receive_media(|| 110, deadline).await.unwrap() {
                    assert!(admitted.is_none());
                    admitted = Some(frame);
                }
            }
            let admitted = admitted.unwrap();
            assert_eq!(admitted.media.color, color);
            assert_eq!(admitted.media.alpha, Some(alpha));
            assert_eq!(admitted.layout, manifest);
            let (sent, replay) = tokio::join!(
                sender.send_manifest(manifest, 1, deadline),
                receiver.receive_manifest(&mut sequence, || 110, deadline)
            );
            sent.unwrap();
            assert!(replay.is_err());
            outbound.close(0_u32.into(), b"done");
            inbound.close(0_u32.into(), b"done");
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn mtls_rejects_different_plan_and_tampered_acceptance() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(2);
            let mut other = plan();
            other.policy.max_tiles = 3;
            let (sender, receiver) = tokio::join!(
                offer_atlas(&outbound, plan(), deadline),
                accept_atlas(&inbound, other, deadline)
            );
            assert!(sender.is_err() && receiver.is_err());
            let (sender, ()) = tokio::join!(offer_atlas(&outbound, plan(), deadline), async {
                let (mut tx, mut rx) = inbound.accept_bi().await.unwrap();
                read_message(&mut rx).await.unwrap();
                let mut answer = plan().message(&inbound, true).unwrap();
                answer.connection_binding[0] ^= 1;
                write_message(&mut tx, answer).await.unwrap();
            });
            assert!(sender.is_err());
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn binding_changes_per_connection_and_missing_ack_times_out() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let (_c1, _s1, a, b) = pair().await;
            let (_c2, _s2, c, _d) = pair().await;
            assert_eq!(
                plan().message(&a, false).unwrap(),
                plan().message(&b, false).unwrap()
            );
            assert_ne!(
                plan().message(&a, false).unwrap().connection_binding,
                plan().message(&c, false).unwrap().connection_binding
            );
            let error = offer_atlas(&a, plan(), Instant::now() + Duration::from_millis(20)).await;
            assert!(error.is_err());
            assert!(offer_atlas(&a, plan(), Instant::now()).await.is_err());
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn datagram_reference_gap_retires_instead_of_admitting_dependent_p_frame() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(2);
            let (sender, receiver) = tokio::join!(
                offer_atlas(&outbound, plan(), deadline),
                accept_atlas(&inbound, plan(), deadline)
            );
            let sender = sender.unwrap();
            let mut receiver = receiver.unwrap();
            let mut sequence = ControlSequencer::default();
            for frame_id in [1, 2, 4] {
                let manifest = AtlasFrame {
                    patches: None,
                    stream_id: Id128(99),
                    frame_id,
                    geometry_epoch: 1,
                    config_generation: 1,
                    layout_revision: 0,
                    width: 64,
                    height: 64,
                    source_submitted_ns: 100 + frame_id,
                    tiles: vec![],
                    color_keyframe: frame_id == 1,
                    alpha_keyframe: true,
                    desktop: None,
                };
                let (sent, received) = tokio::join!(
                    sender.send_manifest(manifest, frame_id, deadline),
                    receiver.receive_manifest(&mut sequence, || 110, deadline)
                );
                sent.unwrap();
                received.unwrap();
                for plane in [
                    viewflow_transport::MediaPlane::Color,
                    viewflow_transport::MediaPlane::Alpha,
                ] {
                    let packet = viewflow_transport::MediaPlaneFrame {
                        window_id: Id128(99),
                        frame_id,
                        geometry_epoch: 1,
                        plane,
                        source_submitted_ns: 100 + frame_id,
                        payload: bytes::Bytes::from_static(b"synthetic"),
                    }
                    .fragment(160)
                    .unwrap()
                    .next()
                    .unwrap();
                    outbound.send_datagram(packet.encode()).unwrap();
                    let received = receiver.receive_media(|| 110, deadline).await;
                    if plane == viewflow_transport::MediaPlane::Color {
                        assert!(received.unwrap().is_none());
                    } else if frame_id == 4 {
                        assert!(received.is_err());
                        assert!(receiver.retired);
                    } else {
                        assert!(received.unwrap().is_some());
                    }
                }
            }
            assert!(receiver.receive_media(|| 110, deadline).await.is_err());
        })
        .await
        .unwrap();
    }

    fn early_packet(
        frame_id: u64,
        plane: viewflow_transport::MediaPlane,
    ) -> viewflow_transport::MediaDatagram {
        viewflow_transport::MediaDatagram {
            window_id: Id128(99),
            frame_id,
            geometry_epoch: 1,
            plane,
            chunk_index: 0,
            chunk_count: 1,
            source_submitted_ns: 100,
            payload: bytes::Bytes::from_static(b"synthetic"),
        }
    }

    #[tokio::test]
    async fn early_datagrams_deliver_when_manifest_arrives_without_timestamp_renewal() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(2);
            let (sender, receiver) = tokio::join!(
                offer_atlas(&outbound, plan(), deadline),
                accept_atlas(&inbound, plan(), deadline)
            );
            let sender = sender.unwrap();
            let mut receiver = receiver.unwrap();
            for plane in [
                viewflow_transport::MediaPlane::Alpha,
                viewflow_transport::MediaPlane::Color,
            ] {
                outbound
                    .send_datagram(early_packet(1, plane).encode())
                    .unwrap();
                assert!(
                    receiver
                        .receive_media(|| 110, deadline)
                        .await
                        .unwrap()
                        .is_none()
                );
            }
            let bytes = receiver.early.as_ref().unwrap().bytes;
            outbound
                .send_datagram(early_packet(1, viewflow_transport::MediaPlane::Color).encode())
                .unwrap();
            assert!(
                receiver
                    .receive_media(|| 120, deadline)
                    .await
                    .unwrap()
                    .is_none()
            );
            let early = receiver.early.as_ref().unwrap();
            assert_eq!(early.bytes, bytes);
            assert!(
                early
                    .packets
                    .values()
                    .all(|packet| packet.received_ns == 110)
            );
            let manifest = AtlasFrame {
                patches: None,
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
            let mut sequence = ControlSequencer::default();
            let (sent, received) = tokio::join!(
                sender.send_manifest(manifest.clone(), 1, deadline),
                receiver.receive_manifest(&mut sequence, || 125, deadline)
            );
            sent.unwrap();
            let frame = received.unwrap().unwrap();
            assert_eq!(frame.layout, manifest);
            assert_eq!(frame.media.manifest.source_submitted_ns, 100);
            assert_eq!(frame.media.manifest.received_ns, 125);
            assert_eq!(frame.media.color.as_ref(), b"synthetic");
            assert!(receiver.early.is_none());
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn early_buffer_is_bounded_and_late_layout_cannot_revive_frame() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(2);
            let (_sender, receiver) = tokio::join!(
                offer_atlas(&outbound, plan(), deadline),
                accept_atlas(&inbound, plan(), deadline)
            );
            let mut receiver = receiver.unwrap();
            let packet = early_packet(1, viewflow_transport::MediaPlane::Color);
            assert!(receiver.push_media(packet.clone(), 110).unwrap().is_none());
            assert!(receiver.push_media(packet, 1000).unwrap().is_none()); // exact duplicate does not renew
            let manifest = AtlasFrame {
                patches: None,
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
            assert!(receiver.stage_manifest(manifest, 1000).is_err());
            assert_eq!(receiver.last_coded_frame, None);
            assert_eq!(
                receiver
                    .early
                    .as_ref()
                    .unwrap()
                    .packets
                    .values()
                    .next()
                    .unwrap()
                    .received_ns,
                110
            );
            // Only the newest frame is retained, and payload bounds are enforced.
            let mut newer = early_packet(3, viewflow_transport::MediaPlane::Color);
            newer.source_submitted_ns = 1000;
            assert!(receiver.push_media(newer, 1010).unwrap().is_none());
            assert!(
                receiver
                    .push_media(early_packet(2, viewflow_transport::MediaPlane::Color), 1100)
                    .unwrap()
                    .is_none()
            );
            assert_eq!(receiver.early.as_ref().unwrap().frame_id, 3);
            let mut oversized = early_packet(4, viewflow_transport::MediaPlane::Color);
            oversized.source_submitted_ns = 1100;
            oversized.payload = bytes::Bytes::from(vec![0; 1025]);
            assert!(receiver.push_media(oversized, 1110).is_err());
            assert!(receiver.retired && receiver.early.is_none());
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn early_packet_or_manifest_conflict_never_retags_buffered_pixels() {
        tokio::time::timeout(Duration::from_secs(5), async {
            for conflict in 0..3 {
                let (_client, _server, outbound, inbound) = pair().await;
                let deadline = Instant::now() + Duration::from_secs(2);
                let (_sender, receiver) = tokio::join!(
                    offer_atlas(&outbound, plan(), deadline),
                    accept_atlas(&inbound, plan(), deadline)
                );
                let mut receiver = receiver.unwrap();
                let packet = early_packet(1, viewflow_transport::MediaPlane::Color);
                receiver.push_media(packet.clone(), 110).unwrap();
                if conflict < 2 {
                    let mut bad = packet;
                    if conflict == 0 {
                        bad.payload = bytes::Bytes::from_static(b"changed");
                    } else {
                        bad.plane = viewflow_transport::MediaPlane::Alpha;
                        bad.source_submitted_ns = 101;
                    }
                    assert!(receiver.push_media(bad, 110).is_err());
                } else {
                    let manifest = AtlasFrame {
                        patches: None,
                        stream_id: Id128(99),
                        frame_id: 1,
                        geometry_epoch: 1,
                        config_generation: 1,
                        layout_revision: 0,
                        width: 64,
                        height: 64,
                        source_submitted_ns: 101,
                        tiles: vec![],
                        color_keyframe: true,
                        alpha_keyframe: true,
                        desktop: None,
                    };
                    assert!(receiver.stage_manifest(manifest, 110).is_err());
                }
                assert!(receiver.retired && receiver.early.is_none());
                assert_eq!(receiver.last_coded_frame, None);
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn postprocessing_expiry_discards_pair_and_retires_codec_chain() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(2);
            let (sender, receiver) = tokio::join!(
                offer_atlas(&outbound, plan(), deadline),
                accept_atlas(&inbound, plan(), deadline)
            );
            let sender = sender.unwrap();
            let mut receiver = receiver.unwrap();
            for plane in [
                viewflow_transport::MediaPlane::Color,
                viewflow_transport::MediaPlane::Alpha,
            ] {
                receiver.push_media(early_packet(1, plane), 110).unwrap();
            }
            let manifest = AtlasFrame {
                patches: None,
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
            let mut sequence = ControlSequencer::default();
            let mut samples = [110, 150].into_iter();
            let (sent, received) = tokio::join!(
                sender.send_manifest(manifest, 1, deadline),
                receiver.receive_manifest(&mut sequence, || samples.next().unwrap(), deadline)
            );
            sent.unwrap();
            assert!(received.is_err());
            assert!(receiver.retired);
            assert_eq!(receiver.last_coded_frame, Some(1)); // processed, but not handed off
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn pump_preserves_half_control_across_timeout_cancellation_and_frame_delivery() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let (_client, _server, outbound, inbound) = pair().await;
            let deadline = Instant::now() + Duration::from_secs(3);
            let (sender, receiver) = tokio::join!(
                offer_atlas(&outbound, plan(), deadline),
                accept_atlas(&inbound, plan(), deadline)
            );
            let sender = sender.unwrap();
            let mut receiver = receiver.unwrap();
            let first = AtlasFrame {
                patches: None,
                stream_id: Id128(99),
                frame_id: 1,
                geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 0,
                width: 64,
                height: 64,
                source_submitted_ns: 101,
                tiles: vec![],
                color_keyframe: true,
                alpha_keyframe: true,
                desktop: None,
            };
            sender.send_manifest(first, 1, deadline).await.unwrap();
            let second = AtlasFrame {
                patches: None,
                stream_id: Id128(99),
                frame_id: 2,
                geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 0,
                width: 64,
                height: 64,
                source_submitted_ns: 102,
                tiles: vec![],
                color_keyframe: false,
                alpha_keyframe: true,
                desktop: None,
            };
            let envelope = wire::ControlEnvelope {
                protocol_major: u32::from(PROTOCOL_VERSION.major),
                protocol_minor: u32::from(PROTOCOL_VERSION.minor),
                sequence: 2,
                payload: Some(wire::control_envelope::Payload::AtlasFrame(second.into())),
            };
            // Same bounded VFRS control framing as send_control, intentionally
            // pause in the middle of the second reliable message.
            let mut bytes = b"VFRS\x01\x01\x00\x00".to_vec();
            bytes.extend(envelope.encode_to_vec());
            let split = bytes.len() / 2;
            let mut partial = outbound.open_uni().await.unwrap();
            partial.write_all(&bytes[..split]).await.unwrap();
            match receiver
                .next_frame(|| 110, Instant::now() + Duration::from_millis(100))
                .await
            {
                Err(error) => assert!(error.is::<AtlasWaitExpired>()),
                Ok(_) => panic!("frame arrived without media"),
            }
            assert!(!receiver.retired && receiver.control_read.is_some());
            assert_eq!(receiver.control_sequence.previous(), Some(1));
            // External cancellation also must leave the same read owned by the
            // session. Synthetic clock values isolate this from latency tests.
            assert!(
                tokio::time::timeout(
                    Duration::from_millis(20),
                    receiver.next_frame(|| 110, deadline)
                )
                .await
                .is_err()
            );
            assert!(!receiver.retired && receiver.control_read.is_some());
            for frame_id in [1, 2] {
                if frame_id == 2 {
                    partial.write_all(&bytes[split..]).await.unwrap();
                    partial.finish().unwrap();
                }
                for plane in [
                    viewflow_transport::MediaPlane::Color,
                    viewflow_transport::MediaPlane::Alpha,
                ] {
                    let mut packet = early_packet(frame_id, plane);
                    packet.source_submitted_ns = 100 + frame_id;
                    outbound.send_datagram(packet.encode()).unwrap();
                }
                let frame = receiver.next_frame(|| 110, deadline).await.unwrap();
                assert_eq!(frame.layout.frame_id, frame_id);
                assert_eq!(receiver.control_sequence.previous(), Some(frame_id));
                assert!(receiver.control_read.is_some());
            }
            assert!(receiver.receive_media(|| 110, deadline).await.is_err());
            assert!(!receiver.retired);
        })
        .await
        .unwrap();
    }
    #[tokio::test]
    async fn selection_rejection_crosses_real_shared_transport_without_retiring_media() {
        let (_client, _server, outbound, inbound) = pair().await;
        let deadline = Instant::now() + Duration::from_secs(2);
        let (sender, receiver) = tokio::join!(
            offer_atlas(&outbound, plan(), deadline),
            accept_atlas(&inbound, plan(), deadline)
        );
        let mut sender = sender.unwrap();
        let mut receiver = receiver.unwrap();
        let writer = crate::shared_control::SharedControlWriter::start(&outbound).unwrap();
        sender.attach_shared_control(writer.sender()).unwrap();
        let (controls, mut events) = tokio::sync::mpsc::channel(1);
        receiver.attach_shared_controls(controls).unwrap();
        let rejected = viewflow_protocol::AtlasWindowSelectionRejected {
            selection: viewflow_protocol::AtlasWindowSelection {
                activate_keyboard: false,
                stream_id: Id128(99),
                atlas_frame_id: 1,
                atlas_geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 1,
                window_id: Id128(3),
                placement_generation: 1,
                source_geometry_epoch: 1,
                source_frame_id: 1,
                sequence: 2,
                sender_not_after_ns: 10,
            },
            reason: viewflow_protocol::AtlasSelectionRejectionReason::EventExpired,
            released_generation: 0,
            capture_age_ns: 0,
            capture_limit_ns: 0,
        };
        writer
            .sender()
            .send(
                wire::control_envelope::Payload::AtlasWindowSelectionRejected(rejected.into()),
                deadline,
            )
            .await
            .unwrap();
        let manifest = AtlasFrame {
            patches: None,
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
        sender
            .send_frame(
                manifest.clone(),
                bytes::Bytes::from(vec![0x65; 512]),
                viewflow_transport::encode_alpha_rle(64, 64, &[0; 4096]).unwrap(),
                1,
                deadline,
            )
            .await
            .unwrap();
        assert_eq!(
            receiver.next_frame(|| 110, deadline).await.unwrap().layout,
            manifest
        );
        let DomainControl::AtlasWindowSelectionRejected(received) = events.try_recv().unwrap()
        else {
            panic!("missing selection rejection")
        };
        assert_eq!(received, rejected);
        assert!(!receiver.retired);
        assert!(events.try_recv().is_err());
    }
}
