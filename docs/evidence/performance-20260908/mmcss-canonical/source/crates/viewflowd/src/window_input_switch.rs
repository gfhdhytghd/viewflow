//! A single native seat route switches targets only across a confirmed END.
use super::{AuthorizedWindow, State, WindowInputSession, elapsed_ns, native_deadline};
use anyhow::{Context, Result, anyhow};
use std::{sync::atomic::Ordering, time::Instant};
use viewflow_core::WindowPointerGrant;
use viewflow_hyprland::window_pointer_wire::Request;

impl super::RoutedWindowInput<'_> {
    pub(super) fn install_atlas_authorization(
        &mut self,
        selection: viewflow_protocol::AtlasWindowSelection,
        authorized: AuthorizedWindow,
    ) -> Result<()> {
        anyhow::ensure!(
            !selection.activate_keyboard || self.session.allow_keyboard,
            "atlas keyboard activation exceeds local capability"
        );
        let previous = self
            .session
            .grant
            .authorization(elapsed_ns(self.session.origin)?)
            .or(self.session.desktop_suspension)
            .or(self.session.resize_suspension);
        let same_window =
            previous.is_some_and(|previous| previous.target_window == selection.window_id);
        let keyboard_mode =
            selection.activate_keyboard || (same_window && self.session.keyboard_grant.is_some());
        if self.session.state == State::Ready
            && (!same_window || keyboard_mode != self.session.keyboard_grant.is_some())
        {
            let geometry = authorized.geometry;
            self.session.switch_window_mode(authorized, keyboard_mode)?;
            let (owner, presentations) = tokio::sync::watch::channel(geometry);
            self.presentations = presentations;
            self.selected_presentation_owner = Some(owner);
            self.announced = None;
            self.announced_keyboard = None;
            return Ok(());
        }
        if self.session.state == State::DesktopPaused {
            self.session.pending_keyboard_mode = Some(keyboard_mode);
        } else {
            anyhow::ensure!(
                keyboard_mode == self.session.keyboard_grant.is_some(),
                "keyboard activation requires an idle or confirmed-ended route"
            );
        }
        self.install_selected_authorization(authorized)
    }

    pub(super) fn install_selected_authorization(
        &mut self,
        authorized: AuthorizedWindow,
    ) -> Result<()> {
        if self.desktop_drag_active {
            self.desktop_authorization_floor =
                self.desktop_authorization_floor.max(authorized.generation);
            return Ok(());
        }
        if authorized.generation <= self.desktop_authorization_floor {
            return Ok(());
        }
        let now = elapsed_ns(self.session.origin)?;
        if self.session.state == State::DesktopPaused {
            let geometry = authorized.geometry;
            // A delayed/replayed watch value is not grounds to tear down the
            // paused desktop route. Keep the native connection ended until a
            // genuinely newer source decision can begin it again.
            if let Err(error) = self.session.resume_after_desktop_pause(authorized) {
                if self.session.state == State::DesktopPaused {
                    eprintln!("window desktop resume waiting for fresh authorization: {error:#}");
                    return Ok(());
                }
                return Err(error);
            }
            let (owner, presentations) = tokio::sync::watch::channel(geometry);
            self.presentations = presentations;
            self.selected_presentation_owner = Some(owner);
            self.announced = None;
            self.announced_keyboard = None;
            return Ok(());
        }
        if self.session.state == State::ResizeSuspended {
            let previous = self
                .session
                .resize_suspension
                .context("missing resize guard")?;
            // The unchanged watch value is not a new local decision. Do not
            // install old receipts or implicitly renew the suspended lease.
            if authorized.generation <= previous.lease_generation {
                anyhow::ensure!(
                    authorized.generation == previous.lease_generation
                        && authorized.owner == previous.owner_device
                        && authorized.target_device == previous.target_device
                        && authorized.expires_local_ns == self.session.expires
                        && authorized.geometry.identity().window == previous.target_window
                        && authorized.geometry.identity().geometry_epoch == previous.geometry_epoch
                        && (
                            authorized.native_address,
                            authorized.native_surface,
                            authorized.native_pid
                        ) == self.session.native_binding
                        && authorized.surface_extent == self.session.surface_extent
                        && authorized.content_origin == self.session.content_origin
                        && authorized.content_scale == self.session.content_scale,
                    "stale resize selection changed source authority"
                );
                return Ok(());
            }
            let geometry = authorized.geometry;
            self.session.rebind_resized(authorized)?;
            let (owner, presentations) = tokio::sync::watch::channel(geometry);
            self.presentations = presentations;
            self.selected_presentation_owner = Some(owner);
            self.announced = None;
            self.announced_keyboard = None;
            return Ok(());
        }
        let previous = self
            .session
            .grant
            .authorization(now)
            .context("source route expired")?;
        let next = WindowPointerGrant::new(
            authorized.owner,
            authorized.target_device,
            authorized.generation,
            authorized.geometry,
            authorized.expires_local_ns,
        )
        .and_then(|grant| grant.authorization(now))
        .context("selected authorization expired")?;
        if next.target_window == previous.target_window
            && next.geometry_epoch == previous.geometry_epoch
        {
            return self.session.install_authorization(authorized);
        }
        anyhow::ensure!(
            self.allow_switching,
            "source route does not permit window switching"
        );
        let geometry = authorized.geometry;
        self.session.switch_window(authorized)?;
        let (owner, presentations) = tokio::sync::watch::channel(geometry);
        self.presentations = presentations;
        self.selected_presentation_owner = Some(owner);
        self.announced = None;
        self.announced_keyboard = None;
        Ok(())
    }
}

