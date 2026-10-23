//! Explicit source-local direct keyboard policy on the shared native FIFO.
use super::{
    AuthorizedWindow, ClockSnapshot, State, WindowInputSession, conservative_input_deadline,
    elapsed_ns, native_deadline,
};
use anyhow::{Context, Result, anyhow};
use std::{sync::atomic::Ordering, time::Instant};
use viewflow_core::WindowKeyboardGrant;
use viewflow_hyprland::{window_pointer_socket::Connection, window_pointer_wire::Request};
use viewflow_protocol::{InputSwitchState, WindowKeyboardAuthorization, WindowKeyboardEvent};
use viewflow_transport::ClockEstimate;

impl WindowInputSession {
    /// Deliver on the authenticated shared reader; success requires exact native
    /// confirmation. The caller owns network sequencing and acknowledgement send.
    /// # Errors
    /// Any context, timing, native or transport failure revokes the route.
    pub async fn deliver_key(
        &mut self,
        network: &quinn::Connection,
        event: WindowKeyboardEvent,
        estimate: Option<(ClockEstimate, u64)>,
        presentations: &mut tokio::sync::watch::Receiver<viewflow_core::PresentedInputGeometry>,
        metadata: &mut impl FnMut(Vec<u8>) -> Result<()>,
    ) -> Result<viewflow_protocol::WindowKeyboardAck> {
        let result = async {
            self.wait_native(network, presentations, metadata).await?;
            if self.state != State::Ready {
                return Ok(viewflow_protocol::WindowKeyboardAck {
                    event,
                    result: viewflow_protocol::WindowKeyboardResult::Rejected,
                });
            }
            if presentations.has_changed()? {
                self.install_receipt(Ok(()), presentations)?;
            }
            if let Some(reason) = network.close_reason() {
                return Err(reason).context("keyboard peer disconnected");
            }
            self.key(event, estimate)?;
            self.wait_native(network, presentations, metadata).await?;
            Ok(viewflow_protocol::WindowKeyboardAck {
                event,
                result: viewflow_protocol::WindowKeyboardResult::KeySent,
            })
        }
        .await;
        if result.is_err() {
            self.revoke();
        }
        result
    }
    /// Explicit LOCAL direct-application keyboard decision, also enabling buttons
    /// and wheel. Incoming events and pointer grants must never select this mode.
    /// This mode does not support routing through an active source IME grab.
    /// # Errors
    /// Invalid authorization, expired deadline or native transport failure.
    pub fn begin_direct_keyboard(
        connection: Connection,
        authorized: AuthorizedWindow,
        origin: Instant,
    ) -> Result<Self> {
        Self::begin_with_capabilities(connection, authorized, origin, true, true, true)
    }

    pub(super) fn new_keyboard_grant(authorized: &AuthorizedWindow) -> Result<WindowKeyboardGrant> {
        WindowKeyboardGrant::new(
            authorized.owner,
            authorized.target_device,
            authorized.generation,
            authorized.geometry.identity(),
            authorized.expires_local_ns,
        )
        .context("invalid keyboard grant")
    }

    /// Available only while native BEGIN/renewal has completed and the FIFO is
    /// idle. This is separate from pointer authorization and never promotes it.
    #[must_use]
    pub fn keyboard_authorization(&self) -> Option<WindowKeyboardAuthorization> {
        if self.state != State::Ready {
            return None;
        }
        self.keyboard_grant
            .as_ref()?
            .authorization(elapsed_ns(self.origin).ok()?)
    }

    /// Queue one authenticated physical usage, never text or a global shortcut.
    /// Completion is observable only through a matching native `KeySent` from poll.
    /// # Errors
    /// All rejection or uncertainty retires the connection for native cleanup.
    pub fn key(
        &mut self,
        event: WindowKeyboardEvent,
        estimate: Option<(ClockEstimate, u64)>,
    ) -> Result<()> {
        let result = self.send_key(event, estimate);
        if result.is_err() {
            self.revoke();
        }
        result
    }

