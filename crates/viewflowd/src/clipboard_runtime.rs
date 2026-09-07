//! Explicit, bounded clipboard bytes over an already-authenticated QUIC peer.
//!
//! This module deliberately has no native clipboard access. Callers must obtain
//! a local [`ClipboardConsent`] capability and the receiver's `apply` callback
//! may return [`ClipboardInstalled`] only after its platform adapter has
//! installed native clipboard ownership. A successful wire completion is never
//! a claim that another application later pasted the data.

use std::{
    collections::HashSet,
    sync::{Mutex, OnceLock},
};

use anyhow::{Context, Result, bail, ensure};
use quinn::Connection;
use sha2::{Digest, Sha256};
use tokio::time::{Duration, Instant, timeout_at};
use viewflow_protocol::{
    ClipboardAccept, ClipboardComplete, ClipboardCompletionStatus, ClipboardOffer,
    ClipboardPayload, ClipboardTransferFlavor, ClipboardTransferOffer, DomainControl, Id128,
    PROTOCOL_VERSION, wire,
};
use viewflow_transport::{ControlSequencer, receive_control_sequenced, send_control};

/// Kept below the transport's 4 MiB control-envelope ceiling. Clipboard data
/// larger than this must be refused; this lane does not silently chunk it.
pub const MAX_CLIPBOARD_BYTES: usize = 1024 * 1024;
/// Maximum duration for one non-resumable clipboard transaction.
pub const MAX_CLIPBOARD_TRANSACTION: Duration = Duration::from_secs(5);
const MAX_ECHO_FINGERPRINTS: usize = 64;
const TLS_EXPORTER_LABEL: &[u8] = b"viewflow-clipboard-v1";

/// Exclusive ownership of all reliable-control reads for one connection.
///
/// The clipboard lane currently has no daemon control multiplexer/inbox. This
/// lease therefore rejects a second clipboard reader in the same process and
/// keeps the direct `receive_control_sequenced` calls restricted to a dedicated
/// clipboard connection. Do not construct it for a connection managed by the
/// normal daemon control reader or [`crate::shared_control::SharedControlWriter`].
#[derive(Debug)]
pub struct DedicatedClipboardControl {
    connection: Connection,
    connection_id: usize,
}

impl DedicatedClipboardControl {
    /// Acquires the sole clipboard control-reader lease for a live mTLS peer.
    ///
    /// # Errors
    ///
    /// Rejects unauthenticated, closed, or already leased connections. The
    /// caller must also ensure no non-clipboard control dispatcher owns it.
    pub fn acquire(connection: &Connection) -> Result<Self> {
        let connection_id = connection.stable_id();
        ensure!(
            connection.peer_identity().is_some() && connection.close_reason().is_none(),
            "clipboard control requires a live authenticated QUIC peer"
        );
        let mut leased = clipboard_control_leases()
            .lock()
            .map_err(|_| anyhow::anyhow!("clipboard control lease registry poisoned"))?;
        ensure!(
            leased.insert(connection_id),
            "clipboard control reader is already leased for this connection"
        );
        Ok(Self {
            connection: connection.clone(),
            connection_id,
        })
    }

    fn connection(&self) -> &Connection {
        &self.connection
    }

    fn retire(&self, reason: &'static [u8]) {
        self.connection.close(0_u32.into(), reason);
    }
}

impl Drop for DedicatedClipboardControl {
    fn drop(&mut self) {
        if let Ok(mut leased) = clipboard_control_leases().lock() {
            leased.remove(&self.connection_id);
        }
    }
}

fn clipboard_control_leases() -> &'static Mutex<HashSet<usize>> {
    static LEASES: OnceLock<Mutex<HashSet<usize>>> = OnceLock::new();
    LEASES.get_or_init(|| Mutex::new(HashSet::new()))
}

/// Local, one-shot permission issued by the embedding policy/UI.
///
/// This is intentionally non-`Clone` and non-`Copy`: a caller must obtain a
/// fresh consent object for every attempted transfer. The correlation is only
/// audit data; the private scope additionally binds it to the exact outgoing
/// offer or incoming delivery.
#[derive(Debug, Eq, PartialEq)]
pub struct ClipboardConsent {
    correlation: [u8; 16],
    scope: ConsentScope,
}