impl WindowInputSession {
    pub(super) fn rebind_resized(&mut self, authorized: AuthorizedWindow) -> Result<()> {
        anyhow::ensure!(
            self.state == State::ResizeSuspended,
            "resize recovery requires suspension"
        );
        let now = elapsed_ns(self.origin)?;
        anyhow::ensure!(now < self.expires, "resize guard expired");
        let previous = self
            .resize_suspension
            .context("missing resize authorization")?;
        let grant = switch_grant(&authorized, self.origin)?;
        let next = grant
            .authorization(now)
            .context("resize authorization expired")?;
        anyhow::ensure!(
            next.owner_device == previous.owner_device
                && next.target_device == previous.target_device
                && next.target_window == previous.target_window
                && next.geometry_epoch > previous.geometry_epoch
                && next.presented_frame > previous.presented_frame
                && next.lease_generation > previous.lease_generation
                && (
                    authorized.native_address,
                    authorized.native_surface,
                    authorized.native_pid
                ) == self.native_binding,
            "resize recovery changed identity or did not advance geometry authority"
        );
        let sequence = self.connection.next_sequence();
        let keyboard = self
            .keyboard_grant
            .as_ref()
            .map(|_| Self::new_keyboard_grant(&authorized))
            .transpose()?;
        let request = Request::rebind_resized(
            sequence,
            authorized.generation,
            authorized.native_address,
            authorized.native_pid,
            native_deadline(self.origin, authorized.expires_local_ns)?,
            authorized.surface_extent,
            authorized.native_surface,
        )
        .map_err(|error| anyhow!("native resize rebind: {error:?}"))?;
        if let Err(error) = self.connection.send(request) {
            self.revoke();
            return Err(error.into());
        }
        self.grant = grant;
        self.keyboard_grant = keyboard;
        self.sequence = sequence;
        self.generation = authorized.generation;
        self.expires = authorized.expires_local_ns;
        self.content_origin = authorized.content_origin;
        self.content_scale = authorized.content_scale;
        self.surface_extent = authorized.surface_extent;
        self.resize_suspension = None;
        self.state = State::Beginning;
        self.recovery_unconfirmed.store(true, Ordering::Release);
        self.last_native_send = None;
        Ok(())
    }

    /// Switch under a new explicit local authorization, without opening another
    /// native connection or resetting its command sequence. Poll until Begun;
    /// neither target can receive input while END/BEGIN is outstanding. The
    /// dispatcher must replace its old presentation watch before resuming input.
    /// Button permission is preserved, never promoted by the new window.
    /// # Errors
    /// Requires an idle, unexpired route, the same authenticated device pair,
    /// a different target (or strictly newer geometry of the same exact native
    /// target), and a strictly newer authorization generation. This cannot
    /// recover an already revoked native route.
    pub fn switch_window(&mut self, authorized: AuthorizedWindow) -> Result<()> {
        self.switch_window_inner(authorized, None)
    }

    fn switch_window_mode(
        &mut self,
        authorized: AuthorizedWindow,
        keyboard_mode: bool,
    ) -> Result<()> {
        anyhow::ensure!(
            !keyboard_mode || self.allow_keyboard,
            "keyboard activation exceeds local capability"
        );
        self.switch_window_inner(authorized, Some(keyboard_mode))
    }

    fn switch_window_inner(
        &mut self,
        authorized: AuthorizedWindow,
        keyboard_mode: Option<bool>,
    ) -> Result<()> {
        anyhow::ensure!(
            self.state == State::Ready,
            "window switch requires an idle native route"
        );
        let now = elapsed_ns(self.origin)?;
        let previous = self
            .grant
            .authorization(now)
            .context("window switch authority expired")?;
        let grant = switch_grant(&authorized, self.origin)?;
        let next = grant
            .authorization(now)
            .context("new window authority expired")?;
        anyhow::ensure!(
            next.owner_device == previous.owner_device
                && next.target_device == previous.target_device
                && (next.target_window != previous.target_window
                    || (keyboard_mode.is_some_and(|mode| mode != self.keyboard_grant.is_some())
                        && next.geometry_epoch == previous.geometry_epoch
                        && next.presented_frame >= previous.presented_frame
                        && (
                            authorized.native_address,
                            authorized.native_surface,
                            authorized.native_pid
                        ) == self.native_binding)
                    || (next.geometry_epoch > previous.geometry_epoch
                        && next.presented_frame > previous.presented_frame
                        && (
                            authorized.native_address,
                            authorized.native_surface,
                            authorized.native_pid
                        ) == self.native_binding))
                && next.lease_generation > previous.lease_generation,
            "window switch changed peer/binding or failed to advance target authority"
        );
        let sequence = self.connection.next_sequence();
        let end = if keyboard_mode.is_some() {
            Request::end_preserving_focus
        } else {
            Request::end
        };
        let end = end(sequence, self.generation)
            .map_err(|error| anyhow!("native switch end: {error:?}"))?;
        if let Err(error) = self.connection.send(end) {
            self.revoke();
            return Err(error.into());
        }
        self.sequence = sequence;
        self.grant.revoke();
        if let Some(keyboard) = &mut self.keyboard_grant {
            keyboard.revoke();
        }
        self.pending_switch = Some(authorized);
        self.pending_keyboard_mode = keyboard_mode;
        self.state = State::SwitchingEnd;
        self.recovery_unconfirmed.store(true, Ordering::Release);
        Ok(())
    }

    pub(super) fn begin_after_switch_end(&mut self) -> Result<()> {
        let authorized = self
            .pending_switch
            .take()
            .context("missing switch authorization")?;
        // Time spent waiting for END cannot renew the incoming authorization.
        let grant = switch_grant(&authorized, self.origin)?;
        let sequence = self.connection.next_sequence();
        let keyboard_mode = self
            .pending_keyboard_mode
            .take()
            .unwrap_or(self.keyboard_grant.is_some());
        let keyboard_grant = keyboard_mode
            .then(|| Self::new_keyboard_grant(&authorized))
            .transpose()?;
        let begin = if keyboard_grant.is_some() {
            Request::begin_direct_keyboard
        } else if self.allow_wheel {
            Request::begin_buttons_wheel
        } else if self.allow_buttons {
            Request::begin_buttons
        } else {
            Request::begin
        };
        let request = begin(
            sequence,
            authorized.generation,
            authorized.native_address,
            authorized.native_pid,
            native_deadline(self.origin, authorized.expires_local_ns)?,
            authorized.surface_extent,
            authorized.native_surface,
        )
        .map_err(|error| anyhow!("native switched begin: {error:?}"))?;
        self.connection.send(request)?;
        self.grant = grant;
        self.keyboard_grant = keyboard_grant;
        self.sequence = sequence;
        self.generation = authorized.generation;
        self.expires = authorized.expires_local_ns;
        self.content_origin = authorized.content_origin;
        self.content_scale = authorized.content_scale;
        self.surface_extent = authorized.surface_extent;
        self.native_binding = (
            authorized.native_address,
            authorized.native_surface,
            authorized.native_pid,
        );
        self.state = State::Beginning;
        self.last_native_send = None;
        Ok(())
    }
}

