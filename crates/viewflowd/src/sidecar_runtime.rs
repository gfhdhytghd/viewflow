use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    future::Future,
    io::Write,
    net::SocketAddr,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    os::unix::net::UnixStream,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use tokio::{
    runtime::Handle,
    sync::watch,
    task,
    time::{Instant, sleep_until, timeout, timeout_at},
};
use viewflow_platform::sidecar::{
    BoundPeerIdentity, CleanupComplete, CleanupMode, DurableQuarantineMarker, EdgeActivated,
    KeyboardHidInput, LocalSidecarListener, MessageDirection, PointerButtonInput,
    PointerWheelInput, QuarantineMarkerState, QuarantineRecoveryRequest, RejectCode,
    RelativePointerInput, ReleaseAllInput, ReturnToLocal, SequenceDisposition, SidecarEdge,
    SidecarInputLease, SidecarMessage, SidecarRequest, SidecarResponse, SidecarSession,
    read_request, read_response, write_request, write_response,
};
use viewflow_protocol::{
    Id128, InputEvent, InputEventKind, InputLease, InputLeaseRevoke, InputLeaseState,
    InputSwitchState, KeyboardHidUsage, PointerButton, PointerButtonEvent, PointerWheelEvent,
    RelativePointerMotion,
};

use crate::acceptance_runtime::{
    AcceptanceRecorder, CleanupAppliedEvidence, InputCoverageKind, RouteActivatedEvidence,
};
use crate::input_runtime::input_lease_payload;
use crate::{
    INPUT_APPLIED_TIMEOUT, OutboundSender, ProcessClock, send_control_confirmed,
    send_input_confirmed, send_input_confirmed_until, send_lease_revoke_confirmed_until,
};

// Deadlines are deliberately nested: activation plus rollback must finish
// inside Deskflow's 30 ms handshake, while a remote applied acknowledgement
// must finish inside the 28 ms input operation and Deskflow's 32 ms input call.
const PEER_ACTIVATION_TIMEOUT: Duration = Duration::from_millis(14);
const CAPTURE_TO_APPLY_TIMEOUT: Duration = Duration::from_millis(32);
const INPUT_CLEANUP_DEADLINE: Duration = Duration::from_millis(32);
const ROUTE_CLEANUP_TIMEOUT: Duration = Duration::from_millis(16);
const REVOKE_RESERVE: Duration = Duration::from_millis(4);
const CLEANUP_RECEIPT_LIFETIME: Duration = Duration::from_secs(5);