    fn send_key(
        &mut self,
        event: WindowKeyboardEvent,
        estimate: Option<(ClockEstimate, u64)>,
    ) -> Result<()> {
        anyhow::ensure!(
            self.state == State::Ready,
            "native window command pending or ended"
        );
        let now = elapsed_ns(self.origin)?;
        let deadline = conservative_input_deadline(
            event.sender_not_after_ns,
            estimate.map(|(estimate, measured_at_local_ns)| ClockSnapshot {
                estimate,
                measured_at_local_ns,
            }),
            now,
        )
        .ok();
        let deadline = self
            .keyboard_grant
            .as_mut()
            .context("no keyboard authority")?
            .prepare(self.owner, event, deadline, now)
            .context("keyboard event not admitted")?;
        let sequence = self.connection.next_sequence();
        let request = Request::key(
            sequence,
            self.generation,
            native_deadline(self.origin, deadline)?,
            [event.key.usage_page, event.key.usage_id],
            match event.key.state {
                InputSwitchState::Pressed => 1,
                InputSwitchState::Released => 2,
            },
            event.key.repeat,
        )
        .map_err(|error| anyhow!("native keyboard request: {error:?}"))?;
        self.connection.send(request)?;
        self.sequence = sequence;
        self.pending_key = Some(event);
        self.state = State::Keying;
        self.recovery_unconfirmed.store(true, Ordering::Release);
        Ok(())
    }
}

