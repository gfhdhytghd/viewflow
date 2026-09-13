use std::collections::HashMap;

use viewflow_protocol::{
    DeviceId, DeviceTopology, DomainControl, FramePlaneReady, GeometryEpoch, InputLease,
    InputLeaseState, WindowDescriptor, WindowId,
};

use crate::{
    AtlasConfig, AtlasError, AtlasPlacement, AtlasSnapshot, AudioRouteError, AudioRouter,
    ClipboardTransfers, DragTransfers, FrameAdmission, FrameQueue, FrameQueueConfig, HidLeaseError,
    HidLeaseManager, StableAtlas, TopologyError, TopologyMap, TransferError, WindowError,
    WindowSession,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CoordinatorError {
    AtlasRuntimeRequired,
    WindowInputRuntimeRequired,
    ClipboardRuntimeRequired,
    DesktopRuntimeRequired,
    Topology(TopologyError),
    TopologyUnavailable,
    UnknownWindow,
    DuplicateWindow,
    Window(WindowError),
    StaleInputLease,
    ControlSequenceRequired,
    Transfer(TransferError),
    AudioRoute(AudioRouteError),
    HidLease(HidLeaseError),
    Atlas(AtlasError),
    InvalidMediaPeer,
    MediaPeerAlreadyConfigured,
    UnknownMediaPeer,
    AtlasGeometryNotCommitted,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CoordinatorOutcome {
    Applied,
    GeometryCommitted(bool),
    Frame(FrameAdmission),
}

impl From<TopologyError> for CoordinatorError {
    fn from(value: TopologyError) -> Self {
        Self::Topology(value)
    }
}

impl From<WindowError> for CoordinatorError {
    fn from(value: WindowError) -> Self {
        Self::Window(value)
    }
}

impl From<TransferError> for CoordinatorError {
    fn from(value: TransferError) -> Self {
        Self::Transfer(value)
    }
}

impl From<AudioRouteError> for CoordinatorError {
    fn from(value: AudioRouteError) -> Self {
        Self::AudioRoute(value)
    }
}

impl From<HidLeaseError> for CoordinatorError {
    fn from(value: HidLeaseError) -> Self {
        Self::HidLease(value)
    }
}

#[derive(Debug, Default)]
pub struct Coordinator {
    topology: Option<TopologyMap>,
    windows: HashMap<WindowId, WindowSession>,
    frame_queues: HashMap<WindowId, FrameQueue>,
    input_lease: Option<InputLease>,
    clipboard_transfers: ClipboardTransfers,
    drag_transfers: DragTransfers,
    audio_router: AudioRouter,
    hid_leases: HidLeaseManager,
    // Local configuration only; peer messages cannot create media ownership.
    media_atlases: HashMap<(DeviceId, DeviceId), StableAtlas>,
}

impl Coordinator {
    /// Configure one shared atlas for a source/destination device pair. Its
    /// caller must retain this coordinator across connection attempts; it does
    /// not allocate an encoder or delegate layout ownership to a transport.
    /// # Errors
    /// Rejects invalid identities, duplicate ownership or invalid pixel limits.
    pub fn configure_media_atlas(
        &mut self,
        source: DeviceId,
        remote: DeviceId,
        config: AtlasConfig,
    ) -> Result<(), CoordinatorError> {
        if source.0 == 0 || remote.0 == 0 || source == remote {
            return Err(CoordinatorError::InvalidMediaPeer);
        }
        if self.media_atlases.contains_key(&(source, remote)) {
            return Err(CoordinatorError::MediaPeerAlreadyConfigured);
        }
        let atlas = StableAtlas::new(config).map_err(CoordinatorError::Atlas)?;
        self.media_atlases.insert((source, remote), atlas);
        Ok(())
    }

    /// Place locally captured, decorated pixel dimensions, never inferred from
    /// desktop DIP bounds. A transport retry does not discard this allocation.
    /// # Errors
    /// Requires a registered source window, configured peer and committed epoch.
    pub fn place_captured_window(
        &mut self,
        remote: DeviceId,
        window: WindowId,
        epoch: u64,
        width: u32,
        height: u32,
    ) -> Result<AtlasPlacement, CoordinatorError> {
        let session = self
            .windows
            .get(&window)
            .ok_or(CoordinatorError::UnknownWindow)?;
        if session.geometry_pending() || session.committed_epoch() != epoch {
            return Err(CoordinatorError::AtlasGeometryNotCommitted);
        }
        self.media_atlases
            .get_mut(&(session.descriptor.source_device, remote))
            .ok_or(CoordinatorError::UnknownMediaPeer)?
            .place(window, epoch, width, height)
            .map_err(CoordinatorError::Atlas)
    }

    #[must_use]
    pub fn media_atlas(&self, source: DeviceId, remote: DeviceId) -> Option<AtlasSnapshot> {
        self.media_atlases
            .get(&(source, remote))
            .map(StableAtlas::snapshot)
    }

    /// Keep the device pair's layout but retire every old connection's tile.
    /// # Errors
    /// Requires a configured peer and an available layout revision.
    pub fn suspend_media_atlas(
        &mut self,
        source: DeviceId,
        remote: DeviceId,
    ) -> Result<(), CoordinatorError> {
        self.media_atlases
            .get_mut(&(source, remote))
            .ok_or(CoordinatorError::UnknownMediaPeer)?
            .suspend()
            .map_err(CoordinatorError::Atlas)
    }

    /// Release one local stream subscription, retaining other windows' slots.
    /// # Errors
    /// Requires a configured device pair and a reserved window in its atlas.
    pub fn remove_atlas_window(
        &mut self,
        source: DeviceId,
        remote: DeviceId,
        window: WindowId,
    ) -> Result<(), CoordinatorError> {
        self.media_atlases
            .get_mut(&(source, remote))
            .ok_or(CoordinatorError::UnknownMediaPeer)?
            .remove(window)
            .map_err(CoordinatorError::Atlas)
    }

    /// Applies one validated peer control message.
    ///
    /// # Errors
    ///
    /// Returns the subsystem-specific coordinator error for invalid state.
    pub fn apply_control(
        &mut self,
        control: DomainControl,
    ) -> Result<CoordinatorOutcome, CoordinatorError> {
        self.apply_control_inner(None, control)
    }

    /// Applies a peer control message while retaining its validated global
    /// control-stream sequence number.
    ///
    /// File and clipboard transfer state uses the sequence to reject replayed
    /// or reordered lifecycle messages while allowing unrelated controls to be
    /// interleaved. Callers should pass the original `ControlEnvelope.sequence`
    /// after transport-level sequence validation.
    ///
    /// # Errors
    ///
    /// Returns the subsystem-specific coordinator error for invalid state.
    pub fn apply_control_sequenced(
        &mut self,
        sequence: u64,
        control: DomainControl,
    ) -> Result<CoordinatorOutcome, CoordinatorError> {
        self.apply_control_inner(Some(sequence), control)
    }

    fn apply_control_inner(
        &mut self,
        sequence: Option<u64>,
        control: DomainControl,
    ) -> Result<CoordinatorOutcome, CoordinatorError> {
        match control {
            // Clipboard payloads require an explicitly consented, connection-
            // local transfer owner. The generic coordinator cannot install or
            // acknowledge OS clipboard contents on behalf of a remote offer.
            DomainControl::ClipboardTransferOffer(_)
            | DomainControl::ClipboardAccept(_)
            | DomainControl::ClipboardPayload(_)
            | DomainControl::ClipboardComplete(_) => {
                Err(CoordinatorError::ClipboardRuntimeRequired)
            }
            // A local layout allocator is not an authenticated remote publisher.
            DomainControl::AtlasFrame(_)
            | DomainControl::ApplicationIcon(_)
            | DomainControl::WindowInputRelease(_) => Err(CoordinatorError::AtlasRuntimeRequired),
            DomainControl::DesktopWindowMove(_) | DomainControl::DesktopWindowMoveAck(_) => {
                Err(CoordinatorError::DesktopRuntimeRequired)
            }
            // A device-wide lease is not authorization for a captured window.
            // Reject until a connection-local window runtime owns validation.
            DomainControl::WindowPointerMotion(_)
            | DomainControl::AtlasWindowSelection(_)
            | DomainControl::AtlasWindowSelectionRejected(_)
            | DomainControl::AtlasWindowSelectionAccepted(_)
            | DomainControl::WindowPointerButton(_)
            | DomainControl::WindowPointerWheel(_)
            | DomainControl::WindowKeyboardEvent(_)
            | DomainControl::WindowKeyboardAck(_)
            | DomainControl::WindowKeyboardAuthorization(_)
            | DomainControl::WindowPointerAck(_)
            | DomainControl::WindowPointerAuthorization(_) => {
                Err(CoordinatorError::WindowInputRuntimeRequired)
            }
            DomainControl::Topology(topology) => {
                self.set_topology(topology)?;
                Ok(CoordinatorOutcome::Applied)
            }
            DomainControl::RegisterWindow(window) => {
                self.register_window(window)?;
                Ok(CoordinatorOutcome::Applied)
            }
            DomainControl::Geometry(geometry) => self
                .apply_geometry(geometry)
                .map(CoordinatorOutcome::GeometryCommitted),
            DomainControl::FramePlane(frame) => self
                .ingest_frame_plane(frame)
                .map(CoordinatorOutcome::Frame),
            DomainControl::InputLease(lease) => {
                self.apply_input_lease(lease)?;
                Ok(CoordinatorOutcome::Applied)
            }
            DomainControl::InputLeaseRevoke(revoke) => {
                self.apply_input_lease(revoke.lease())?;
                Ok(CoordinatorOutcome::Applied)
            }
            // Input events are validated and injected by the connection-local
            // platform runtime. Their acknowledgments, including the
            // operation-bound revoke acknowledgment, are resolved by that
            // same connection's registries. The coordinator only owns the
            // shared lease lifecycle, so it must not inject, sequence, or
            // reapply any of these controls.
            DomainControl::InputEvent(_)
            | DomainControl::InputAppliedAck(_)
            | DomainControl::InputLeaseRevokedAck(_)
            | DomainControl::ClockSyncProbe(_)
            | DomainControl::ClockSyncReply(_) => Ok(CoordinatorOutcome::Applied),
            DomainControl::ClipboardOffer(offer) => {
                self.clipboard_transfers.offer_control(
                    sequence.ok_or(CoordinatorError::ControlSequenceRequired)?,
                    offer,
                )?;
                Ok(CoordinatorOutcome::Applied)
            }
            DomainControl::FileDragOffer(offer) => {
                self.drag_transfers.offer_control(
                    sequence.ok_or(CoordinatorError::ControlSequenceRequired)?,
                    offer,
                )?;
                Ok(CoordinatorOutcome::Applied)
            }
            DomainControl::FileDragAccept(accept) => {
                self.drag_transfers.accept_control(
                    sequence.ok_or(CoordinatorError::ControlSequenceRequired)?,
                    &accept,
                )?;
                Ok(CoordinatorOutcome::Applied)
            }
            DomainControl::FileDragProgress(progress) => {
                self.drag_transfers.progress_control(
                    sequence.ok_or(CoordinatorError::ControlSequenceRequired)?,
                    progress,
                )?;
                Ok(CoordinatorOutcome::Applied)
            }
            DomainControl::FileDragComplete(completion) => {
                self.drag_transfers.complete_control(
                    sequence.ok_or(CoordinatorError::ControlSequenceRequired)?,
                    completion,
                )?;
                Ok(CoordinatorOutcome::Applied)
            }
            DomainControl::AudioRoute(route) => {
                self.audio_router.apply_route(route)?;
                Ok(CoordinatorOutcome::Applied)
            }
            DomainControl::HidDeviceOffer(offer) => {
                self.hid_leases.register_device(offer)?;
                Ok(CoordinatorOutcome::Applied)
            }
            DomainControl::HidDeviceLease(lease) => {
                self.hid_leases.apply_lease(lease)?;
                Ok(CoordinatorOutcome::Applied)
            }
        }
    }
    /// Replaces the complete display topology and recalculates window migration.
    ///
    /// # Errors
    ///
    /// Returns a topology validation error when the supplied snapshot is invalid.
    pub fn set_topology(&mut self, topology: DeviceTopology) -> Result<(), CoordinatorError> {
        let topology = TopologyMap::new(topology)?;
        for window in self.windows.values_mut() {
            window.update_migration(&topology);
        }
        self.topology = Some(topology);
        Ok(())
    }

    /// Registers a source window and creates its bounded-latency frame queue.
    ///
    /// # Errors
    ///
    /// Returns an error for duplicate identifiers or before topology discovery.
    pub fn register_window(
        &mut self,
        descriptor: WindowDescriptor,
    ) -> Result<(), CoordinatorError> {
        if self.windows.contains_key(&descriptor.id) {
            return Err(CoordinatorError::DuplicateWindow);
        }
        let topology = self
            .topology
            .as_ref()
            .ok_or(CoordinatorError::TopologyUnavailable)?;
        let refresh_millihz = topology
            .slices_for(&descriptor)
            .iter()
            .map(|slice| slice.display.refresh_millihz)
            .max()
            .unwrap_or(60_000);
        let window_id = descriptor.id;
        let requires_alpha = descriptor.has_alpha;
        let mut session = WindowSession::new(descriptor);
        session.update_migration(topology);
        self.frame_queues.insert(
            window_id,
            FrameQueue::new(FrameQueueConfig {
                refresh_millihz,
                max_refresh_periods: 2,
                requires_alpha,
            }),
        );
        self.windows.insert(window_id, session);
        Ok(())
    }

    /// Applies a geometry phase and advances the frame epoch on commit.
    ///
    /// # Errors
    ///
    /// Returns an error for an unknown window or invalid geometry sequence.
    pub fn apply_geometry(&mut self, update: GeometryEpoch) -> Result<bool, CoordinatorError> {
        let mut session = self
            .windows
            .get(&update.window_id)
            .ok_or(CoordinatorError::UnknownWindow)?
            .clone();
        let committed = session.apply_geometry(update)?;
        let mut layouts = Vec::new();
        if committed {
            for (pair, atlas) in &self.media_atlases {
                if pair.0 == session.descriptor.source_device && atlas.contains(update.window_id) {
                    let mut next = atlas.clone();
                    next.invalidate(update.window_id, update.epoch)
                        .map_err(CoordinatorError::Atlas)?;
                    layouts.push((*pair, next));
                }
            }
        }
        if committed {
            self.frame_queues
                .get_mut(&update.window_id)
                .ok_or(CoordinatorError::UnknownWindow)?
                .set_geometry_epoch(update.epoch);
            if let Some(topology) = &self.topology {
                session.update_migration(topology);
            }
        }
        self.windows.insert(update.window_id, session);
        self.media_atlases.extend(layouts);
        Ok(committed)
    }

    /// Submits one decoded color or alpha plane to the proxy admission queue.
    ///
    /// # Errors
    ///
    /// Returns an error when the plane refers to an unknown window.
    pub fn ingest_frame_plane(
        &mut self,
        plane: FramePlaneReady,
    ) -> Result<FrameAdmission, CoordinatorError> {
        self.frame_queues
            .get_mut(&plane.window_id)
            .map(|queue| queue.push(plane))
            .ok_or(CoordinatorError::UnknownWindow)
    }

    /// Installs a newer generation-numbered input routing lease.
    ///
    /// # Errors
    ///
    /// Rejects lease generations that do not strictly increase.
    pub fn apply_input_lease(&mut self, lease: InputLease) -> Result<(), CoordinatorError> {
        if self
            .input_lease
            .is_some_and(|current| lease.generation <= current.generation)
        {
            return Err(CoordinatorError::StaleInputLease);
        }
        self.input_lease = Some(lease);
        Ok(())
    }

    #[must_use]
    pub fn active_input_route(&self) -> Option<(DeviceId, DeviceId)> {
        self.input_lease.and_then(|lease| {
            (lease.state == InputLeaseState::Active).then_some((lease.owner, lease.route_to))
        })
    }

    #[must_use]
    pub fn window(&self, id: WindowId) -> Option<&WindowSession> {
        self.windows.get(&id)
    }

    #[must_use]
    pub fn clipboard_transfers(&self) -> &ClipboardTransfers {
        &self.clipboard_transfers
    }

    #[must_use]
    pub fn drag_transfers(&self) -> &DragTransfers {
        &self.drag_transfers
    }

    #[must_use]
    pub fn audio_router(&self) -> &AudioRouter {
        &self.audio_router
    }

    #[must_use]
    pub fn hid_leases(&self) -> &HidLeaseManager {
        &self.hid_leases
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn atlas_metadata_requires_dedicated_runtime() {
        let frame = viewflow_protocol::AtlasFrame {
            patches: None,
            color_keyframe: true,
            alpha_keyframe: true,
            desktop: None,
            stream_id: viewflow_protocol::Id128(99),
            frame_id: 1,
            geometry_epoch: 1,
            config_generation: 1,
            layout_revision: 0,
            width: 64,
            height: 64,
            source_submitted_ns: 100,
            tiles: vec![],
        };
        assert!(frame.validate().is_ok());
        assert_eq!(
            Coordinator::default().apply_control(DomainControl::AtlasFrame(frame)),
            Err(CoordinatorError::AtlasRuntimeRequired)
        );
    }
    #[test]
    fn window_pointer_cannot_be_accepted_as_device_input() {
        let motion = viewflow_protocol::WindowPointerMotion {
            lease_generation: 1,
            target_device: viewflow_protocol::Id128(2),
            target_window: viewflow_protocol::Id128(3),
            geometry_epoch: 4,
            presented_frame: 5,
            sequence: 6,
            sender_not_after_ns: 7,
            x_pixels: 40,
            y_pixels: 80,
            viewport_width: 1626,
            viewport_height: 1240,
        };
        assert_eq!(
            Coordinator::default().apply_control(DomainControl::WindowKeyboardEvent(
                viewflow_protocol::WindowKeyboardEvent {
                    lease_generation: motion.lease_generation,
                    target_device: motion.target_device,
                    target_window: motion.target_window,
                    geometry_epoch: motion.geometry_epoch,
                    presented_frame: motion.presented_frame,
                    sequence: motion.sequence,
                    sender_not_after_ns: motion.sender_not_after_ns,
                    key: viewflow_protocol::KeyboardHidUsage {
                        usage_page: 7,
                        usage_id: 4,
                        state: viewflow_protocol::InputSwitchState::Pressed,
                        repeat: false,
                    },
                },
            )),
            Err(CoordinatorError::WindowInputRuntimeRequired)
        );
        assert_eq!(
            Coordinator::default().apply_control(DomainControl::WindowPointerMotion(motion)),
            Err(CoordinatorError::WindowInputRuntimeRequired)
        );
        assert_eq!(
            Coordinator::default().apply_control(DomainControl::WindowPointerWheel(
                viewflow_protocol::WindowPointerWheel {
                    position: motion,
                    delta: viewflow_protocol::PointerWheelEvent {
                        vertical_delta_detents: 0.25,
                        horizontal_delta_detents: -0.5,
                    },
                },
            )),
            Err(CoordinatorError::WindowInputRuntimeRequired)
        );
        assert_eq!(
            Coordinator::default().apply_control(DomainControl::WindowPointerButton(
                viewflow_protocol::WindowPointerButton {
                    position: motion,
                    transition: viewflow_protocol::PointerButtonEvent {
                        button: viewflow_protocol::PointerButton::Left,
                        state: viewflow_protocol::InputSwitchState::Pressed,
                    },
                },
            )),
            Err(CoordinatorError::WindowInputRuntimeRequired)
        );
    }
    use viewflow_protocol::{
        AudioRoute, ClipboardFlavor, ClipboardOffer, DisplayDescriptor, DragAccept, DragComplete,
        DragCompletionStatus, DragItem, DragItemResult, DragOffer, DragOperation, DragProgress,
        GeometryPhase, Id128, InputLeaseRevoke, InputLeaseRevokedAck, InputLeaseRevokedResult,
        Point, Rect, Size, WindowRole,
    };

    fn rect(x: f64, width: f64) -> Rect {
        Rect {
            origin: Point { x, y: 0.0 },
            size: Size {
                width,
                height: 100.0,
            },
        }
    }

    fn coordinator() -> Coordinator {
        let mut coordinator = Coordinator::default();
        coordinator
            .set_topology(DeviceTopology {
                generation: 1,
                displays: vec![
                    DisplayDescriptor {
                        id: Id128(10),
                        device_id: Id128(1),
                        bounds_dip: rect(0.0, 100.0),
                        scale: 1.0,
                        refresh_millihz: 60_000,
                    },
                    DisplayDescriptor {
                        id: Id128(11),
                        device_id: Id128(2),
                        bounds_dip: rect(100.0, 100.0),
                        scale: 2.0,
                        refresh_millihz: 60_000,
                    },
                ],
            })
            .unwrap();
        coordinator
    }

    #[test]
    fn media_atlas_uses_capture_pixels_and_invalidates_only_committed_window() {
        let mut coordinator = coordinator();
        let config = AtlasConfig {
            width: 128,
            height: 128,
            alignment: 2,
            max_windows: 4,
        };
        coordinator
            .configure_media_atlas(Id128(1), Id128(2), config)
            .unwrap();
        coordinator
            .configure_media_atlas(Id128(1), Id128(3), config)
            .unwrap();
        assert_eq!(
            coordinator.configure_media_atlas(Id128(1), Id128(2), config),
            Err(CoordinatorError::MediaPeerAlreadyConfigured)
        );
        for id in [20, 21] {
            coordinator
                .register_window(WindowDescriptor {
                    id: Id128(id),
                    family_id: Id128(30),
                    source_device: Id128(1),
                    role: WindowRole::Main,
                    bounds_dip: rect(25.0, 50.0),
                    min_size_dip: Size::default(),
                    max_size_dip: None,
                    has_alpha: true,
                    blur_radius_dip: None,
                })
                .unwrap();
        }
        let first = coordinator
            .place_captured_window(Id128(2), Id128(20), 0, 63, 40)
            .unwrap();
        coordinator
            .place_captured_window(Id128(3), Id128(20), 0, 63, 40)
            .unwrap();
        let second = coordinator
            .place_captured_window(Id128(2), Id128(21), 0, 32, 32)
            .unwrap();
        assert_eq!(first.allocation.width, 64);
        assert_eq!(first.content_width, 63); // Not 50 DIP or the target's 2x scale.
        assert_eq!(
            coordinator.place_captured_window(Id128(4), Id128(20), 0, 63, 40),
            Err(CoordinatorError::UnknownMediaPeer)
        );
        let old = coordinator.media_atlas(Id128(1), Id128(2)).unwrap();
        let geometry = |phase| GeometryEpoch {
            window_id: Id128(20),
            epoch: 1,
            phase,
            bounds_dip: rect(50.0, 32.0),
        };
        coordinator
            .apply_geometry(geometry(GeometryPhase::Begin))
            .unwrap();
        assert_eq!(
            coordinator.place_captured_window(Id128(2), Id128(20), 0, 63, 40),
            Err(CoordinatorError::AtlasGeometryNotCommitted)
        );
        assert_eq!(coordinator.media_atlas(Id128(1), Id128(2)).unwrap(), old);
        assert_atomic_atlas_geometry_failure(&mut coordinator, geometry(GeometryPhase::End));
        coordinator
            .apply_geometry(geometry(GeometryPhase::End))
            .unwrap();
        assert!(
            coordinator
                .media_atlas(Id128(1), Id128(3))
                .unwrap()
                .placements
                .is_empty()
        );
        let invalidated = coordinator.media_atlas(Id128(1), Id128(2)).unwrap();
        assert_eq!(invalidated.placements, vec![second]);
        let next = coordinator
            .place_captured_window(Id128(2), Id128(20), 1, 32, 32)
            .unwrap();
        assert_eq!(
            (next.allocation.x, next.allocation.y),
            (first.allocation.x, first.allocation.y)
        );
        assert_eq!((next.allocation.width, next.allocation.height), (32, 32));
        assert_ne!(next.generation, first.generation);
        coordinator
            .remove_atlas_window(Id128(1), Id128(2), Id128(20))
            .unwrap();
        assert_eq!(
            coordinator
                .media_atlas(Id128(1), Id128(2))
                .unwrap()
                .placements,
            vec![second]
        );
    }

    fn assert_atomic_atlas_geometry_failure(coordinator: &mut Coordinator, update: GeometryEpoch) {
        let saved = coordinator.media_atlases.clone();
        // Deliberately inconsistent backend state: one peer advanced ahead of
        // the coordinator. Failure must not commit another peer's prepared map.
        coordinator
            .media_atlases
            .get_mut(&(Id128(1), Id128(3)))
            .unwrap()
            .place(Id128(20), 99, 63, 40)
            .unwrap();
        let inconsistent = coordinator.media_atlases.clone();
        assert_eq!(
            coordinator.apply_geometry(update),
            Err(CoordinatorError::Atlas(AtlasError::StaleGeometry))
        );
        assert_eq!(coordinator.window(Id128(20)).unwrap().committed_epoch(), 0);
        assert!(coordinator.window(Id128(20)).unwrap().geometry_pending());
        assert_eq!(coordinator.media_atlases, inconsistent);
        coordinator.media_atlases = saved;
    }

    #[test]
    fn geometry_commit_virtualizes_window_and_advances_frame_epoch() {
        let mut coordinator = coordinator();
        let window_id = Id128(20);
        coordinator
            .register_window(WindowDescriptor {
                id: window_id,
                family_id: Id128(21),
                source_device: Id128(1),
                role: WindowRole::Main,
                bounds_dip: rect(25.0, 50.0),
                min_size_dip: Size::default(),
                max_size_dip: None,
                has_alpha: false,
                blur_radius_dip: None,
            })
            .unwrap();
        let moved = rect(75.0, 50.0);
        coordinator
            .apply_geometry(GeometryEpoch {
                window_id,
                epoch: 1,
                phase: GeometryPhase::Begin,
                bounds_dip: moved,
            })
            .unwrap();
        coordinator
            .apply_geometry(GeometryEpoch {
                window_id,
                epoch: 1,
                phase: GeometryPhase::End,
                bounds_dip: moved,
            })
            .unwrap();

        assert!(matches!(
            coordinator.window(window_id).unwrap().migration,
            crate::MigrationState::Virtualized { .. }
        ));
    }

    #[test]
    fn input_lease_generation_prevents_two_active_owners() {
        let mut coordinator = coordinator();
        let active = InputLease {
            generation: 5,
            owner: Id128(1),
            route_to: Id128(2),
            state: InputLeaseState::Active,
        };
        coordinator.apply_input_lease(active).unwrap();
        assert_eq!(coordinator.active_input_route(), Some((Id128(1), Id128(2))));
        assert_eq!(
            coordinator.apply_input_lease(active),
            Err(CoordinatorError::StaleInputLease)
        );
    }

    #[test]
    fn revoke_updates_shared_lease_while_its_ack_remains_connection_local() {
        let mut coordinator = coordinator();
        coordinator
            .apply_input_lease(InputLease {
                generation: 5,
                owner: Id128(1),
                route_to: Id128(2),
                state: InputLeaseState::Active,
            })
            .unwrap();

        let ack = InputLeaseRevokedAck {
            operation_id: Id128(100),
            lease_generation: 6,
            owner_device: Id128(1),
            target_device: Id128(2),
            state: InputLeaseState::Revoked,
            result: InputLeaseRevokedResult::Applied,
        };
        assert_eq!(
            coordinator.apply_control(DomainControl::InputLeaseRevokedAck(ack)),
            Ok(CoordinatorOutcome::Applied)
        );
        assert_eq!(coordinator.active_input_route(), Some((Id128(1), Id128(2))));

        let revoke = InputLeaseRevoke {
            operation_id: ack.operation_id,
            lease_generation: ack.lease_generation,
            owner_device: ack.owner_device,
            target_device: ack.target_device,
            state: InputLeaseState::Revoked,
        };
        assert_eq!(
            coordinator.apply_control(DomainControl::InputLeaseRevoke(revoke)),
            Ok(CoordinatorOutcome::Applied)
        );
        assert_eq!(coordinator.active_input_route(), None);
        assert_eq!(
            coordinator.apply_control(DomainControl::InputLeaseRevoke(InputLeaseRevoke {
                operation_id: Id128(101),
                ..revoke
            })),
            Err(CoordinatorError::StaleInputLease)
        );
    }

    #[test]
    fn transfer_controls_require_and_retain_envelope_sequence() {
        let mut coordinator = coordinator();
        let clipboard = ClipboardOffer {
            id: Id128(30),
            owner: Id128(1),
            generation: 1,
            flavors: vec![ClipboardFlavor {
                name: "text/plain".to_owned(),
                size_bytes: 4,
            }],
        };
        assert_eq!(
            coordinator.apply_control(DomainControl::ClipboardOffer(clipboard.clone())),
            Err(CoordinatorError::ControlSequenceRequired)
        );
        coordinator
            .apply_control_sequenced(10, DomainControl::ClipboardOffer(clipboard))
            .unwrap();
        assert_eq!(
            coordinator
                .clipboard_transfers()
                .current()
                .map(crate::ClipboardTransfer::last_sequence),
            Some(10)
        );
    }

    #[test]
    fn sequenced_file_drag_controls_drive_complete_state() {
        let mut coordinator = coordinator();
        coordinator
            .apply_control_sequenced(
                10,
                DomainControl::FileDragOffer(DragOffer {
                    id: Id128(40),
                    generation: 1,
                    source_device: Id128(1),
                    target_device: Id128(2),
                    operation: DragOperation::Copy,
                    items: vec![DragItem {
                        relative_path: "document.txt".to_owned(),
                        size_bytes: 2,
                        content_hash: Some([3; 32]),
                    }],
                }),
            )
            .unwrap();
        coordinator
            .apply_control_sequenced(
                12,
                DomainControl::FileDragAccept(DragAccept {
                    offer_id: Id128(40),
                    generation: 1,
                    operation: DragOperation::Copy,
                    destination_token: "portal:document/1".to_owned(),
                }),
            )
            .unwrap();
        coordinator
            .apply_control_sequenced(
                15,
                DomainControl::FileDragProgress(DragProgress {
                    offer_id: Id128(40),
                    generation: 1,
                    bytes_transferred: 2,
                    total_bytes: 2,
                    item_index: 0,
                    offset_bytes: 0,
                    chunk_size_bytes: 2,
                    chunk_hash: Some([8; 32]),
                }),
            )
            .unwrap();
        coordinator
            .apply_control_sequenced(
                20,
                DomainControl::FileDragComplete(DragComplete {
                    offer_id: Id128(40),
                    generation: 1,
                    status: DragCompletionStatus::Completed,
                    error_message: None,
                    item_results: vec![DragItemResult {
                        item_index: 0,
                        bytes_received: 2,
                        content_hash: Some([3; 32]),
                    }],
                }),
            )
            .unwrap();
        assert_eq!(
            coordinator
                .drag_transfers()
                .current()
                .map(|transfer| transfer.state),
            Some(crate::DragTransferState::Completed)
        );
    }

    #[test]
    fn audio_route_control_is_keyed_by_window_family() {
        let mut coordinator = coordinator();
        coordinator
            .apply_control(DomainControl::AudioRoute(AudioRoute {
                generation: 1,
                family_id: Id128(50),
                source_device: Id128(1),
                target_device: Id128(2),
                target_output_id: "default".to_owned(),
                enabled: true,
            }))
            .unwrap();
        assert_eq!(
            coordinator.audio_router().target_for_family(Id128(50)),
            Some((Id128(2), "default"))
        );
    }
}