#[derive(Clone, Debug)]
pub(crate) struct SidecarProducerConfig {
    pub(crate) socket_path: PathBuf,
    pub(crate) local_device: Id128,
    pub(crate) target_device: Id128,
    pub(crate) clock: ProcessClock,
    pub(crate) quiesce_proof: Option<PathBuf>,
    pub(crate) quiesce_arm_file: Option<PathBuf>,
    pub(crate) artifact_hashes: BTreeMap<String, String>,
    pub(crate) acceptance: Option<AcceptanceRecorder>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ArmQuiesceConfig {
    pub arm_file: PathBuf,
    pub operation_id: String,
    pub daemon_pid: u32,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct QuiescenceArm {
    schema_version: u32,
    operation_id: String,
    daemon_pid: u32,
    daemon_start_ticks: u64,
    boot_id: String,
    daemon_sha256: String,
    armed_at_unix_ms: u128,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct AppliedAckIdentity {
    lease_generation: u64,
    target_device: String,
    event_sequence: u64,
    result: &'static str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum ReleaseAllStatus {
    NotRequiredNoActiveRoute,
    Applied,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct ReleaseAllEvidence {
    status: ReleaseAllStatus,
    ack: Option<AppliedAckIdentity>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum LeaseRevokeStatus {
    NotRequiredNoActiveRoute,
    Applied,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct LeaseRevokeAckIdentity {
    operation_id: String,
    lease_generation: u64,
    owner_device: String,
    target_device: String,
    state: &'static str,
    result: &'static str,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct LeaseRevokeEvidence {
    status: LeaseRevokeStatus,
    generation: Option<u64>,
    ack: Option<LeaseRevokeAckIdentity>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct RouteCleanupEvidence {
    route_ever_activated: bool,
    route_was_active: bool,
    source_display: Option<String>,
    route_generation: Option<u64>,
    active_lease_generation: Option<u64>,
    last_input_sequence: Option<u64>,
    release_all: ReleaseAllEvidence,
    lease_revoke: LeaseRevokeEvidence,
    bound_peer_epoch: Option<u64>,
    bound_peer_socket: Option<String>,
}

#[derive(Debug, Serialize)]
struct QuiescenceReceipt {
    schema_version: u32,
    state: &'static str,
    daemon_instance_id: String,
    operation_id: String,
    daemon_pid: u32,
    daemon_start_ticks: u64,
    boot_id: String,
    daemon_sha256: String,
    protocol_version: String,
    local_device: String,
    target_device: String,
    cleanup: RouteCleanupEvidence,
    route_status: &'static str,
    peer_disconnect_status: &'static str,
    daemon_exit_required: bool,
    sidecar_session_disconnected: bool,
    artifact_hashes: BTreeMap<String, String>,
    completed_at_unix_ms: u128,
}

#[derive(Clone)]
struct ProducerPeer {
    epoch: u64,
    address: SocketAddr,
    outbound: OutboundSender,
}

#[derive(Clone)]
pub(crate) struct ProducerPeerRegistry {
    changes: watch::Sender<Option<ProducerPeer>>,
    state: Arc<Mutex<ProducerPeerRegistryState>>,
}

struct ProducerPeerRegistryState {
    next_epoch: u64,
    current_epoch: Option<u64>,
    live_peers: BTreeMap<u64, ProducerPeer>,
    admission_closed: bool,
    acceptance: Option<AcceptanceRecorder>,
}

pub(crate) struct ProducerPeerRegistration {
    registry: ProducerPeerRegistry,
    epoch: Option<u64>,
}

impl ProducerPeerRegistry {
    #[cfg(test)]
    pub(crate) fn new() -> (Self, ProducerPeerReceiver) {
        Self::new_with_acceptance(None)
    }

    pub(crate) fn new_with_acceptance(
        acceptance: Option<AcceptanceRecorder>,
    ) -> (Self, ProducerPeerReceiver) {
        let (changes, receiver) = watch::channel(None);
        let registry = Self {
            changes,
            state: Arc::new(Mutex::new(ProducerPeerRegistryState {
                next_epoch: 1,
                current_epoch: None,
                live_peers: BTreeMap::new(),
                admission_closed: false,
                acceptance,
            })),
        };
        (
            registry.clone(),
            ProducerPeerReceiver {
                receiver,
                state: registry.state,
            },
        )
    }

    pub(crate) fn register(
        &self,
        address: SocketAddr,
        outbound: OutboundSender,
    ) -> ProducerPeerRegistration {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.admission_closed {
            drop(state);
            outbound.abort_peer("deployment quiesce has closed producer admission");
            return ProducerPeerRegistration {
                registry: self.clone(),
                epoch: None,
            };
        }
        let epoch = state.next_epoch;
        state.next_epoch = epoch.checked_add(1).expect("producer peer epoch exhausted");
        let peer = ProducerPeer {
            epoch,
            address,
            outbound,
        };
        state.live_peers.insert(epoch, peer.clone());
        state.current_epoch = Some(epoch);
        self.changes.send_replace(Some(peer));
        drop(state);
        ProducerPeerRegistration {
            registry: self.clone(),
            epoch: Some(epoch),
        }
    }
}

impl Drop for ProducerPeerRegistration {
    fn drop(&mut self) {
        let Some(epoch) = self.epoch else {
            return;
        };
        let mut state = self
            .registry
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let disconnected = state.live_peers.remove(&epoch);
        if state.current_epoch == Some(epoch) {
            let replacement = state
                .live_peers
                .last_key_value()
                .map(|(_, peer)| peer.clone());
            state.current_epoch = replacement.as_ref().map(|peer| peer.epoch);
            self.registry.changes.send_replace(replacement);
        }
        let acceptance = state.acceptance.clone();
        drop(state);
        if let (Some(acceptance), Some(peer)) = (acceptance, disconnected) {
            acceptance.peer_disconnected(
                peer.epoch,
                peer.address,
                peer.outbound.input_ack_metrics(),
            );
        }
    }
}

pub(crate) struct ProducerPeerReceiver {
    receiver: watch::Receiver<Option<ProducerPeer>>,
    state: Arc<Mutex<ProducerPeerRegistryState>>,
}

impl ProducerPeerReceiver {
    fn begin_quiescence(&self) -> (Option<ProducerPeer>, Vec<ProducerPeer>) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.admission_closed = true;
        let current = state
            .current_epoch
            .and_then(|epoch| state.live_peers.get(&epoch))
            .cloned();
        let live = state.live_peers.values().cloned().collect();
        (current, live)
    }

    async fn current(&mut self) -> Result<ProducerPeer> {
        loop {
            if let Some(peer) = self.receiver.borrow().clone() {
                return Ok(peer);
            }
            self.receiver
                .changed()
                .await
                .context("input producer peer registry stopped")?;
        }
    }

    async fn changed_after(&mut self, epoch: u64) -> Result<()> {
        loop {
            let changed = self
                .receiver
                .borrow()
                .as_ref()
                .is_none_or(|peer| peer.epoch != epoch);
            if changed {
                return Ok(());
            }
            self.receiver
                .changed()
                .await
                .context("input producer peer registry stopped")?;
        }
    }
}

#[derive(Clone)]
struct ActiveRoute {
    offered: InputLease,
    active: InputLease,
    source_display: Id128,
    route_generation: u64,
    last_event_sequence: u64,
    bound_peer: Option<ProducerPeer>,
}

struct ProducerState {
    config: SidecarProducerConfig,
    peers: ProducerPeerReceiver,
    route: Option<ActiveRoute>,
    next_offered_generation: u64,
    next_revoke_operation: u64,
    last_cleanup: Option<RouteCleanupEvidence>,
    last_cleanup_peer: Option<ProducerPeer>,
    last_runtime_marker: Option<DurableQuarantineMarker>,
    last_cleanup_complete: Option<CleanupComplete>,
    route_ever_activated: bool,
    quiescence_uncertainty: Option<&'static str>,
    #[cfg(test)]
    aborted_peer_epochs: Vec<u64>,
}

struct PreparedLocalReturn {
    cleanup_complete: CleanupComplete,
    return_to_local: ReturnToLocal,
    revoked: SidecarInputLease,
}

impl ProducerState {
    fn new(config: SidecarProducerConfig, peers: ProducerPeerReceiver) -> Self {
        Self {
            config,
            peers,
            route: None,
            next_offered_generation: 1,
            next_revoke_operation: 1,
            last_cleanup: None,
            last_cleanup_peer: None,
            last_runtime_marker: None,
            last_cleanup_complete: None,
            route_ever_activated: false,
            quiescence_uncertainty: None,
            #[cfg(test)]
            aborted_peer_epochs: Vec::new(),
        }
    }

    fn validate_edge(&self, edge: EdgeActivated) -> Result<(), RejectCode> {
        if edge.route_to == self.config.local_device {
            return self
                .route
                .is_some()
                .then_some(())
                .ok_or(RejectCode::LeaseNotActive);
        }
        if edge.route_to != self.config.target_device {
            return Err(RejectCode::WrongTarget);
        }
        if self.route.is_some() {
            return Err(RejectCode::InvalidLeaseTransition);
        }
        Ok(())
    }

    async fn activate(
        &mut self,
        edge: EdgeActivated,
    ) -> Result<(SidecarInputLease, SidecarInputLease)> {
        if self.route.is_some() {
            bail!("input route is already active");
        }
        if edge.route_to != self.config.target_device {
            bail!("edge target does not match configured input target");
        }
        self.route_ever_activated = true;
        self.last_cleanup = None;
        self.last_cleanup_peer = None;
        self.last_runtime_marker = None;
        self.last_cleanup_complete = None;
        let offered_generation = self.next_offered_generation;
        let active_generation = offered_generation
            .checked_add(1)
            .ok_or_else(|| anyhow!("input lease generation exhausted"))?;
        self.next_offered_generation = offered_generation
            .checked_add(3)
            .ok_or_else(|| anyhow!("input lease generation exhausted"))?;
        let offered = InputLease {
            generation: offered_generation,
            owner: self.config.local_device,
            route_to: self.config.target_device,
            state: InputLeaseState::Offered,
        };
        let active = InputLease {
            generation: active_generation,
            state: InputLeaseState::Active,
            ..offered
        };
        self.route = Some(ActiveRoute {
            offered,
            active,
            source_display: edge.source_display,
            route_generation: edge.route_generation,
            last_event_sequence: 0,
            bound_peer: None,
        });
        let bind_result = timeout(PEER_ACTIVATION_TIMEOUT, self.ensure_remote_lease()).await;
        let (activation_peer, activation_error) = match bind_result {
            Ok(Ok(peer)) => (Some(peer), None),
            Ok(Err(error)) => (None, Some(error)),
            Err(_) => (
                None,
                Some(anyhow!(
                    "timed out waiting for an input producer peer after {} ms",
                    PEER_ACTIVATION_TIMEOUT.as_millis()
                )),
            ),
        };
        if let Some(error) = activation_error {
            if let Err(cleanup_error) = self.shutdown_route().await {
                eprintln!("viewflowd input producer activation rollback failed: {cleanup_error:#}");
            }
            return Err(error);
        }
        let peer = activation_peer.expect("successful activation retains its exact peer");
        if let Some(acceptance) = &self.config.acceptance {
            acceptance.route_activated(RouteActivatedEvidence {
                source_display: edge.source_display,
                target_device: edge.route_to,
                route_generation: edge.route_generation,
                active_lease_generation: active.generation,
                peer_epoch: peer.epoch,
                peer_socket: peer.address,
            });
        }
        let bound_peer = BoundPeerIdentity {
            epoch: peer.epoch,
            address: peer.address,
        };
        Ok((
            SidecarInputLease {
                lease: offered,
                bound_peer,
            },
            SidecarInputLease {
                lease: active,
                bound_peer,
            },
        ))
    }

    async fn send_input(&mut self, message: &SidecarMessage) -> Result<()> {
        let operation_now = Instant::now();
        let sender_now_ns = self.config.clock.now_ns();
        let capture_deadline_monotonic_ns = sidecar_apply_deadline_monotonic_ns(message)?;
        let (operation_deadline, sender_not_after_ns) = match capture_deadline_monotonic_ns {
            Some(capture_deadline_ns) => map_capture_apply_deadline(
                capture_deadline_ns,
                linux_monotonic_now_ns()?,
                sender_now_ns,
                operation_now,
            )?,
            None => (operation_now + INPUT_APPLIED_TIMEOUT, 0),
        };
        let event = sidecar_input_event(message, sender_not_after_ns)?;
        let route = self
            .route
            .as_ref()
            .ok_or_else(|| anyhow!("input event arrived without an active producer route"))?;
        if event.lease_generation != route.active.generation
            || event.target_device != route.active.route_to
        {
            bail!("sidecar input does not match the active producer route");
        }
        if event.sequence <= route.last_event_sequence {
            bail!("sidecar input event is replayed or out of order");
        }
        let send_error = self
            .send_event_persistent(event, operation_deadline)
            .await
            .err();
        if let Some(error) = send_error {
            self.route
                .as_mut()
                .expect("route remains active while rolling back input")
                .last_event_sequence = event.sequence;
            return Err(error);
        }
        self.route
            .as_mut()
            .expect("route remains active while sending input")
            .last_event_sequence = event.sequence;
        if let (Some(acceptance), Some(capture_deadline_monotonic_ns)) =
            (&self.config.acceptance, capture_deadline_monotonic_ns)
        {
            let capture_monotonic_ns = capture_deadline_monotonic_ns
                .checked_sub(duration_ns(CAPTURE_TO_APPLY_TIMEOUT))
                .ok_or_else(|| anyhow!("captured input deadline precedes its 32 ms budget"))?;
            let applied_ack_monotonic_ns = linux_monotonic_now_ns()?;
            let latency_us = applied_ack_monotonic_ns
                .checked_sub(capture_monotonic_ns)
                .ok_or_else(|| anyhow!("Applied ACK monotonic time precedes input capture"))?
                / 1_000;
            let kinds = acceptance_coverage_kinds(message)?;
            acceptance.input_applied(event.sequence, latency_us, &kinds);
        }
        Ok(())
    }

    async fn prepare_return_to_local(
        &mut self,
        edge: EdgeActivated,
    ) -> Result<PreparedLocalReturn> {
        let route = self
            .route
            .clone()
            .ok_or_else(|| anyhow!("return-to-local arrived without an active route"))?;
        if edge.route_to != self.config.local_device {
            bail!("return edge does not target the local device");
        }
        let revoked = revoked_lease(&route)?;
        self.shutdown_route()
            .await
            .context("refusing local fallback because remote cleanup was not verified")?;
        let peer = route
            .bound_peer
            .as_ref()
            .ok_or_else(|| anyhow!("verified cleanup lost its exact bound peer"))?;
        let bound_peer = BoundPeerIdentity {
            epoch: peer.epoch,
            address: peer.address,
        };
        let cleanup_complete = self
            .last_cleanup_complete
            .ok_or_else(|| anyhow!("remote cleanup omitted its terminal sidecar evidence"))?;
        Ok(PreparedLocalReturn {
            cleanup_complete,
            return_to_local: ReturnToLocal {
                generation: route.active.generation,
                target_display: route.source_display,
                edge: opposite_edge(edge.edge),
                edge_position: edge.edge_position,
            },
            revoked: SidecarInputLease {
                lease: revoked,
                bound_peer,
            },
        })
    }

    async fn shutdown_route(&mut self) -> Result<()> {
        self.shutdown_route_before(Instant::now() + ROUTE_CLEANUP_TIMEOUT)
            .await
    }

    #[allow(clippy::too_many_lines)]
    async fn shutdown_route_before(&mut self, deadline: Instant) -> Result<()> {
        let Some(route) = self.route.clone() else {
            if let Some(reason) = self.quiescence_uncertainty {
                return Err(anyhow!(
                    "quiescence remains fail-closed after uncertain input cleanup: {reason}"
                ));
            }
            if self.route_ever_activated {
                if let Err(error) = self.verified_quiescence_cleanup() {
                    self.quiescence_uncertainty = Some(
                        "an input route was activated without matching verified cleanup evidence",
                    );
                    return Err(error.context(
                        "an activated route does not have reusable verified cleanup evidence",
                    ));
                }
                return Ok(());
            }
            self.last_cleanup = Some(RouteCleanupEvidence {
                route_ever_activated: false,
                route_was_active: false,
                source_display: None,
                route_generation: None,
                active_lease_generation: None,
                last_input_sequence: None,
                release_all: ReleaseAllEvidence {
                    status: ReleaseAllStatus::NotRequiredNoActiveRoute,
                    ack: None,
                },
                lease_revoke: LeaseRevokeEvidence {
                    status: LeaseRevokeStatus::NotRequiredNoActiveRoute,
                    generation: None,
                    ack: None,
                },
                bound_peer_epoch: None,
                bound_peer_socket: None,
            });
            self.last_cleanup_peer = None;
            self.last_runtime_marker = None;
            self.last_cleanup_complete = None;
            return Ok(());
        };
        let Some(peer) = route.bound_peer.clone() else {
            self.quiescence_uncertainty =
                Some("active route lost its exact bound peer before ReleaseAll could be confirmed");
            self.last_cleanup = None;
            self.last_cleanup_peer = None;
            self.last_runtime_marker = None;
            self.last_cleanup_complete = None;
            return Err(anyhow!(
                "active input route has no exact bound peer for ReleaseAll Applied cleanup"
            ));
        };
        let revoked = match revoked_lease(&route) {
            Ok(revoked) => revoked,
            Err(error) => {
                self.abort_peer(&peer, "input lease generation exhausted during cleanup");
                self.route = None;
                self.last_cleanup = None;
                self.last_cleanup_peer = None;
                self.last_runtime_marker = None;
                self.last_cleanup_complete = None;
                self.quiescence_uncertainty =
                    Some("input lease generation exhausted before cleanup was verified");
                return Err(error);
            }
        };
        let revoke = match self.next_revoke_operation(revoked, peer.epoch) {
            Ok(revoke) => revoke,
            Err(error) => {
                self.abort_peer(&peer, "input lease revoke operation identity exhausted");
                self.route = None;
                self.last_cleanup = None;
                self.last_cleanup_peer = None;
                self.last_runtime_marker = None;
                self.last_cleanup_complete = None;
                self.quiescence_uncertainty =
                    Some("input lease revoke operation identity exhausted before cleanup");
                return Err(error);
            }
        };
        let release_deadline = deadline.checked_sub(REVOKE_RESERVE).unwrap_or(deadline);
        let Some(release_sequence) = route.last_event_sequence.checked_add(1) else {
            self.abort_peer(&peer, "ReleaseAll input sequence exhausted during cleanup");
            self.route = None;
            self.last_cleanup = None;
            self.last_cleanup_peer = None;
            self.last_runtime_marker = None;
            self.last_cleanup_complete = None;
            self.quiescence_uncertainty =
                Some("ReleaseAll input sequence exhausted before cleanup was sent");
            return Err(anyhow!(
                "input sequence cannot advance for ReleaseAll; bound peer was aborted"
            ));
        };
        let release_sequence = release_sequence.max(1);
        let runtime_marker = match Self::runtime_marker_for_route(&route, &peer) {
            Ok(marker) => marker,
            Err(error) => {
                self.abort_peer(&peer, "runtime quarantine marker identity was invalid");
                self.route = None;
                self.last_cleanup = None;
                self.last_cleanup_peer = None;
                self.last_runtime_marker = None;
                self.last_cleanup_complete = None;
                self.quiescence_uncertainty =
                    Some("runtime quarantine marker could not be reconstructed exactly");
                return Err(error);
            }
        };
        let cleanup_result = timeout_at(deadline, async {
            let release_result = match timeout_at(
                release_deadline,
                send_input_confirmed(
                    &peer.outbound,
                    InputEvent {
                        lease_generation: route.active.generation,
                        target_device: route.active.route_to,
                        sequence: release_sequence,
                        sender_not_after_ns: 0,
                        event: InputEventKind::ReleaseAll,
                    },
                ),
            )
            .await
            {
                Ok(result) => result.map_err(anyhow::Error::from),
                Err(_) => Err(anyhow!(
                    "ReleaseAll did not complete before the revoke reserve of {} ms",
                    REVOKE_RESERVE.as_millis()
                )),
            };
            release_result.context("ReleaseAll was not confirmed applied")?;
            send_lease_revoke_confirmed_until(&peer.outbound, revoke, deadline)
                .await
                .map_err(anyhow::Error::from)
                .context("lease revoke was not confirmed applied")
        })
        .await;
        let result = match cleanup_result {
            Ok(result) => result,
            Err(_) => Err(anyhow!(
                "input producer route cleanup missed its absolute deadline"
            )),
        };
        if let Err(error) = &result {
            self.abort_peer(
                &peer,
                "input cleanup was not confirmed before leaving quarantine",
            );
            self.route = None;
            self.last_cleanup = None;
            self.last_cleanup_peer = None;
            self.last_runtime_marker = None;
            self.last_cleanup_complete = None;
            self.quiescence_uncertainty =
                Some("ReleaseAll Applied or lease revoke confirmation failed");
            return Err(anyhow!("{error:#}; bound peer was aborted"));
        }
        let revoke_ack = result.expect("successful cleanup returns the exact revoke ACK");
        let cleanup_complete = match cleanup_complete_from_applied(
            runtime_marker,
            route.last_event_sequence,
            release_sequence,
            revoke_ack,
        ) {
            Ok(cleanup) => cleanup,
            Err(error) => {
                self.abort_peer(&peer, "terminal cleanup evidence could not be constructed");
                self.route = None;
                self.last_cleanup = None;
                self.last_cleanup_peer = None;
                self.last_runtime_marker = None;
                self.last_cleanup_complete = None;
                self.quiescence_uncertainty =
                    Some("terminal sidecar cleanup evidence could not be constructed");
                return Err(error);
            }
        };
        if let Some(acceptance) = &self.config.acceptance {
            acceptance.cleanup_applied(CleanupAppliedEvidence {
                release_lease_generation: route.active.generation,
                release_event_sequence: release_sequence,
                revoke_operation_id: revoke_ack.operation_id,
                revoke_lease_generation: revoke_ack.lease_generation,
                peer_epoch: peer.epoch,
            });
        }
        self.route = None;
        self.last_cleanup = Some(RouteCleanupEvidence {
            route_ever_activated: true,
            route_was_active: true,
            source_display: Some(format!("{:032x}", route.source_display.0)),
            route_generation: Some(route.route_generation),
            active_lease_generation: Some(route.active.generation),
            last_input_sequence: Some(route.last_event_sequence),
            release_all: ReleaseAllEvidence {
                status: ReleaseAllStatus::Applied,
                ack: Some(AppliedAckIdentity {
                    lease_generation: route.active.generation,
                    target_device: format!("{:032x}", route.active.route_to.0),
                    event_sequence: release_sequence,
                    result: "applied",
                }),
            },
            lease_revoke: LeaseRevokeEvidence {
                status: LeaseRevokeStatus::Applied,
                generation: Some(revoked.generation),
                ack: Some(LeaseRevokeAckIdentity {
                    operation_id: format!("{:032x}", revoke_ack.operation_id.0),
                    lease_generation: revoke_ack.lease_generation,
                    owner_device: format!("{:032x}", revoke_ack.owner_device.0),
                    target_device: format!("{:032x}", revoke_ack.target_device.0),
                    state: "revoked",
                    result: "applied",
                }),
            },
            bound_peer_epoch: Some(peer.epoch),
            bound_peer_socket: Some(peer.address.to_string()),
        });
        self.last_cleanup_peer = Some(peer);
        self.last_runtime_marker = Some(runtime_marker);
        self.last_cleanup_complete = Some(cleanup_complete);
        Ok(())
    }

    fn runtime_marker_for_route(
        route: &ActiveRoute,
        peer: &ProducerPeer,
    ) -> Result<DurableQuarantineMarker> {
        let daemon = current_daemon_marker_identity()?;
        let marker = DurableQuarantineMarker {
            state: QuarantineMarkerState::Active,
            source_display: route.source_display,
            target_device: route.active.route_to,
            owner_device: route.active.owner,
            old_daemon_boot_id: daemon.boot_id,
            route_generation: route.route_generation,
            active_lease_generation: route.active.generation,
            last_sequence: route.last_event_sequence,
            old_daemon_pid: u64::from(daemon.pid),
            old_daemon_start_ticks: daemon.start_ticks,
            bound_peer: BoundPeerIdentity {
                epoch: peer.epoch,
                address: peer.address,
            },
        };
        marker
            .encode()
            .map_err(anyhow::Error::from)
            .context("runtime quarantine marker contract rejected the live route")?;
        Ok(marker)
    }

    fn prepare_recovery_cleanup(
        &self,
        credentials: SidecarPeerCredentials,
        request_sequence: u64,
        recovery: QuarantineRecoveryRequest,
    ) -> Result<CleanupComplete> {
        validate_sidecar_peer_credentials(credentials, current_effective_uid()?)?;
        if request_sequence == 0 {
            bail!("quarantine recovery uses the reserved zero request sequence");
        }
        recovery
            .marker
            .encode()
            .map_err(anyhow::Error::from)
            .context("quarantine recovery marker is invalid")?;
        if recovery
            .marker
            .sha256()
            .map_err(anyhow::Error::from)
            .context("failed to hash quarantine recovery marker")?
            != recovery.marker_sha256
        {
            bail!("quarantine recovery marker SHA-256 does not match its bytes");
        }
        let daemon = current_daemon_marker_identity()?;
        if recovery.marker.old_daemon_boot_id != daemon.boot_id
            || recovery.marker.old_daemon_pid != u64::from(daemon.pid)
            || recovery.marker.old_daemon_start_ticks != daemon.start_ticks
        {
            bail!("quarantine recovery does not bind this exact daemon instance");
        }
        if recovery.marker.owner_device != self.config.local_device
            || recovery.marker.target_device != self.config.target_device
        {
            bail!("quarantine recovery does not bind the configured route endpoints");
        }
        if self.route.is_some() || self.quiescence_uncertainty.is_some() {
            bail!("quarantine recovery has no terminal exact cleanup evidence");
        }
        self.verified_quiescence_cleanup()
            .context("quarantine recovery cleanup evidence is not exact")?;
        let retained_marker = self
            .last_runtime_marker
            .ok_or_else(|| anyhow!("no retained runtime marker matches quarantine recovery"))?;
        if recovery.marker != retained_marker {
            bail!("quarantine recovery marker does not exactly match retained cleanup evidence");
        }
        let retained = self
            .last_cleanup_complete
            .ok_or_else(|| anyhow!("no retained terminal cleanup receipt is available"))?;
        if retained.mode != CleanupMode::Normal
            || retained.recovery_request_sequence != 0
            || retained.marker_sha256 != recovery.marker_sha256
        {
            bail!("retained terminal cleanup receipt does not bind the recovery marker");
        }
        let now = unix_time_ms_u64()?;
        if now < retained.receipt_issued_at_unix_ms || now > retained.receipt_expires_at_unix_ms {
            bail!("retained terminal cleanup receipt has expired or is from the future");
        }
        Ok(CleanupComplete {
            mode: CleanupMode::Recovery,
            recovery_request_sequence: request_sequence,
            ..retained
        })
    }

    fn next_revoke_operation(
        &mut self,
        revoked: InputLease,
        peer_epoch: u64,
    ) -> Result<InputLeaseRevoke> {
        if peer_epoch == 0 {
            bail!("bound peer epoch zero is reserved");
        }
        let operation = self.next_revoke_operation;
        self.next_revoke_operation = operation
            .checked_add(1)
            .ok_or_else(|| anyhow!("input lease revoke operation identity exhausted"))?;
        Ok(InputLeaseRevoke {
            operation_id: Id128((u128::from(peer_epoch) << 64) | u128::from(operation)),
            lease_generation: revoked.generation,
            owner_device: revoked.owner,
            target_device: revoked.route_to,
            state: revoked.state,
        })
    }

    fn verified_quiescence_cleanup(&self) -> Result<&RouteCleanupEvidence> {
        if let Some(reason) = self.quiescence_uncertainty {
            bail!("quiescence is permanently fail-closed for this daemon instance: {reason}");
        }
        if self.route.is_some() {
            bail!("an active input route remains during quiescence finalization");
        }
        let cleanup = self
            .last_cleanup
            .as_ref()
            .ok_or_else(|| anyhow!("route cleanup did not produce verifiable evidence"))?;
        if !self.route_ever_activated {
            if cleanup.route_ever_activated
                || cleanup.route_was_active
                || cleanup.source_display.is_some()
                || cleanup.route_generation.is_some()
                || cleanup.active_lease_generation.is_some()
                || cleanup.last_input_sequence.is_some()
                || cleanup.release_all.status != ReleaseAllStatus::NotRequiredNoActiveRoute
                || cleanup.release_all.ack.is_some()
                || cleanup.lease_revoke.status != LeaseRevokeStatus::NotRequiredNoActiveRoute
                || cleanup.lease_revoke.generation.is_some()
                || cleanup.lease_revoke.ack.is_some()
                || cleanup.bound_peer_epoch.is_some()
                || cleanup.bound_peer_socket.is_some()
            {
                bail!("never-active route cleanup evidence is inconsistent");
            }
            return Ok(cleanup);
        }

        let active_generation = cleanup
            .active_lease_generation
            .ok_or_else(|| anyhow!("activated route cleanup omits its lease generation"))?;
        if active_generation == 0 {
            bail!("activated route cleanup has an invalid zero lease generation");
        }
        let source_display = cleanup
            .source_display
            .as_deref()
            .ok_or_else(|| anyhow!("activated route cleanup omits its source display"))?;
        let source_display_id = u128::from_str_radix(source_display, 16)
            .map_err(|_| anyhow!("activated route cleanup source display is not lowercase hex"))?;
        let route_generation = cleanup
            .route_generation
            .ok_or_else(|| anyhow!("activated route cleanup omits its route generation"))?;
        let last_sequence = cleanup
            .last_input_sequence
            .ok_or_else(|| anyhow!("activated route cleanup omits its last input sequence"))?;
        let expected_release_sequence = last_sequence.checked_add(1).ok_or_else(|| {
            anyhow!("activated route cleanup input sequence cannot advance for ReleaseAll")
        })?;
        let ack = cleanup.release_all.ack.as_ref().ok_or_else(|| {
            anyhow!("activated route cleanup omits the exact ReleaseAll Applied ACK")
        })?;
        let revoke_generation = cleanup
            .lease_revoke
            .generation
            .ok_or_else(|| anyhow!("activated route cleanup omits its revoke generation"))?;
        let expected_revoke_generation = active_generation.checked_add(1).ok_or_else(|| {
            anyhow!("activated route cleanup lease generation cannot advance for revoke")
        })?;
        let revoke_ack = cleanup.lease_revoke.ack.as_ref().ok_or_else(|| {
            anyhow!("activated route cleanup omits the exact lease revoke Applied ACK")
        })?;
        let bound_peer_epoch = cleanup
            .bound_peer_epoch
            .ok_or_else(|| anyhow!("activated route cleanup omits its bound peer epoch"))?;
        let bound_peer_socket = cleanup
            .bound_peer_socket
            .as_deref()
            .ok_or_else(|| anyhow!("activated route cleanup omits its bound peer socket"))?;
        let revoke_operation = u128::from_str_radix(&revoke_ack.operation_id, 16)
            .map_err(|_| anyhow!("lease revoke ACK operation identity is not lowercase hex"))?;
        if !cleanup.route_ever_activated
            || !cleanup.route_was_active
            || source_display.len() != 32
            || format!("{source_display_id:032x}") != source_display
            || source_display_id == 0
            || route_generation == 0
            || cleanup.release_all.status != ReleaseAllStatus::Applied
            || ack.result != "applied"
            || ack.lease_generation != active_generation
            || ack.target_device != format!("{:032x}", self.config.target_device.0)
            || ack.event_sequence != expected_release_sequence
            || cleanup.lease_revoke.status != LeaseRevokeStatus::Applied
            || revoke_generation != expected_revoke_generation
            || revoke_ack.lease_generation != expected_revoke_generation
            || revoke_ack.owner_device != format!("{:032x}", self.config.local_device.0)
            || revoke_ack.target_device != format!("{:032x}", self.config.target_device.0)
            || revoke_ack.state != "revoked"
            || revoke_ack.result != "applied"
            || revoke_operation >> 64 != u128::from(bound_peer_epoch)
            || u64::try_from(revoke_operation & u128::from(u64::MAX)).unwrap_or(0) == 0
            || bound_peer_epoch == 0
            || bound_peer_socket.parse::<SocketAddr>().is_err()
        {
            bail!("activated route cleanup evidence is incomplete or inconsistent");
        }
        Ok(cleanup)
    }

    fn finalize_quiescence(&mut self, arm: QuiescenceArm) -> Result<()> {
        let path = self
            .config
            .quiesce_proof
            .as_ref()
            .ok_or_else(|| anyhow!("quiescence proof output is not configured"))?;
        let cleanup = self.verified_quiescence_cleanup()?.clone();

        let (current_peer, live_peers) = self.peers.begin_quiescence();
        let allowed_live_epoch = if cleanup.route_ever_activated {
            cleanup.bound_peer_epoch
        } else {
            current_peer.as_ref().map(|peer| peer.epoch)
        };
        let unexpected_live_peers = live_peers
            .into_iter()
            .filter(|peer| Some(peer.epoch) != allowed_live_epoch)
            .collect::<Vec<_>>();
        if !unexpected_live_peers.is_empty() {
            let epochs = unexpected_live_peers
                .iter()
                .map(|peer| peer.epoch.to_string())
                .collect::<Vec<_>>()
                .join(",");
            for peer in unexpected_live_peers {
                peer.outbound
                    .abort_peer("deployment quiesce rejected a superseded live peer");
            }
            bail!("refusing quiescence receipt while superseded peer epochs remain live: {epochs}");
        }

        if let Some(peer) = self.last_cleanup_peer.take() {
            peer.outbound.abort_peer("deployment quiesce completed");
        }
        if let Some(peer) = current_peer {
            peer.outbound
                .abort_peer("deployment quiesce closes producer admission");
        }

        let completed_at_unix_ms = unix_time_ms()?;
        let receipt = QuiescenceReceipt {
            schema_version: 4,
            state: "viewflow-input-quiesced",
            daemon_instance_id: format!(
                "{}-{}-{}",
                arm.boot_id, arm.daemon_pid, arm.daemon_start_ticks
            ),
            operation_id: arm.operation_id,
            daemon_pid: arm.daemon_pid,
            daemon_start_ticks: arm.daemon_start_ticks,
            boot_id: arm.boot_id,
            daemon_sha256: arm.daemon_sha256,
            protocol_version: format!(
                "{}.{}",
                viewflow_protocol::PROTOCOL_VERSION.major,
                viewflow_protocol::PROTOCOL_VERSION.minor
            ),
            local_device: format!("{:032x}", self.config.local_device.0),
            target_device: format!("{:032x}", self.config.target_device.0),
            cleanup,
            route_status: "removed",
            peer_disconnect_status: "initiated_before_daemon_exit",
            daemon_exit_required: true,
            sidecar_session_disconnected: true,
            artifact_hashes: self.config.artifact_hashes.clone(),
            completed_at_unix_ms,
        };
        write_quiescence_receipt(path, &receipt)
    }

    async fn send_event_persistent(
        &mut self,
        event: InputEvent,
        operation_deadline: Instant,
    ) -> Result<()> {
        loop {
            let Some(peer) =
                run_before_deadline(operation_deadline, self.ensure_remote_lease()).await
            else {
                bail!("captured input deadline expired before a peer lease was available");
            };
            let peer = peer?;
            match send_input_confirmed_until(&peer.outbound, event, operation_deadline).await {
                Ok(()) => return Ok(()),
                Err(error) if error.is_connection_failure() => {
                    self.abort_peer(
                        &peer,
                        "bound input peer stopped before queueing the captured event",
                    );
                    eprintln!(
                        "viewflowd input producer peer {} event={} transport failed: {error:#}; \
                         waiting for reconnect",
                        peer.address, event.sequence
                    );
                    self.mark_peer_unbound(peer.epoch);
                    let Some(changed) = run_before_deadline(
                        operation_deadline,
                        self.peers.changed_after(peer.epoch),
                    )
                    .await
                    else {
                        bail!("captured input deadline expired while waiting for peer reconnect");
                    };
                    changed?;
                }
                Err(error) => return Err(error.into()),
            }
        }
    }

    async fn ensure_remote_lease(&mut self) -> Result<ProducerPeer> {
        loop {
            if let Some(peer) = self
                .route
                .as_ref()
                .and_then(|route| route.bound_peer.clone())
            {
                return Ok(peer);
            }
            let peer = self.peers.current().await?;
            let route = self
                .route
                .as_ref()
                .ok_or_else(|| anyhow!("cannot bind a peer without an active route"))?;
            let offered = route.offered;
            let active = route.active;
            self.route
                .as_mut()
                .expect("route remains active while binding peer")
                .bound_peer = Some(peer.clone());
            let offer_result =
                send_control_confirmed(&peer.outbound, input_lease_payload(offered)).await;
            let result = match offer_result {
                Ok(()) => send_control_confirmed(&peer.outbound, input_lease_payload(active)).await,
                Err(error) => Err(error),
            };
            match result {
                Ok(()) => {
                    println!(
                        "viewflowd input producer peer {} lease_offered={} lease_active={} \
                         transport_confirmed=true",
                        peer.address, offered.generation, active.generation
                    );
                    return Ok(peer);
                }
                Err(error) => {
                    self.abort_peer(&peer, "input lease activation was not transport-confirmed");
                    eprintln!(
                        "viewflowd input producer peer {} lease transport failed: {error:#}; \
                         waiting for reconnect",
                        peer.address
                    );
                    self.mark_peer_unbound(peer.epoch);
                    self.peers.changed_after(peer.epoch).await?;
                }
            }
        }
    }

    fn mark_peer_unbound(&mut self, epoch: u64) {
        if let Some(route) = &mut self.route
            && route
                .bound_peer
                .as_ref()
                .is_some_and(|peer| peer.epoch == epoch)
        {
            route.bound_peer = None;
        }
    }

    fn abort_peer(&mut self, peer: &ProducerPeer, reason: &str) {
        debug_assert!(
            self.route
                .as_ref()
                .and_then(|route| route.bound_peer.as_ref())
                .is_some_and(|bound_peer| bound_peer.epoch == peer.epoch),
            "peer abort must stay pinned to the route's exact bound peer"
        );
        peer.outbound.abort_peer(reason);
        #[cfg(test)]
        self.aborted_peer_epochs.push(peer.epoch);
    }
}

fn revoked_lease(route: &ActiveRoute) -> Result<InputLease> {
    Ok(InputLease {
        generation: route
            .active
            .generation
            .checked_add(1)
            .ok_or_else(|| anyhow!("input lease generation exhausted"))?,
        state: InputLeaseState::Revoked,
        ..route.active
    })
}

fn cleanup_complete_from_applied(
    marker: DurableQuarantineMarker,
    observed_last_sequence: u64,
    release_sequence: u64,
    revoke_ack: viewflow_protocol::InputLeaseRevokedAck,
) -> Result<CleanupComplete> {
    if marker.last_sequence != observed_last_sequence {
        bail!("runtime marker sequence does not match observed cleanup sequence");
    }
    let expected_release_sequence = observed_last_sequence
        .checked_add(1)
        .ok_or_else(|| anyhow!("cleanup ReleaseAll sequence exhausted"))?;
    if release_sequence != expected_release_sequence {
        bail!("cleanup ReleaseAll sequence does not immediately follow observed input");
    }
    let expected_revoke_generation = marker
        .active_lease_generation
        .checked_add(1)
        .ok_or_else(|| anyhow!("cleanup revoke lease generation exhausted"))?;
    if revoke_ack.operation_id.0 == 0
        || revoke_ack.operation_id.0 >> 64 != u128::from(marker.bound_peer.epoch)
        || revoke_ack.operation_id.0 & u128::from(u64::MAX) == 0
        || revoke_ack.lease_generation != expected_revoke_generation
        || revoke_ack.owner_device != marker.owner_device
        || revoke_ack.target_device != marker.target_device
        || revoke_ack.state != InputLeaseState::Revoked
    {
        bail!("lease revoke Applied ACK does not bind the exact runtime marker route");
    }
    let issued = unix_time_ms_u64()?;
    let lifetime_ms = u64::try_from(CLEANUP_RECEIPT_LIFETIME.as_millis())
        .context("cleanup receipt lifetime does not fit u64")?;
    let expires = issued
        .checked_add(lifetime_ms)
        .ok_or_else(|| anyhow!("cleanup receipt expiry overflow"))?;
    Ok(CleanupComplete {
        mode: CleanupMode::Normal,
        recovery_request_sequence: 0,
        marker_sha256: marker
            .sha256()
            .map_err(anyhow::Error::from)
            .context("failed to hash runtime quarantine marker")?,
        cleanup_operation_id: revoke_ack.operation_id,
        receipt_issued_at_unix_ms: issued,
        receipt_expires_at_unix_ms: expires,
        source_display: marker.source_display,
        route_generation: marker.route_generation,
        target_device: marker.target_device,
        owner_device: marker.owner_device,
        active_lease_generation: marker.active_lease_generation,
        marker_last_sequence: marker.last_sequence,
        observed_last_sequence,
        sequence_disposition: SequenceDisposition::Exact,
        bound_peer: marker.bound_peer,
        release_all: ReleaseAllInput {
            generation: marker.active_lease_generation,
            target_device: marker.target_device,
            event_sequence: release_sequence,
        },
        release_all_applied: true,
        revoke_operation_id: revoke_ack.operation_id,
        revoke_lease_generation: revoke_ack.lease_generation,
        revoke_owner_device: revoke_ack.owner_device,
        revoke_target_device: revoke_ack.target_device,
        revoke_state: revoke_ack.state,
        revoke_applied: true,
    })
}

pub fn arm_quiescence(config: &ArmQuiesceConfig) -> Result<()> {
    let identity = process_identity(config.daemon_pid)?;
    let armed_at_unix_ms = unix_time_ms()?;
    let arm = QuiescenceArm {
        schema_version: 1,
        operation_id: config.operation_id.clone(),
        daemon_pid: config.daemon_pid,
        daemon_start_ticks: identity.start_ticks,
        boot_id: identity.boot_id,
        daemon_sha256: identity.executable_sha256,
        armed_at_unix_ms,
    };
    write_owner_only_json_new(&config.arm_file, &arm, "quiescence arm")?;
    println!(
        "viewflowd quiescence armed operation_id={} daemon_pid={} daemon_start_ticks={}",
        arm.operation_id, arm.daemon_pid, arm.daemon_start_ticks
    );
    Ok(())
}

struct ProcessIdentity {
    start_ticks: u64,
    boot_id: String,
    executable_sha256: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DaemonMarkerIdentity {
    boot_id: Id128,
    pid: u32,
    start_ticks: u64,
}

fn current_daemon_marker_identity() -> Result<DaemonMarkerIdentity> {
    let pid = std::process::id();
    let start_ticks = process_start_ticks(pid)?;
    let boot_id = fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .context("failed to read kernel boot id")?;
    Ok(DaemonMarkerIdentity {
        boot_id: parse_boot_id(boot_id.trim())?,
        pid,
        start_ticks,
    })
}

fn parse_boot_id(value: &str) -> Result<Id128> {
    let compact = value.replace('-', "");
    if compact.len() != 32 || !compact.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("kernel boot id is not a 128-bit UUID");
    }
    let parsed = u128::from_str_radix(&compact, 16).context("invalid kernel boot id")?;
    if parsed == 0 {
        bail!("kernel boot id uses the reserved zero identity");
    }
    Ok(Id128(parsed))
}

fn process_identity(pid: u32) -> Result<ProcessIdentity> {
    let start_ticks_before_open = process_start_ticks(pid)?;
    let executable_path = PathBuf::from(format!("/proc/{pid}/exe"));
    let mut executable = OpenOptions::new()
        .read(true)
        .open(&executable_path)
        .with_context(|| format!("failed to open executable for pid {pid}"))?;
    let executable_metadata = executable
        .metadata()
        .with_context(|| format!("failed to inspect executable for pid {pid}"))?;
    if !executable_metadata.is_file() {
        bail!("executable for pid {pid} is not a regular file");
    }
    let start_ticks_after_open = process_start_ticks(pid)?;
    if start_ticks_before_open != start_ticks_after_open {
        bail!("pid {pid} changed identity while opening its executable");
    }
    let executable_sha256 = crate::sha256_file_handle(&mut executable)
        .with_context(|| format!("failed to hash executable for pid {pid}"))?;
    let start_ticks_after_hash = process_start_ticks(pid)?;
    if start_ticks_before_open != start_ticks_after_hash {
        bail!("pid {pid} changed identity while hashing its executable");
    }
    let boot_id = fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .context("failed to read kernel boot id")?
        .trim()
        .to_owned();
    Ok(ProcessIdentity {
        start_ticks: start_ticks_before_open,
        boot_id,
        executable_sha256,
    })
}

fn process_start_ticks(pid: u32) -> Result<u64> {
    let stat_path = PathBuf::from(format!("/proc/{pid}/stat"));
    let stat = fs::read_to_string(&stat_path)
        .with_context(|| format!("failed to read {}", stat_path.display()))?;
    let after_comm = stat
        .rfind(')')
        .and_then(|index| stat.get(index + 2..))
        .ok_or_else(|| anyhow!("malformed {}", stat_path.display()))?;
    after_comm
        .split_whitespace()
        .nth(19)
        .ok_or_else(|| anyhow!("{} lacks process start ticks", stat_path.display()))?
        .parse::<u64>()
        .context("invalid process start ticks")
}

fn unix_time_ms() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock precedes Unix epoch")?
        .as_millis())
}

fn unix_time_ms_u64() -> Result<u64> {
    u64::try_from(unix_time_ms()?).context("Unix millisecond timestamp does not fit u64")
}

fn current_effective_uid() -> Result<u32> {
    let status =
        fs::read_to_string("/proc/self/status").context("failed to read process status")?;
    let line = status
        .lines()
        .find(|line| line.starts_with("Uid:"))
        .ok_or_else(|| anyhow!("process status lacks Uid"))?;
    line.split_whitespace()
        .nth(2)
        .ok_or_else(|| anyhow!("process status lacks effective uid"))?
        .parse::<u32>()
        .context("invalid effective uid")
}

fn validate_secure_parent(path: &std::path::Path) -> Result<&std::path::Path> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .ok_or_else(|| anyhow!("path must have a parent directory"))?;
    let metadata = fs::symlink_metadata(parent)
        .with_context(|| format!("failed to inspect {}", parent.display()))?;
    if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
        bail!("parent must be a real directory: {}", parent.display());
    }
    if metadata.uid() != current_effective_uid()? || metadata.permissions().mode() & 0o022 != 0 {
        bail!(
            "parent must be owned by the daemon user and not group/world writable: {}",
            parent.display()
        );
    }
    Ok(parent)
}

fn write_owner_only_json_new<T: Serialize>(
    path: &std::path::Path,
    value: &T,
    description: &str,
) -> Result<()> {
    validate_secure_parent(path)?;
    let serialized = serde_json::to_vec_pretty(value)
        .with_context(|| format!("failed to serialize {description}"))?;
    let mut file = create_owner_only_new(path)?;
    let result = (|| -> Result<()> {
        file.write_all(&serialized)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(path);
    }
    result
}

fn create_owner_only_new(path: &std::path::Path) -> Result<fs::File> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("refusing to replace existing {}", path.display()))
}

fn consume_quiescence_arm(path: &std::path::Path) -> Result<Option<QuiescenceArm>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        bail!("quiescence arm must be a regular file");
    }
    if metadata.uid() != current_effective_uid()? || metadata.permissions().mode() & 0o077 != 0 {
        bail!("quiescence arm must be owner-only and owned by the daemon user");
    }
    let bytes = fs::read(path)?;
    let arm: QuiescenceArm = serde_json::from_slice(&bytes).context("invalid quiescence arm")?;
    if arm.schema_version != 1 {
        bail!("unsupported quiescence arm schema {}", arm.schema_version);
    }
    let now = unix_time_ms()?;
    if now < arm.armed_at_unix_ms || now.saturating_sub(arm.armed_at_unix_ms) > 30_000 {
        bail!("quiescence arm is stale or from the future");
    }
    let current = process_identity(std::process::id())?;
    if arm.daemon_pid != std::process::id()
        || arm.daemon_start_ticks != current.start_ticks
        || arm.boot_id != current.boot_id
        || arm.daemon_sha256 != current.executable_sha256
    {
        bail!("quiescence arm does not bind this daemon instance");
    }
    fs::remove_file(path).context("failed to consume quiescence arm")?;
    Ok(Some(arm))
}