impl super::RoutedWindowInput<'_> {
    pub(crate) fn keyboard_announcement(&mut self) -> Result<Option<WindowKeyboardAuthorization>> {
        self.clocks.has_changed()?;
        if self.clocks.borrow().is_none() {
            return Ok(None);
        }
        if let Some(owner) = &self.authorizations {
            if owner.has_changed()? {
                return Ok(None);
            }
        }
        let Some(authorization) = self.session.keyboard_authorization() else {
            return Ok(None);
        };
        if self.announced_keyboard == Some(authorization) {
            return Ok(None);
        }
        self.announced_keyboard = Some(authorization);
        Ok(Some(authorization))
    }

    pub(crate) async fn deliver_key(
        &mut self,
        network: &quinn::Connection,
        event: WindowKeyboardEvent,
    ) -> Result<viewflow_protocol::WindowKeyboardAck> {
        if self
            .authorizations
            .as_ref()
            .is_some_and(|owner| owner.has_changed().unwrap_or(true))
        {
            self.maintain(network).await?;
        }
        if let Some(owner) = &self.authorizations {
            owner.has_changed()?;
        }
        self.clocks.has_changed()?;
        let estimate = self
            .clocks
            .borrow()
            .map(|snapshot| (snapshot.estimate, snapshot.measured_at_local_ns));
        self.session
            .deliver_key(
                network,
                event,
                estimate,
                &mut self.presentations,
                &mut self.metadata,
            )
            .await
    }
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use crate::window_input_runtime::window_switch::tests::{authorization, receive, reply};
    use nix::sys::socket::{self, AddressFamily, MsgFlags, SockFlag, SockType, UnixAddr};
    use std::os::{
        fd::{AsRawFd, OwnedFd},
        unix::fs::PermissionsExt,
    };
    use viewflow_hyprland::window_pointer_socket::Listener;
    use viewflow_protocol::{Id128, KeyboardHidUsage};

    pub(in crate::window_input_runtime) async fn preview_keys(
        events: &crate::window_preview_input::PreviewPointerEvents,
        acknowledgements: &mut tokio::sync::watch::Receiver<
            Option<viewflow_protocol::WindowPointerAck>,
        >,
        native: &OwnedFd,
        origin: Instant,
        presented: viewflow_core::PresentedInputIdentity,
        sample_sequence: &mut u64,
    ) {
        use crate::window_preview_input::{PreviewPointerEvent, PreviewPointerSample};
        use std::time::Duration;
        for index in 0..4 {
            *sample_sequence += 1;
            let key = (index % 2 == 0).then_some(KeyboardHidUsage {
                usage_page: 7,
                usage_id: 4,
                state: if index == 0 {
                    InputSwitchState::Pressed
                } else {
                    InputSwitchState::Released
                },
                repeat: false,
            });
            events
                .push(PreviewPointerEvent {
                    sample: PreviewPointerSample {
                        sample_sequence: *sample_sequence,
                        presented,
                        sender_not_after_ns: elapsed_ns(origin).unwrap() + 30_000_000,
                        x_pixels: 10,
                        y_pixels: 10,
                        viewport_width: 200,
                        viewport_height: 100,
                    },
                    button: None,
                    wheel: None,
                    key,
                })
                .unwrap();
        }
        for index in 0..4 {
            let mut bytes = [0; 128];
            tokio::time::timeout(Duration::from_millis(20), async {
                loop {
                    match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                        Ok(size) => {
                            assert_eq!(size, 52);
                            break;
                        }
                        Err(nix::errno::Errno::EAGAIN) => {
                            tokio::time::sleep(Duration::from_millis(1)).await
                        }
                        other => panic!("expected mixed FIFO event: {other:?}"),
                    }
                }
            })
            .await
            .unwrap();
            let key = index % 2 == 0;
            assert_eq!(
                u16::from_le_bytes(bytes[6..8].try_into().unwrap()),
                if key { 60 } else { 51 }
            );
            let sequence = u64::from_le_bytes(bytes[12..20].try_into().unwrap());
            if key {
                assert_eq!(u32::from_le_bytes(bytes[36..40].try_into().unwrap()), 7);
                assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 4);
                assert_eq!(
                    u32::from_le_bytes(bytes[44..48].try_into().unwrap()),
                    if index == 0 { 1 } else { 2 }
                );
            }
            // Queued following motion cannot overtake this unconfirmed key.
            assert!(
                tokio::time::timeout(Duration::from_millis(2), acknowledgements.changed())
                    .await
                    .is_err()
            );
            assert!(
                socket::recv(native.as_raw_fd(), &mut [0; 128], MsgFlags::MSG_DONTWAIT).is_err()
            );
            reply(native, sequence, 7, if key { 6 } else { 2 });
            if !key {
                tokio::time::timeout(Duration::from_millis(24), acknowledgements.changed())
                    .await
                    .unwrap()
                    .unwrap();
                let ack = acknowledgements.borrow_and_update().unwrap();
                assert_eq!(ack.event_sequence, sequence - 1);
                assert_eq!(
                    ack.result,
                    viewflow_protocol::WindowPointerResult::MotionSent
                );
            }
        }
    }

    pub(in crate::window_input_runtime) async fn shared_keyboard(
        remote: &quinn::Connection,
        native: &OwnedFd,
        work: tokio::task::JoinHandle<Result<()>>,
        origin: Instant,
        denied: bool,
        wrong_ack: bool,
    ) {
        use std::time::Duration;
        use viewflow_protocol::{DomainControl, PROTOCOL_VERSION, WindowKeyboardResult, wire};
        use viewflow_transport::{receive_control, send_control};
        let envelope = |sequence, released| {
            let event = WindowKeyboardEvent {
                lease_generation: 7,
                target_device: Id128(2),
                target_window: Id128(3),
                geometry_epoch: 4,
                presented_frame: 5,
                sequence,
                sender_not_after_ns: elapsed_ns(origin).unwrap() + 30_000_000,
                key: KeyboardHidUsage {
                    usage_page: 7,
                    usage_id: 4,
                    state: if released {
                        InputSwitchState::Released
                    } else {
                        InputSwitchState::Pressed
                    },
                    repeat: false,
                },
            };
            (
                event,
                wire::ControlEnvelope {
                    protocol_major: u32::from(PROTOCOL_VERSION.major),
                    protocol_minor: u32::from(PROTOCOL_VERSION.minor),
                    sequence,
                    payload: Some(wire::control_envelope::Payload::WindowKeyboardEvent(
                        event.into(),
                    )),
                },
            )
        };
        let mut bytes = [0; 128];
        for (sequence, released) in [(3, false), (4, true)] {
            let (event, message) = envelope(sequence, released);
            send_control(remote, &message).await.unwrap();
            if denied {
                break;
            }
            tokio::time::timeout(Duration::from_millis(20), async {
                loop {
                    match socket::recv(native.as_raw_fd(), &mut bytes, MsgFlags::MSG_DONTWAIT) {
                        Ok(size) => {
                            assert_eq!(size, 52);
                            break;
                        }
                        Err(nix::errno::Errno::EAGAIN) => {
                            tokio::time::sleep(Duration::from_millis(1)).await
                        }
                        other => panic!("expected native key: {other:?}"),
                    }
                }
            })
            .await
            .unwrap();
            assert_eq!(u16::from_le_bytes(bytes[6..8].try_into().unwrap()), 60);
            assert_eq!(
                u64::from_le_bytes(bytes[12..20].try_into().unwrap()),
                sequence - 1
            );
            assert!(
                tokio::time::timeout(Duration::from_millis(2), receive_control(remote))
                    .await
                    .is_err()
            );
            reply(native, sequence - 1, 7, if wrong_ack { 2 } else { 6 });
            if wrong_ack {
                break;
            }
            let ack = tokio::time::timeout(Duration::from_millis(24), receive_control(remote))
                .await
                .unwrap()
                .unwrap();
            let DomainControl::WindowKeyboardAck(ack) = DomainControl::try_from(ack).unwrap()
            else {
                panic!("expected dedicated keyboard ACK");
            };
            assert_eq!(ack.event, event);
            assert_eq!(ack.result, WindowKeyboardResult::KeySent);
        }
        if !denied && !wrong_ack {
            // Exact network sequence replay must retire the route before injection.
            send_control(remote, &envelope(4, true).1).await.unwrap();
        }
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
        assert!(
            tokio::time::timeout(Duration::from_millis(100), receive_control(remote))
                .await
                .unwrap()
                .is_err()
        );
    }

    fn fixture(enabled: bool) -> (tempfile::TempDir, OwnedFd, WindowInputSession) {
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("keyboard.sock");
        let listener = Listener::bind(&path, i32::try_from(std::process::id()).unwrap()).unwrap();
        let peer = socket::socket(
            AddressFamily::Unix,
            SockType::SeqPacket,
            SockFlag::SOCK_NONBLOCK,
            None,
        )
        .unwrap();
        socket::connect(peer.as_raw_fd(), &UnixAddr::new(&path).unwrap()).unwrap();
        let begin = if enabled {
            WindowInputSession::begin_direct_keyboard
        } else {
            WindowInputSession::begin_buttons_wheel
        };
        let mut session = begin(
            listener.accept().unwrap(),
            authorization(3, 7),
            Instant::now(),
        )
        .unwrap();
        assert!(session.keyboard_authorization().is_none());
        assert_eq!(receive(&peer), (if enabled { 59 } else { 58 }, 1, 7));
        reply(&peer, 1, 7, 1);
        session.poll().unwrap();
        assert_eq!(session.keyboard_authorization().is_some(), enabled);
        (directory, peer, session)
    }

    fn send(session: &mut WindowInputSession, sequence: u64, released: bool) -> Result<()> {
        let now = elapsed_ns(session.origin).unwrap();
        let auth = session.grant.authorization(now).unwrap();
        session.key(
            WindowKeyboardEvent {
                lease_generation: auth.lease_generation,
                target_device: Id128(2),
                target_window: Id128(3),
                geometry_epoch: 4,
                presented_frame: auth.presented_frame,
                sequence,
                sender_not_after_ns: now + 30_000_000,
                key: KeyboardHidUsage {
                    usage_page: 7,
                    usage_id: 4,
                    state: if released {
                        InputSwitchState::Released
                    } else {
                        InputSwitchState::Pressed
                    },
                    repeat: false,
                },
            },
            Some((
                ClockEstimate {
                    remote_offset_ns: 0,
                    uncertainty_ns: 0,
                    network_round_trip_ns: 0,
                },
                now,
            )),
        )
    }

    #[test]
    fn keyboard_native_fifo_renewal_preserves_held_usage_and_confirmation() {
        let (_directory, peer, mut session) = fixture(true);
        send(&mut session, 1, false).unwrap();
        assert_eq!(receive(&peer), (60, 2, 7));
        assert!(session.keyboard_authorization().is_none());
        assert!(session.poll().unwrap().is_none());
        reply(&peer, 2, 7, 6);
        session.poll().unwrap();
        let mut next = authorization(3, 8);
        // New verified frame, same native geometry and object binding.
        let rect = viewflow_protocol::Rect {
            origin: viewflow_protocol::Point::default(),
            size: viewflow_protocol::Size {
                width: 100.0,
                height: 50.0,
            },
        };
        let capture = viewflow_core::CaptureGeometry::new(rect, rect, 200, 100).unwrap();
        next.geometry = viewflow_core::PresentedInputGeometry::new(
            viewflow_core::PresentedInputIdentity {
                window: Id128(3),
                frame: 6,
                geometry_epoch: 4,
            },
            capture,
            capture
                .slice_for_display(viewflow_protocol::Point::default(), rect)
                .unwrap(),
        )
        .unwrap();
        next.expires_local_ns += 100_000_000;
        session.renew(next).unwrap();
        assert_eq!(receive(&peer), (59, 3, 8));
        assert!(session.keyboard_authorization().is_none());
        assert_eq!(
            session
                .keyboard_grant
                .as_ref()
                .unwrap()
                .possibly_pressed()
                .count(),
            1
        );
        reply(&peer, 3, 8, 1);
        session.poll().unwrap();
        send(&mut session, 2, true).unwrap();
        assert_eq!(receive(&peer), (60, 4, 8));
        assert_eq!(
            session
                .keyboard_grant
                .as_ref()
                .unwrap()
                .possibly_pressed()
                .count(),
            1
        );
        reply(&peer, 4, 8, 6);
        session.poll().unwrap();
        assert_eq!(
            session
                .keyboard_grant
                .as_ref()
                .unwrap()
                .possibly_pressed()
                .count(),
            0
        );
        assert!(session.keyboard_authorization().is_some());
        assert!(send(&mut session, 2, true).is_err());
        assert_eq!(session.state, State::Ended);
    }

    #[test]
    fn keyboard_wrong_ack_and_expired_ack_keep_cleanup_fence() {
        for wrong_ack in [true, false] {
            let (_directory, peer, mut session) = fixture(true);
            send(&mut session, 1, false).unwrap();
            assert_eq!(receive(&peer), (60, 2, 7));
            if !wrong_ack {
                session.origin -= std::time::Duration::from_millis(40);
            }
            reply(&peer, 2, 7, if wrong_ack { 2 } else { 6 });
            assert!(session.poll().is_err());
            assert_eq!(session.state, State::Ended);
            assert!(session.recovery_unconfirmed.load(Ordering::Acquire));
            assert_eq!(
                session
                    .keyboard_grant
                    .as_ref()
                    .unwrap()
                    .possibly_pressed()
                    .count(),
                1
            );
        }
    }

    #[test]
    fn pointer_authority_cannot_enable_keys_and_pending_key_cannot_be_overwritten() {
        for enabled in [false, true] {
            let (_directory, peer, mut session) = fixture(enabled);
            if enabled {
                send(&mut session, 1, false).unwrap();
                assert_eq!(receive(&peer), (60, 2, 7));
            }
            assert!(send(&mut session, 2, false).is_err());
            assert_eq!(session.state, State::Ended);
            assert_eq!(
                socket::recv(peer.as_raw_fd(), &mut [0; 128], MsgFlags::MSG_DONTWAIT).unwrap(),
                0
            );
        }
    }
}