#[derive(Debug, Eq, PartialEq)]
enum ConsentScope {
    Outgoing {
        offer_id: Id128,
        generation: u64,
        offer_nonce: [u8; 16],
    },
    Incoming {
        offer_id: Id128,
        generation: u64,
        offer_nonce: [u8; 16],
        payload_sequence: u64,
    },
}

impl ClipboardConsent {
    /// Issues local consent for one source offer before its payload sequence is
    /// allocated. The object is consumed by [`ClipboardSender::send`].
    ///
    /// # Errors
    ///
    /// A zero correlation is reserved and cannot stand in for consent.
    pub fn for_outgoing(
        correlation: [u8; 16],
        offer_id: Id128,
        generation: u64,
        offer_nonce: [u8; 16],
    ) -> Result<Self> {
        ensure!(
            correlation != [0; 16] && offer_id.0 != 0 && generation != 0 && offer_nonce != [0; 16],
            "clipboard outgoing consent identity is invalid"
        );
        Ok(Self {
            correlation,
            scope: ConsentScope::Outgoing {
                offer_id,
                generation,
                offer_nonce,
            },
        })
    }

    /// Issues local consent for one exact remote payload delivery. The object
    /// is consumed by [`ClipboardReceiver::receive`].
    ///
    /// # Errors
    ///
    /// Rejects a zero correlation or incomplete delivery identity.
    pub fn for_incoming(
        correlation: [u8; 16],
        offer_id: Id128,
        generation: u64,
        offer_nonce: [u8; 16],
        payload_sequence: u64,
    ) -> Result<Self> {
        ensure!(
            correlation != [0; 16]
                && offer_id.0 != 0
                && generation != 0
                && offer_nonce != [0; 16]
                && payload_sequence != 0,
            "clipboard incoming consent identity is invalid"
        );
        Ok(Self {
            correlation,
            scope: ConsentScope::Incoming {
                offer_id,
                generation,
                offer_nonce,
                payload_sequence,
            },
        })
    }

    fn matches_outgoing(&self, offer: &ClipboardOffer, offer_nonce: [u8; 16]) -> bool {
        matches!(
            self.scope,
            ConsentScope::Outgoing { offer_id, generation, offer_nonce: expected_nonce }
                if offer_id == offer.id
                    && generation == offer.generation
                    && expected_nonce == offer_nonce
        )
    }

    fn matches_incoming(&self, key: &DeliveryKey) -> bool {
        matches!(
            self.scope,
            ConsentScope::Incoming {
                offer_id,
                generation,
                offer_nonce,
                payload_sequence,
            } if offer_id == key.offer_id
                && generation == key.generation
                && offer_nonce == key.offer_nonce
                && payload_sequence == key.payload_sequence
        )
    }

    const fn correlation(&self) -> [u8; 16] {
        self.correlation
    }
}

/// Sender-provided immutable bytes and their complete advertised flavor set.
#[derive(Debug)]
pub struct ClipboardSendRequest {
    pub offer: ClipboardOffer,
    pub flavors: Vec<ClipboardTransferFlavor>,
    pub offer_nonce: [u8; 16],
    pub consent: ClipboardConsent,
    pub mime_type: String,
    pub data: Vec<u8>,
}

/// Marker an adapter returns only after it installed clipboard ownership.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ClipboardInstalled;

/// The complete proof handed to a platform adapter after this runtime has
/// verified the mTLS-bound offer, matching accept, payload identity, size, and
/// digest. Pass these exact values to `apply_verified_remote`; do not rebuild a
/// receipt from payload bytes alone. The callback is synchronous: it must use
/// its own bounded native-operation timeout and must not block a Tokio worker.
/// A future daemon route should run native work in a blocking worker tied to
/// the original transaction deadline.
#[derive(Debug)]
pub struct VerifiedClipboardTransfer<'a> {
    pub transfer: &'a ClipboardTransferOffer,
    pub accepted: &'a ClipboardAccept,
    pub payload: &'a ClipboardPayload,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardReceiveReceipt {
    pub offer_id: Id128,
    pub generation: u64,
    pub offer_nonce: [u8; 16],
    pub payload_sequence: u64,
    pub status: ClipboardCompletionStatus,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DeliveryKey {
    offer_id: Id128,
    generation: u64,
    offer_nonce: [u8; 16],
    payload_sequence: u64,
}

