//! A bounded, consent-gated adapter for the Wayland `wl-clipboard` tools.
//!
//! The adapter deliberately has no background watcher. A caller must request a
//! snapshot after it has obtained local consent, and must pass a payload only
//! after the Viewflow transfer state machine has accepted it. This keeps a
//! clipboard monitor from silently reading arbitrary local clipboard contents.
//! `wl-paste`/`wl-copy` are real Wayland clipboard clients; the tests replace
//! the command runner and do not claim OS clipboard delivery.

use std::{
    collections::{HashSet, VecDeque},
    ffi::OsString,
    io::{Read, Write},
    path::PathBuf,
    process::{Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

use sha2::{Digest, Sha256};
use viewflow_protocol::{
    ClipboardAccept, ClipboardFlavor, ClipboardOffer, ClipboardPayload as WireClipboardPayload,
    ClipboardTransferFlavor, ClipboardTransferOffer, DeviceId, Id128,
};

const MAX_TYPE_LIST_BYTES: usize = 64 * 1024;
const DEFAULT_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const WORKER_REAP_TIMEOUT: Duration = Duration::from_millis(100);
const CHILD_POLL_INTERVAL: Duration = Duration::from_millis(10);
const MAX_APPLIED_RECEIPTS: usize = 4_096;
const MAX_PENDING_LOCAL_ECHOES: usize = 64;
const LOCAL_ECHO_WINDOW: Duration = Duration::from_secs(5);
const MAX_RELIABLE_PAYLOAD_BYTES: usize = 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClipboardConsent {
    /// The local user has expressly enabled this clipboard route for this
    /// operation. Consent is intentionally per call, not a sticky global bit.
    Granted,
    NotGranted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardPayload {
    pub mime_type: String,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NativeClipboardSnapshot {
    pub payloads: Vec<ClipboardPayload>,
}

impl NativeClipboardSnapshot {
    /// Converts a locally read snapshot into the legacy discovery-only offer.
    /// A live clipboard transfer must instead use [`Self::into_transfer_offer`].
    #[must_use]
    pub fn into_offer(self, id: Id128, owner: DeviceId, generation: u64) -> ClipboardOffer {
        self.offer(id, owner, generation)
    }

    /// Builds the discovery portion of an offer without changing the payload
    /// bytes retained by this native snapshot.
    #[must_use]
    pub fn offer(&self, id: Id128, owner: DeviceId, generation: u64) -> ClipboardOffer {
        ClipboardOffer {
            id,
            owner,
            generation,
            flavors: self
                .payloads
                .iter()
                .map(|payload| ClipboardFlavor {
                    name: payload.mime_type.clone(),
                    size_bytes: payload.bytes.len() as u64,
                })
                .collect(),
        }
    }

    /// Builds the digest-bound transfer offer required before payload bytes are
    /// sent. Local consent is still required by [`WlClipboardAdapter`] before
    /// this snapshot may be created or any remote payload may be installed.
    #[must_use]
    #[allow(clippy::too_many_arguments)]
    pub fn into_transfer_offer(
        self,
        id: Id128,
        owner: DeviceId,
        generation: u64,
        offer_nonce: [u8; 16],
        consent_correlation: [u8; 16],
        connection_binding: [u8; 32],
        payload_sequence: u64,
    ) -> ClipboardTransferOffer {
        ClipboardTransferOffer {
            offer: self.offer(id, owner, generation),
            flavors: self
                .payloads
                .iter()
                .map(|payload| ClipboardTransferFlavor {
                    name: payload.mime_type.clone(),
                    size_bytes: payload.bytes.len() as u64,
                    sha256: sha256(&payload.bytes),
                })
                .collect(),
            offer_nonce,
            consent_correlation,
            connection_binding,
            payload_sequence,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ClipboardPolicy {
    pub max_item_bytes: usize,
    pub max_total_bytes: usize,
}

impl Default for ClipboardPolicy {
    fn default() -> Self {
        Self {
            // Clipboard payloads travel over the authenticated control stream
            // until a dedicated bounded blob stream exists.
            max_item_bytes: MAX_RELIABLE_PAYLOAD_BYTES,
            max_total_bytes: 4 * MAX_RELIABLE_PAYLOAD_BYTES,
        }
    }
}

impl ClipboardPolicy {
    fn validate(&self, payload: &ClipboardPayload) -> Result<(), ClipboardError> {
        if self.max_item_bytes == 0 || self.max_total_bytes < self.max_item_bytes {
            return Err(ClipboardError::InvalidPolicy);
        }
        if !supported_mime_type(&payload.mime_type) {
            return Err(ClipboardError::UnsupportedMimeType);
        }
        if payload.bytes.len() > self.max_item_bytes
            || payload.bytes.len() > MAX_RELIABLE_PAYLOAD_BYTES
        {
            return Err(ClipboardError::ItemTooLarge);
        }
        Ok(())
    }
}

/// Opaque identity supplied by the future reliable clipboard-payload route.
/// The triple is replay-fenced before the adapter writes the OS clipboard.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct RemoteClipboardReceipt {
    pub offer_id: Id128,
    pub generation: u64,
    pub offer_nonce: [u8; 16],
    pub payload_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ClipboardObservation {
    /// The first echo of an exact payload Viewflow just installed. It must not
    /// become a new outbound offer.
    SuppressedLocalEcho(RemoteClipboardReceipt),
    /// A snapshot which is eligible to become an outbound offer after the
    /// caller has obtained consent for that capture operation.
    Forward(NativeClipboardSnapshot),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ClipboardError {
    ConsentRequired,
    InvalidPolicy,
    UnsupportedMimeType,
    ItemTooLarge,
    TotalTooLarge,
    NoSupportedTypes,
    InvalidTypeList,
    CommandFailed,
    CommandIo,
    CommandTimedOut,
    ReplayedRemotePayload,
    ReplayFenceExhausted,
    InvalidRemoteReceipt,
    InvalidTransferBinding,
    PayloadDigestMismatch,
    FlavorNotAdvertised,
    PayloadSizeMismatch,
}

/// Small command boundary so tests can exercise the real command contract
/// without reading or overwriting the user's clipboard.
#[allow(clippy::missing_errors_doc)]
pub trait ClipboardCommandRunner {
    fn capture(
        &mut self,
        program: &std::path::Path,
        args: &[OsString],
        maximum_bytes: usize,
    ) -> Result<Vec<u8>, ClipboardError>;

    fn write(
        &mut self,
        program: &std::path::Path,
        args: &[OsString],
        bytes: &[u8],
    ) -> Result<(), ClipboardError>;
}

pub struct SystemClipboardCommandRunner {
    command_timeout: Duration,
}

impl Default for SystemClipboardCommandRunner {
    fn default() -> Self {
        Self::with_timeout(DEFAULT_COMMAND_TIMEOUT)
    }
}

impl SystemClipboardCommandRunner {
    /// Overrides the default five-second command budget. Primarily useful for
    /// deployment probes and owned-subprocess tests; a zero timeout fails
    /// immediately rather than allowing an unbounded child lifetime.
    #[must_use]
    pub fn with_timeout(command_timeout: Duration) -> Self {
        Self { command_timeout }
    }
}

impl ClipboardCommandRunner for SystemClipboardCommandRunner {
    fn capture(
        &mut self,
        program: &std::path::Path,
        args: &[OsString],
        maximum_bytes: usize,
    ) -> Result<Vec<u8>, ClipboardError> {
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| ClipboardError::CommandIo)?;
        let stdout = child.stdout.take().ok_or(ClipboardError::CommandIo)?;
        let (reader_sender, reader_receiver) = mpsc::sync_channel(1);
        thread::spawn(move || {
            let mut output = Vec::with_capacity(maximum_bytes.min(64 * 1024));
            let result = stdout
                .take((maximum_bytes as u64).saturating_add(1))
                .read_to_end(&mut output)
                .map(|_| output)
                .map_err(|_| ClipboardError::CommandIo);
            let _ = reader_sender.send(result);
        });

        let deadline = Instant::now() + self.command_timeout;
        let mut output = None;
        loop {
            if output.is_none() {
                match reader_receiver.try_recv() {
                    Ok(Ok(bytes)) if bytes.len() > maximum_bytes => {
                        terminate_child(&mut child);
                        return Err(ClipboardError::ItemTooLarge);
                    }
                    Ok(Ok(bytes)) => output = Some(bytes),
                    Ok(Err(error)) => {
                        terminate_child(&mut child);
                        return Err(error);
                    }
                    Err(mpsc::TryRecvError::Disconnected) => {
                        terminate_child(&mut child);
                        return Err(ClipboardError::CommandIo);
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                }
            }
            let Ok(status) = child.try_wait() else {
                terminate_child(&mut child);
                return Err(ClipboardError::CommandIo);
            };
            if let Some(status) = status {
                let output = match output {
                    Some(output) => output,
                    None => reader_receiver
                        .recv_timeout(WORKER_REAP_TIMEOUT)
                        .map_err(|_| ClipboardError::CommandIo)??,
                };
                if output.len() > maximum_bytes {
                    return Err(ClipboardError::ItemTooLarge);
                }
                if !status.success() {
                    return Err(ClipboardError::CommandFailed);
                }
                return Ok(output);
            }
            if Instant::now() >= deadline {
                terminate_child(&mut child);
                let _ = reader_receiver.recv_timeout(WORKER_REAP_TIMEOUT);
                return Err(ClipboardError::CommandTimedOut);
            }
            thread::sleep(CHILD_POLL_INTERVAL);
        }
    }

    fn write(
        &mut self,
        program: &std::path::Path,
        args: &[OsString],
        bytes: &[u8],
    ) -> Result<(), ClipboardError> {
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| ClipboardError::CommandIo)?;
        let mut stdin = child.stdin.take().ok_or(ClipboardError::CommandIo)?;
        let bytes = bytes.to_vec();
        let (writer_sender, writer_receiver) = mpsc::sync_channel(1);
        thread::spawn(move || {
            let result = stdin
                .write_all(&bytes)
                .map_err(|_| ClipboardError::CommandIo);
            let _ = writer_sender.send(result);
        });

        let deadline = Instant::now() + self.command_timeout;
        let mut writer_finished = false;
        loop {
            if !writer_finished {
                match writer_receiver.try_recv() {
                    Ok(Ok(())) => writer_finished = true,
                    Ok(Err(error)) => {
                        terminate_child(&mut child);
                        return Err(error);
                    }
                    Err(mpsc::TryRecvError::Disconnected) => {
                        terminate_child(&mut child);
                        return Err(ClipboardError::CommandIo);
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                }
            }
            let Ok(status) = child.try_wait() else {
                terminate_child(&mut child);
                return Err(ClipboardError::CommandIo);
            };
            if let Some(status) = status {
                if !writer_finished {
                    writer_receiver
                        .recv_timeout(WORKER_REAP_TIMEOUT)
                        .map_err(|_| ClipboardError::CommandIo)??;
                }
                if !status.success() {
                    return Err(ClipboardError::CommandFailed);
                }
                return Ok(());
            }
            if Instant::now() >= deadline {
                terminate_child(&mut child);
                let _ = writer_receiver.recv_timeout(WORKER_REAP_TIMEOUT);
                return Err(ClipboardError::CommandTimedOut);
            }
            thread::sleep(CHILD_POLL_INTERVAL);
        }
    }
}

fn terminate_child(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/*
 * `wl-copy` may daemonize after it has taken ownership of the Wayland
 * selection. A successful launcher exit is the narrow completion boundary:
 * it does not claim that another application has pasted the content.
 */

#[derive(Clone, Debug, Eq, PartialEq)]
struct RecentWrite {
    receipt: RemoteClipboardReceipt,
    payload: ClipboardPayload,
    installed_at: Instant,
}

/// Native Wayland clipboard boundary. `wl_paste` and `wl_copy` default to the
/// standard `wl-paste` and `wl-copy` paths, but are injectable for isolated
/// deployment smoke tests.
pub struct WlClipboardAdapter<R = SystemClipboardCommandRunner> {
    runner: R,
    wl_paste: PathBuf,
    wl_copy: PathBuf,
    policy: ClipboardPolicy,
    applied_receipts: HashSet<RemoteClipboardReceipt>,
    recent_writes: VecDeque<RecentWrite>,
}

impl WlClipboardAdapter<SystemClipboardCommandRunner> {
    #[must_use]
    pub fn new(policy: ClipboardPolicy) -> Self {
        Self::with_runner(
            SystemClipboardCommandRunner::default(),
            PathBuf::from("wl-paste"),
            PathBuf::from("wl-copy"),
            policy,
        )
    }
}

impl<R: ClipboardCommandRunner> WlClipboardAdapter<R> {
    #[must_use]
    pub fn with_runner(
        runner: R,
        wl_paste: PathBuf,
        wl_copy: PathBuf,
        policy: ClipboardPolicy,
    ) -> Self {
        Self {
            runner,
            wl_paste,
            wl_copy,
            policy,
            applied_receipts: HashSet::new(),
            recent_writes: VecDeque::new(),
        }
    }

    /// Reads a bounded snapshot from the current regular Wayland selection.
    /// The call is rejected before invoking `wl-paste` unless consent is
    /// supplied by the caller for this exact capture.
    #[allow(clippy::missing_errors_doc)]
    pub fn capture_local(
        &mut self,
        consent: ClipboardConsent,
    ) -> Result<NativeClipboardSnapshot, ClipboardError> {
        if consent != ClipboardConsent::Granted {
            return Err(ClipboardError::ConsentRequired);
        }
        self.read_snapshot()
    }

    /// Applies a digest-verified payload only after the caller accepted the
    /// exact transfer offer. The receipt is consumed before calling `wl-copy`,
    /// so a retry cannot install the same remote payload twice. A failed write
    /// stays fenced because it may have taken Wayland ownership before
    /// reporting its error; callers must create a new delivery receipt.
    #[allow(clippy::missing_errors_doc)]
    pub fn apply_verified_remote(
        &mut self,
        consent: ClipboardConsent,
        transfer: &ClipboardTransferOffer,
        accepted: &ClipboardAccept,
        payload: &WireClipboardPayload,
    ) -> Result<(), ClipboardError> {
        transfer
            .validate()
            .map_err(|_| ClipboardError::InvalidTransferBinding)?;
        if consent != ClipboardConsent::Granted {
            return Err(ClipboardError::ConsentRequired);
        }
        if accepted.offer_id != transfer.offer.id
            || accepted.generation != transfer.offer.generation
            || accepted.offer_nonce != transfer.offer_nonce
            || accepted.payload_sequence != transfer.payload_sequence
            || accepted.mime_type != payload.mime_type
            || payload.offer_id != transfer.offer.id
            || payload.generation != transfer.offer.generation
            || payload.offer_nonce != transfer.offer_nonce
            || payload.payload_sequence != transfer.payload_sequence
        {
            return Err(ClipboardError::InvalidRemoteReceipt);
        }
        let receipt = RemoteClipboardReceipt {
            offer_id: payload.offer_id,
            generation: payload.generation,
            offer_nonce: payload.offer_nonce,
            payload_sequence: payload.payload_sequence,
        };
        let native_payload = ClipboardPayload {
            mime_type: payload.mime_type.clone(),
            bytes: payload.data.clone(),
        };
        let Some(flavor) = transfer
            .flavors
            .iter()
            .find(|flavor| flavor.name == native_payload.mime_type)
        else {
            return Err(ClipboardError::FlavorNotAdvertised);
        };
        if flavor.size_bytes != native_payload.bytes.len() as u64 {
            return Err(ClipboardError::PayloadSizeMismatch);
        }
        if flavor.sha256 != sha256(&native_payload.bytes) {
            return Err(ClipboardError::PayloadDigestMismatch);
        }
        self.apply_checked_remote(consent, receipt, native_payload)
    }

    fn apply_checked_remote(
        &mut self,
        consent: ClipboardConsent,
        receipt: RemoteClipboardReceipt,
        payload: ClipboardPayload,
    ) -> Result<(), ClipboardError> {
        if consent != ClipboardConsent::Granted || receipt.payload_sequence == 0 {
            return Err(ClipboardError::InvalidRemoteReceipt);
        }
        if self.applied_receipts.contains(&receipt) {
            return Err(ClipboardError::ReplayedRemotePayload);
        }
        if self.applied_receipts.len() == MAX_APPLIED_RECEIPTS {
            return Err(ClipboardError::ReplayFenceExhausted);
        }
        self.policy.validate(&payload)?;
        self.applied_receipts.insert(receipt);
        self.runner.write(
            &self.wl_copy,
            &[OsString::from("--type"), OsString::from(&payload.mime_type)],
            &payload.bytes,
        )?;
        if self.recent_writes.len() == MAX_PENDING_LOCAL_ECHOES {
            self.recent_writes.pop_front();
        }
        self.recent_writes.push_back(RecentWrite {
            receipt,
            payload,
            installed_at: Instant::now(),
        });
        Ok(())
    }

    /// Suppresses an exact, recent echo of any remote payload just written
    /// through this adapter. Unrelated snapshots retain pending echoes; an echo
    /// is consumed only when it matches, and expired echoes cannot hide a later
    /// user copy of identical bytes.
    #[must_use]
    pub fn classify_observation(
        &mut self,
        snapshot: NativeClipboardSnapshot,
    ) -> ClipboardObservation {
        self.recent_writes
            .retain(|recent| recent.installed_at.elapsed() < LOCAL_ECHO_WINDOW);
        if snapshot.payloads.len() == 1
            && let Some(index) = self
                .recent_writes
                .iter()
                .position(|recent| snapshot.payloads[0] == recent.payload)
        {
            if let Some(recent) = self.recent_writes.remove(index) {
                return ClipboardObservation::SuppressedLocalEcho(recent.receipt);
            }
        }
        ClipboardObservation::Forward(snapshot)
    }

    fn read_snapshot(&mut self) -> Result<NativeClipboardSnapshot, ClipboardError> {
        if self.policy.max_item_bytes == 0
            || self.policy.max_total_bytes < self.policy.max_item_bytes
        {
            return Err(ClipboardError::InvalidPolicy);
        }
        let types = self.runner.capture(
            &self.wl_paste,
            &[OsString::from("--list-types")],
            MAX_TYPE_LIST_BYTES,
        )?;
        let types = std::str::from_utf8(&types).map_err(|_| ClipboardError::InvalidTypeList)?;
        let mut payloads = Vec::new();
        let mut seen = HashSet::new();
        let mut total = 0_usize;
        for mime_type in types.lines().map(str::trim).filter(|mime| !mime.is_empty()) {
            if !supported_mime_type(mime_type) || !seen.insert(mime_type.to_ascii_lowercase()) {
                continue;
            }
            let bytes = self.runner.capture(
                &self.wl_paste,
                &[OsString::from("--type"), OsString::from(mime_type)],
                self.policy.max_item_bytes.min(MAX_RELIABLE_PAYLOAD_BYTES),
            )?;
            let payload = ClipboardPayload {
                mime_type: mime_type.to_owned(),
                bytes,
            };
            self.policy.validate(&payload)?;
            total = total
                .checked_add(payload.bytes.len())
                .ok_or(ClipboardError::TotalTooLarge)?;
            if total > self.policy.max_total_bytes {
                return Err(ClipboardError::TotalTooLarge);
            }
            payloads.push(payload);
        }
        if payloads.is_empty() {
            return Err(ClipboardError::NoSupportedTypes);
        }
        Ok(NativeClipboardSnapshot { payloads })
    }
}

fn supported_mime_type(mime_type: &str) -> bool {
    let mut parts = mime_type.split(';');
    let base = parts.next().unwrap_or_default().trim();
    if base.eq_ignore_ascii_case("text/plain") {
        return parts.all(|parameter| parameter.trim().eq_ignore_ascii_case("charset=utf-8"));
    }
    parts.next().is_none()
        && (base.eq_ignore_ascii_case("text/html") || base.eq_ignore_ascii_case("image/png"))
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

#[cfg(test)]
mod tests {
    use std::{collections::VecDeque, path::Path};

    use super::*;

    #[derive(Default)]
    struct FakeRunner {
        captures: VecDeque<Result<Vec<u8>, ClipboardError>>,
        capture_calls: Vec<(PathBuf, Vec<OsString>, usize)>,
        writes: Vec<(PathBuf, Vec<OsString>, Vec<u8>)>,
    }

    impl ClipboardCommandRunner for FakeRunner {
        fn capture(
            &mut self,
            program: &Path,
            args: &[OsString],
            maximum_bytes: usize,
        ) -> Result<Vec<u8>, ClipboardError> {
            self.capture_calls
                .push((program.to_owned(), args.to_vec(), maximum_bytes));
            self.captures.pop_front().expect("configured capture")
        }

        fn write(
            &mut self,
            program: &Path,
            args: &[OsString],
            bytes: &[u8],
        ) -> Result<(), ClipboardError> {
            self.writes
                .push((program.to_owned(), args.to_vec(), bytes.to_vec()));
            Ok(())
        }
    }

    fn adapter(runner: FakeRunner) -> WlClipboardAdapter<FakeRunner> {
        WlClipboardAdapter::with_runner(
            runner,
            PathBuf::from("test-wl-paste"),
            PathBuf::from("test-wl-copy"),
            ClipboardPolicy {
                max_item_bytes: 10,
                max_total_bytes: 15,
            },
        )
    }

    fn transfer_offer(
        mime_type: &str,
        bytes: &[u8],
        payload_sequence: u64,
    ) -> ClipboardTransferOffer {
        let offer = ClipboardOffer {
            id: Id128(10),
            owner: Id128(20),
            generation: 30,
            flavors: vec![ClipboardFlavor {
                name: mime_type.to_owned(),
                size_bytes: bytes.len() as u64,
            }],
        };
        ClipboardTransferOffer {
            flavors: vec![ClipboardTransferFlavor {
                name: mime_type.to_owned(),
                size_bytes: bytes.len() as u64,
                sha256: sha256(bytes),
            }],
            offer,
            offer_nonce: [3; 16],
            consent_correlation: [4; 16],
            connection_binding: [5; 32],
            payload_sequence,
        }
    }

    fn accept(mime_type: &str, payload_sequence: u64) -> ClipboardAccept {
        ClipboardAccept {
            offer_id: Id128(10),
            generation: 30,
            offer_nonce: [3; 16],
            mime_type: mime_type.to_owned(),
            payload_sequence,
        }
    }

    fn wire_payload(mime_type: &str, bytes: &[u8], payload_sequence: u64) -> WireClipboardPayload {
        WireClipboardPayload {
            offer_id: Id128(10),
            generation: 30,
            offer_nonce: [3; 16],
            payload_sequence,
            mime_type: mime_type.to_owned(),
            data: bytes.to_vec(),
        }
    }

    fn receipt(payload_sequence: u64) -> RemoteClipboardReceipt {
        RemoteClipboardReceipt {
            offer_id: Id128(10),
            generation: 30,
            offer_nonce: [3; 16],
            payload_sequence,
        }
    }

    #[test]
    fn capture_requires_per_operation_consent_before_reading_clipboard() {
        let mut adapter = adapter(FakeRunner::default());
        assert_eq!(
            adapter.capture_local(ClipboardConsent::NotGranted),
            Err(ClipboardError::ConsentRequired)
        );
        assert!(adapter.runner.capture_calls.is_empty());
    }

    #[test]
    fn capture_reads_only_supported_types_with_individual_and_total_bounds() {
        let runner = FakeRunner {
            captures: VecDeque::from([
                Ok(b"text/plain;charset=utf-8\nimage/jpeg\ntext/html\n".to_vec()),
                Ok(b"hello".to_vec()),
                Ok(b"<b>x</b>".to_vec()),
            ]),
            ..FakeRunner::default()
        };
        let mut adapter = adapter(runner);
        let snapshot = adapter.capture_local(ClipboardConsent::Granted).unwrap();
        assert_eq!(
            snapshot.payloads,
            vec![
                ClipboardPayload {
                    mime_type: "text/plain;charset=utf-8".to_owned(),
                    bytes: b"hello".to_vec(),
                },
                ClipboardPayload {
                    mime_type: "text/html".to_owned(),
                    bytes: b"<b>x</b>".to_vec(),
                },
            ]
        );
        assert_eq!(adapter.runner.capture_calls.len(), 3);
        let wire_offer = snapshot.into_offer(Id128(1), Id128(2), 3);
        assert_eq!(wire_offer.flavors[1].size_bytes, 8);
    }

    #[test]
    fn remote_payload_is_digest_bound_written_once_and_recent_echoes_are_suppressed() {
        let mut adapter = adapter(FakeRunner::default());
        let payload = ClipboardPayload {
            mime_type: "text/plain;charset=utf-8".to_owned(),
            bytes: b"hello".to_vec(),
        };
        let transfer = transfer_offer(&payload.mime_type, &payload.bytes, 40);
        let wire_payload = wire_payload(&payload.mime_type, &payload.bytes, 40);
        adapter
            .apply_verified_remote(
                ClipboardConsent::Granted,
                &transfer,
                &accept(&payload.mime_type, 40),
                &wire_payload,
            )
            .unwrap();
        assert_eq!(adapter.runner.writes.len(), 1);
        assert_eq!(
            adapter.runner.writes[0].1,
            vec![
                OsString::from("--type"),
                OsString::from("text/plain;charset=utf-8")
            ]
        );
        assert_eq!(adapter.runner.writes[0].2, b"hello");
        assert_eq!(
            adapter.classify_observation(NativeClipboardSnapshot {
                payloads: vec![payload.clone()],
            }),
            ClipboardObservation::SuppressedLocalEcho(receipt(40))
        );
        assert_eq!(
            adapter.classify_observation(NativeClipboardSnapshot {
                payloads: vec![payload.clone()],
            }),
            ClipboardObservation::Forward(NativeClipboardSnapshot {
                payloads: vec![ClipboardPayload {
                    mime_type: "text/plain;charset=utf-8".to_owned(),
                    bytes: b"hello".to_vec(),
                }],
            })
        );
        assert_eq!(
            adapter.apply_verified_remote(
                ClipboardConsent::Granted,
                &transfer,
                &accept(&payload.mime_type, 40),
                &wire_payload,
            ),
            Err(ClipboardError::ReplayedRemotePayload)
        );
        assert_eq!(adapter.runner.writes.len(), 1);
    }

    #[test]
    fn remote_write_rejects_unadvertised_or_wrong_sized_data_before_wl_copy() {
        let mut adapter = adapter(FakeRunner::default());
        let transfer = transfer_offer("text/plain;charset=utf-8", b"hello", 40);
        assert_eq!(
            adapter.apply_verified_remote(
                ClipboardConsent::Granted,
                &transfer,
                &accept("text/plain;charset=utf-8", 40),
                &wire_payload("text/plain;charset=utf-8", b"four", 40),
            ),
            Err(ClipboardError::PayloadSizeMismatch)
        );
        assert!(adapter.runner.writes.is_empty());
    }

    #[test]
    fn remote_write_rejects_digest_or_receipt_mismatch_before_wl_copy() {
        let mut adapter = adapter(FakeRunner::default());
        let transfer = transfer_offer("text/plain;charset=utf-8", b"hello", 40);
        assert_eq!(
            adapter.apply_verified_remote(
                ClipboardConsent::Granted,
                &transfer,
                &accept("text/plain;charset=utf-8", 40),
                &wire_payload("text/plain;charset=utf-8", b"world", 40),
            ),
            Err(ClipboardError::PayloadDigestMismatch)
        );
        assert_eq!(
            adapter.apply_verified_remote(
                ClipboardConsent::Granted,
                &transfer,
                &accept("text/plain;charset=utf-8", 40),
                &wire_payload("text/plain;charset=utf-8", b"hello", 41),
            ),
            Err(ClipboardError::InvalidRemoteReceipt)
        );
        assert!(adapter.runner.writes.is_empty());
    }

    #[test]
    fn unsupported_types_cannot_be_written() {
        let mut adapter = adapter(FakeRunner::default());
        let transfer = transfer_offer("application/x-danger", b"payload", 40);
        assert_eq!(
            adapter.apply_verified_remote(
                ClipboardConsent::Granted,
                &transfer,
                &accept("application/x-danger", 40),
                &wire_payload("application/x-danger", b"payload", 40),
            ),
            Err(ClipboardError::UnsupportedMimeType)
        );
        assert!(adapter.runner.writes.is_empty());
    }

    #[test]
    fn unrelated_snapshot_does_not_lose_pending_echoes_from_two_remote_writes() {
        let mut adapter = adapter(FakeRunner::default());
        let first = ClipboardPayload {
            mime_type: "text/plain;charset=utf-8".to_owned(),
            bytes: b"first".to_vec(),
        };
        let second = ClipboardPayload {
            mime_type: "text/plain;charset=utf-8".to_owned(),
            bytes: b"second".to_vec(),
        };
        let first_offer = transfer_offer(&first.mime_type, &first.bytes, 1);
        let second_offer = transfer_offer(&second.mime_type, &second.bytes, 2);
        adapter
            .apply_verified_remote(
                ClipboardConsent::Granted,
                &first_offer,
                &accept(&first.mime_type, 1),
                &wire_payload(&first.mime_type, &first.bytes, 1),
            )
            .unwrap();
        adapter
            .apply_verified_remote(
                ClipboardConsent::Granted,
                &second_offer,
                &accept(&second.mime_type, 2),
                &wire_payload(&second.mime_type, &second.bytes, 2),
            )
            .unwrap();
        let unrelated = NativeClipboardSnapshot {
            payloads: vec![ClipboardPayload {
                mime_type: "text/plain;charset=utf-8".to_owned(),
                bytes: b"unrelated".to_vec(),
            }],
        };
        assert_eq!(
            adapter.classify_observation(unrelated.clone()),
            ClipboardObservation::Forward(unrelated)
        );
        assert_eq!(
            adapter.classify_observation(NativeClipboardSnapshot {
                payloads: vec![first],
            }),
            ClipboardObservation::SuppressedLocalEcho(receipt(1))
        );
        assert_eq!(
            adapter.classify_observation(NativeClipboardSnapshot {
                payloads: vec![second],
            }),
            ClipboardObservation::SuppressedLocalEcho(receipt(2))
        );
    }

    #[test]
    fn system_runner_bounds_owned_non_clipboard_subprocesses() {
        let mut runner = SystemClipboardCommandRunner::with_timeout(Duration::from_millis(20));
        assert_eq!(
            runner.capture(Path::new("/bin/sleep"), &[OsString::from("1")], 1,),
            Err(ClipboardError::CommandTimedOut)
        );

        let mut runner = SystemClipboardCommandRunner::default();
        assert_eq!(
            runner.capture(Path::new("/usr/bin/printf"), &[OsString::from("hello")], 5,),
            Ok(b"hello".to_vec())
        );
        assert_eq!(
            runner.write(Path::new("/usr/bin/cat"), &[], b"owned subprocess"),
            Ok(())
        );
    }
}