pub(crate) async fn run_sidecar_producer(
    config: SidecarProducerConfig,
    peers: ProducerPeerReceiver,
) -> Result<()> {
    let runtime = Handle::current();
    task::spawn_blocking(move || run_sidecar_producer_blocking(config, peers, &runtime))
        .await
        .context("input sidecar task panicked")?
}

fn run_sidecar_producer_blocking(
    config: SidecarProducerConfig,
    peers: ProducerPeerReceiver,
    runtime: &Handle,
) -> Result<()> {
    let listener = LocalSidecarListener::bind(&config.socket_path).with_context(|| {
        format!(
            "failed to bind input sidecar {}",
            config.socket_path.display()
        )
    })?;
    println!(
        "viewflowd input producer listening on {} owner={:032x} target={:032x}",
        listener.path().display(),
        config.local_device.0,
        config.target_device.0
    );
    let mut producer = ProducerState::new(config, peers);
    loop {
        let mut stream = listener
            .accept()
            .context("failed to accept input sidecar")?;
        let credentials = authenticate_sidecar_peer(&stream)
            .context("refusing unauthenticated input sidecar peer")?;
        println!(
            "viewflowd accepted input sidecar peer uid={} pid={}",
            credentials.uid, credentials.pid
        );
        let result = serve_sidecar_stream(&mut stream, runtime, &mut producer, credentials);
        let arm = match &producer.config.quiesce_arm_file {
            Some(path) => match consume_quiescence_arm(path) {
                Ok(arm) => arm,
                Err(error) => {
                    eprintln!("viewflowd rejected deployment quiescence arm: {error:#}");
                    None
                }
            },
            None => None,
        };
        let cleanup = runtime.block_on(producer.shutdown_route());
        if let Err(error) = &cleanup {
            eprintln!("viewflowd input sidecar disconnect cleanup failed: {error:#}");
        }
        if let Err(error) = result {
            eprintln!("viewflowd input sidecar session ended: {error:#}");
        }
        if let Some(arm) = arm {
            cleanup.context("refusing quiescence proof because route cleanup failed")?;
            producer.finalize_quiescence(arm)?;
            println!("viewflowd deployment quiescence receipt written; daemon exiting");
            return Ok(());
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct SidecarPeerCredentials {
    uid: u32,
    pid: u32,
}

fn validate_sidecar_peer_credentials(
    credentials: SidecarPeerCredentials,
    expected_uid: u32,
) -> Result<SidecarPeerCredentials> {
    if credentials.uid != expected_uid {
        bail!(
            "sidecar uid {} does not match daemon uid {expected_uid}",
            credentials.uid
        );
    }
    if credentials.pid == 0 {
        bail!("sidecar peer supplied the reserved zero pid");
    }
    Ok(credentials)
}

fn authenticate_sidecar_peer(stream: &UnixStream) -> Result<SidecarPeerCredentials> {
    let credentials = crate::local_peer::identity(stream).context("local peer identity failed")?;
    let pid = u32::try_from(credentials.pid).context("sidecar peer pid is not positive")?;
    validate_sidecar_peer_credentials(
        SidecarPeerCredentials {
            uid: credentials.uid,
            pid,
        },
        current_effective_uid()?,
    )
}

fn write_quiescence_receipt(path: &std::path::Path, receipt: &QuiescenceReceipt) -> Result<()> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .ok_or_else(|| anyhow!("quiescence proof path must have a parent directory"))?;
    let metadata =
        fs::metadata(parent).with_context(|| format!("failed to inspect {}", parent.display()))?;
    if !metadata.is_dir() {
        bail!(
            "quiescence proof parent is not a directory: {}",
            parent.display()
        );
    }
    if metadata.permissions().mode() & 0o022 != 0 {
        bail!(
            "quiescence proof parent must not be group/world writable: {}",
            parent.display()
        );
    }

    let serialized =
        serde_json::to_vec_pretty(receipt).context("failed to serialize quiescence receipt")?;
    let temporary = parent.join(format!(
        ".{}.tmp-{}-{}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("viewflow-quiescence"),
        std::process::id(),
        receipt.completed_at_unix_ms
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .with_context(|| format!("failed to create {}", temporary.display()))?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    let write_result = (|| -> Result<()> {
        file.write_all(&serialized)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temporary, path)
            .with_context(|| format!("failed to publish quiescence receipt {}", path.display()))?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    write_result
}

fn serve_sidecar_stream(
    stream: &mut UnixStream,
    runtime: &Handle,
    producer: &mut ProducerState,
    credentials: SidecarPeerCredentials,
) -> Result<()> {
    let mut session = SidecarSession::default();
    let mut sidecar_sequence = 1_u64;
    loop {
        let Some(request) = read_request(stream).context("failed to read sidecar request")? else {
            return Ok(());
        };
        let request_sequence = request.sequence;
        let previous_session = session.clone();
        let accepted = session.accept_from(MessageDirection::SidecarToDaemon, request);
        let event = match accepted {
            Ok(event) => event,
            Err(code) => {
                write_response(
                    stream,
                    SidecarResponse {
                        sequence: request_sequence,
                        result: Err(code),
                    },
                )?;
                continue;
            }
        };

        match event {
            SidecarMessage::EdgeActivated(edge) => {
                handle_edge_event(
                    stream,
                    runtime,
                    producer,
                    &mut session,
                    previous_session,
                    &mut sidecar_sequence,
                    request_sequence,
                    edge,
                )?;
            }
            SidecarMessage::RelativePointer(_)
            | SidecarMessage::PointerButton(_)
            | SidecarMessage::PointerWheel(_)
            | SidecarMessage::KeyboardHid(_)
            | SidecarMessage::ReleaseAll(_) => {
                handle_input_event(
                    stream,
                    runtime,
                    producer,
                    &mut session,
                    previous_session,
                    request_sequence,
                    &event,
                )?;
            }
            SidecarMessage::Pointer(_)
            | SidecarMessage::Key(_)
            | SidecarMessage::RawHidReportBundle(_) => {
                session = previous_session;
                write_response(
                    stream,
                    SidecarResponse {
                        sequence: request_sequence,
                        result: Err(RejectCode::BackendFailure),
                    },
                )?;
            }
            SidecarMessage::QuarantineRecovery(recovery) => {
                handle_quarantine_recovery(
                    stream,
                    producer,
                    &mut session,
                    &mut sidecar_sequence,
                    request_sequence,
                    credentials,
                    recovery,
                )?;
            }
            SidecarMessage::InputLease(_)
            | SidecarMessage::ReturnToLocal(_)
            | SidecarMessage::CleanupComplete(_) => {
                unreachable!("direction validation rejects daemon-owned sidecar messages")
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn handle_edge_event(
    stream: &mut UnixStream,
    runtime: &Handle,
    producer: &mut ProducerState,
    session: &mut SidecarSession,
    previous_session: SidecarSession,
    sidecar_sequence: &mut u64,
    request_sequence: u64,
    edge: EdgeActivated,
) -> Result<()> {
    if let Err(code) = producer.validate_edge(edge) {
        *session = previous_session;
        write_response(
            stream,
            SidecarResponse {
                sequence: request_sequence,
                result: Err(code),
            },
        )?;
        return Ok(());
    }
    if edge.route_to == producer.config.local_device {
        let prepared = match runtime.block_on(producer.prepare_return_to_local(edge)) {
            Ok(prepared) => prepared,
            Err(error) => {
                *session = previous_session;
                eprintln!(
                    "viewflowd input producer return-to-local cleanup failed before ACK: {error:#}"
                );
                write_response(
                    stream,
                    SidecarResponse {
                        sequence: request_sequence,
                        result: Err(RejectCode::BackendFailure),
                    },
                )?;
                return Ok(());
            }
        };
        write_response(
            stream,
            SidecarResponse {
                sequence: request_sequence,
                result: Ok(()),
            },
        )?;
        send_sidecar_command(
            stream,
            session,
            sidecar_sequence,
            SidecarMessage::CleanupComplete(prepared.cleanup_complete),
        )
        .context("sidecar did not ACK exact normal cleanup completion")?;
        send_sidecar_command(
            stream,
            session,
            sidecar_sequence,
            SidecarMessage::ReturnToLocal(prepared.return_to_local),
        )?;
        send_sidecar_command(
            stream,
            session,
            sidecar_sequence,
            SidecarMessage::InputLease(prepared.revoked),
        )?;
        if let Some(acceptance) = &producer.config.acceptance {
            acceptance.return_acknowledged(edge.route_generation);
        }
        return Ok(());
    }
    let (offered, active) = match runtime.block_on(producer.activate(edge)) {
        Ok(leases) => leases,
        Err(error) => {
            *session = previous_session;
            eprintln!("viewflowd input sidecar activation failed before ACK: {error:#}");
            write_response(
                stream,
                SidecarResponse {
                    sequence: request_sequence,
                    result: Err(RejectCode::BackendFailure),
                },
            )?;
            return Ok(());
        }
    };
    write_response(
        stream,
        SidecarResponse {
            sequence: request_sequence,
            result: Ok(()),
        },
    )?;
    send_sidecar_command(
        stream,
        session,
        sidecar_sequence,
        SidecarMessage::InputLease(offered),
    )?;
    send_sidecar_command(
        stream,
        session,
        sidecar_sequence,
        SidecarMessage::InputLease(active),
    )?;
    if let Some(acceptance) = &producer.config.acceptance {
        acceptance.entry_acknowledged(edge.route_generation);
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn handle_quarantine_recovery(
    stream: &mut UnixStream,
    producer: &ProducerState,
    session: &mut SidecarSession,
    sidecar_sequence: &mut u64,
    request_sequence: u64,
    credentials: SidecarPeerCredentials,
    recovery: QuarantineRecoveryRequest,
) -> Result<()> {
    let cleanup = match producer.prepare_recovery_cleanup(credentials, request_sequence, recovery) {
        Ok(cleanup) => cleanup,
        Err(error) => {
            eprintln!("viewflowd rejected fail-closed sidecar quarantine recovery: {error:#}");
            write_response(
                stream,
                SidecarResponse {
                    sequence: request_sequence,
                    result: Err(RejectCode::BackendFailure),
                },
            )?;
            return Ok(());
        }
    };
    write_response(
        stream,
        SidecarResponse {
            sequence: request_sequence,
            result: Ok(()),
        },
    )?;
    send_sidecar_command(
        stream,
        session,
        sidecar_sequence,
        SidecarMessage::CleanupComplete(cleanup),
    )
    .context("sidecar did not ACK exact recovery cleanup completion")
}

fn handle_input_event(
    stream: &mut UnixStream,
    runtime: &Handle,
    producer: &mut ProducerState,
    session: &mut SidecarSession,
    previous_session: SidecarSession,
    request_sequence: u64,
    event: &SidecarMessage,
) -> Result<()> {
    let cleanup_deadline = Instant::now() + INPUT_CLEANUP_DEADLINE;
    let result = runtime.block_on(producer.send_input(event));
    let (response, needs_cleanup) = match result {
        Ok(()) => (Ok(()), false),
        Err(error) => {
            *session = previous_session;
            eprintln!("viewflowd input sidecar event transport failed before ACK: {error:#}");
            (Err(RejectCode::BackendFailure), true)
        }
    };
    let write_result = write_response(
        stream,
        SidecarResponse {
            sequence: request_sequence,
            result: response,
        },
    );
    if needs_cleanup
        && let Err(error) = runtime.block_on(producer.shutdown_route_before(cleanup_deadline))
    {
        eprintln!(
            "viewflowd input producer event rollback failed after sidecar response: {error:#}"
        );
    }
    write_result.context("failed to write sidecar input response")
}

fn send_sidecar_command(
    stream: &mut UnixStream,
    session: &mut SidecarSession,
    sequence: &mut u64,
    message: SidecarMessage,
) -> Result<()> {
    let request = SidecarRequest {
        sequence: *sequence,
        message,
    };
    let previous_session = session.clone();
    session
        .accept_from(MessageDirection::DaemonToSidecar, request.clone())
        .map_err(|code| anyhow!("daemon sidecar command rejected locally: {code:?}"))?;
    write_request(stream, &request).context("failed to write sidecar command")?;
    let response = read_response(stream)
        .context("failed to read sidecar command response")?
        .ok_or_else(|| anyhow!("sidecar disconnected before command response"))?;
    if response.sequence != *sequence {
        *session = previous_session;
        bail!(
            "sidecar response sequence {} does not match command {}",
            response.sequence,
            *sequence
        );
    }
    if let Err(code) = response.result {
        *session = previous_session;
        bail!("sidecar rejected daemon command: {code:?}");
    }
    *sequence = sequence
        .checked_add(1)
        .ok_or_else(|| anyhow!("sidecar command sequence exhausted"))?;
    Ok(())
}

async fn run_before_deadline<F, T>(deadline: Instant, future: F) -> Option<T>
where
    F: Future<Output = T>,
{
    if Instant::now() >= deadline {
        return None;
    }
    tokio::select! {
        biased;
        () = sleep_until(deadline) => None,
        result = future => (Instant::now() < deadline).then_some(result),
    }
}

fn sidecar_apply_deadline_monotonic_ns(message: &SidecarMessage) -> Result<Option<u64>> {
    let deadline = match message {
        SidecarMessage::RelativePointer(input) => input.apply_deadline_monotonic_ns,
        SidecarMessage::PointerButton(input) => input.apply_deadline_monotonic_ns,
        SidecarMessage::PointerWheel(input) => input.apply_deadline_monotonic_ns,
        SidecarMessage::KeyboardHid(input) => input.apply_deadline_monotonic_ns,
        SidecarMessage::ReleaseAll(_) => return Ok(None),
        _ => bail!("sidecar message is not a peer input event"),
    };
    if deadline == 0 {
        bail!("captured input apply deadline must be non-zero");
    }
    Ok(Some(deadline))
}

fn acceptance_coverage_kinds(message: &SidecarMessage) -> Result<Vec<InputCoverageKind>> {
    let kinds = match message {
        SidecarMessage::RelativePointer(_) => vec![InputCoverageKind::PointerMotion],
        SidecarMessage::PointerButton(input) => {
            let kind = match (input.button, input.state) {
                (PointerButton::Left, InputSwitchState::Pressed) => {
                    InputCoverageKind::Button1Pressed
                }
                (PointerButton::Left, InputSwitchState::Released) => {
                    InputCoverageKind::Button1Released
                }
                (PointerButton::Middle, InputSwitchState::Pressed) => {
                    InputCoverageKind::Button2Pressed
                }
                (PointerButton::Middle, InputSwitchState::Released) => {
                    InputCoverageKind::Button2Released
                }
                (PointerButton::Right, InputSwitchState::Pressed) => {
                    InputCoverageKind::Button3Pressed
                }
                (PointerButton::Right, InputSwitchState::Released) => {
                    InputCoverageKind::Button3Released
                }
                (PointerButton::Back, InputSwitchState::Pressed) => {
                    InputCoverageKind::Button4Pressed
                }
                (PointerButton::Back, InputSwitchState::Released) => {
                    InputCoverageKind::Button4Released
                }
                (PointerButton::Forward, InputSwitchState::Pressed) => {
                    InputCoverageKind::Button5Pressed
                }
                (PointerButton::Forward, InputSwitchState::Released) => {
                    InputCoverageKind::Button5Released
                }
            };
            vec![kind]
        }
        SidecarMessage::PointerWheel(input) => {
            let mut kinds = Vec::with_capacity(2);
            if input.vertical_delta_detents != 0.0 {
                kinds.push(InputCoverageKind::VerticalWheel);
            }
            if input.horizontal_delta_detents != 0.0 {
                kinds.push(InputCoverageKind::HorizontalWheel);
            }
            if kinds.is_empty() {
                bail!("zero wheel input has no acceptance coverage");
            }
            kinds
        }
        SidecarMessage::KeyboardHid(input) => vec![match input.state {
            InputSwitchState::Pressed => InputCoverageKind::KeyboardPressed,
            InputSwitchState::Released => InputCoverageKind::KeyboardReleased,
        }],
        SidecarMessage::ReleaseAll(_) => bail!("ReleaseAll coverage is recorded from cleanup ACK"),
        _ => bail!("non-input sidecar message has no HID acceptance coverage"),
    };
    Ok(kinds)
}

fn map_capture_apply_deadline(
    capture_deadline_monotonic_ns: u64,
    linux_now_monotonic_ns: u64,
    sender_now_ns: u64,
    operation_now: Instant,
) -> Result<(Instant, u64)> {
    let remaining_ns = capture_deadline_monotonic_ns
        .checked_sub(linux_now_monotonic_ns)
        .ok_or_else(|| anyhow!("captured input apply deadline has already expired"))?;
    if remaining_ns == 0 {
        bail!("captured input apply deadline has already expired");
    }
    if remaining_ns > duration_ns(CAPTURE_TO_APPLY_TIMEOUT) {
        bail!(
            "captured input apply deadline exceeds the {} ms budget",
            CAPTURE_TO_APPLY_TIMEOUT.as_millis()
        );
    }
    let remaining = Duration::from_nanos(remaining_ns);
    Ok((
        operation_now + remaining,
        sender_now_ns
            .checked_add(remaining_ns)
            .ok_or_else(|| anyhow!("sender input deadline overflow"))?,
    ))
}

#[allow(unsafe_code)]
fn linux_monotonic_now_ns() -> Result<u64> {
    let mut timestamp = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `timestamp` is a valid writable timespec and CLOCK_MONOTONIC
    // requires no additional lifetime or ownership invariants.
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &raw mut timestamp) } != 0 {
        return Err(std::io::Error::last_os_error()).context("CLOCK_MONOTONIC read failed");
    }
    let seconds = u64::try_from(timestamp.tv_sec)
        .context("CLOCK_MONOTONIC returned a negative second count")?;
    let nanoseconds = u64::try_from(timestamp.tv_nsec)
        .context("CLOCK_MONOTONIC returned a negative nanosecond count")?;
    seconds
        .checked_mul(1_000_000_000)
        .and_then(|value| value.checked_add(nanoseconds))
        .ok_or_else(|| anyhow!("CLOCK_MONOTONIC nanosecond value overflow"))
}

fn sidecar_input_event(message: &SidecarMessage, sender_not_after_ns: u64) -> Result<InputEvent> {
    match *message {
        SidecarMessage::RelativePointer(RelativePointerInput {
            generation,
            target_device,
            event_sequence,
            apply_deadline_monotonic_ns: _,
            delta_x_dip,
            delta_y_dip,
        }) => Ok(InputEvent {
            lease_generation: generation,
            target_device,
            sequence: event_sequence,
            sender_not_after_ns,
            event: InputEventKind::PointerMotion(RelativePointerMotion {
                delta_x_dip,
                delta_y_dip,
            }),
        }),
        SidecarMessage::PointerButton(PointerButtonInput {
            generation,
            target_device,
            event_sequence,
            apply_deadline_monotonic_ns: _,
            button,
            state,
        }) => Ok(InputEvent {
            lease_generation: generation,
            target_device,
            sequence: event_sequence,
            sender_not_after_ns,
            event: InputEventKind::PointerButton(PointerButtonEvent { button, state }),
        }),
        SidecarMessage::PointerWheel(PointerWheelInput {
            generation,
            target_device,
            event_sequence,
            apply_deadline_monotonic_ns: _,
            vertical_delta_detents,
            horizontal_delta_detents,
        }) => Ok(InputEvent {
            lease_generation: generation,
            target_device,
            sequence: event_sequence,
            sender_not_after_ns,
            event: InputEventKind::PointerWheel(PointerWheelEvent {
                vertical_delta_detents,
                horizontal_delta_detents,
            }),
        }),
        SidecarMessage::KeyboardHid(KeyboardHidInput {
            generation,
            target_device,
            event_sequence,
            apply_deadline_monotonic_ns: _,
            usage_page,
            usage_id,
            state,
            repeat,
        }) => Ok(InputEvent {
            lease_generation: generation,
            target_device,
            sequence: event_sequence,
            sender_not_after_ns,
            event: InputEventKind::KeyboardHidUsage(KeyboardHidUsage {
                usage_page,
                usage_id,
                state,
                repeat,
            }),
        }),
        SidecarMessage::ReleaseAll(ReleaseAllInput {
            generation,
            target_device,
            event_sequence,
        }) => Ok(InputEvent {
            lease_generation: generation,
            target_device,
            sequence: event_sequence,
            sender_not_after_ns: 0,
            event: InputEventKind::ReleaseAll,
        }),
        _ => bail!("sidecar message is not a peer input event"),
    }
}

fn duration_ns(duration: Duration) -> u64 {
    u64::try_from(duration.as_nanos()).unwrap_or(u64::MAX)
}

const fn opposite_edge(edge: SidecarEdge) -> SidecarEdge {
    match edge {
        SidecarEdge::Left => SidecarEdge::Right,
        SidecarEdge::Right => SidecarEdge::Left,
        SidecarEdge::Top => SidecarEdge::Bottom,
        SidecarEdge::Bottom => SidecarEdge::Top,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    use viewflow_protocol::{
        InputAppliedAck, InputAppliedResult, InputLeaseRevokedAck, InputLeaseRevokedResult,
        InputSwitchState, PointerButton,
    };

    const TARGET: Id128 = Id128(0x22);

    #[test]
    fn sidecar_peer_credentials_require_owner_and_positive_pid() {
        let credentials = SidecarPeerCredentials { uid: 1000, pid: 42 };
        assert_eq!(
            validate_sidecar_peer_credentials(credentials, 1000).unwrap(),
            credentials
        );
        assert!(
            validate_sidecar_peer_credentials(SidecarPeerCredentials { uid: 1001, pid: 42 }, 1000)
                .is_err()
        );
        assert!(
            validate_sidecar_peer_credentials(SidecarPeerCredentials { uid: 1000, pid: 0 }, 1000)
                .is_err()
        );
    }

    fn fresh_capture_deadline() -> u64 {
        linux_monotonic_now_ns()
            .unwrap()
            .saturating_add(duration_ns(Duration::from_millis(30)))
    }

    fn applied_revoke_ack(revoke: InputLeaseRevoke) -> InputLeaseRevokedAck {
        InputLeaseRevokedAck {
            operation_id: revoke.operation_id,
            lease_generation: revoke.lease_generation,
            owner_device: revoke.owner_device,
            target_device: revoke.target_device,
            state: revoke.state,
            result: InputLeaseRevokedResult::Applied,
        }
    }

    fn assert_nested_input_deadlines() {
        assert!(crate::INPUT_APPLIED_TIMEOUT < CAPTURE_TO_APPLY_TIMEOUT);
        assert_eq!(CAPTURE_TO_APPLY_TIMEOUT, INPUT_CLEANUP_DEADLINE);
        assert!(INPUT_CLEANUP_DEADLINE < Duration::from_micros(33_334));
    }

    async fn assert_verified_cleanup_survives_empty_shutdown(producer: &mut ProducerState) {
        let cleanup = producer.last_cleanup.clone();
        producer.shutdown_route().await.unwrap();
        assert_eq!(producer.last_cleanup, cleanup);
        assert!(producer.verified_quiescence_cleanup().is_ok());
    }

    fn test_quiescence_arm(operation_id: &str) -> QuiescenceArm {
        QuiescenceArm {
            schema_version: 1,
            operation_id: operation_id.into(),
            daemon_pid: std::process::id(),
            daemon_start_ticks: 1,
            boot_id: "test-boot".into(),
            daemon_sha256: "00".repeat(32),
            armed_at_unix_ms: unix_time_ms().unwrap(),
        }
    }

    #[test]
    fn maps_modern_sidecar_input_without_reusing_request_sequence() {
        let cases = [
            SidecarMessage::RelativePointer(RelativePointerInput {
                generation: 41,
                target_device: TARGET,
                event_sequence: 7,
                apply_deadline_monotonic_ns: 100,
                delta_x_dip: 12.5,
                delta_y_dip: -4.0,
            }),
            SidecarMessage::PointerButton(PointerButtonInput {
                generation: 41,
                target_device: TARGET,
                event_sequence: 8,
                apply_deadline_monotonic_ns: 100,
                button: PointerButton::Back,
                state: InputSwitchState::Pressed,
            }),
            SidecarMessage::PointerWheel(PointerWheelInput {
                generation: 41,
                target_device: TARGET,
                event_sequence: 9,
                apply_deadline_monotonic_ns: 100,
                vertical_delta_detents: -0.5,
                horizontal_delta_detents: 1.25,
            }),
            SidecarMessage::KeyboardHid(KeyboardHidInput {
                generation: 41,
                target_device: TARGET,
                event_sequence: 10,
                apply_deadline_monotonic_ns: 100,
                usage_page: 7,
                usage_id: 4,
                state: InputSwitchState::Released,
                repeat: false,
            }),
            SidecarMessage::ReleaseAll(ReleaseAllInput {
                generation: 41,
                target_device: TARGET,
                event_sequence: 11,
            }),
        ];
        for (index, message) in cases.iter().enumerate() {
            let event = sidecar_input_event(message, 100).unwrap();
            assert_eq!(event.lease_generation, 41);
            assert_eq!(event.target_device, TARGET);
            assert_eq!(event.sequence, u64::try_from(index).unwrap() + 7);
            assert_eq!(
                event.sender_not_after_ns,
                if matches!(event.event, InputEventKind::ReleaseAll) {
                    0
                } else {
                    100
                }
            );
        }
    }

    #[test]
    fn capture_deadline_maps_one_remaining_budget_to_transport_and_receiver() {
        let operation_now = Instant::now();
        let remaining_ns = 12_345_678;
        let (operation_deadline, sender_not_after_ns) = map_capture_apply_deadline(
            9_000_000_000 + remaining_ns,
            9_000_000_000,
            700_000_000,
            operation_now,
        )
        .unwrap();
        assert_eq!(
            operation_deadline,
            operation_now + Duration::from_nanos(remaining_ns)
        );
        assert_eq!(sender_not_after_ns, 700_000_000 + remaining_ns);
    }

    #[test]
    fn capture_deadline_is_fail_closed_when_expired_or_over_budget() {
        let operation_now = Instant::now();
        assert!(
            map_capture_apply_deadline(99, 100, 1, operation_now)
                .unwrap_err()
                .to_string()
                .contains("already expired")
        );
        assert!(
            map_capture_apply_deadline(100, 100, 1, operation_now)
                .unwrap_err()
                .to_string()
                .contains("already expired")
        );
        assert!(
            map_capture_apply_deadline(
                100 + duration_ns(CAPTURE_TO_APPLY_TIMEOUT) + 1,
                100,
                1,
                operation_now,
            )
            .unwrap_err()
            .to_string()
            .contains("exceeds")
        );
    }

    #[test]
    fn release_all_is_the_only_unexpired_sidecar_input() {
        let release = SidecarMessage::ReleaseAll(ReleaseAllInput {
            generation: 41,
            target_device: TARGET,
            event_sequence: 11,
        });
        assert_eq!(sidecar_apply_deadline_monotonic_ns(&release).unwrap(), None);
        assert_eq!(
            sidecar_input_event(&release, u64::MAX)
                .unwrap()
                .sender_not_after_ns,
            0
        );
    }

    #[test]
    fn rejects_control_and_legacy_sidecar_messages_as_peer_input() {
        let edge = SidecarMessage::EdgeActivated(EdgeActivated {
            route_generation: 40,
            source_display: Id128(3),
            route_to: TARGET,
            edge: SidecarEdge::Right,
            edge_position: 0.5,
        });
        assert!(sidecar_input_event(&edge, 100).is_err());
        assert!(
            sidecar_input_event(
                &SidecarMessage::InputLease(SidecarInputLease {
                    lease: InputLease {
                        generation: 40,
                        owner: Id128(1),
                        route_to: TARGET,
                        state: InputLeaseState::Offered,
                    },
                    bound_peer: BoundPeerIdentity {
                        epoch: 1,
                        address: "127.0.0.1:41000".parse().unwrap(),
                    },
                }),
                100
            )
            .is_err()
        );
    }

    #[tokio::test]
    #[allow(clippy::too_many_lines)]
    async fn daemon_allocates_monotonic_generations_independent_of_sidecar() {
        let (registry, peers) = ProducerPeerRegistry::new();
        let (controls, mut received) = tokio::sync::mpsc::channel(16);
        let outbound = OutboundSender::new(controls);
        let ack_outbound = outbound.clone();
        let _registration = registry.register("127.0.0.1:41000".parse().unwrap(), outbound);
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observed_task = observed.clone();
        let collector = tokio::spawn(async move {
            while let Some(control) = received.recv().await {
                let event = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputEvent(event) => {
                        InputEvent::try_from(*event).ok()
                    }
                    _ => None,
                };
                let revoke = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(
                        revoke,
                    ) => InputLeaseRevoke::try_from(*revoke).ok(),
                    _ => None,
                };
                observed_task.lock().unwrap().push(control.payload);
                if let Some(sent) = control.sent {
                    let _ = sent.send(Ok(()));
                }
                if let Some(event) = event {
                    let _ = ack_outbound.input_acks.resolve(InputAppliedAck {
                        lease_generation: event.lease_generation,
                        target_device: event.target_device,
                        event_sequence: event.sequence,
                        result: InputAppliedResult::Applied,
                    });
                }
                if let Some(revoke) = revoke {
                    let _ = ack_outbound
                        .lease_revoke_acks
                        .resolve(applied_revoke_ack(revoke));
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        let first = producer
            .activate(EdgeActivated {
                route_generation: 9_000,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();
        assert_eq!((first.0.lease.generation, first.1.lease.generation), (1, 2));
        let active_route = producer.route.as_ref().unwrap();
        assert_eq!(active_route.source_display, Id128(3));
        assert_eq!(active_route.route_generation, 9_000);
        producer.shutdown_route().await.unwrap();
        let second = producer
            .activate(EdgeActivated {
                route_generation: 1,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();
        assert_eq!(
            (second.0.lease.generation, second.1.lease.generation),
            (4, 5)
        );
        let payloads = observed.lock().unwrap();
        assert_eq!(payloads.len(), 6);
        let generations = payloads
            .iter()
            .filter_map(|payload| match payload {
                viewflow_protocol::wire::control_envelope::Payload::InputLease(lease) => {
                    Some(lease.generation)
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(generations, [1, 2, 4, 5]);
        assert!(payloads.iter().any(|payload| matches!(
            payload,
            viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(revoke)
                if revoke.lease_generation == 3
        )));
        drop(payloads);
        collector.abort();
    }

    #[tokio::test]
    #[allow(clippy::too_many_lines)]
    async fn expired_capture_deadline_never_reaches_quic_and_preserves_cleanup() {
        let (registry, peers) = ProducerPeerRegistry::new();
        let (controls, mut received) = tokio::sync::mpsc::channel(16);
        let outbound = OutboundSender::new(controls);
        let ack_outbound = outbound.clone();
        let _registration = registry.register("127.0.0.1:41000".parse().unwrap(), outbound);
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observed_task = observed.clone();
        let collector = tokio::spawn(async move {
            while let Some(control) = received.recv().await {
                let release = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputEvent(event) => {
                        InputEvent::try_from(*event)
                            .ok()
                            .filter(|event| matches!(event.event, InputEventKind::ReleaseAll))
                    }
                    _ => None,
                };
                let revoke = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(
                        revoke,
                    ) => InputLeaseRevoke::try_from(*revoke).ok(),
                    _ => None,
                };
                observed_task.lock().unwrap().push(control.payload);
                if let Some(sent) = control.sent {
                    let _ = sent.send(Ok(()));
                }
                if let Some(event) = release {
                    let _ = ack_outbound.input_acks.resolve(InputAppliedAck {
                        lease_generation: event.lease_generation,
                        target_device: event.target_device,
                        event_sequence: event.sequence,
                        result: InputAppliedResult::Applied,
                    });
                }
                if let Some(revoke) = revoke {
                    let _ = ack_outbound
                        .lease_revoke_acks
                        .resolve(applied_revoke_ack(revoke));
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        producer
            .activate(EdgeActivated {
                route_generation: 1,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();
        tokio::task::yield_now().await;
        observed.lock().unwrap().clear();

        let expired_deadline = linux_monotonic_now_ns().unwrap().saturating_sub(1);
        let error = producer
            .send_input(&SidecarMessage::RelativePointer(RelativePointerInput {
                generation: 2,
                target_device: TARGET,
                event_sequence: 1,
                apply_deadline_monotonic_ns: expired_deadline,
                delta_x_dip: 12.0,
                delta_y_dip: -3.0,
            }))
            .await
            .unwrap_err();
        assert!(error.to_string().contains("already expired"));
        tokio::task::yield_now().await;
        assert!(observed.lock().unwrap().is_empty());
        let route = producer.route.as_ref().expect("route remains quarantined");
        assert_eq!(route.last_event_sequence, 0);

        producer.shutdown_route().await.unwrap();
        let payloads = observed.lock().unwrap();
        assert_eq!(payloads.len(), 2);
        assert!(matches!(
            &payloads[0],
            viewflow_protocol::wire::control_envelope::Payload::InputEvent(event)
                if matches!(
                    InputEvent::try_from(*event).unwrap().event,
                    InputEventKind::ReleaseAll
                )
        ));
        assert!(matches!(
            &payloads[1],
            viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(revoke)
                if revoke.lease_generation == 3
        ));
        drop(payloads);
        assert!(producer.route.is_none());
        assert!(producer.verified_quiescence_cleanup().is_ok());
        collector.abort();
    }

    #[tokio::test]
    async fn reconnect_rebuilds_lease_before_confirming_pending_event() {
        let (registry, peers) = ProducerPeerRegistry::new();
        let (first_outbound, mut first_received) = tokio::sync::mpsc::channel(8);
        let first_registration =
            registry.register("127.0.0.1:41000".parse().unwrap(), first_outbound.into());
        let first_collector = tokio::spawn(async move {
            while let Some(control) = first_received.recv().await {
                if let Some(sent) = control.sent {
                    let _ = sent.send(Ok(()));
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        producer
            .activate(EdgeActivated {
                route_generation: 500,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();
        drop(first_registration);
        first_collector.abort();

        let pending = tokio::spawn(async move {
            producer
                .send_input(&SidecarMessage::RelativePointer(RelativePointerInput {
                    generation: 2,
                    target_device: TARGET,
                    event_sequence: 1,
                    apply_deadline_monotonic_ns: fresh_capture_deadline(),
                    delta_x_dip: 12.0,
                    delta_y_dip: -3.0,
                }))
                .await
                .unwrap();
            producer
        });
        tokio::task::yield_now().await;
        assert!(!pending.is_finished());

        let (second_outbound, mut second_received) = tokio::sync::mpsc::channel(8);
        let _second_registration =
            registry.register("127.0.0.1:41000".parse().unwrap(), second_outbound.into());
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observed_task = observed.clone();
        let second_collector = tokio::spawn(async move {
            while let Some(control) = second_received.recv().await {
                observed_task.lock().unwrap().push(control.payload);
                if let Some(sent) = control.sent {
                    let _ = sent.send(Ok(()));
                }
            }
        });
        let producer = pending.await.unwrap();
        let payloads = observed.lock().unwrap();
        assert_eq!(payloads.len(), 3);
        assert!(matches!(
            &payloads[0],
            viewflow_protocol::wire::control_envelope::Payload::InputLease(lease)
                if lease.generation == 1
        ));
        assert!(matches!(
            &payloads[1],
            viewflow_protocol::wire::control_envelope::Payload::InputLease(lease)
                if lease.generation == 2
        ));
        assert!(matches!(
            &payloads[2],
            viewflow_protocol::wire::control_envelope::Payload::InputEvent(event)
                if event.event_sequence == 1 && event.lease_generation == 2
        ));
        drop(payloads);
        assert_eq!(
            producer
                .route
                .as_ref()
                .expect("route stays active after reconnect")
                .last_event_sequence,
            1
        );
        assert_eq!(producer.aborted_peer_epochs, [1]);
        second_collector.abort();
    }

    #[tokio::test]
    async fn newer_registry_epoch_does_not_replace_a_live_bound_peer() {
        let (registry, peers) = ProducerPeerRegistry::new();
        let (first_controls, mut first_received) = tokio::sync::mpsc::channel(16);
        let first_outbound = OutboundSender::new(first_controls);
        let first_ack_outbound = first_outbound.clone();
        let _first_registration =
            registry.register("127.0.0.1:41000".parse().unwrap(), first_outbound);
        let first_observed = Arc::new(Mutex::new(Vec::new()));
        let first_observed_task = first_observed.clone();
        let first_collector = tokio::spawn(async move {
            while let Some(control) = first_received.recv().await {
                let event = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputEvent(event) => {
                        InputEvent::try_from(*event).ok()
                    }
                    _ => None,
                };
                let revoke = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(
                        revoke,
                    ) => InputLeaseRevoke::try_from(*revoke).ok(),
                    _ => None,
                };
                first_observed_task.lock().unwrap().push(control.payload);
                if let Some(sent) = control.sent {
                    let _ = sent.send(Ok(()));
                }
                if let Some(event) = event {
                    let _ = first_ack_outbound.input_acks.resolve(InputAppliedAck {
                        lease_generation: event.lease_generation,
                        target_device: event.target_device,
                        event_sequence: event.sequence,
                        result: InputAppliedResult::Applied,
                    });
                }
                if let Some(revoke) = revoke {
                    let _ = first_ack_outbound
                        .lease_revoke_acks
                        .resolve(applied_revoke_ack(revoke));
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        producer
            .activate(EdgeActivated {
                route_generation: 1,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();

        let (second_outbound, mut second_received) = tokio::sync::mpsc::channel(8);
        let _second_registration =
            registry.register("127.0.0.1:42000".parse().unwrap(), second_outbound.into());
        producer
            .send_input(&SidecarMessage::RelativePointer(RelativePointerInput {
                generation: 2,
                target_device: TARGET,
                event_sequence: 1,
                apply_deadline_monotonic_ns: fresh_capture_deadline(),
                delta_x_dip: 4.0,
                delta_y_dip: -2.0,
            }))
            .await
            .unwrap();
        producer.shutdown_route().await.unwrap();

        assert!(second_received.try_recv().is_err());
        let payloads = first_observed.lock().unwrap();
        let event_sequences = payloads
            .iter()
            .filter_map(|payload| match payload {
                viewflow_protocol::wire::control_envelope::Payload::InputEvent(event) => {
                    Some(event.event_sequence)
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(event_sequences, [1, 2]);
        assert!(payloads.iter().any(|payload| matches!(
            payload,
            viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(revoke)
                if revoke.lease_generation == 3
        )));
        drop(payloads);
        assert!(producer.route.is_none());
        assert!(producer.aborted_peer_epochs.is_empty());
        first_collector.abort();
    }

    #[tokio::test]
    #[allow(clippy::too_many_lines)]
    async fn timed_out_input_cleanup_advances_sequence_and_still_revokes() {
        let (registry, peers) = ProducerPeerRegistry::new();
        let (controls, mut received) = tokio::sync::mpsc::channel(16);
        let outbound = OutboundSender::new(controls);
        let ack_outbound = outbound.clone();
        let _registration = registry.register("127.0.0.1:41000".parse().unwrap(), outbound);
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observed_task = observed.clone();
        let collector = tokio::spawn(async move {
            while let Some(control) = received.recv().await {
                let release = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputEvent(event) => {
                        InputEvent::try_from(*event)
                            .ok()
                            .filter(|event| matches!(event.event, InputEventKind::ReleaseAll))
                    }
                    _ => None,
                };
                let revoke = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(
                        revoke,
                    ) => InputLeaseRevoke::try_from(*revoke).ok(),
                    _ => None,
                };
                observed_task.lock().unwrap().push(control.payload);
                if let Some(sent) = control.sent {
                    let _ = sent.send(Ok(()));
                }
                if let Some(event) = release {
                    let _ = ack_outbound.input_acks.resolve(InputAppliedAck {
                        lease_generation: event.lease_generation,
                        target_device: event.target_device,
                        event_sequence: event.sequence,
                        result: InputAppliedResult::Applied,
                    });
                }
                if let Some(revoke) = revoke {
                    let _ = ack_outbound
                        .lease_revoke_acks
                        .resolve(applied_revoke_ack(revoke));
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        producer
            .activate(EdgeActivated {
                route_generation: 1,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();

        let result = producer
            .send_input(&SidecarMessage::RelativePointer(RelativePointerInput {
                generation: 2,
                target_device: TARGET,
                event_sequence: 1,
                apply_deadline_monotonic_ns: fresh_capture_deadline(),
                delta_x_dip: 1.0,
                delta_y_dip: 0.0,
            }))
            .await;
        assert!(result.is_err());
        assert_eq!(
            producer
                .route
                .as_ref()
                .expect("uncertain delivery keeps cleanup context")
                .last_event_sequence,
            1
        );
        producer.shutdown_route().await.unwrap();
        assert!(producer.route.is_none());
        assert!(producer.aborted_peer_epochs.is_empty());
        assert_verified_cleanup_survives_empty_shutdown(&mut producer).await;

        let payloads = observed.lock().unwrap();
        let event_sequences = payloads
            .iter()
            .filter_map(|payload| match payload {
                viewflow_protocol::wire::control_envelope::Payload::InputEvent(event) => {
                    Some(event.event_sequence)
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(event_sequences, [1, 2]);
        let lease_generations = payloads
            .iter()
            .filter_map(|payload| match payload {
                viewflow_protocol::wire::control_envelope::Payload::InputLease(lease) => {
                    Some(lease.generation)
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(lease_generations, [1, 2]);
        assert!(payloads.iter().any(|payload| matches!(
            payload,
            viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(revoke)
                if revoke.lease_generation == 3
        )));
        drop(payloads);
        collector.abort();
    }

    #[tokio::test]
    async fn release_all_sequence_overflow_aborts_before_cleanup_send() {
        let (registry, peers) = ProducerPeerRegistry::new();
        let (controls, mut received) = tokio::sync::mpsc::channel(16);
        let outbound = OutboundSender::new(controls);
        let _registration = registry.register("127.0.0.1:41000".parse().unwrap(), outbound);
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observed_task = observed.clone();
        let collector = tokio::spawn(async move {
            while let Some(control) = received.recv().await {
                observed_task.lock().unwrap().push(control.payload);
                if let Some(sent) = control.sent {
                    let _ = sent.send(Ok(()));
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        producer
            .activate(EdgeActivated {
                route_generation: 1,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();
        producer
            .route
            .as_mut()
            .expect("active route must retain cleanup sequence")
            .last_event_sequence = u64::MAX;

        let error = producer.shutdown_route().await.unwrap_err();
        assert!(error.to_string().contains("input sequence cannot advance"));
        assert!(producer.route.is_none());
        assert_eq!(producer.aborted_peer_epochs, [1]);
        assert!(producer.last_cleanup.is_none());
        assert!(producer.quiescence_uncertainty.is_some());
        assert!(producer.shutdown_route().await.is_err());

        tokio::task::yield_now().await;
        let payloads = observed.lock().unwrap();
        assert!(!payloads.iter().any(|payload| matches!(
            payload,
            viewflow_protocol::wire::control_envelope::Payload::InputEvent(_)
                | viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(_)
        )));
        drop(payloads);
        collector.abort();
    }

    #[tokio::test]
    async fn release_all_transport_success_without_applied_ack_aborts_bound_peer() {
        let (registry, peers) = ProducerPeerRegistry::new();
        let (controls, mut received) = tokio::sync::mpsc::channel(16);
        let outbound = OutboundSender::new(controls);
        let _registration = registry.register("127.0.0.1:41000".parse().unwrap(), outbound);
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observed_task = observed.clone();
        let collector = tokio::spawn(async move {
            while let Some(control) = received.recv().await {
                observed_task.lock().unwrap().push(control.payload);
                if let Some(sent) = control.sent {
                    let _ = sent.send(Ok(()));
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        producer
            .activate(EdgeActivated {
                route_generation: 1,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();
        producer
            .route
            .as_mut()
            .expect("active route must retain cleanup sequence")
            .last_event_sequence = 1;

        let error = producer.shutdown_route().await.unwrap_err();
        assert!(error.to_string().contains("bound peer was aborted"));
        assert!(producer.route.is_none());
        assert_eq!(producer.aborted_peer_epochs, [1]);
        let sticky_error = producer.shutdown_route().await.unwrap_err();
        assert!(sticky_error.to_string().contains("fail-closed"));
        assert!(producer.last_cleanup.is_none());
        assert!(producer.verified_quiescence_cleanup().is_err());
        let payloads = observed.lock().unwrap();
        assert!(payloads.iter().any(|payload| matches!(
            payload,
            viewflow_protocol::wire::control_envelope::Payload::InputEvent(event)
                if event.event_sequence == 2
        )));
        assert!(!payloads.iter().any(|payload| matches!(
            payload,
            viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(revoke)
                if revoke.lease_generation == 3
        )));
        drop(payloads);
        collector.abort();
    }

    #[tokio::test]
    async fn release_all_applied_but_revoke_failure_aborts_bound_peer() {
        let (registry, peers) = ProducerPeerRegistry::new();
        let (controls, mut received) = tokio::sync::mpsc::channel(16);
        let outbound = OutboundSender::new(controls);
        let ack_outbound = outbound.clone();
        let _registration = registry.register("127.0.0.1:41000".parse().unwrap(), outbound);
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observed_task = observed.clone();
        let collector = tokio::spawn(async move {
            while let Some(control) = received.recv().await {
                let release = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputEvent(event) => {
                        InputEvent::try_from(*event)
                            .ok()
                            .filter(|event| matches!(event.event, InputEventKind::ReleaseAll))
                    }
                    _ => None,
                };
                let revoke = matches!(
                    &control.payload,
                    viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(revoke)
                        if revoke.lease_generation == 3
                );
                observed_task.lock().unwrap().push(control.payload);
                if let Some(sent) = control.sent {
                    if revoke {
                        let _ = sent.send(Err(crate::OutboundSendError(
                            "test revoke confirmation failure".into(),
                        )));
                    } else {
                        let _ = sent.send(Ok(()));
                    }
                }
                if let Some(event) = release {
                    let _ = ack_outbound.input_acks.resolve(InputAppliedAck {
                        lease_generation: event.lease_generation,
                        target_device: event.target_device,
                        event_sequence: event.sequence,
                        result: InputAppliedResult::Applied,
                    });
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        producer
            .activate(EdgeActivated {
                route_generation: 1,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();
        producer
            .route
            .as_mut()
            .expect("active route must retain cleanup sequence")
            .last_event_sequence = 1;

        let error = producer.shutdown_route().await.unwrap_err();
        assert!(error.to_string().contains("bound peer was aborted"));
        assert!(producer.route.is_none());
        assert_eq!(producer.aborted_peer_epochs, [1]);
        let payloads = observed.lock().unwrap();
        assert!(payloads.iter().any(|payload| matches!(
            payload,
            viewflow_protocol::wire::control_envelope::Payload::InputEvent(event)
                if event.event_sequence == 2
        )));
        assert!(payloads.iter().any(|payload| matches!(
            payload,
            viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(revoke)
                if revoke.lease_generation == 3
        )));
        drop(payloads);
        collector.abort();
    }

    #[tokio::test]
    async fn forced_abort_stays_pinned_to_old_peer_when_new_epoch_is_registered() {
        let (registry, peers) = ProducerPeerRegistry::new();
        let (first_outbound, mut first_received) = tokio::sync::mpsc::channel(16);
        let first_sender = OutboundSender::new(first_outbound);
        let _first_registration =
            registry.register("127.0.0.1:41000".parse().unwrap(), first_sender);
        let first_observed = Arc::new(Mutex::new(Vec::new()));
        let first_observed_task = first_observed.clone();
        let first_collector = tokio::spawn(async move {
            while let Some(control) = first_received.recv().await {
                first_observed_task.lock().unwrap().push(control.payload);
                if let Some(sent) = control.sent {
                    let _ = sent.send(Ok(()));
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        producer
            .activate(EdgeActivated {
                route_generation: 1,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();
        producer
            .route
            .as_mut()
            .expect("active route must retain cleanup sequence")
            .last_event_sequence = 1;

        let (second_outbound, mut second_received) = tokio::sync::mpsc::channel(8);
        let _second_registration =
            registry.register("127.0.0.1:42000".parse().unwrap(), second_outbound.into());
        let error = producer.shutdown_route().await.unwrap_err();

        assert!(error.to_string().contains("bound peer was aborted"));
        assert!(producer.route.is_none());
        assert_eq!(producer.aborted_peer_epochs, [1]);
        assert!(second_received.try_recv().is_err());
        let payloads = first_observed.lock().unwrap();
        assert!(payloads.iter().any(|payload| matches!(
            payload,
            viewflow_protocol::wire::control_envelope::Payload::InputEvent(event)
                if event.event_sequence == 2
        )));
        assert!(!payloads.iter().any(|payload| matches!(
            payload,
            viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(revoke)
                if revoke.lease_generation == 3
        )));
        drop(payloads);
        first_collector.abort();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[allow(clippy::too_many_lines)]
    async fn uncertain_input_responds_before_absolute_cleanup_deadline() {
        assert_nested_input_deadlines();

        let (registry, peers) = ProducerPeerRegistry::new();
        let (controls, mut received) = tokio::sync::mpsc::channel(16);
        let _registration = registry.register(
            "127.0.0.1:41000".parse().unwrap(),
            OutboundSender::new(controls),
        );
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observed_task = observed.clone();
        let collector = tokio::spawn(async move {
            let mut input_count = 0_u8;
            while let Some(control) = received.recv().await {
                let is_input = matches!(
                    &control.payload,
                    viewflow_protocol::wire::control_envelope::Payload::InputEvent(_)
                );
                if is_input {
                    input_count += 1;
                }
                let delay_confirmation = is_input && input_count == 2;
                observed_task.lock().unwrap().push(control.payload);
                if let Some(sent) = control.sent {
                    if delay_confirmation {
                        tokio::spawn(async move {
                            tokio::time::sleep(Duration::from_millis(50)).await;
                            let _ = sent.send(Ok(()));
                        });
                    } else {
                        let _ = sent.send(Ok(()));
                    }
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        producer
            .activate(EdgeActivated {
                route_generation: 1,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();

        let (mut client, mut server) = UnixStream::pair().unwrap();
        // The production deadline is asserted above and enforced from the
        // capture timestamp. Give this blocking test reader scheduler grace:
        // SO_RCVTIMEO starts before the spawn-blocking worker is scheduled.
        client
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        let runtime = Handle::current();
        let server_task = task::spawn_blocking(move || {
            let mut session = SidecarSession::default();
            let previous_session = session.clone();
            let event = SidecarMessage::RelativePointer(RelativePointerInput {
                generation: 2,
                target_device: TARGET,
                event_sequence: 1,
                apply_deadline_monotonic_ns: fresh_capture_deadline(),
                delta_x_dip: 1.0,
                delta_y_dip: 0.0,
            });
            let result = handle_input_event(
                &mut server,
                &runtime,
                &mut producer,
                &mut session,
                previous_session,
                7,
                &event,
            );
            (producer, result)
        });

        let response = read_response(&mut client)
            .expect("uncertain delivery must return an explicit bounded IPC response")
            .expect("daemon must return an explicit uncertain response");
        assert_eq!(response.sequence, 7);
        assert_eq!(response.result, Err(RejectCode::BackendFailure));
        drop(client);

        let (producer, result) = timeout(Duration::from_secs(1), server_task)
            .await
            .expect("post-response cleanup must remain bounded")
            .unwrap();
        result.unwrap();
        assert!(producer.route.is_none());
        assert_eq!(producer.aborted_peer_epochs, [1]);
        let payloads = observed.lock().unwrap();
        assert!(!payloads.iter().any(|payload| matches!(
            payload,
            viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(revoke)
                if revoke.lease_generation == 3
        )));
        drop(payloads);
        collector.abort();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stale_registration_cannot_unregister_a_concurrent_replacement() {
        for index in 0..128_u16 {
            let (registry, mut peers) = ProducerPeerRegistry::new();
            let (first_outbound, _first_received) = tokio::sync::mpsc::channel(1);
            let first_registration =
                registry.register("127.0.0.1:41000".parse().unwrap(), first_outbound.into());
            let (second_outbound, _second_received) = tokio::sync::mpsc::channel(1);
            let second_address: SocketAddr =
                format!("127.0.0.1:{}", 42000 + index).parse().unwrap();
            let barrier = Arc::new(tokio::sync::Barrier::new(2));

            let drop_barrier = barrier.clone();
            let drop_task = tokio::spawn(async move {
                drop_barrier.wait().await;
                drop(first_registration);
            });
            let register_barrier = barrier.clone();
            let replacement_registry = registry.clone();
            let register_task = tokio::spawn(async move {
                register_barrier.wait().await;
                replacement_registry.register(second_address, second_outbound.into())
            });
            let (drop_result, register_result) = tokio::join!(drop_task, register_task);
            drop_result.unwrap();
            let replacement_registration = register_result.unwrap();

            let current = timeout(Duration::from_millis(100), peers.current())
                .await
                .expect("replacement peer should remain registered")
                .unwrap();
            assert_eq!(current.address, second_address);
            drop(replacement_registration);
            assert!(peers.receiver.borrow().is_none());
        }
    }

    #[tokio::test]
    async fn active_unbound_cleanup_is_fail_closed_and_writes_no_receipt() {
        let (_registry, peers) = ProducerPeerRegistry::new();
        let unique = unix_time_ms().unwrap();
        let directory = std::env::temp_dir().join(format!(
            "viewflow-unbound-quiesce-test-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let receipt = directory.join("quiescence.json");
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: Some(receipt.clone()),
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        producer.route_ever_activated = true;
        producer.route = Some(ActiveRoute {
            offered: InputLease {
                generation: 1,
                owner: Id128(0x11),
                route_to: TARGET,
                state: InputLeaseState::Offered,
            },
            active: InputLease {
                generation: 2,
                owner: Id128(0x11),
                route_to: TARGET,
                state: InputLeaseState::Active,
            },
            source_display: Id128(3),
            route_generation: 1,
            last_event_sequence: 0,
            bound_peer: None,
        });

        let started = Instant::now();
        let error = producer.shutdown_route().await.unwrap_err();
        assert!(error.to_string().contains("no exact bound peer"));
        assert!(producer.route.is_some());
        assert!(producer.aborted_peer_epochs.is_empty());
        assert!(producer.last_cleanup.is_none());
        assert!(producer.quiescence_uncertainty.is_some());
        assert!(started.elapsed() < Duration::from_millis(100));

        let finalization =
            producer.finalize_quiescence(test_quiescence_arm("active-unbound-must-fail"));
        assert!(finalization.is_err());
        assert!(!receipt.exists());
        fs::remove_dir(&directory).unwrap();
    }

    #[tokio::test]
    async fn never_activated_route_is_the_only_no_active_receipt_shape() {
        let (_registry, peers) = ProducerPeerRegistry::new();
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );

        producer.shutdown_route().await.unwrap();
        let cleanup = producer.verified_quiescence_cleanup().unwrap();
        let json = serde_json::to_value(cleanup).unwrap();
        assert_eq!(json["route_ever_activated"], false);
        assert_eq!(json["route_was_active"], false);
        assert!(json["source_display"].is_null());
        assert!(json["route_generation"].is_null());
        assert_eq!(
            json["release_all"]["status"],
            "not_required_no_active_route"
        );
        assert_eq!(
            json["lease_revoke"]["status"],
            "not_required_no_active_route"
        );
        assert!(!json.to_string().contains("not_required_no_bound_peer"));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn failed_remote_cleanup_suppresses_return_to_local_commands() {
        let (_registry, peers) = ProducerPeerRegistry::new();
        let (mut client, mut server) = UnixStream::pair().unwrap();
        let runtime = Handle::current();
        let server_task = task::spawn_blocking(move || {
            let mut producer = ProducerState::new(
                SidecarProducerConfig {
                    socket_path: "/unused".into(),
                    local_device: Id128(0x11),
                    target_device: TARGET,
                    clock: ProcessClock::new(),
                    quiesce_proof: None,
                    quiesce_arm_file: None,
                    artifact_hashes: BTreeMap::new(),
                    acceptance: None,
                },
                peers,
            );
            producer.route_ever_activated = true;
            producer.route = Some(ActiveRoute {
                offered: InputLease {
                    generation: 1,
                    owner: Id128(0x11),
                    route_to: TARGET,
                    state: InputLeaseState::Offered,
                },
                active: InputLease {
                    generation: 2,
                    owner: Id128(0x11),
                    route_to: TARGET,
                    state: InputLeaseState::Active,
                },
                source_display: Id128(3),
                route_generation: 1,
                last_event_sequence: 7,
                bound_peer: None,
            });
            let mut session = SidecarSession::default();
            let previous_session = session.clone();
            let mut sidecar_sequence = 1;
            let result = handle_edge_event(
                &mut server,
                &runtime,
                &mut producer,
                &mut session,
                previous_session,
                &mut sidecar_sequence,
                9,
                EdgeActivated {
                    route_generation: 1,
                    source_display: Id128(3),
                    route_to: Id128(0x11),
                    edge: SidecarEdge::Left,
                    edge_position: 0.25,
                },
            );
            (producer, sidecar_sequence, result)
        });

        let (producer, sidecar_sequence, result) = server_task.await.unwrap();
        result.unwrap();
        let response = read_response(&mut client)
            .unwrap()
            .expect("return-to-local failure must receive an explicit rejection");
        assert_eq!(response.sequence, 9);
        assert_eq!(response.result, Err(RejectCode::BackendFailure));
        assert!(read_request(&mut client).unwrap().is_none());
        assert_eq!(sidecar_sequence, 1);
        assert!(producer.route.is_some());
        assert!(producer.quiescence_uncertainty.is_some());
        assert!(producer.last_cleanup.is_none());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[allow(clippy::too_many_lines)]
    async fn normal_cleanup_complete_is_acked_before_any_local_fallback() {
        let (registry, peers) = ProducerPeerRegistry::new();
        let (controls, mut received) = tokio::sync::mpsc::channel(16);
        let outbound = OutboundSender::new(controls);
        let ack_outbound = outbound.clone();
        let peer_address = "127.0.0.1:41000".parse().unwrap();
        let _registration = registry.register(peer_address, outbound);
        let collector = tokio::spawn(async move {
            while let Some(control) = received.recv().await {
                let event = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputEvent(event) => {
                        InputEvent::try_from(*event).ok()
                    }
                    _ => None,
                };
                let revoke = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(
                        revoke,
                    ) => InputLeaseRevoke::try_from(*revoke).ok(),
                    _ => None,
                };
                if let Some(sent) = control.sent {
                    let _ = sent.send(Ok(()));
                }
                if let Some(event) = event {
                    let _ = ack_outbound.input_acks.resolve(InputAppliedAck {
                        lease_generation: event.lease_generation,
                        target_device: event.target_device,
                        event_sequence: event.sequence,
                        result: InputAppliedResult::Applied,
                    });
                }
                if let Some(revoke) = revoke {
                    let _ = ack_outbound
                        .lease_revoke_acks
                        .resolve(applied_revoke_ack(revoke));
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        let leases = producer
            .activate(EdgeActivated {
                route_generation: 99,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();
        let (mut client, mut server) = UnixStream::pair().unwrap();
        let runtime = Handle::current();
        let server_task = task::spawn_blocking(move || {
            let mut session = SidecarSession::default();
            session
                .accept_from(
                    MessageDirection::DaemonToSidecar,
                    SidecarRequest {
                        sequence: 1,
                        message: SidecarMessage::InputLease(leases.0),
                    },
                )
                .unwrap();
            session
                .accept_from(
                    MessageDirection::DaemonToSidecar,
                    SidecarRequest {
                        sequence: 2,
                        message: SidecarMessage::InputLease(leases.1),
                    },
                )
                .unwrap();
            let mut sidecar_sequence = 3;
            let previous_session = session.clone();
            let result = handle_edge_event(
                &mut server,
                &runtime,
                &mut producer,
                &mut session,
                previous_session,
                &mut sidecar_sequence,
                9,
                EdgeActivated {
                    route_generation: 99,
                    source_display: Id128(3),
                    route_to: Id128(0x11),
                    edge: SidecarEdge::Left,
                    edge_position: 0.25,
                },
            );
            (producer, sidecar_sequence, result)
        });

        let edge_response = read_response(&mut client).unwrap().unwrap();
        assert_eq!(edge_response.sequence, 9);
        assert_eq!(edge_response.result, Ok(()));

        let cleanup_request = read_request(&mut client).unwrap().unwrap();
        assert_eq!(cleanup_request.sequence, 3);
        let cleanup = match cleanup_request.message {
            SidecarMessage::CleanupComplete(cleanup) => cleanup,
            other => panic!("expected CleanupComplete before fallback, got {other:?}"),
        };
        assert_eq!(cleanup.mode, CleanupMode::Normal);
        assert_eq!(cleanup.recovery_request_sequence, 0);
        assert_eq!(cleanup.marker_last_sequence, 0);
        assert_eq!(cleanup.observed_last_sequence, 0);
        assert_eq!(cleanup.sequence_disposition, SequenceDisposition::Exact);
        assert_eq!(cleanup.release_all.event_sequence, 1);
        assert_eq!(cleanup.bound_peer.epoch, 1);
        assert_eq!(cleanup.bound_peer.address, peer_address);
        write_response(
            &mut client,
            SidecarResponse {
                sequence: 3,
                result: Ok(()),
            },
        )
        .unwrap();

        let return_request = read_request(&mut client).unwrap().unwrap();
        assert!(matches!(
            return_request.message,
            SidecarMessage::ReturnToLocal(_)
        ));
        write_response(
            &mut client,
            SidecarResponse {
                sequence: return_request.sequence,
                result: Ok(()),
            },
        )
        .unwrap();
        let revoke_request = read_request(&mut client).unwrap().unwrap();
        assert!(matches!(
            revoke_request.message,
            SidecarMessage::InputLease(SidecarInputLease {
                lease: InputLease {
                    state: InputLeaseState::Revoked,
                    ..
                },
                bound_peer: BoundPeerIdentity { epoch: 1, .. },
            })
        ));
        write_response(
            &mut client,
            SidecarResponse {
                sequence: revoke_request.sequence,
                result: Ok(()),
            },
        )
        .unwrap();

        let (producer, sidecar_sequence, result) = server_task.await.unwrap();
        result.unwrap();
        assert_eq!(sidecar_sequence, 6);
        assert!(producer.route.is_none());
        assert_eq!(
            producer.last_runtime_marker.unwrap().sha256().unwrap(),
            cleanup.marker_sha256
        );
        collector.abort();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[allow(clippy::too_many_lines)]
    async fn lost_normal_cleanup_ack_never_emits_ordinary_deskflow_fallback() {
        let (registry, peers) = ProducerPeerRegistry::new();
        let (controls, mut received) = tokio::sync::mpsc::channel(16);
        let outbound = OutboundSender::new(controls);
        let ack_outbound = outbound.clone();
        let _registration = registry.register("127.0.0.1:41000".parse().unwrap(), outbound);
        let collector = tokio::spawn(async move {
            while let Some(control) = received.recv().await {
                let event = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputEvent(event) => {
                        InputEvent::try_from(*event).ok()
                    }
                    _ => None,
                };
                let revoke = match &control.payload {
                    viewflow_protocol::wire::control_envelope::Payload::InputLeaseRevoke(
                        revoke,
                    ) => InputLeaseRevoke::try_from(*revoke).ok(),
                    _ => None,
                };
                if let Some(sent) = control.sent {
                    let _ = sent.send(Ok(()));
                }
                if let Some(event) = event {
                    let _ = ack_outbound.input_acks.resolve(InputAppliedAck {
                        lease_generation: event.lease_generation,
                        target_device: event.target_device,
                        event_sequence: event.sequence,
                        result: InputAppliedResult::Applied,
                    });
                }
                if let Some(revoke) = revoke {
                    let _ = ack_outbound
                        .lease_revoke_acks
                        .resolve(applied_revoke_ack(revoke));
                }
            }
        });
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        let leases = producer
            .activate(EdgeActivated {
                route_generation: 99,
                source_display: Id128(3),
                route_to: TARGET,
                edge: SidecarEdge::Right,
                edge_position: 0.5,
            })
            .await
            .unwrap();
        let (mut client, mut server) = UnixStream::pair().unwrap();
        let runtime = Handle::current();
        let server_task = task::spawn_blocking(move || {
            let mut session = SidecarSession::default();
            for (sequence, lease) in [(1, leases.0), (2, leases.1)] {
                session
                    .accept_from(
                        MessageDirection::DaemonToSidecar,
                        SidecarRequest {
                            sequence,
                            message: SidecarMessage::InputLease(lease),
                        },
                    )
                    .unwrap();
            }
            let previous_session = session.clone();
            let mut sidecar_sequence = 3;
            let result = handle_edge_event(
                &mut server,
                &runtime,
                &mut producer,
                &mut session,
                previous_session,
                &mut sidecar_sequence,
                9,
                EdgeActivated {
                    route_generation: 99,
                    source_display: Id128(3),
                    route_to: Id128(0x11),
                    edge: SidecarEdge::Left,
                    edge_position: 0.25,
                },
            );
            (producer, sidecar_sequence, result)
        });

        assert_eq!(read_response(&mut client).unwrap().unwrap().result, Ok(()));
        let cleanup = read_request(&mut client).unwrap().unwrap();
        assert!(matches!(
            cleanup.message,
            SidecarMessage::CleanupComplete(CleanupComplete {
                mode: CleanupMode::Normal,
                ..
            })
        ));
        drop(client);

        let (producer, sidecar_sequence, result) = server_task.await.unwrap();
        let error = result.unwrap_err();
        assert!(
            error
                .to_string()
                .contains("did not ACK exact normal cleanup")
        );
        assert_eq!(sidecar_sequence, 3);
        assert!(producer.route.is_none());
        assert!(producer.last_cleanup_complete.is_some());
        collector.abort();
    }

    #[tokio::test]
    async fn superseded_live_peer_blocks_receipt_until_registration_closes() {
        let unique = unix_time_ms().unwrap();
        let directory = std::env::temp_dir().join(format!(
            "viewflow-peer-registry-quiesce-test-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let receipt = directory.join("quiescence.json");
        let (registry, peers) = ProducerPeerRegistry::new();
        let (first_outbound, _first_received) = tokio::sync::mpsc::channel(1);
        let first_registration =
            registry.register("127.0.0.1:41000".parse().unwrap(), first_outbound.into());
        let (second_outbound, _second_received) = tokio::sync::mpsc::channel(1);
        let _second_registration =
            registry.register("127.0.0.1:42000".parse().unwrap(), second_outbound.into());
        let mut producer = ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: Some(receipt.clone()),
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        );
        producer.shutdown_route().await.unwrap();

        let error = producer
            .finalize_quiescence(test_quiescence_arm("superseded-peer-rejected"))
            .unwrap_err();
        assert!(error.to_string().contains("superseded peer epochs"));
        assert!(!receipt.exists());

        let (late_outbound, _late_received) = tokio::sync::mpsc::channel(1);
        let _rejected_late_registration =
            registry.register("127.0.0.1:43000".parse().unwrap(), late_outbound.into());
        drop(first_registration);
        producer
            .finalize_quiescence(test_quiescence_arm("single-live-peer-accepted"))
            .unwrap();
        assert!(receipt.exists());
        fs::remove_file(&receipt).unwrap();
        fs::remove_dir(&directory).unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn unavailable_peer_rejects_edge_before_ack_and_taints_daemon_lifetime() {
        assert!(PEER_ACTIVATION_TIMEOUT + ROUTE_CLEANUP_TIMEOUT <= Duration::from_millis(30));
        let (_registry, peers) = ProducerPeerRegistry::new();
        let (mut client, mut server) = UnixStream::pair().unwrap();
        let runtime = Handle::current();
        let server_task = task::spawn_blocking(move || {
            let mut producer = ProducerState::new(
                SidecarProducerConfig {
                    socket_path: "/unused".into(),
                    local_device: Id128(0x11),
                    target_device: TARGET,
                    clock: ProcessClock::new(),
                    quiesce_proof: None,
                    quiesce_arm_file: None,
                    artifact_hashes: BTreeMap::new(),
                    acceptance: None,
                },
                peers,
            );
            let result = serve_sidecar_stream(
                &mut server,
                &runtime,
                &mut producer,
                SidecarPeerCredentials {
                    uid: current_effective_uid().unwrap(),
                    pid: std::process::id(),
                },
            );
            (producer, result)
        });

        let started = Instant::now();
        write_request(
            &mut client,
            &SidecarRequest {
                sequence: 1,
                message: SidecarMessage::EdgeActivated(EdgeActivated {
                    route_generation: 99,
                    source_display: Id128(3),
                    route_to: TARGET,
                    edge: SidecarEdge::Right,
                    edge_position: 0.5,
                }),
            },
        )
        .unwrap();
        let response = read_response(&mut client)
            .unwrap()
            .expect("activation should receive an explicit rejection");
        assert_eq!(response.sequence, 1);
        assert_eq!(response.result, Err(RejectCode::BackendFailure));
        assert!(started.elapsed() < Duration::from_millis(100));

        drop(client);
        let (producer, result) = timeout(Duration::from_secs(1), server_task)
            .await
            .expect("sidecar stream should finish after disconnect")
            .unwrap();
        result.unwrap();
        assert!(producer.route.is_some());
        assert!(producer.route_ever_activated);
        assert!(producer.quiescence_uncertainty.is_some());
        assert!(producer.last_cleanup.is_none());
    }

    fn cleanup_test_producer() -> ProducerState {
        let (_registry, peers) = ProducerPeerRegistry::new();
        ProducerState::new(
            SidecarProducerConfig {
                socket_path: "/unused".into(),
                local_device: Id128(0x11),
                target_device: TARGET,
                clock: ProcessClock::new(),
                quiesce_proof: None,
                quiesce_arm_file: None,
                artifact_hashes: BTreeMap::new(),
                acceptance: None,
            },
            peers,
        )
    }

    fn verified_active_cleanup() -> RouteCleanupEvidence {
        RouteCleanupEvidence {
            route_ever_activated: true,
            route_was_active: true,
            source_display: Some(format!("{:032x}", 3_u128)),
            route_generation: Some(99),
            active_lease_generation: Some(2),
            last_input_sequence: Some(7),
            release_all: ReleaseAllEvidence {
                status: ReleaseAllStatus::Applied,
                ack: Some(AppliedAckIdentity {
                    lease_generation: 2,
                    target_device: format!("{:032x}", TARGET.0),
                    event_sequence: 8,
                    result: "applied",
                }),
            },
            lease_revoke: LeaseRevokeEvidence {
                status: LeaseRevokeStatus::Applied,
                generation: Some(3),
                ack: Some(LeaseRevokeAckIdentity {
                    operation_id: format!("{:032x}", (u128::from(4_u64) << 64) | 1),
                    lease_generation: 3,
                    owner_device: format!("{:032x}", 0x11_u128),
                    target_device: format!("{:032x}", TARGET.0),
                    state: "revoked",
                    result: "applied",
                }),
            },
            bound_peer_epoch: Some(4),
            bound_peer_socket: Some("127.0.0.1:41000".into()),
        }
    }

    fn retained_runtime_marker(last_sequence: u64) -> DurableQuarantineMarker {
        let daemon = current_daemon_marker_identity().unwrap();
        DurableQuarantineMarker {
            state: QuarantineMarkerState::Active,
            source_display: Id128(3),
            target_device: TARGET,
            owner_device: Id128(0x11),
            old_daemon_boot_id: daemon.boot_id,
            route_generation: 99,
            active_lease_generation: 2,
            last_sequence,
            old_daemon_pid: u64::from(daemon.pid),
            old_daemon_start_ticks: daemon.start_ticks,
            bound_peer: BoundPeerIdentity {
                epoch: 4,
                address: "127.0.0.1:41000".parse().unwrap(),
            },
        }
    }

    fn producer_with_retained_cleanup() -> ProducerState {
        let mut producer = cleanup_test_producer();
        let marker = retained_runtime_marker(7);
        let revoke = InputLeaseRevoke {
            operation_id: Id128((u128::from(4_u64) << 64) | 1),
            lease_generation: 3,
            owner_device: Id128(0x11),
            target_device: TARGET,
            state: InputLeaseState::Revoked,
        };
        producer.route_ever_activated = true;
        producer.last_cleanup = Some(verified_active_cleanup());
        producer.last_runtime_marker = Some(marker);
        producer.last_cleanup_complete =
            Some(cleanup_complete_from_applied(marker, 7, 8, applied_revoke_ack(revoke)).unwrap());
        producer
    }

    fn test_sidecar_credentials() -> SidecarPeerCredentials {
        SidecarPeerCredentials {
            uid: current_effective_uid().unwrap(),
            pid: std::process::id(),
        }
    }

    #[test]
    fn same_daemon_recovery_requires_exact_marker_credentials_and_unexpired_receipt() {
        let recovery_sequence = 44;
        let producer = producer_with_retained_cleanup();
        let marker = producer.last_runtime_marker.unwrap();
        let recovery = QuarantineRecoveryRequest::new(marker).unwrap();
        let credentials = SidecarPeerCredentials {
            uid: current_effective_uid().unwrap(),
            pid: std::process::id().checked_add(1).unwrap(),
        };
        let cleanup = producer
            .prepare_recovery_cleanup(credentials, recovery_sequence, recovery)
            .unwrap();
        assert_eq!(cleanup.mode, CleanupMode::Recovery);
        assert_eq!(cleanup.recovery_request_sequence, recovery_sequence);
        assert_eq!(cleanup.marker_sha256, recovery.marker_sha256);
        assert_eq!(cleanup.cleanup_operation_id, cleanup.revoke_operation_id);
        assert_eq!(cleanup.bound_peer, marker.bound_peer);
        assert!(producer.last_cleanup_complete.is_some());

        let mut mismatched_marker = marker;
        mismatched_marker.route_generation += 1;
        let mismatched_recovery = QuarantineRecoveryRequest::new(mismatched_marker).unwrap();
        assert!(
            producer
                .prepare_recovery_cleanup(
                    test_sidecar_credentials(),
                    recovery_sequence + 1,
                    mismatched_recovery,
                )
                .unwrap_err()
                .to_string()
                .contains("does not exactly match")
        );

        let wrong_uid = SidecarPeerCredentials {
            uid: test_sidecar_credentials().uid.saturating_add(1),
            pid: 1,
        };
        assert!(
            producer
                .prepare_recovery_cleanup(wrong_uid, recovery_sequence + 2, recovery)
                .unwrap_err()
                .to_string()
                .contains("does not match daemon uid")
        );

        let mut expired = producer_with_retained_cleanup();
        let receipt = expired.last_cleanup_complete.as_mut().unwrap();
        receipt.receipt_issued_at_unix_ms = 1;
        receipt.receipt_expires_at_unix_ms = 2;
        assert!(
            expired
                .prepare_recovery_cleanup(
                    test_sidecar_credentials(),
                    recovery_sequence + 3,
                    recovery,
                )
                .unwrap_err()
                .to_string()
                .contains("expired")
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn same_daemon_exact_recovery_sends_kind13_and_retains_receipt() {
        let producer = producer_with_retained_cleanup();
        let retained = producer.last_cleanup_complete;
        let marker = producer.last_runtime_marker.unwrap();
        let recovery = QuarantineRecoveryRequest::new(marker).unwrap();
        let request_sequence = 44;
        let (mut client, mut server) = UnixStream::pair().unwrap();
        let server_task = task::spawn_blocking(move || {
            let mut session = SidecarSession::default();
            session
                .accept_from(
                    MessageDirection::SidecarToDaemon,
                    SidecarRequest {
                        sequence: request_sequence,
                        message: SidecarMessage::QuarantineRecovery(recovery),
                    },
                )
                .unwrap();
            let mut sidecar_sequence = 1;
            let result = handle_quarantine_recovery(
                &mut server,
                &producer,
                &mut session,
                &mut sidecar_sequence,
                request_sequence,
                test_sidecar_credentials(),
                recovery,
            );
            (producer, sidecar_sequence, result)
        });

        let response = read_response(&mut client).unwrap().unwrap();
        assert_eq!(response.sequence, request_sequence);
        assert_eq!(response.result, Ok(()));
        let command = read_request(&mut client).unwrap().unwrap();
        let cleanup = match command.message {
            SidecarMessage::CleanupComplete(cleanup) => cleanup,
            other => panic!("expected recovery CleanupComplete, got {other:?}"),
        };
        assert_eq!(cleanup.mode, CleanupMode::Recovery);
        assert_eq!(cleanup.recovery_request_sequence, request_sequence);
        assert_eq!(cleanup.marker_sha256, recovery.marker_sha256);
        write_response(
            &mut client,
            SidecarResponse {
                sequence: command.sequence,
                result: Ok(()),
            },
        )
        .unwrap();

        let (producer, sidecar_sequence, result) = server_task.await.unwrap();
        result.unwrap();
        assert_eq!(sidecar_sequence, 2);
        assert_eq!(producer.last_cleanup_complete, retained);
        assert_eq!(producer.last_runtime_marker, Some(marker));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn fresh_daemon_kind12_is_fail_closed_and_replay_is_consumed() {
        let producer = cleanup_test_producer();
        let recovery = QuarantineRecoveryRequest::new(retained_runtime_marker(7)).unwrap();
        let (mut client, mut server) = UnixStream::pair().unwrap();
        let runtime = Handle::current();
        let server_task = task::spawn_blocking(move || {
            let mut producer = producer;
            let result = serve_sidecar_stream(
                &mut server,
                &runtime,
                &mut producer,
                test_sidecar_credentials(),
            );
            (producer, result)
        });

        for expected in [RejectCode::BackendFailure, RejectCode::ReplayedEvent] {
            write_request(
                &mut client,
                &SidecarRequest {
                    sequence: 44,
                    message: SidecarMessage::QuarantineRecovery(recovery),
                },
            )
            .unwrap();
            let response = read_response(&mut client).unwrap().unwrap();
            assert_eq!(response.sequence, 44);
            assert_eq!(response.result, Err(expected));
        }
        drop(client);
        let (producer, result) = server_task.await.unwrap();
        result.unwrap();
        assert!(producer.route.is_none());
        assert!(producer.last_cleanup.is_none());
        assert!(producer.last_runtime_marker.is_none());
        assert!(producer.last_cleanup_complete.is_none());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn sidecar_origin_cleanup_complete_is_rejected_by_direction_gate() {
        let producer = producer_with_retained_cleanup();
        let cleanup = producer.last_cleanup_complete.unwrap();
        let (mut client, mut server) = UnixStream::pair().unwrap();
        let runtime = Handle::current();
        let server_task = task::spawn_blocking(move || {
            let mut producer = producer;
            let result = serve_sidecar_stream(
                &mut server,
                &runtime,
                &mut producer,
                test_sidecar_credentials(),
            );
            (producer, result)
        });

        write_request(
            &mut client,
            &SidecarRequest {
                sequence: 55,
                message: SidecarMessage::CleanupComplete(cleanup),
            },
        )
        .unwrap();
        let response = read_response(&mut client).unwrap().unwrap();
        assert_eq!(response.sequence, 55);
        assert_eq!(response.result, Err(RejectCode::WrongDirection));
        drop(client);

        let (producer, result) = server_task.await.unwrap();
        result.unwrap();
        assert_eq!(producer.last_cleanup_complete, Some(cleanup));
        assert!(producer.route.is_none());
    }

    #[tokio::test]
    async fn verified_active_cleanup_remains_sticky_after_route_is_gone() {
        let mut producer = cleanup_test_producer();
        let cleanup = verified_active_cleanup();
        producer.route_ever_activated = true;
        producer.last_cleanup = Some(cleanup.clone());

        producer.shutdown_route().await.unwrap();

        assert!(producer.route_ever_activated);
        assert_eq!(producer.last_cleanup, Some(cleanup));
        assert!(producer.verified_quiescence_cleanup().is_ok());
    }

    #[test]
    fn activated_cleanup_rejects_overflow_and_invalid_bound_peer_identity() {
        let mut producer = cleanup_test_producer();
        producer.route_ever_activated = true;

        let mut sequence_overflow = verified_active_cleanup();
        sequence_overflow.last_input_sequence = Some(u64::MAX);
        sequence_overflow
            .release_all
            .ack
            .as_mut()
            .unwrap()
            .event_sequence = u64::MAX;

        let mut generation_overflow = verified_active_cleanup();
        generation_overflow.active_lease_generation = Some(u64::MAX);
        generation_overflow
            .release_all
            .ack
            .as_mut()
            .unwrap()
            .lease_generation = u64::MAX;
        generation_overflow.lease_revoke.generation = Some(u64::MAX);

        let mut zero_epoch = verified_active_cleanup();
        zero_epoch.bound_peer_epoch = Some(0);

        let mut empty_socket = verified_active_cleanup();
        empty_socket.bound_peer_socket = Some(String::new());

        let mut malformed_socket = verified_active_cleanup();
        malformed_socket.bound_peer_socket = Some("not-a-socket".into());

        for cleanup in [
            sequence_overflow,
            generation_overflow,
            zero_epoch,
            empty_socket,
            malformed_socket,
        ] {
            producer.last_cleanup = Some(cleanup);
            assert!(producer.verified_quiescence_cleanup().is_err());
        }
    }

    #[test]
    fn activated_cleanup_requires_exact_local_route_identity() {
        let mut producer = cleanup_test_producer();
        producer.route_ever_activated = true;

        let cleanup = verified_active_cleanup();
        producer.last_cleanup = Some(cleanup.clone());
        assert!(producer.verified_quiescence_cleanup().is_ok());
        let json = serde_json::to_value(&cleanup).unwrap();
        assert_eq!(json["source_display"], format!("{:032x}", 3_u128));
        assert_eq!(json["route_generation"], 99);

        let mut missing_display = cleanup.clone();
        missing_display.source_display = None;
        let mut malformed_display = cleanup.clone();
        malformed_display.source_display = Some("3".into());
        let mut zero_display = cleanup.clone();
        zero_display.source_display = Some("0".repeat(32));
        let mut missing_generation = cleanup.clone();
        missing_generation.route_generation = None;
        let mut zero_generation = cleanup;
        zero_generation.route_generation = Some(0);

        for invalid in [
            missing_display,
            malformed_display,
            zero_display,
            missing_generation,
            zero_generation,
        ] {
            producer.last_cleanup = Some(invalid);
            assert!(producer.verified_quiescence_cleanup().is_err());
        }
    }

    #[test]
    fn owner_only_arm_binds_and_is_consumed_once() {
        let unique = unix_time_ms().unwrap();
        let directory =
            std::env::temp_dir().join(format!("viewflow-arm-test-{}-{unique}", std::process::id()));
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let arm_file = directory.join("quiesce.arm");
        let config = ArmQuiesceConfig {
            arm_file: arm_file.clone(),
            operation_id: "deploy-20260829-test".into(),
            daemon_pid: std::process::id(),
        };

        arm_quiescence(&config).unwrap();
        let metadata = fs::metadata(&arm_file).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        let arm = consume_quiescence_arm(&arm_file)
            .unwrap()
            .expect("fresh matching arm must be consumed");
        assert_eq!(arm.operation_id, config.operation_id);
        assert!(!arm_file.exists());
        assert!(consume_quiescence_arm(&arm_file).unwrap().is_none());

        fs::remove_dir(&directory).unwrap();
    }

    #[test]
    fn owner_only_mode_is_present_when_create_returns() {
        let unique = unix_time_ms().unwrap();
        let directory = std::env::temp_dir().join(format!(
            "viewflow-owner-mode-test-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.join("owner-only.json");

        let file = create_owner_only_new(&path).unwrap();
        assert_eq!(file.metadata().unwrap().permissions().mode() & 0o777, 0o600);

        drop(file);
        fs::remove_file(path).unwrap();
        fs::remove_dir(directory).unwrap();
    }

    #[test]
    fn open_file_hash_stays_pinned_across_symlink_replacement() {
        use sha2::{Digest, Sha256};
        use std::os::unix::fs::symlink;

        let unique = unix_time_ms().unwrap();
        let directory = std::env::temp_dir().join(format!(
            "viewflow-pinned-hash-test-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let original = directory.join("original");
        let replacement = directory.join("replacement");
        let selected = directory.join("selected");
        let original_bytes = b"running executable bytes";
        let replacement_bytes = b"replacement path bytes";
        fs::write(&original, original_bytes).unwrap();
        fs::write(&replacement, replacement_bytes).unwrap();
        symlink(&original, &selected).unwrap();

        let mut pinned = fs::File::open(&selected).unwrap();
        assert!(pinned.metadata().unwrap().is_file());
        fs::remove_file(&selected).unwrap();
        symlink(&replacement, &selected).unwrap();

        let pinned_hash = crate::sha256_file_handle(&mut pinned).unwrap();
        assert_eq!(pinned_hash, format!("{:x}", Sha256::digest(original_bytes)));
        assert_eq!(
            format!("{:x}", Sha256::digest(fs::read(&selected).unwrap())),
            format!("{:x}", Sha256::digest(replacement_bytes))
        );

        drop(pinned);
        fs::remove_file(selected).unwrap();
        fs::remove_file(original).unwrap();
        fs::remove_file(replacement).unwrap();
        fs::remove_dir(directory).unwrap();
    }
}