impl DeliveryKey {
    fn from_offer(offer: &ClipboardTransferOffer) -> Self {
        Self {
            offer_id: offer.offer.id,
            generation: offer.offer.generation,
            offer_nonce: offer.offer_nonce,
            payload_sequence: offer.payload_sequence,
        }
    }

    fn matches_payload(&self, payload: &ClipboardPayload) -> bool {
        self.offer_id == payload.offer_id
            && self.generation == payload.generation
            && self.offer_nonce == payload.offer_nonce
            && self.payload_sequence == payload.payload_sequence
    }

    fn matches_complete(&self, complete: &ClipboardComplete) -> bool {
        self.offer_id == complete.offer_id
            && self.generation == complete.generation
            && self.offer_nonce == complete.offer_nonce
            && self.payload_sequence == complete.payload_sequence
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct ClipboardFingerprint {
    mime_type: String,
    sha256: [u8; 32],
}

/// Sender boundary. The sequence state is intentionally connection-scoped;
/// create a new sender after reconnecting.
#[derive(Debug)]
pub struct ClipboardSender {
    control: DedicatedClipboardControl,
    next_control_sequence: u64,
    next_payload_sequence: u64,
    incoming: ControlSequencer,
}

struct TransactionGuard {
    connection: Connection,
    armed: bool,
}

impl TransactionGuard {
    fn new(connection: Connection) -> Self {
        Self {
            connection,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for TransactionGuard {
    fn drop(&mut self) {
        if self.armed {
            self.connection
                .close(0_u32.into(), b"clipboard transaction cancelled or failed");
        }
    }
}

impl ClipboardSender {
    /// `control` must be a dedicated reader lease; normal daemon control
    /// dispatch must route through a future typed inbox instead. The sequences
    /// are the next unused values for this connection direction.
    ///
    /// # Errors
    ///
    /// Rejects zero sequence numbers.
    pub fn new(
        control: DedicatedClipboardControl,
        next_control_sequence: u64,
        next_payload_sequence: u64,
    ) -> Result<Self> {
        ensure!(
            next_control_sequence > 0 && next_payload_sequence > 0,
            "clipboard sequences must be non-zero"
        );
        Ok(Self {
            control,
            next_control_sequence,
            next_payload_sequence,
            incoming: ControlSequencer::default(),
        })
    }

    /// Sends one offered clipboard payload and waits for its exact completion.
    /// It may return Cancelled/Rejected/Failed after a valid remote completion;
    /// only Completed means the receiver's adapter reported installed ownership.
    ///
    /// # Errors
    ///
    /// Fails closed for an invalid local offer or bytes, a non-mTLS/closed
    /// connection, replayed/reordered peer control, mismatched phase identity,
    /// or a QUIC transport error.
    pub async fn send(
        &mut self,
        request: ClipboardSendRequest,
        deadline: Instant,
    ) -> Result<ClipboardComplete> {
        ensure!(
            deadline > Instant::now() && deadline <= Instant::now() + MAX_CLIPBOARD_TRANSACTION,
            "clipboard transaction deadline is invalid"
        );
        let connection = self.control.connection().clone();
        let mut guard = TransactionGuard::new(connection.clone());
        let result = timeout_at(deadline, self.send_inner(&connection, request))
            .await
            .context("clipboard transaction timed out")?;
        if result.is_ok() {
            guard.disarm();
        } else {
            self.control.retire(b"clipboard transaction failed");
        }
        result
    }

    async fn send_inner(
        &mut self,
        connection: &Connection,
        request: ClipboardSendRequest,
    ) -> Result<ClipboardComplete> {
        let binding = connection_binding(connection)?;
        ensure!(
            request
                .consent
                .matches_outgoing(&request.offer, request.offer_nonce),
            "local clipboard consent does not match outgoing offer"
        );
        ensure!(
            request.data.len() <= MAX_CLIPBOARD_BYTES,
            "clipboard payload exceeds {MAX_CLIPBOARD_BYTES}-byte limit"
        );
        let payload_sequence = self.take_payload_sequence()?;
        let offer = ClipboardTransferOffer {
            offer: request.offer,
            flavors: request.flavors,
            offer_nonce: request.offer_nonce,
            consent_correlation: request.consent.correlation(),
            connection_binding: binding,
            payload_sequence,
        };
        offer
            .validate()
            .map_err(|error| anyhow::anyhow!("invalid clipboard transfer offer: {error:?}"))?;
        let flavor = exact_flavor(&offer, &request.mime_type)?;
        ensure!(
            usize::try_from(flavor.size_bytes).ok() == Some(request.data.len()),
            "clipboard payload size differs from its advertised flavor"
        );
        ensure!(
            sha256(&request.data) == flavor.sha256,
            "clipboard payload digest differs from its advertised flavor"
        );
        let key = DeliveryKey::from_offer(&offer);
        self.send_domain(
            connection,
            wire::control_envelope::Payload::ClipboardTransferOffer(offer.clone().into()),
        )
        .await?;

        match self.receive_domain(connection).await? {
            DomainControl::ClipboardComplete(complete) => {
                ensure!(
                    key.matches_complete(&complete),
                    "clipboard completion identity mismatch"
                );
                ensure!(
                    complete.status != ClipboardCompletionStatus::Completed,
                    "receiver completed clipboard transfer before payload"
                );
                return Ok(complete);
            }
            DomainControl::ClipboardAccept(accept) => {
                ensure!(
                    accept.offer_id == key.offer_id
                        && accept.generation == key.generation
                        && accept.offer_nonce == key.offer_nonce
                        && accept.payload_sequence == key.payload_sequence
                        && accept.mime_type == request.mime_type,
                    "clipboard accept identity or flavor mismatch"
                );
            }
            _ => bail!("unexpected control while waiting for clipboard acceptance"),
        }

        let payload = ClipboardPayload {
            offer_id: key.offer_id,
            generation: key.generation,
            offer_nonce: key.offer_nonce,
            payload_sequence: key.payload_sequence,
            mime_type: request.mime_type,
            data: request.data,
        };
        self.send_domain(
            connection,
            wire::control_envelope::Payload::ClipboardPayload(payload.into()),
        )
        .await?;
        let DomainControl::ClipboardComplete(complete) = self.receive_domain(connection).await?
        else {
            bail!("unexpected control while waiting for clipboard completion");
        };
        ensure!(
            key.matches_complete(&complete),
            "clipboard completion identity mismatch"
        );
        Ok(complete)
    }

    fn take_payload_sequence(&mut self) -> Result<u64> {
        let sequence = self.next_payload_sequence;
        self.next_payload_sequence = self
            .next_payload_sequence
            .checked_add(1)
            .context("clipboard payload sequence exhausted")?;
        Ok(sequence)
    }

    async fn send_domain(
        &mut self,
        connection: &Connection,
        payload: wire::control_envelope::Payload,
    ) -> Result<()> {
        let sequence = self.next_control_sequence;
        self.next_control_sequence = self
            .next_control_sequence
            .checked_add(1)
            .context("clipboard control sequence exhausted")?;
        send_control(connection, &envelope(sequence, payload))
            .await
            .context("send clipboard control")
    }

    async fn receive_domain(&mut self, connection: &Connection) -> Result<DomainControl> {
        let envelope = receive_control_sequenced(connection, &mut self.incoming)
            .await
            .context("receive ordered clipboard control")?;
        DomainControl::try_from(envelope)
            .map_err(|error| anyhow::anyhow!("decode clipboard control: {error:?}"))
    }
}

/// Receiver boundary. The caller chooses a single MIME type from a valid offer
/// and receives bytes only through the supplied native-install callback.
#[derive(Debug)]
pub struct ClipboardReceiver {
    control: DedicatedClipboardControl,
    next_control_sequence: u64,
    incoming: ControlSequencer,
    last_payload_sequence: Option<u64>,
    applied: HashSet<ClipboardFingerprint>,
}

impl ClipboardReceiver {
    /// `control` must be the sole dedicated control-reader lease. Local consent
    /// is supplied to each [`Self::receive`] transaction, never retained here.
    ///
    /// # Errors
    ///
    /// Rejects zero sequence numbers.
    pub fn new(control: DedicatedClipboardControl, next_control_sequence: u64) -> Result<Self> {
        ensure!(
            next_control_sequence > 0,
            "clipboard control sequence must be non-zero"
        );
        Ok(Self {
            control,
            next_control_sequence,
            incoming: ControlSequencer::default(),
            last_payload_sequence: None,
            applied: HashSet::new(),
        })
    }

    /// Receives exactly one offer/accept/payload/completion lifecycle.
    ///
    /// `install` must not return [`ClipboardInstalled`] until the platform
    /// adapter confirms it owns the local clipboard. The callback is never
    /// invoked for invalid, replayed, cancelled, or echo-suppressed bytes.
    /// Because `install` is synchronous, the Tokio deadline bounds only the
    /// network/control phases; callers must bound native work themselves. It
    /// must not block a Tokio worker. Daemon integration should dispatch it to
    /// a bounded blocking worker while retaining the original deadline.
    ///
    /// # Errors
    ///
    /// Fails closed for a non-mTLS/closed connection, malformed or reordered
    /// control, a foreign connection binding, a duplicate delivery, or a QUIC
    /// transport error. A valid payload hash/size mismatch is instead reported
    /// to the sender as an exact Failed completion.
    #[allow(clippy::too_many_lines)] // All completion paths intentionally retain exact identity at this boundary.
    pub async fn receive<F>(
        &mut self,
        consent: ClipboardConsent,
        accepted_mime: &str,
        deadline: Instant,
        install: F,
    ) -> Result<ClipboardReceiveReceipt>
    where
        F: FnOnce(VerifiedClipboardTransfer<'_>) -> Result<ClipboardInstalled>,
    {
        let connection = self.control.connection().clone();
        ensure!(
            deadline > Instant::now() && deadline <= Instant::now() + MAX_CLIPBOARD_TRANSACTION,
            "clipboard transaction deadline is invalid"
        );
        let mut guard = TransactionGuard::new(connection.clone());
        let result = timeout_at(
            deadline,
            self.receive_inner(&connection, consent, accepted_mime, install),
        )
        .await
        .context("clipboard transaction timed out")?;
        if result.is_ok() {
            guard.disarm();
        } else {
            self.control.retire(b"clipboard transaction failed");
        }
        result
    }

    #[allow(clippy::too_many_lines)] // Terminal paths must retain the same verified transfer identity.
    async fn receive_inner<F>(
        &mut self,
        connection: &Connection,
        consent: ClipboardConsent,
        accepted_mime: &str,
        install: F,
    ) -> Result<ClipboardReceiveReceipt>
    where
        F: FnOnce(VerifiedClipboardTransfer<'_>) -> Result<ClipboardInstalled>,
    {
        ensure!(
            !accepted_mime.is_empty(),
            "accepted clipboard MIME type is empty"
        );
        let binding = connection_binding(connection)?;
        let DomainControl::ClipboardTransferOffer(offer) = self.receive_domain(connection).await?
        else {
            bail!("expected clipboard transfer offer");
        };
        let key = DeliveryKey::from_offer(&offer);
        ensure!(
            offer.connection_binding == binding,
            "clipboard offer is bound to a different QUIC connection"
        );
        if offer.consent_correlation != consent.correlation() || !consent.matches_incoming(&key) {
            return self
                .complete(
                    connection,
                    &key,
                    ClipboardCompletionStatus::Rejected,
                    Some("local consent does not match transfer"),
                )
                .await;
        }
        ensure!(
            self.last_payload_sequence
                .is_none_or(|previous| key.payload_sequence > previous),
            "replayed or reordered clipboard payload sequence"
        );
        self.last_payload_sequence = Some(key.payload_sequence);
        let Ok(flavor) = exact_flavor(&offer, accepted_mime) else {
            return self
                .complete(
                    connection,
                    &key,
                    ClipboardCompletionStatus::Rejected,
                    Some("requested clipboard MIME was not offered"),
                )
                .await;
        };
        let accepted = ClipboardAccept {
            offer_id: key.offer_id,
            generation: key.generation,
            offer_nonce: key.offer_nonce,
            mime_type: accepted_mime.to_owned(),
            payload_sequence: key.payload_sequence,
        };
        self.send_domain(
            connection,
            wire::control_envelope::Payload::ClipboardAccept(accepted.clone().into()),
        )
        .await?;
        let DomainControl::ClipboardPayload(payload) = self.receive_domain(connection).await?
        else {
            bail!("expected clipboard payload");
        };
        if !key.matches_payload(&payload)
            || payload.mime_type != accepted_mime
            || payload.data.len() > MAX_CLIPBOARD_BYTES
            || usize::try_from(flavor.size_bytes).ok() != Some(payload.data.len())
            || sha256(&payload.data) != flavor.sha256
        {
            return self
                .complete(
                    connection,
                    &key,
                    ClipboardCompletionStatus::Failed,
                    Some("clipboard payload did not match accepted offer"),
                )
                .await;
        }
        let fingerprint = ClipboardFingerprint {
            mime_type: payload.mime_type.clone(),
            sha256: flavor.sha256,
        };
        if self.applied.contains(&fingerprint) {
            return self
                .complete(
                    connection,
                    &key,
                    ClipboardCompletionStatus::Cancelled,
                    Some("clipboard echo suppressed"),
                )
                .await;
        }
        if self.applied.len() == MAX_ECHO_FINGERPRINTS {
            return self
                .complete(
                    connection,
                    &key,
                    ClipboardCompletionStatus::Failed,
                    Some("clipboard echo ledger exhausted"),
                )
                .await;
        }
        if install(VerifiedClipboardTransfer {
            transfer: &offer,
            accepted: &accepted,
            payload: &payload,
        })
        .is_err()
        {
            return self
                .complete(
                    connection,
                    &key,
                    ClipboardCompletionStatus::Failed,
                    Some("native clipboard installation failed"),
                )
                .await;
        }
        self.applied.insert(fingerprint);
        self.complete(connection, &key, ClipboardCompletionStatus::Completed, None)
            .await
    }

    async fn complete(
        &mut self,
        connection: &Connection,
        key: &DeliveryKey,
        status: ClipboardCompletionStatus,
        error_message: Option<&str>,
    ) -> Result<ClipboardReceiveReceipt> {
        self.send_domain(
            connection,
            wire::control_envelope::Payload::ClipboardComplete(
                ClipboardComplete {
                    offer_id: key.offer_id,
                    generation: key.generation,
                    offer_nonce: key.offer_nonce,
                    payload_sequence: key.payload_sequence,
                    status,
                    error_message: error_message.map(str::to_owned),
                }
                .into(),
            ),
        )
        .await?;
        Ok(ClipboardReceiveReceipt {
            offer_id: key.offer_id,
            generation: key.generation,
            offer_nonce: key.offer_nonce,
            payload_sequence: key.payload_sequence,
            status,
        })
    }

    async fn send_domain(
        &mut self,
        connection: &Connection,
        payload: wire::control_envelope::Payload,
    ) -> Result<()> {
        let sequence = self.next_control_sequence;
        self.next_control_sequence = self
            .next_control_sequence
            .checked_add(1)
            .context("clipboard control sequence exhausted")?;
        send_control(connection, &envelope(sequence, payload))
            .await
            .context("send clipboard control")
    }

    async fn receive_domain(&mut self, connection: &Connection) -> Result<DomainControl> {
        let envelope = receive_control_sequenced(connection, &mut self.incoming)
            .await
            .context("receive ordered clipboard control")?;
        DomainControl::try_from(envelope)
            .map_err(|error| anyhow::anyhow!("decode clipboard control: {error:?}"))
    }
}

fn exact_flavor<'a>(
    offer: &'a ClipboardTransferOffer,
    mime_type: &str,
) -> Result<&'a ClipboardTransferFlavor> {
    offer
        .flavors
        .iter()
        .find(|flavor| flavor.name == mime_type)
        .context("clipboard MIME is not in the advertised transfer offer")
}

fn connection_binding(connection: &Connection) -> Result<[u8; 32]> {
    ensure!(
        connection.peer_identity().is_some() && connection.close_reason().is_none(),
        "clipboard transfer requires a live authenticated QUIC peer"
    );
    let mut binding = [0; 32];
    connection
        .export_keying_material(&mut binding, TLS_EXPORTER_LABEL, b"")
        .map_err(|_| anyhow::anyhow!("clipboard TLS binding unavailable"))?;
    Ok(binding)
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn envelope(sequence: u64, payload: wire::control_envelope::Payload) -> wire::ControlEnvelope {
    wire::ControlEnvelope {
        protocol_major: u32::from(PROTOCOL_VERSION.major),
        protocol_minor: u32::from(PROTOCOL_VERSION.minor),
        sequence,
        payload: Some(payload),
    }
}