pub(super) fn switch_grant(
    authorized: &AuthorizedWindow,
    origin: Instant,
) -> Result<WindowPointerGrant> {
    anyhow::ensure!(
        authorized
            .content_origin
            .iter()
            .all(|value| value.is_finite() && *value >= 0.0)
            && authorized
                .content_scale
                .iter()
                .all(|value| value.is_finite() && *value > 0.0),
        "invalid switched content mapping"
    );
    let deadline = native_deadline(origin, authorized.expires_local_ns)?;
    // Validate all native fields before ending the existing route.
    Request::begin(
        1,
        authorized.generation,
        authorized.native_address,
        authorized.native_pid,
        deadline,
        authorized.surface_extent,
        authorized.native_surface,
    )
    .map_err(|error| anyhow!("invalid switched native binding: {error:?}"))?;
    let grant = WindowPointerGrant::new(
        authorized.owner,
        authorized.target_device,
        authorized.generation,
        authorized.geometry,
        authorized.expires_local_ns,
    )
    .context("invalid switched window grant")?;
    anyhow::ensure!(
        grant.authorization(elapsed_ns(origin)?).is_some(),
        "switched grant expired"
    );
    Ok(grant)
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use nix::sys::socket::{self, AddressFamily, MsgFlags, SockFlag, SockType, UnixAddr};
    use std::os::fd::{AsRawFd, OwnedFd};
    use viewflow_core::PresentedInputGeometry;
    use viewflow_core::{CaptureGeometry, PresentedInputIdentity};
    use viewflow_hyprland::{window_pointer_socket::Event, window_pointer_wire::Outcome};
    use viewflow_protocol::{Id128, Point, Rect, Size};

    pub(in crate::window_input_runtime) fn authorization(
        window: u128,
        generation: u64,
    ) -> AuthorizedWindow {
        let rect = Rect {
            origin: Point::default(),
            size: Size {
                width: 100.0,
                height: 50.0,
            },
        };
        let capture = CaptureGeometry::new(rect, rect, 200, 100).unwrap();
        AuthorizedWindow {
            owner: Id128(1),
            target_device: Id128(2),
            generation,
            geometry: PresentedInputGeometry::new(
                PresentedInputIdentity {
                    window: Id128(window),
                    frame: 5,
                    geometry_epoch: 4,
                },
                capture,
                capture.slice_for_display(Point::default(), rect).unwrap(),
            )
            .unwrap(),
            expires_local_ns: 1_000_000_000,
            native_address: u64::try_from(window).unwrap(),
            native_surface: 789,
            native_pid: 456,
            surface_extent: [100.0, 50.0],
            content_origin: [0.0, 0.0],
            content_scale: [1.0, 1.0],
        }
    }

    pub(in crate::window_input_runtime) fn receive(peer: &OwnedFd) -> (u16, u64, u64) {
        let mut bytes = [0; 128];
        socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap();
        (
            u16::from_le_bytes(bytes[6..8].try_into().unwrap()),
            u64::from_le_bytes(bytes[12..20].try_into().unwrap()),
            u64::from_le_bytes(bytes[20..28].try_into().unwrap()),
        )
    }

    pub(in crate::window_input_runtime) fn reply(
        peer: &OwnedFd,
        sequence: u64,
        generation: u64,
        outcome: u32,
    ) {
        reply_for(peer, sequence, sequence, generation, outcome);
    }

    pub(in crate::window_input_runtime) fn reply_for(
        peer: &OwnedFd,
        envelope: u64,
        sequence: u64,
        generation: u64,
        outcome: u32,
    ) {
        let mut bytes = b"VFHY\x01\x00".to_vec();
        bytes.extend(53_u16.to_le_bytes());
        bytes.extend(24_u32.to_le_bytes());
        bytes.extend(envelope.to_le_bytes());
        bytes.extend(generation.to_le_bytes());
        bytes.extend(sequence.to_le_bytes());
        bytes.extend(outcome.to_le_bytes());
        bytes.extend(0_u32.to_le_bytes());
        socket::send(peer.as_raw_fd(), &bytes, MsgFlags::MSG_NOSIGNAL).unwrap();
    }

    pub(crate) async fn shared_switch(
        remote: &quinn::Connection,
        native: &OwnedFd,
        owner: tokio::sync::watch::Sender<AuthorizedWindow>,
        work: tokio::task::JoinHandle<Result<()>>,
        origin: Instant,
        mut first_control_sequence: u64,
        same_window_geometry: bool,
        resize_suspended: bool,
    ) {
        use std::time::Duration;
        use viewflow_protocol::{
            DomainControl, PROTOCOL_VERSION, WindowPointerMotion, WindowPointerResult, wire,
        };
        use viewflow_transport::{receive_control, send_control};
        if resize_suspended {
            revoked(native, 2, 7, 5);
            // With no fresh local selection there must be no native command
            // and no replacement authorization. The route must stay alive.
            assert!(
                tokio::time::timeout(Duration::from_millis(4), receive_control(remote))
                    .await
                    .is_err()
            );
            assert!(!work.is_finished());
            let mut bytes = [0; 128];
            assert!(matches!(
                socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT),
                Err(nix::errno::Errno::EAGAIN)
            ));
            let stale = WindowPointerMotion {
                lease_generation: 7,
                target_device: Id128(2),
                target_window: Id128(3),
                geometry_epoch: 4,
                presented_frame: 5,
                sequence: first_control_sequence,
                sender_not_after_ns: elapsed_ns(origin).unwrap() + 30_000_000,
                x_pixels: 100,
                y_pixels: 50,
                viewport_width: 200,
                viewport_height: 100,
            };
            send_control(
                remote,
                &wire::ControlEnvelope {
                    protocol_major: u32::from(PROTOCOL_VERSION.major),
                    protocol_minor: u32::from(PROTOCOL_VERSION.minor),
                    sequence: first_control_sequence,
                    payload: Some(wire::control_envelope::Payload::WindowPointerMotion(
                        stale.into(),
                    )),
                },
            )
            .await
            .unwrap();
            let response = tokio::time::timeout(Duration::from_millis(20), receive_control(remote))
                .await
                .unwrap()
                .unwrap();
            let DomainControl::WindowPointerAck(ack) = DomainControl::try_from(response).unwrap()
            else {
                panic!("expected paused input rejection");
            };
            assert_eq!(ack.result, WindowPointerResult::Rejected);
            assert!(!work.is_finished());
            assert!(matches!(
                socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT),
                Err(nix::errno::Errno::EAGAIN)
            ));
            first_control_sequence += 1;
        }
        let mut next = authorization(if same_window_geometry { 3 } else { 4 }, 8);
        if same_window_geometry {
            // The existing shared-route fixture binds window 3 to address 123.
            next.native_address = 123;
            let rect = Rect {
                origin: Point::default(),
                size: Size {
                    width: 120.0,
                    height: 50.0,
                },
            };
            let capture = CaptureGeometry::new(rect, rect, 240, 100).unwrap();
            next.geometry = PresentedInputGeometry::new(
                PresentedInputIdentity {
                    window: Id128(3),
                    frame: 6,
                    geometry_epoch: 5,
                },
                capture,
                capture.slice_for_display(Point::default(), rect).unwrap(),
            )
            .unwrap();
            next.surface_extent = [120.0, 50.0];
        }
        let identity = next.geometry.identity();
        owner.send(next).unwrap();
        let mut bytes = [0; 128];
        let commands = if resize_suspended {
            vec![(61, 2, 8, 1)]
        } else {
            vec![(52, 2, 7, 3), (50, 3, 8, 1)]
        };
        for (opcode, sequence, generation, outcome) in commands {
            tokio::time::timeout(Duration::from_millis(20), async {
                loop {
                    match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                        Ok(_) => break,
                        Err(nix::errno::Errno::EAGAIN) => {
                            tokio::time::sleep(Duration::from_millis(1)).await
                        }
                        other => panic!("expected switch command: {other:?}"),
                    }
                }
            })
            .await
            .unwrap();
            assert_eq!(u16::from_le_bytes(bytes[6..8].try_into().unwrap()), opcode);
            assert_eq!(
                u64::from_le_bytes(bytes[12..20].try_into().unwrap()),
                sequence
            );
            assert_eq!(
                u64::from_le_bytes(bytes[20..28].try_into().unwrap()),
                generation
            );
            assert!(
                tokio::time::timeout(Duration::from_millis(2), receive_control(remote))
                    .await
                    .is_err()
            );
            reply_for(
                native,
                if resize_suspended { 3 } else { sequence },
                sequence,
                generation,
                outcome,
            );
        }
        let update = tokio::time::timeout(Duration::from_millis(20), receive_control(remote))
            .await
            .unwrap()
            .unwrap();
        let DomainControl::WindowPointerAuthorization(update) =
            DomainControl::try_from(update).unwrap()
        else {
            panic!("expected switched authorization");
        };
        assert_eq!(update.target_window, identity.window);
        assert_eq!(update.lease_generation, 8);
        assert_eq!(update.geometry_epoch, identity.geometry_epoch);
        for (index, (control_sequence, window, generation)) in [
            (first_control_sequence, 3, 7),
            (first_control_sequence + 1, identity.window.0, 8),
        ]
        .into_iter()
        .enumerate()
        {
            let current = index == 1;
            let event = WindowPointerMotion {
                lease_generation: generation,
                target_device: Id128(2),
                target_window: Id128(window),
                geometry_epoch: if current { identity.geometry_epoch } else { 4 },
                presented_frame: if current { identity.frame } else { 5 },
                sequence: control_sequence,
                sender_not_after_ns: elapsed_ns(origin).unwrap() + 30_000_000,
                x_pixels: 100,
                y_pixels: 50,
                viewport_width: if current && same_window_geometry {
                    240
                } else {
                    200
                },
                viewport_height: 100,
            };
            send_control(
                remote,
                &wire::ControlEnvelope {
                    protocol_major: u32::from(PROTOCOL_VERSION.major),
                    protocol_minor: u32::from(PROTOCOL_VERSION.minor),
                    sequence: control_sequence,
                    payload: Some(wire::control_envelope::Payload::WindowPointerMotion(
                        event.into(),
                    )),
                },
            )
            .await
            .unwrap();
            if current {
                tokio::time::timeout(Duration::from_millis(20), async {
                    loop {
                        match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                            Ok(52) => break,
                            Err(nix::errno::Errno::EAGAIN) => {
                                tokio::time::sleep(Duration::from_millis(1)).await
                            }
                            other => panic!("expected new-window motion: {other:?}"),
                        }
                    }
                })
                .await
                .unwrap();
                assert_eq!(u16::from_le_bytes(bytes[6..8].try_into().unwrap()), 51);
                assert_eq!(u64::from_le_bytes(bytes[20..28].try_into().unwrap()), 8);
                reply_for(native, 4, if resize_suspended { 3 } else { 4 }, 8, 2);
            }
            let ack = tokio::time::timeout(Duration::from_millis(20), receive_control(remote))
                .await
                .unwrap()
                .unwrap();
            let DomainControl::WindowPointerAck(ack) = DomainControl::try_from(ack).unwrap() else {
                panic!("expected pointer acknowledgement");
            };
            assert_eq!(
                ack.result,
                if current {
                    WindowPointerResult::MotionSent
                } else {
                    WindowPointerResult::Rejected
                }
            );
            if !current {
                assert!(
                    socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).is_err()
                );
            }
        }
        drop(owner);
        assert!(
            tokio::time::timeout(Duration::from_secs(1), work)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
        assert_eq!(
            socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
            0
        );
    }

    #[test]
    fn atlas_hover_activation_and_cross_window_hover_use_explicit_native_modes() {
        use std::os::unix::fs::PermissionsExt;
        for allow_keyboard in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
                .unwrap();
            let path = directory.path().join("activation.sock");
            let listener = viewflow_hyprland::window_pointer_socket::Listener::bind(
                &path,
                i32::try_from(std::process::id()).unwrap(),
            )
            .unwrap();
            let peer = socket::socket(
                AddressFamily::Unix,
                SockType::SeqPacket,
                SockFlag::SOCK_NONBLOCK,
                None,
            )
            .unwrap();
            socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
            let session = WindowInputSession::prepare_atlas(
                listener.accept().unwrap(),
                authorization(3, 7),
                Instant::now(),
                true,
                allow_keyboard,
            )
            .unwrap();
            assert!(session.keyboard_grant.is_none());
            let (_clock, clock) = tokio::sync::watch::channel(None);
            let (_presentation, presentation) =
                tokio::sync::watch::channel(authorization(3, 7).geometry);
            let mut route = super::super::RoutedWindowInput::new(
                session,
                clock,
                presentation,
                None,
                true,
                |_| Ok(()),
            );
            let selection = viewflow_protocol::AtlasWindowSelection {
                activate_keyboard: false,
                stream_id: Id128(99),
                atlas_frame_id: 1,
                atlas_geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 1,
                window_id: Id128(4),
                placement_generation: 1,
                source_frame_id: 5,
                source_geometry_epoch: 4,
                sequence: 1,
                sender_not_after_ns: 30_000_000,
            };
            route
                .install_atlas_authorization(selection, authorization(4, 8))
                .unwrap();
            assert_eq!(receive(&peer), (58, 1, 8));
            assert!(route.session.keyboard_grant.is_none());
            reply(&peer, 1, 8, 1);
            route.session.poll().unwrap();
            let activation = viewflow_protocol::AtlasWindowSelection {
                activate_keyboard: true,
                sequence: 2,
                ..selection
            };
            if !allow_keyboard {
                assert!(
                    route
                        .install_atlas_authorization(activation, authorization(4, 9))
                        .is_err()
                );
                assert!(route.session.keyboard_grant.is_none());
                continue;
            }
            route
                .install_atlas_authorization(activation, authorization(4, 9))
                .unwrap();
            assert_eq!(receive(&peer), (62, 2, 8));
            assert_eq!(route.session.state, State::SwitchingEnd);
            assert!(route.session.keyboard_grant.is_none());
            reply(&peer, 2, 8, 3);
            route.session.poll().unwrap();
            assert_eq!(receive(&peer), (59, 3, 9));
            assert_eq!(route.session.state, State::Beginning);
            reply(&peer, 3, 9, 1);
            route.session.poll().unwrap();
            assert!(route.session.keyboard_grant.is_some());
            route
                .install_atlas_authorization(
                    viewflow_protocol::AtlasWindowSelection {
                        sequence: 3,
                        ..selection
                    },
                    authorization(4, 9),
                )
                .unwrap();
            let mut bytes = [0; 128];
            assert!(matches!(
                socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT),
                Err(nix::errno::Errno::EAGAIN)
            ));
            assert!(route.session.keyboard_grant.is_some());
            route
                .install_atlas_authorization(
                    viewflow_protocol::AtlasWindowSelection {
                        window_id: Id128(5),
                        sequence: 4,
                        ..selection
                    },
                    authorization(5, 10),
                )
                .unwrap();
            assert_eq!(receive(&peer), (62, 4, 9));
            reply(&peer, 4, 9, 3);
            route.session.poll().unwrap();
            assert_eq!(receive(&peer), (58, 5, 10));
            reply(&peer, 5, 10, 1);
            route.session.poll().unwrap();
            assert!(route.session.keyboard_grant.is_none());
        }
    }

    #[test]
    fn same_window_geometry_rebind_requires_end_and_preserves_native_identity() {
        geometry_rebind(false);
    }

    #[test]
    fn atlas_startup_does_not_take_local_seat_before_explicit_selection() {
        let directory = tempfile::tempdir().unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("deferred.sock");
        let listener = viewflow_hyprland::window_pointer_socket::Listener::bind(
            &path,
            i32::try_from(std::process::id()).unwrap(),
        )
        .unwrap();
        let peer = socket::socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_NONBLOCK,
            None,
        )
        .unwrap();
        socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
        let mut session = WindowInputSession::prepare_atlas(
            listener.accept().unwrap(),
            authorization(3, 7),
            Instant::now(),
            false,
            false,
        )
        .unwrap();
        let mut bytes = [0; 128];
        assert!(matches!(
            socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT),
            Err(nix::errno::Errno::EAGAIN)
        ));
        assert_eq!(session.state, State::DesktopPaused);
        assert!(session.grant.authorization(0).is_none());
        session.expires = 0; // Retired comparison evidence cannot expire the idle video connection.
        assert!(session.poll().unwrap().is_none());
        assert!(
            session
                .resume_after_desktop_pause(authorization(4, 7))
                .is_err()
        );
        session
            .resume_after_desktop_pause(authorization(4, 8))
            .unwrap();
        let (_, sequence, generation) = receive(&peer);
        assert_eq!((sequence, generation), (1, 8));
        reply(&peer, sequence, generation, 1);
        session.poll().unwrap();
        assert_eq!(session.state, State::Ready);
    }

    #[test]
    fn closed_atlas_target_ends_exact_native_route_before_switching() {
        for reason in [2, 3, 4] {
            let directory = tempfile::tempdir().unwrap();
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
                .unwrap();
            let path = directory.path().join("closed-target.sock");
            let listener = viewflow_hyprland::window_pointer_socket::Listener::bind(
                &path,
                i32::try_from(std::process::id()).unwrap(),
            )
            .unwrap();
            let peer = socket::socket(
                AddressFamily::Unix,
                SockType::SeqPacket,
                SockFlag::SOCK_NONBLOCK,
                None,
            )
            .unwrap();
            socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
            let mut session = WindowInputSession::begin(
                listener.accept().unwrap(),
                authorization(3, 7),
                Instant::now(),
            )
            .unwrap();
            let (_membership, view) =
                tokio::sync::watch::channel(super::super::AtlasInputMembership::default());
            session.attach_atlas_membership(view);
            assert_eq!(receive(&peer), (50, 1, 7));
            reply(&peer, 1, 7, 1);
            session.poll().unwrap();
            revoked(&peer, 2, 7, reason);
            assert!(session.poll().unwrap().is_none());
            assert_eq!(session.state, State::ResizeSuspended);
            assert!(session.grant.authorization(0).is_none());
            session.pause_for_desktop().unwrap();
            assert_eq!(receive(&peer), (52, 2, 7));
            assert!(
                session
                    .resume_after_desktop_pause(authorization(4, 8))
                    .is_err()
            );
            // Native close can also arrive after local inventory has already
            // sent END. It cannot replace that command's exact completion.
            revoked(&peer, 3, 7, reason);
            assert!(session.poll().unwrap().is_none());
            assert_eq!(session.state, State::DesktopEnding);
            reply_for(&peer, 4, 2, 7, 3);
            session.poll().unwrap();
            assert_eq!(session.state, State::DesktopPaused);
            assert!(
                session
                    .resume_after_desktop_pause(authorization(3, 8))
                    .is_err()
            );
            session
                .resume_after_desktop_pause(authorization(4, 8))
                .unwrap();
            assert_eq!(receive(&peer), (50, 3, 8));
        }
    }

    #[test]
    fn capacity_withdrawal_after_resize_requires_explicit_native_end() {
        let directory = tempfile::tempdir().unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("capacity-pause.sock");
        let listener = viewflow_hyprland::window_pointer_socket::Listener::bind(
            &path,
            i32::try_from(std::process::id()).unwrap(),
        )
        .unwrap();
        let peer = socket::socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_NONBLOCK,
            None,
        )
        .unwrap();
        socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
        let mut session = WindowInputSession::begin(
            listener.accept().unwrap(),
            authorization(3, 7),
            Instant::now(),
        )
        .unwrap();
        assert_eq!(receive(&peer), (50, 1, 7));
        reply(&peer, 1, 7, 1);
        session.poll().unwrap();
        session.resize_suspension = session.grant.authorization(0);
        session.grant.revoke();
        session.state = State::ResizeSuspended;
        session.pause_for_desktop().unwrap();
        assert_eq!(receive(&peer), (52, 2, 7));
        assert_eq!(session.state, State::DesktopEnding);
        assert!(session.resize_suspension.is_none());
        reply(&peer, 2, 7, 3);
        session.poll().unwrap();
        assert_eq!(session.state, State::DesktopPaused);
        assert!(session.grant.authorization(0).is_none());
    }

    #[test]
    fn desktop_pause_waits_for_ended_and_resumes_noop_or_new_window() {
        let directory = tempfile::tempdir().unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("desktop-pause.sock");
        let listener = viewflow_hyprland::window_pointer_socket::Listener::bind(
            &path,
            i32::try_from(std::process::id()).unwrap(),
        )
        .unwrap();
        let peer = socket::socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_NONBLOCK,
            None,
        )
        .unwrap();
        socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
        let mut session = WindowInputSession::begin(
            listener.accept().unwrap(),
            authorization(3, 7),
            Instant::now(),
        )
        .unwrap();
        assert_eq!(receive(&peer), (50, 1, 7));
        reply(&peer, 1, 7, 1);
        session.poll().unwrap();

        session.pause_for_desktop().unwrap();
        assert_eq!(receive(&peer), (52, 2, 7));
        assert_eq!(session.state, State::DesktopEnding);
        // A controller cannot make the local route live again before the
        // exact END reply; there is no premature second BEGIN on the socket.
        assert!(
            session
                .resume_after_desktop_pause(authorization(3, 8))
                .is_err()
        );
        let mut bytes = [0; 128];
        assert!(matches!(
            socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT),
            Err(nix::errno::Errno::EAGAIN)
        ));

        reply(&peer, 2, 7, 3);
        assert!(matches!(
            session.poll().unwrap(),
            Some(Event::Completed(Outcome::Ended))
        ));
        assert_eq!(session.state, State::DesktopPaused);
        assert!(session.grant.authorization(0).is_none());
        // The old grant leaves the seat paused and does not emit BEGIN.
        assert!(
            session
                .resume_after_desktop_pause(authorization(3, 7))
                .is_err()
        );
        assert_eq!(session.state, State::DesktopPaused);
        assert!(matches!(
            socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT),
            Err(nix::errno::Errno::EAGAIN)
        ));

        let mut fresh = authorization(3, 8);
        let rect = Rect {
            origin: Point::default(),
            size: Size {
                width: 120.0,
                height: 50.0,
            },
        };
        let capture = CaptureGeometry::new(rect, rect, 240, 100).unwrap();
        // A no-op desktop Begin/End does not have to change geometry. A new
        // source frame is allowed; a newer authorization generation is required.
        fresh.geometry = PresentedInputGeometry::new(
            PresentedInputIdentity {
                window: Id128(3),
                frame: 6,
                geometry_epoch: 4,
            },
            capture,
            capture.slice_for_display(Point::default(), rect).unwrap(),
        )
        .unwrap();
        fresh.surface_extent = [120.0, 50.0];
        let (_clock_owner, clocks) = tokio::sync::watch::channel(None);
        let (_presentation_owner, presentations) = tokio::sync::watch::channel(fresh.geometry);
        let mut routed = super::super::RoutedWindowInput::new(
            session,
            clocks,
            presentations,
            None,
            true,
            |_| Ok(()),
        );
        routed.desktop_drag_active = true;
        routed
            .install_selected_authorization(fresh.clone())
            .unwrap();
        assert_eq!(routed.session.state, State::DesktopPaused);
        routed.desktop_drag_active = false;
        // A renewal observed during the drag cannot become a fresh selection
        // merely because End has completed in the meantime.
        routed
            .install_selected_authorization(fresh.clone())
            .unwrap();
        assert_eq!(routed.session.state, State::DesktopPaused);
        assert!(matches!(
            socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT),
            Err(nix::errno::Errno::EAGAIN)
        ));
        session = routed.session;
        session.resume_after_desktop_pause(fresh).unwrap();
        assert_eq!(receive(&peer), (50, 3, 8));
        assert_eq!(session.state, State::Beginning);
        reply(&peer, 3, 8, 1);
        session.poll().unwrap();

        session.pause_for_desktop().unwrap();
        assert_eq!(receive(&peer), (52, 4, 8));
        reply(&peer, 4, 8, 3);
        session.poll().unwrap();
        assert_eq!(session.state, State::DesktopPaused);

        // Frame/epoch counters belong to a window. A selected replacement may
        // legitimately have lower independent values, but must name a new
        // native binding and carry a newer authorization generation.
        let mut other = authorization(4, 9);
        let rect = Rect {
            origin: Point::default(),
            size: Size {
                width: 100.0,
                height: 50.0,
            },
        };
        let capture = CaptureGeometry::new(rect, rect, 200, 100).unwrap();
        other.geometry = PresentedInputGeometry::new(
            PresentedInputIdentity {
                window: Id128(4),
                frame: 1,
                geometry_epoch: 1,
            },
            capture,
            capture.slice_for_display(Point::default(), rect).unwrap(),
        )
        .unwrap();
        session.resume_after_desktop_pause(other).unwrap();
        assert_eq!(receive(&peer), (50, 5, 9));
        assert_eq!(session.state, State::Beginning);
    }

    #[test]
    fn native_resize_suspension_requires_explicit_rebind_and_fresh_geometry() {
        geometry_rebind(true);
    }

    #[test]
    fn resize_recovery_never_survives_pending_work_terminal_revocation_or_expiry() {
        for scenario in 0..10 {
            let directory = tempfile::tempdir().unwrap();
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
                .unwrap();
            let path = directory.path().join("resize.sock");
            let listener = viewflow_hyprland::window_pointer_socket::Listener::bind(
                &path,
                i32::try_from(std::process::id()).unwrap(),
            )
            .unwrap();
            let peer = socket::socket(
                AddressFamily::Unix,
                SockType::SeqPacket,
                SockFlag::SOCK_NONBLOCK,
                None,
            )
            .unwrap();
            socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
            let mut session = WindowInputSession::begin(
                listener.accept().unwrap(),
                authorization(3, 7),
                Instant::now(),
            )
            .unwrap();
            receive(&peer);
            session.allow_resize_recovery = scenario != 0;
            if scenario != 1 {
                reply(&peer, 1, 7, 1);
                session.poll().unwrap();
            }
            revoked(
                &peer,
                if scenario == 1 { 1 } else { 2 },
                if scenario == 2 { 8 } else { 7 },
                5,
            );
            if scenario <= 2 {
                // No opt-in, pending BEGIN, or wrong native generation.
                assert!(session.poll().is_err());
            } else {
                session.poll().unwrap();
                assert_eq!(session.state, State::ResizeSuspended);
                if scenario == 3 {
                    session.expires = 0;
                } else {
                    // Local key/motion, lock, unmap, expiry, repeated resize.
                    let reason = [10, 7, 6, 2, 13, 5][scenario - 4];
                    revoked(&peer, 3, 7, reason);
                }
                assert!(session.poll().is_err());
            }
            assert_eq!(session.state, State::Ended);
            assert!(session.grant.authorization(0).is_none());
            assert!(session.resize_suspension.is_none());
            assert!(session.rebind_resized(authorization(3, 8)).is_err());
        }
    }

    #[tokio::test]
    async fn cursor_local_revocation_retires_old_grant_and_requires_fresh_begin() {
        for scenario in 0..5 {
            let directory = tempfile::tempdir().unwrap();
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
                .unwrap();
            let path = directory.path().join("cursor.sock");
            let listener = viewflow_hyprland::window_pointer_socket::Listener::bind(
                &path,
                i32::try_from(std::process::id()).unwrap(),
            )
            .unwrap();
            let peer = socket::socket(
                AddressFamily::Unix,
                SockType::SeqPacket,
                SockFlag::SOCK_NONBLOCK,
                None,
            )
            .unwrap();
            socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
            let mut session = WindowInputSession::begin(
                listener.accept().unwrap(),
                authorization(3, 7),
                Instant::now(),
            )
            .unwrap();
            receive(&peer);
            if scenario != 0 {
                session.attach_cursor(crate::atlas_cursor_handoff::CursorBridge::fixture());
            }
            if scenario != 1 {
                reply(&peer, 1, 7, 1);
                session.poll().unwrap();
            }
            revoked(
                &peer,
                if scenario == 1 { 1 } else { 2 },
                if scenario == 2 { 8 } else { 7 },
                if scenario == 3 { 16 } else { 7 },
            );
            if scenario < 4 {
                assert!(session.poll().is_err());
                assert_eq!(session.state, State::Ended);
            } else {
                assert!(session.poll().unwrap().is_none());
                assert_eq!(session.state, State::DesktopPaused);
                assert!(session.grant.authorization(0).is_none());
                assert!(
                    session
                        .recovery_unconfirmed
                        .load(std::sync::atomic::Ordering::Acquire)
                );
                assert!(
                    session
                        .resume_after_desktop_pause(authorization(3, 7))
                        .is_err()
                );
                session
                    .resume_after_desktop_pause(authorization(4, 8))
                    .unwrap();
                let (tag, sequence, generation) = receive(&peer);
                assert_eq!((tag, generation), (62, 7));
                assert_eq!(session.state, State::SwitchingEnd);
                session.expires = 0; // Old grant expiry cannot interrupt END.
                revoked(&peer, 3, generation, 13); // Native Expired precedes END receipt.
                session.poll().unwrap();
                assert_eq!(session.state, State::SwitchingEnd);
                reply_for(&peer, 4, sequence, generation, 3);
                session.poll().unwrap();
                let (tag, sequence, generation) = receive(&peer);
                assert_eq!((tag, generation), (50, 8));
                assert_eq!(session.state, State::Beginning);
                reply_for(&peer, 5, sequence, generation, 1);
                session.poll().unwrap();
                assert_eq!(session.state, State::Ready);
                assert!(
                    !session
                        .recovery_unconfirmed
                        .load(std::sync::atomic::Ordering::Acquire)
                );
            }
        }
    }

    pub(in crate::window_input_runtime) fn revoked(
        peer: &OwnedFd,
        envelope: u64,
        generation: u64,
        reason: u32,
    ) {
        let mut bytes = b"VFHY\x01\x00".to_vec();
        bytes.extend(54_u16.to_le_bytes());
        bytes.extend(16_u32.to_le_bytes());
        bytes.extend(envelope.to_le_bytes());
        bytes.extend(generation.to_le_bytes());
        bytes.extend(reason.to_le_bytes());
        bytes.extend(0_u32.to_le_bytes());
        socket::send(peer.as_raw_fd(), &bytes, MsgFlags::MSG_NOSIGNAL).unwrap();
    }

    fn geometry_rebind(resize: bool) {
        let directory = tempfile::tempdir().unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("geometry.sock");
        let listener = viewflow_hyprland::window_pointer_socket::Listener::bind(
            &path,
            i32::try_from(std::process::id()).unwrap(),
        )
        .unwrap();
        let peer = socket::socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_NONBLOCK,
            None,
        )
        .unwrap();
        socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
        let mut session = WindowInputSession::begin_with_capabilities(
            listener.accept().unwrap(),
            authorization(3, 7),
            Instant::now(),
            true,
            true,
            true,
        )
        .unwrap();
        assert_eq!(receive(&peer), (59, 1, 7));
        reply(&peer, 1, 7, 1);
        session.poll().unwrap();
        if resize {
            session.allow_resize_recovery = true;
            revoked(&peer, 2, 7, 5);
            assert!(session.poll().unwrap().is_none());
            assert_eq!(session.state, State::ResizeSuspended);
            assert!(session.grant.authorization(0).is_none());
            assert!(
                session
                    .recovery_unconfirmed
                    .load(std::sync::atomic::Ordering::Acquire)
            );
            assert!(session.renew(authorization(3, 8)).is_err());
        }
        let mut next = authorization(3, 8);
        let rect = Rect {
            origin: Point::default(),
            size: Size {
                width: 120.0,
                height: 50.0,
            },
        };
        let capture = CaptureGeometry::new(rect, rect, 240, 100).unwrap();
        next.geometry = PresentedInputGeometry::new(
            PresentedInputIdentity {
                window: Id128(3),
                frame: 6,
                geometry_epoch: 5,
            },
            capture,
            capture.slice_for_display(Point::default(), rect).unwrap(),
        )
        .unwrap();
        next.surface_extent = [120.0, 50.0];
        for field in 0..4 {
            let mut bad = next.clone();
            match field {
                0 => bad.native_address += 1,
                1 => bad.native_surface += 1,
                2 => bad.native_pid += 1,
                _ => bad.generation = 7,
            }
            if resize {
                assert!(session.rebind_resized(bad).is_err());
                assert_eq!(session.state, State::ResizeSuspended);
            } else {
                assert!(session.switch_window(bad).is_err());
                assert_eq!(session.state, State::Ready);
            }
        }
        if resize {
            assert!(session.rebind_resized(authorization(3, 8)).is_err()); // old epoch/frame
            assert!(session.rebind_resized(authorization(4, 8)).is_err()); // different target
            session.rebind_resized(next).unwrap();
            assert_eq!(receive(&peer), (61, 2, 8));
            assert_eq!(session.state, State::Beginning);
            assert!(
                session
                    .recovery_unconfirmed
                    .load(std::sync::atomic::Ordering::Acquire)
            );
            reply_for(&peer, 3, 2, 8, 1);
            session.poll().unwrap();
        } else {
            session.switch_window(next).unwrap();
            assert_eq!(receive(&peer), (52, 2, 7));
            assert!(session.grant.authorization(0).is_none());
            assert_eq!(session.state, State::SwitchingEnd);
            assert!(session.poll().unwrap().is_none());
            reply(&peer, 2, 7, 3);
            session.poll().unwrap();
            assert_eq!(receive(&peer), (59, 3, 8));
            assert_eq!(session.state, State::Beginning);
            reply(&peer, 3, 8, 1);
            session.poll().unwrap();
        }
        assert_eq!(session.state, State::Ready);
        let grant = session.grant.authorization(0).unwrap();
        assert_eq!(grant.target_window, Id128(3));
        assert_eq!(grant.geometry_epoch, 5);
        assert_eq!(grant.presented_frame, 6);
        assert_eq!(session.surface_extent, [120.0, 50.0]);
        assert!(session.allow_buttons && session.allow_wheel && session.keyboard_grant.is_some());
        let fresh = viewflow_protocol::WindowPointerMotion {
            lease_generation: 8,
            target_device: Id128(2),
            target_window: Id128(3),
            geometry_epoch: 5,
            presented_frame: 6,
            sequence: 1,
            sender_not_after_ns: 1000,
            x_pixels: 100,
            y_pixels: 50,
            viewport_width: 240,
            viewport_height: 100,
        };
        for stale in [
            viewflow_protocol::WindowPointerMotion {
                lease_generation: 7,
                ..fresh
            },
            viewflow_protocol::WindowPointerMotion {
                geometry_epoch: 4,
                ..fresh
            },
            viewflow_protocol::WindowPointerMotion {
                presented_frame: 5,
                ..fresh
            },
        ] {
            assert!(
                session
                    .grant
                    .admit_motion(Id128(1), stale, Some(1000), 1)
                    .is_none()
            );
        }
        assert!(
            session
                .grant
                .admit_motion(Id128(1), fresh, Some(1000), 1)
                .is_some()
        );
        // A revoked route is never resurrected by this geometry path.
        session.revoke();
        assert!(session.switch_window(authorization(3, 9)).is_err());
    }

    #[test]
    fn switch_requires_end_confirmation_and_preserves_connection_sequence() {
        for (mode, expire_pending) in [
            (0, false),
            (1, false),
            (2, false),
            (3, false),
            (0, true),
            (1, true),
            (2, true),
            (3, true),
        ] {
            let buttons = mode != 0;
            let wheel = mode >= 2;
            let directory = tempfile::tempdir().unwrap();
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
                .unwrap();
            let path = directory.path().join("switch.sock");
            let listener = viewflow_hyprland::window_pointer_socket::Listener::bind(
                &path,
                i32::try_from(std::process::id()).unwrap(),
            )
            .unwrap();
            let peer = socket::socket(
                AddressFamily::Unix,
                SockType::SeqPacket,
                SockFlag::SOCK_NONBLOCK,
                None,
            )
            .unwrap();
            socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
            let mut session = WindowInputSession::begin_with_capabilities(
                listener.accept().unwrap(),
                authorization(3, 7),
                Instant::now(),
                buttons,
                wheel,
                mode == 3,
            )
            .unwrap();
            let begin_opcode = if mode == 3 {
                59
            } else if wheel {
                58
            } else if buttons {
                56
            } else {
                50
            };
            assert_eq!(receive(&peer), (begin_opcode, 1, 7));
            reply(&peer, 1, 7, 1);
            session.poll().unwrap();
            for candidate in [authorization(3, 8), authorization(4, 7)] {
                assert!(session.switch_window(candidate).is_err());
                assert_eq!(session.state, State::Ready);
            }
            let mut wrong_peer = authorization(4, 8);
            wrong_peer.owner = Id128(10);
            assert!(session.switch_window(wrong_peer).is_err());
            session.switch_window(authorization(4, 8)).unwrap();
            assert_eq!(receive(&peer), (52, 2, 7));
            assert_eq!(session.state, State::SwitchingEnd);
            assert!(session.grant.authorization(0).is_none());
            assert!(session.switch_window(authorization(5, 9)).is_err());
            assert!(session.poll().unwrap().is_none());
            let mut bytes = [0; 128];
            assert!(socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).is_err());
            reply(&peer, 2, 7, 3);
            assert!(matches!(
                session.poll().unwrap(),
                Some(Event::Completed(Outcome::Ended))
            ));
            assert_eq!(receive(&peer), (begin_opcode, 3, 8));
            assert_eq!(session.state, State::Beginning);
            reply(&peer, 3, 8, 1);
            session.poll().unwrap();
            assert_eq!(session.state, State::Ready);
            assert_eq!(
                session.grant.authorization(0).unwrap().target_window,
                Id128(4)
            );
            assert_eq!(session.allow_buttons, buttons);
            assert_eq!(session.allow_wheel, wheel);
            // Rejected END or a new grant expiring during END cannot emit BEGIN.
            session.switch_window(authorization(5, 9)).unwrap();
            assert_eq!(receive(&peer), (52, 4, 8));
            if expire_pending {
                session.pending_switch.as_mut().unwrap().expires_local_ns = 0;
            }
            reply(&peer, 4, 8, if expire_pending { 3 } else { 0 });
            assert!(session.poll().is_err());
            assert_eq!(session.state, State::Ended);
            assert!(session.pending_switch.is_none());
            assert_eq!(
                socket::recv(peer.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT).unwrap(),
                0
            );
        }
    }
}
