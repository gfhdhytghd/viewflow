//! Connection-local producer for a native window preview. All samples retain
//! their original native event deadline; authorization is received from source.

use crate::input_runtime::{ClockSnapshot, conservative_authorization_deadline};
use anyhow::{Result, anyhow, bail};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, watch};
use viewflow_core::PresentedInputIdentity;
use viewflow_protocol::{Id128, WindowPointerAck, WindowPointerAuthorization, WindowPointerMotion};

#[path = "window_preview_keyboard.rs"]
mod keyboard;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PreviewPointerSample {
    pub sample_sequence: u64,
    pub presented: PresentedInputIdentity,
    /// Same process clock origin passed to `WindowPreviewInput::new`.
    pub sender_not_after_ns: u64,
    pub x_pixels: u32,
    pub y_pixels: u32,
    pub viewport_width: u32,
    pub viewport_height: u32,
}

/// A single native event stream when buttons are enabled. Motion cannot leap
/// over a down/up boundary by replacing a watch value.
#[derive(Clone, Copy, Debug)]
pub struct PreviewPointerEvent {
    pub sample: PreviewPointerSample,
    pub button: Option<viewflow_protocol::PointerButtonEvent>,
    pub wheel: Option<viewflow_protocol::PointerWheelEvent>,
    /// Physical usage on the sample's exact visual; pointer coordinates are ignored.
    pub key: Option<viewflow_protocol::KeyboardHidUsage>,
}

impl PreviewPointerEvent {
    #[must_use]
    pub fn is_motion(&self) -> bool {
        self.button.is_none() && self.wheel.is_none() && self.key.is_none()
    }

    fn valid_kind(&self) -> bool {
        if usize::from(self.button.is_some())
            + usize::from(self.wheel.is_some())
            + usize::from(self.key.is_some())
            > 1
        {
            return false;
        }
        if self.key.is_some_and(|key| {
            key.usage_page == 0
                || key.usage_id == 0
                || (key.repeat && key.state != viewflow_protocol::InputSwitchState::Pressed)
        }) {
            return false;
        }
        self.wheel.is_none_or(|delta| {
            delta.vertical_delta_detents.is_finite()
                && delta.horizontal_delta_detents.is_finite()
                && (delta.vertical_delta_detents != 0.0 || delta.horizontal_delta_detents != 0.0)
        })
    }
}

#[derive(Debug)]
pub struct PreviewPointerEvents {
    sender: mpsc::Sender<PreviewPointerEvent>,
    failed: Arc<AtomicBool>,
}

pub struct PreviewPointerEventReceiver {
    receiver: mpsc::Receiver<PreviewPointerEvent>,
    failed: Arc<AtomicBool>,
}

/// Cumulative native confirmations; unlike the latest-ACK watch, these cannot
/// lose a down/up count when a diagnostic observer skips an intermediate value.
#[derive(Debug, Default)]
pub struct WindowPointerReceiptCounts {
    motion: AtomicU64,
    down: AtomicU64,
    up: AtomicU64,
    wheel: AtomicU64,
}

impl WindowPointerReceiptCounts {
    /// Monotonic observations, not an atomic multi-counter snapshot. Read after
    /// the route has ended for final totals. Cleanup without ACK is never counted.
    #[must_use]
    pub fn snapshot(&self) -> (u64, u64, u64) {
        (
            self.motion.load(Ordering::Acquire),
            self.down.load(Ordering::Acquire),
            self.up.load(Ordering::Acquire),
        )
    }

    #[must_use]
    pub fn wheel_count(&self) -> u64 {
        self.wheel.load(Ordering::Acquire)
    }

    fn record(
        &self,
        result: viewflow_protocol::WindowPointerResult,
        button: Option<viewflow_protocol::PointerButtonEvent>,
        wheel: Option<viewflow_protocol::PointerWheelEvent>,
    ) -> Result<()> {
        use viewflow_protocol::{InputSwitchState, WindowPointerResult};
        let counter = match (result, button, wheel) {
            (WindowPointerResult::MotionSent, None, None) => &self.motion,
            (WindowPointerResult::WheelSent, None, Some(_)) => &self.wheel,
            (WindowPointerResult::ButtonSent, Some(button), None) => match button.state {
                InputSwitchState::Pressed => &self.down,
                InputSwitchState::Released => &self.up,
            },
            (WindowPointerResult::Rejected, None, None) => return Ok(()),
            _ => bail!("receipt kind does not match pending input"),
        };
        counter
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
                value.checked_add(1)
            })
            .map_err(|_| anyhow!("native receipt count exhausted"))?;
        Ok(())
    }
}

impl PreviewPointerEvents {
    #[must_use]
    pub fn channel() -> (Self, PreviewPointerEventReceiver) {
        let (sender, receiver) = mpsc::channel(64);
        let failed = Arc::new(AtomicBool::new(false));
        (
            Self {
                sender,
                failed: failed.clone(),
            },
            PreviewPointerEventReceiver { receiver, failed },
        )
    }

    /// Never drop a transition or wait on the native event thread.
    /// # Errors
    /// Overflow, previous failure or a missing owner retires this stream.
    pub fn push(&self, event: PreviewPointerEvent) -> Result<()> {
        if !event.valid_kind() {
            self.failed.store(true, Ordering::Release);
            bail!("invalid native pointer event kind");
        }
        if self.failed.load(Ordering::Acquire) {
            bail!("native pointer event stream retired");
        }
        if let Err(error) = self.sender.try_send(event) {
            self.failed.store(true, Ordering::Release);
            bail!("native pointer event queue failed: {error}");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::WindowPointerResult;
    use viewflow_transport::ClockEstimate;

    fn authorization() -> WindowPointerAuthorization {
        WindowPointerAuthorization {
            lease_generation: 7,
            owner_device: Id128(1),
            target_device: Id128(2),
            target_window: Id128(3),
            geometry_epoch: 4,
            presented_frame: 5,
            source_not_after_ns: 1_000_000_000,
        }
    }

    fn state(sequence: u64) -> PreviewPointerState {
        let presented = PresentedInputIdentity {
            window: Id128(3),
            geometry_epoch: 4,
            frame: 5,
        };
        PreviewPointerState {
            presented: Some(presented),
            motion: Some(PreviewPointerSample {
                sample_sequence: sequence,
                presented,
                sender_not_after_ns: 30_000_000,
                x_pixels: 50,
                y_pixels: 20,
                viewport_width: 100,
                viewport_height: 50,
            }),
        }
    }

    fn clock() -> Option<ClockSnapshot> {
        Some(ClockSnapshot {
            estimate: ClockEstimate {
                remote_offset_ns: 0,
                network_round_trip_ns: 0,
                uncertainty_ns: 0,
            },
            measured_at_local_ns: 0,
        })
    }

    fn fixture() -> (
        WindowPreviewInput,
        watch::Sender<PreviewPointerState>,
        watch::Receiver<Option<WindowPointerAck>>,
    ) {
        let (samples, sample_rx) = watch::channel(state(1));
        let (acks, ack_rx) = watch::channel(None);
        let preview = WindowPreviewInput::new(
            Id128(1),
            Id128(2),
            Id128(3),
            Instant::now(),
            sample_rx,
            acks,
        )
        .unwrap();
        (preview, samples, ack_rx)
    }

    fn wheel(sequence: u64) -> PreviewPointerEvent {
        PreviewPointerEvent {
            key: None,
            sample: state(sequence).motion.unwrap(),
            button: None,
            wheel: Some(viewflow_protocol::PointerWheelEvent {
                vertical_delta_detents: 0.25,
                horizontal_delta_detents: -0.5,
            }),
        }
    }

    fn keyboard_authorization() -> viewflow_protocol::WindowKeyboardAuthorization {
        viewflow_protocol::WindowKeyboardAuthorization {
            lease_generation: 7,
            owner_device: Id128(1),
            target_device: Id128(2),
            target_window: Id128(3),
            geometry_epoch: 4,
            presented_frame: 5,
            source_not_after_ns: 1_000_000_000,
            mode: viewflow_protocol::WindowKeyboardMode::DirectApplication,
        }
    }

    fn key_sample(sequence: u64, released: bool) -> PreviewPointerEvent {
        let mut sample = state(sequence).motion.unwrap();
        // Keyboard target is the committed visual, not a pointer hit test.
        sample.x_pixels = u32::MAX;
        sample.y_pixels = u32::MAX;
        sample.viewport_width = 0;
        sample.viewport_height = 0;
        PreviewPointerEvent {
            sample,
            button: None,
            wheel: None,
            key: Some(viewflow_protocol::KeyboardHidUsage {
                usage_page: 7,
                usage_id: 4,
                state: if released {
                    viewflow_protocol::InputSwitchState::Released
                } else {
                    viewflow_protocol::InputSwitchState::Pressed
                },
                repeat: false,
            }),
        }
    }

    #[test]
    fn keyboard_and_motion_share_fifo_but_not_ack_types() {
        let (preview, _samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_direct_keyboard(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        preview
            .authorize_keyboard(keyboard_authorization())
            .unwrap();
        events.push(key_sample(1, false)).unwrap();
        events
            .push(PreviewPointerEvent {
                sample: state(2).motion.unwrap(),
                button: None,
                wheel: None,
                key: None,
            })
            .unwrap();
        events.push(key_sample(3, true)).unwrap();
        for sequence in 1..=3 {
            let (event, deadline) = preview.next_motion(clock(), 1000).unwrap().unwrap();
            assert_eq!(event.sequence, sequence);
            assert_eq!(deadline, 30_000_000);
            assert!(preview.next_motion(clock(), 1001).unwrap().is_none());
            assert!(!preview.idle_for_selection());
            if sequence == 2 {
                assert!(preview.pending_key.is_none());
                preview
                    .acknowledge(WindowPointerAck::for_motion(
                        event,
                        WindowPointerResult::MotionSent,
                    ))
                    .unwrap();
            } else {
                let key = preview.pending_key.unwrap();
                assert_eq!(key.key, key_sample(sequence, sequence == 3).key.unwrap());
                assert!(
                    preview
                        .acknowledge(WindowPointerAck::for_motion(
                            event,
                            WindowPointerResult::MotionSent
                        ))
                        .is_err()
                );
                let mut ack = viewflow_protocol::WindowKeyboardAck {
                    event: key,
                    result: viewflow_protocol::WindowKeyboardResult::KeySent,
                };
                ack.event.key.usage_id += 1;
                assert!(preview.acknowledge_keyboard(ack).is_err());
                assert_eq!(preview.pending_key, Some(key));
                ack.event = key;
                preview.acknowledge_keyboard(ack).unwrap();
            }
        }
        assert!(preview.idle_for_selection());
        assert_eq!(preview.receipt_counts().snapshot(), (1, 0, 0));
    }

    #[test]
    fn keyboard_requires_both_local_and_exact_separate_source_authority() {
        for scenario in 0..5 {
            let (preview, _samples, _acks) = fixture();
            let (events, receiver) = PreviewPointerEvents::channel();
            let mut preview = if scenario == 0 {
                preview.with_buttons(receiver)
            } else {
                preview.with_direct_keyboard(receiver)
            }
            .unwrap();
            preview.authorize(authorization()).unwrap();
            let mut auth = keyboard_authorization();
            match scenario {
                0 => assert!(preview.authorize_keyboard(auth).is_err()),
                1 => {} // Pointer authority alone is insufficient.
                2 => {
                    auth.presented_frame += 1;
                    preview.authorize_keyboard(auth).unwrap();
                }
                3 => {
                    auth.lease_generation += 1;
                    preview.authorize_keyboard(auth).unwrap();
                }
                _ => {
                    auth.owner_device = Id128(99);
                    assert!(preview.authorize_keyboard(auth).is_err());
                }
            }
            events.push(key_sample(1, false)).unwrap();
            assert!(preview.next_motion(clock(), 1000).is_err());
            assert!(preview.pending_key.is_none());
        }
    }

    #[test]
    fn keyboard_late_ack_preserves_pending_and_switch_clears_old_authority() {
        let (preview, _samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_direct_keyboard(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        preview
            .authorize_keyboard(keyboard_authorization())
            .unwrap();
        events.push(key_sample(1, false)).unwrap();
        preview.next_motion(clock(), 1000).unwrap().unwrap();
        let key = preview.pending_key.unwrap();
        preview.origin -= Duration::from_millis(40);
        assert!(
            preview
                .acknowledge_keyboard(viewflow_protocol::WindowKeyboardAck {
                    event: key,
                    result: viewflow_protocol::WindowKeyboardResult::KeySent
                })
                .is_err()
        );
        assert_eq!(preview.pending_key, Some(key));
        assert!(preview.select_local(Id128(4)).is_err());
        // Separate idle route may switch, but cannot carry old source authority.
        let (preview, _samples, _acks) = fixture();
        let (_events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_direct_keyboard(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        preview
            .authorize_keyboard(keyboard_authorization())
            .unwrap();
        preview.select_local(Id128(4)).unwrap();
        assert!(preview.keyboard_authorization.is_none());
        assert!(preview.keyboard_history.is_empty());
    }

    #[test]
    fn locally_selected_geometry_clears_both_authorities_and_rejects_late_grants() {
        let (preview, _samples, _acks) = fixture();
        let (_events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_direct_keyboard(receiver).unwrap();
        let old = state(1).presented.unwrap();
        preview.select_presented(old).unwrap();
        preview.authorize(authorization()).unwrap();
        preview
            .authorize_keyboard(keyboard_authorization())
            .unwrap();
        let fresh = PresentedInputIdentity {
            geometry_epoch: 5,
            frame: 6,
            ..old
        };
        preview.select_presented(fresh).unwrap();
        assert!(preview.authorization_history.is_empty() && preview.keyboard_history.is_empty());
        assert!(!preview.authorized_presented(old) && !preview.keyboard_presented(old));
        assert!(!preview.accepts_selected_geometry(4));
        assert!(preview.authorize(authorization()).is_err());
        assert!(
            preview
                .authorize_keyboard(keyboard_authorization())
                .is_err()
        );
        assert!(preview.select_presented(old).is_err());
        let mut pointer = authorization();
        pointer.geometry_epoch = 5;
        pointer.presented_frame = 6;
        assert!(preview.authorize(pointer).is_err()); // new geometry cannot reuse old grant
        pointer.lease_generation = 8;
        preview.authorize(pointer).unwrap();
        assert!(preview.authorized_presented(fresh));
        assert!(!preview.keyboard_presented(fresh));
        let mut keyboard = keyboard_authorization();
        keyboard.geometry_epoch = 5;
        keyboard.presented_frame = 6;
        assert!(preview.authorize_keyboard(keyboard).is_err());
        keyboard.lease_generation = 8;
        preview.authorize_keyboard(keyboard).unwrap();
        assert!(preview.keyboard_presented(fresh));
        assert!(!preview.authorized_presented(old));
    }

    #[test]
    fn repeated_wheels_preserve_order_deadline_and_distinct_receipts() {
        let (preview, _samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_buttons_and_wheel(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        events.push(wheel(1)).unwrap();
        events.push(wheel(2)).unwrap(); // Same point and deltas must not coalesce.
        for sequence in 1..=2 {
            let (event, deadline) = preview.next_motion(clock(), 1000).unwrap().unwrap();
            assert_eq!(event.sequence, sequence);
            assert_eq!(deadline, 30_000_000);
            assert_eq!(preview.pending_wheel, wheel(sequence).wheel);
            assert!(preview.next_motion(clock(), 1001).unwrap().is_none());
            for wrong in [
                WindowPointerResult::MotionSent,
                WindowPointerResult::ButtonSent,
                WindowPointerResult::Rejected,
            ] {
                assert!(
                    preview
                        .acknowledge(WindowPointerAck::for_motion(event, wrong))
                        .is_err()
                );
            }
            assert_eq!(preview.receipt_counts().wheel_count(), sequence - 1);
            preview
                .acknowledge(WindowPointerAck::for_motion(
                    event,
                    WindowPointerResult::WheelSent,
                ))
                .unwrap();
        }
        assert_eq!(preview.receipt_counts().snapshot(), (0, 0, 0));
        assert_eq!(preview.receipt_counts().wheel_count(), 2);
    }

    #[tokio::test]
    async fn wheel_pump_uses_distinct_payload_and_waits_for_native_receipt() {
        let (preview, _samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_buttons_and_wheel(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        events.push(wheel(1)).unwrap();
        let (sender, mut controls) = mpsc::channel(1);
        let outbound = crate::OutboundSender::new(sender);
        let (sent, position) = tokio::join!(preview.pump(clock(), &outbound), async {
            let control = controls.recv().await.unwrap();
            assert!(control.input_gate.is_some());
            let viewflow_protocol::wire::control_envelope::Payload::WindowPointerWheel(payload) =
                control.payload
            else {
                panic!("wheel must not be serialized as motion or button");
            };
            let event = viewflow_protocol::WindowPointerWheel::try_from(payload).unwrap();
            assert_eq!(event.delta, wheel(1).wheel.unwrap());
            assert_eq!(event.position.sequence, 1);
            assert_eq!(event.position.sender_not_after_ns, 30_000_000);
            assert_eq!(event.position.target_window, Id128(3));
            control.sent.unwrap().send(Ok(())).unwrap();
            event.position
        });
        sent.unwrap();
        assert_eq!(preview.receipt_counts().wheel_count(), 0);
        assert!(preview.pending_wheel.is_some());
        preview
            .acknowledge(WindowPointerAck::for_motion(
                position,
                WindowPointerResult::WheelSent,
            ))
            .unwrap();
        assert_eq!(preview.receipt_counts().wheel_count(), 1);
        assert_eq!(preview.receipt_counts().snapshot(), (0, 0, 0));
    }

    #[test]
    fn wheel_opt_in_expiry_and_publication_gates_are_explicit() {
        for mode in 0..4 {
            let (preview, samples, _acks) = fixture();
            let (events, receiver) = PreviewPointerEvents::channel();
            let mut preview = if mode == 0 {
                preview.with_buttons(receiver)
            } else {
                preview.with_buttons_and_wheel(receiver)
            }
            .unwrap();
            if mode != 1 {
                preview.authorize(authorization()).unwrap();
            }
            events.push(wheel(1)).unwrap();
            if mode == 3 {
                samples.send(PreviewPointerState::default()).unwrap();
                assert!(preview.next_motion(clock(), 1000).unwrap().is_none());
                assert!(preview.deferred_receipt.is_some());
            }
            let now = if mode >= 2 { 30_000_000 } else { 1000 };
            assert!(preview.next_motion(clock(), now).is_err());
            assert_eq!(preview.receipt_counts().wheel_count(), 0);
        }
    }

    #[test]
    fn ambiguous_or_invalid_wheel_retires_ordered_queue() {
        for mode in 0..4 {
            let (events, _receiver) = PreviewPointerEvents::channel();
            let mut invalid = wheel(1);
            match mode {
                0 => {
                    invalid.button = Some(viewflow_protocol::PointerButtonEvent {
                        button: viewflow_protocol::PointerButton::Left,
                        state: viewflow_protocol::InputSwitchState::Pressed,
                    })
                }
                1 => invalid.wheel.as_mut().unwrap().vertical_delta_detents = f64::NAN,
                2 => invalid.wheel.as_mut().unwrap().horizontal_delta_detents = f64::INFINITY,
                _ => {
                    invalid.wheel = Some(viewflow_protocol::PointerWheelEvent {
                        vertical_delta_detents: 0.0,
                        horizontal_delta_detents: -0.0,
                    })
                }
            }
            assert!(events.push(invalid).is_err());
            assert!(events.push(wheel(2)).is_err());
        }
    }

    #[test]
    fn local_switch_preserves_sequences_and_requires_resolved_input() {
        let (mut preview, _samples, _acks) = fixture();
        preview.authorize(authorization()).unwrap();
        preview.sequence = 20;
        preview.last_sample = 30;
        assert!(
            preview
                .authorize(viewflow_protocol::WindowPointerAuthorization {
                    target_window: Id128(4),
                    ..authorization()
                })
                .is_err()
        );
        preview.select_local(Id128(4)).unwrap();
        assert_eq!(preview.selected_window(), Id128(4));
        assert!(preview.authorization.is_none());
        assert!(preview.authorization_history.is_empty());
        assert_eq!((preview.sequence, preview.last_sample), (20, 30));
        preview
            .authorize(viewflow_protocol::WindowPointerAuthorization {
                target_window: Id128(4),
                lease_generation: 8,
                ..authorization()
            })
            .unwrap();
        let (events, receiver) = PreviewPointerEvents::channel();
        preview.ordered = Some(receiver);
        events
            .push(PreviewPointerEvent {
                key: None,
                wheel: None,
                sample: state(31).motion.unwrap(),
                button: None,
            })
            .unwrap();
        assert!(!preview.idle_for_selection());
        assert!(preview.select_local(Id128(3)).is_err());
        assert_eq!(preview.selected_window(), Id128(4));
    }

    #[test]
    fn desktop_pause_drops_authority_and_requires_a_newer_source_generation() {
        let (preview, _samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_direct_keyboard(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        preview
            .authorize_keyboard(keyboard_authorization())
            .unwrap();
        preview.pause_for_desktop_move().unwrap();
        assert_eq!(preview.geometry_generation_floor, Some(7));
        assert!(preview.authorization.is_none());
        assert!(preview.keyboard_authorization.is_none());
        assert!(preview.authorization_history.is_empty());
        assert!(preview.keyboard_history.is_empty());
        assert!(preview.authorize(authorization()).is_err());
        let mut fresh = authorization();
        fresh.lease_generation = 8;
        fresh.source_not_after_ns += 1;
        preview.authorize(fresh).unwrap();
        // The pointer grant never recreates keyboard authority.
        assert!(preview.keyboard_authorization.is_none());
        drop(events);
    }

    #[test]
    fn exact_activation_receipt_allows_new_generation_on_same_frame_only_explicitly() {
        let (mut preview, _samples, _acks) = fixture();
        preview.authorize(authorization()).unwrap();
        let old = authorization();
        let fresh = viewflow_protocol::WindowPointerAuthorization {
            lease_generation: old.lease_generation + 1,
            source_not_after_ns: old.source_not_after_ns + 1,
            ..old
        };
        assert!(preview.authorize(fresh).is_err());
        let accepted = viewflow_protocol::AtlasWindowSelectionAccepted {
            selection: viewflow_protocol::AtlasWindowSelection {
                activate_keyboard: false,
                stream_id: Id128(99),
                atlas_frame_id: 1,
                atlas_geometry_epoch: 1,
                config_generation: 1,
                layout_revision: 1,
                window_id: old.target_window,
                placement_generation: 1,
                source_frame_id: old.presented_frame,
                source_geometry_epoch: old.geometry_epoch,
                sequence: 1,
                sender_not_after_ns: 30_000_000,
            },
            authorization: fresh,
        };
        assert!(preview.authorize_selection(accepted).is_err());
        preview
            .authorize_selection(viewflow_protocol::AtlasWindowSelectionAccepted {
                selection: viewflow_protocol::AtlasWindowSelection {
                    activate_keyboard: true,
                    ..accepted.selection
                },
                ..accepted
            })
            .unwrap();
        assert_eq!(preview.authorization, Some(fresh));
        assert!(preview.keyboard_authorization.is_none());
        assert_eq!(
            preview.geometry_generation_floor,
            Some(old.lease_generation)
        );
    }

    #[test]
    fn desktop_pause_refuses_unresolved_native_input() {
        let (preview, _samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_buttons(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        events
            .push(PreviewPointerEvent {
                key: None,
                sample: state(1).motion.unwrap(),
                button: None,
                wheel: None,
            })
            .unwrap();
        assert!(!preview.idle_for_selection());
        assert!(preview.pause_for_desktop_move().is_err());
        assert_eq!(preview.authorization, Some(authorization()));
    }

    #[test]
    fn delayed_exact_receipt_preserves_order_and_original_button_deadline() {
        use viewflow_protocol::{InputSwitchState, PointerButton, PointerButtonEvent};
        let (preview, samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_buttons(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        let mut current = state(1);
        current.presented.as_mut().unwrap().frame = 6;
        current.motion.as_mut().unwrap().presented.frame = 6;
        current.motion.as_mut().unwrap().sender_not_after_ns = 5_000_001_000;
        samples.send_replace(current);
        for (sequence, transition) in [
            (1, InputSwitchState::Pressed),
            (2, InputSwitchState::Released),
        ] {
            let mut sample = current.motion.unwrap();
            sample.sample_sequence = sequence;
            events
                .push(PreviewPointerEvent {
                    key: None,
                    wheel: None,
                    sample,
                    button: Some(PointerButtonEvent {
                        button: PointerButton::Left,
                        state: transition,
                    }),
                })
                .unwrap();
        }
        assert!(preview.next_motion(clock(), 1000).unwrap().is_none());
        assert!(preview.next_motion(clock(), 2000).unwrap().is_none());
        assert_eq!(preview.last_sample, 1);
        assert!(preview.pending.is_none());
        let mut next = authorization();
        next.presented_frame = 6;
        preview.authorize(next).unwrap();
        for sequence in 1..=2 {
            let (event, deadline) = preview.next_motion(clock(), 3000).unwrap().unwrap();
            assert_eq!(event.presented_frame, 6);
            assert_eq!(event.sequence, sequence);
            assert_eq!(
                event.sender_not_after_ns,
                current.motion.unwrap().sender_not_after_ns
            );
            assert!(deadline < event.sender_not_after_ns); // The shorter lease still bounds transport.
            preview
                .acknowledge(WindowPointerAck::for_motion(
                    event,
                    WindowPointerResult::ButtonSent,
                ))
                .unwrap();
        }
        assert_eq!(preview.receipt_counts().snapshot(), (0, 1, 1));
    }

    #[test]
    fn deferred_button_expires_or_rejects_renewal_without_sending() {
        use viewflow_protocol::{InputSwitchState, PointerButton, PointerButtonEvent};
        for renew in [false, true] {
            let (preview, samples, _acks) = fixture();
            let (events, receiver) = PreviewPointerEvents::channel();
            let mut preview = preview.with_buttons(receiver).unwrap();
            preview.authorize(authorization()).unwrap();
            let mut current = state(1);
            current.presented.as_mut().unwrap().frame = 6;
            current.motion.as_mut().unwrap().presented.frame = 6;
            samples.send_replace(current);
            events
                .push(PreviewPointerEvent {
                    key: None,
                    wheel: None,
                    sample: current.motion.unwrap(),
                    button: Some(PointerButtonEvent {
                        button: PointerButton::Left,
                        state: InputSwitchState::Released,
                    }),
                })
                .unwrap();
            assert!(preview.next_motion(clock(), 1000).unwrap().is_none());
            if renew {
                let mut next = authorization();
                next.presented_frame = 6;
                next.lease_generation += 1;
                next.source_not_after_ns += 1;
                assert!(preview.authorize(next).is_err());
            } else {
                assert!(
                    preview
                        .next_motion(clock(), current.motion.unwrap().sender_not_after_ns)
                        .is_err()
                );
            }
            assert!(preview.pending.is_none());
            assert_eq!(preview.sequence, 0);
        }
    }

    #[test]
    fn newer_visual_does_not_invalidate_a_verified_queued_sample() {
        let (mut preview, samples, _acks) = fixture();
        preview.authorize(authorization()).unwrap();
        let mut current = state(1);
        current.presented.as_mut().unwrap().frame = 6;
        samples.send_replace(current);
        let (event, _) = preview.next_motion(clock(), 1000).unwrap().unwrap();
        assert_eq!(event.presented_frame, 5);
        assert_eq!(preview.authorization.unwrap().presented_frame, 5);
    }

    #[test]
    fn queued_button_release_keeps_old_verified_frame_after_visual_advance() {
        use viewflow_protocol::{InputSwitchState, PointerButton, PointerButtonEvent};
        let (preview, samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_buttons(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        for (sequence, transition) in [
            (1, InputSwitchState::Pressed),
            (2, InputSwitchState::Released),
        ] {
            if sequence == 2 {
                let mut next = authorization();
                next.presented_frame = 6;
                preview.authorize(next).unwrap();
                let mut current = state(2);
                current.presented.as_mut().unwrap().frame = 6;
                samples.send_replace(current);
            }
            events
                .push(PreviewPointerEvent {
                    key: None,
                    wheel: None,
                    sample: state(sequence).motion.unwrap(),
                    button: Some(PointerButtonEvent {
                        button: PointerButton::Left,
                        state: transition,
                    }),
                })
                .unwrap();
            let (event, _) = preview.next_motion(clock(), 1000).unwrap().unwrap();
            assert_eq!(event.presented_frame, 5);
            preview
                .acknowledge(WindowPointerAck::for_motion(
                    event,
                    WindowPointerResult::ButtonSent,
                ))
                .unwrap();
        }
        assert_eq!(preview.receipt_counts().snapshot(), (0, 1, 1));
    }

    #[test]
    fn verified_button_waits_for_publication_without_retagging_or_extending_deadline() {
        use viewflow_protocol::{InputSwitchState, PointerButton, PointerButtonEvent};
        let (preview, samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_buttons(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        let sample = state(1).motion.unwrap();
        events
            .push(PreviewPointerEvent {
                key: None,
                wheel: None,
                sample,
                button: Some(PointerButtonEvent {
                    button: PointerButton::Left,
                    state: InputSwitchState::Released,
                }),
            })
            .unwrap();
        samples.send_replace(PreviewPointerState::default());
        assert!(preview.next_motion(clock(), 1000).unwrap().is_none());
        assert!(preview.pending.is_none());
        assert_eq!(preview.sequence, 0);
        let mut published = state(2);
        published.presented.as_mut().unwrap().frame = 6;
        samples.send_replace(published);
        let (event, deadline) = preview.next_motion(clock(), 1001).unwrap().unwrap();
        assert_eq!(event.presented_frame, sample.presented.frame);
        assert_eq!(event.sender_not_after_ns, sample.sender_not_after_ns);
        assert!(deadline <= sample.sender_not_after_ns);
    }

    #[test]
    fn publication_wait_rejects_expiry_geometry_renewal_and_closed_owner() {
        use viewflow_protocol::{InputSwitchState, PointerButton, PointerButtonEvent};
        for failure in 0..4 {
            let (preview, samples, _acks) = fixture();
            let (events, receiver) = PreviewPointerEvents::channel();
            let mut preview = preview.with_buttons(receiver).unwrap();
            preview.authorize(authorization()).unwrap();
            let sample = state(1).motion.unwrap();
            events
                .push(PreviewPointerEvent {
                    key: None,
                    wheel: None,
                    sample,
                    button: Some(PointerButtonEvent {
                        button: PointerButton::Left,
                        state: InputSwitchState::Released,
                    }),
                })
                .unwrap();
            samples.send_replace(PreviewPointerState::default());
            assert!(preview.next_motion(clock(), 1000).unwrap().is_none());
            let now = match failure {
                0 => sample.sender_not_after_ns,
                1 => {
                    let mut changed = state(2);
                    changed.presented.as_mut().unwrap().geometry_epoch += 1;
                    samples.send_replace(changed);
                    1001
                }
                2 => {
                    let mut renewed = authorization();
                    renewed.lease_generation += 1;
                    renewed.source_not_after_ns += 1;
                    renewed.presented_frame += 1;
                    assert!(preview.authorize(renewed).is_err());
                    assert!(preview.pending.is_none());
                    assert_eq!(preview.sequence, 0);
                    continue;
                }
                _ => {
                    drop(samples);
                    1001
                }
            };
            assert!(preview.next_motion(clock(), now).is_err());
            assert!(preview.pending.is_none());
            assert_eq!(preview.sequence, 0);
        }
    }

    #[test]
    fn receipt_eviction_and_renewal_do_not_reauthorize_old_samples() {
        for renew in [false, true] {
            let (mut preview, samples, _acks) = fixture();
            preview.authorize(authorization()).unwrap();
            let mut next = authorization();
            if renew {
                next.lease_generation += 1;
                next.source_not_after_ns += 1;
                next.presented_frame += 1;
                preview.authorize(next).unwrap();
                assert_eq!(preview.authorization_history.len(), 1);
            } else {
                for frame in 6..=37 {
                    next.presented_frame = frame;
                    preview.authorize(next).unwrap();
                }
                assert_eq!(preview.authorization_history.len(), 32);
            }
            let mut current = state(1);
            current.presented.as_mut().unwrap().frame = next.presented_frame;
            samples.send_replace(current);
            assert!(preview.next_motion(clock(), 1000).unwrap().is_none());
            assert_eq!(preview.last_sample, 1); // Never replay after another grant.
        }
    }

    #[test]
    fn retained_authorization_preserves_event_frame_and_rejects_missing_receipt() {
        let (mut preview, samples, _acks) = fixture();
        preview.authorize(authorization()).unwrap();
        let mut next = authorization();
        next.presented_frame = 7; // Frame 6 never had an authorization receipt.
        preview.authorize(next).unwrap();
        let mut current = state(1);
        current.presented.as_mut().unwrap().frame = 7;
        samples.send_replace(current);
        let (event, _) = preview.next_motion(clock(), 1000).unwrap().unwrap();
        assert_eq!(event.presented_frame, 5);
        preview
            .acknowledge(WindowPointerAck::for_motion(
                event,
                WindowPointerResult::MotionSent,
            ))
            .unwrap();
        current.motion.as_mut().unwrap().sample_sequence = 2;
        current.motion.as_mut().unwrap().presented.frame = 6;
        samples.send_replace(current);
        assert!(preview.next_motion(clock(), 1000).unwrap().is_none());
    }

    #[test]
    fn ordered_down_motion_up_requires_matching_confirmation() {
        use viewflow_protocol::{InputSwitchState, PointerButton, PointerButtonEvent};
        let (preview, _samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_buttons(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        for (sequence, button) in [
            (
                1,
                Some(PointerButtonEvent {
                    button: PointerButton::Left,
                    state: InputSwitchState::Pressed,
                }),
            ),
            (2, None),
            (
                3,
                Some(PointerButtonEvent {
                    button: PointerButton::Left,
                    state: InputSwitchState::Released,
                }),
            ),
        ] {
            events
                .push(PreviewPointerEvent {
                    key: None,
                    wheel: None,
                    sample: state(sequence).motion.unwrap(),
                    button,
                })
                .unwrap();
        }
        for sequence in 1..=3 {
            let (event, _) = preview.next_motion(clock(), 1000).unwrap().unwrap();
            assert_eq!(event.sequence, sequence);
            assert_eq!(preview.last_sample, sequence);
            assert!(preview.next_motion(clock(), 1001).unwrap().is_none());
            let result = if sequence == 2 {
                WindowPointerResult::MotionSent
            } else {
                WindowPointerResult::ButtonSent
            };
            let wrong = if sequence == 2 {
                WindowPointerResult::ButtonSent
            } else {
                WindowPointerResult::MotionSent
            };
            assert!(
                preview
                    .acknowledge(WindowPointerAck::for_motion(
                        event,
                        WindowPointerResult::WheelSent
                    ))
                    .is_err()
            );
            assert!(
                preview
                    .acknowledge(WindowPointerAck::for_motion(event, wrong))
                    .is_err()
            );
            preview
                .acknowledge(WindowPointerAck::for_motion(event, result))
                .unwrap();
        }
        assert!(preview.next_motion(clock(), 1002).unwrap().is_none());
        assert_eq!(preview.receipt_counts().snapshot(), (1, 1, 1));
        drop(events);
        assert!(preview.next_motion(clock(), 1003).is_err());
    }

    #[test]
    fn ordered_overflow_retires_even_while_waiting_for_ack() {
        let (preview, _samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_buttons(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        events
            .push(PreviewPointerEvent {
                key: None,
                wheel: None,
                sample: state(1).motion.unwrap(),
                button: None,
            })
            .unwrap();
        assert!(preview.next_motion(clock(), 1).unwrap().is_some());
        for sequence in 2..=65 {
            events
                .push(PreviewPointerEvent {
                    key: None,
                    wheel: None,
                    sample: state(sequence).motion.unwrap(),
                    button: None,
                })
                .unwrap();
        }
        assert!(
            events
                .push(PreviewPointerEvent {
                    key: None,
                    wheel: None,
                    sample: state(66).motion.unwrap(),
                    button: None
                })
                .is_err()
        );
        assert!(preview.next_motion(clock(), 2).is_err());
    }

    #[test]
    fn stale_ordered_release_is_not_silently_discarded() {
        let (preview, _samples, _acks) = fixture();
        let (events, receiver) = PreviewPointerEvents::channel();
        let mut preview = preview.with_buttons(receiver).unwrap();
        preview.authorize(authorization()).unwrap();
        events
            .push(PreviewPointerEvent {
                key: None,
                wheel: None,
                sample: state(1).motion.unwrap(),
                button: Some(viewflow_protocol::PointerButtonEvent {
                    button: viewflow_protocol::PointerButton::Left,
                    state: viewflow_protocol::InputSwitchState::Released,
                }),
            })
            .unwrap();
        assert!(preview.next_motion(clock(), 30_000_000).is_err());
    }

    #[test]
    fn original_deadline_and_one_exact_pending_ack_are_preserved() {
        let (mut preview, samples, acks) = fixture();
        let recovery = preview.recovery_unconfirmed();
        assert!(!recovery.load(Ordering::Acquire));
        assert!(preview.next_motion(clock(), 1).unwrap().is_none());
        preview.authorize(authorization()).unwrap();
        assert!(preview.next_motion(clock(), 2).unwrap().is_none());
        samples.send(state(2)).unwrap();
        let (event, deadline) = preview.next_motion(clock(), 1000).unwrap().unwrap();
        assert!(recovery.load(Ordering::Acquire));
        assert_eq!(event.sequence, 1);
        assert_eq!(event.sender_not_after_ns, 30_000_000);
        assert_eq!(deadline, 30_000_000);
        assert!(preview.next_motion(clock(), 2000).unwrap().is_none());
        let ack = WindowPointerAck::for_motion(event, WindowPointerResult::MotionSent);
        let receipts = preview.receipt_counts();
        assert_eq!(receipts.snapshot(), (0, 0, 0));
        assert!(
            preview
                .acknowledge(WindowPointerAck {
                    result: WindowPointerResult::ButtonSent,
                    ..ack
                })
                .is_err()
        );
        assert!(
            preview
                .acknowledge(WindowPointerAck {
                    target_window: Id128(99),
                    ..ack
                })
                .is_err()
        );
        preview.acknowledge(ack).unwrap();
        assert!(!recovery.load(Ordering::Acquire));
        assert_eq!(receipts.snapshot(), (1, 0, 0));
        assert_eq!(*acks.borrow(), Some(ack));
        assert!(preview.acknowledge(ack).is_err());
        assert_eq!(receipts.snapshot(), (1, 0, 0));
        assert!(preview.next_motion(clock(), 3000).unwrap().is_none());
    }

    #[test]
    fn authorization_cannot_retarget_silently_extend_or_regress() {
        let (mut preview, _samples, _acks) = fixture();
        let valid = authorization();
        preview.authorize(valid).unwrap();
        preview.authorize(valid).unwrap();
        for invalid in [
            WindowPointerAuthorization {
                owner_device: Id128(9),
                ..valid
            },
            WindowPointerAuthorization {
                target_device: Id128(9),
                ..valid
            },
            WindowPointerAuthorization {
                target_window: Id128(9),
                ..valid
            },
            WindowPointerAuthorization {
                lease_generation: 8,
                ..valid
            },
            WindowPointerAuthorization {
                geometry_epoch: 5,
                ..valid
            },
            WindowPointerAuthorization {
                source_not_after_ns: 2_000_000_000,
                ..valid
            },
            WindowPointerAuthorization {
                presented_frame: 4,
                ..valid
            },
        ] {
            assert!(preview.authorize(invalid).is_err());
        }
        assert_eq!(preview.authorization, Some(valid));
        let renewed = WindowPointerAuthorization {
            lease_generation: valid.lease_generation + 1,
            presented_frame: valid.presented_frame + 1,
            source_not_after_ns: valid.source_not_after_ns + 1,
            ..valid
        };
        preview.authorize(renewed).unwrap();
        assert!(preview.authorize(valid).is_err());
        assert_eq!(preview.authorization, Some(renewed));
    }

    #[test]
    fn late_motion_rejection_finishes_pending_and_allows_new_motion() {
        let (mut preview, samples, _acks) = fixture();
        preview.next_motion(clock(), 1).unwrap();
        preview.authorize(authorization()).unwrap();
        preview.next_motion(clock(), 2).unwrap();
        samples.send(state(2)).unwrap();
        let (event, _) = preview.next_motion(clock(), 1000).unwrap().unwrap();
        preview.origin = Instant::now() - Duration::from_millis(100);
        assert!(preview.awaiting_confirmation(100_000_000).unwrap());
        preview
            .acknowledge(WindowPointerAck::for_motion(
                event,
                WindowPointerResult::Rejected,
            ))
            .unwrap();
        assert!(preview.pending.is_none());
        let mut next = state(3);
        next.motion.as_mut().unwrap().sender_not_after_ns = 130_000_000;
        samples.send(next).unwrap();
        let (fresh, _) = preview.next_motion(clock(), 100_000_001).unwrap().unwrap();
        assert!(fresh.sequence > event.sequence);
        assert_eq!(fresh.sender_not_after_ns, 130_000_000);
    }

    #[test]
    fn actual_visual_clock_and_expiry_gate_each_sample_without_replay() {
        let (mut preview, samples, _acks) = fixture();
        preview.authorize(authorization()).unwrap();
        assert!(preview.next_motion(None, 1).unwrap().is_none());
        assert!(preview.next_motion(clock(), 2).unwrap().is_none());
        let mut mismatched = state(2);
        mismatched.presented.as_mut().unwrap().geometry_epoch = 6;
        samples.send(mismatched).unwrap();
        assert!(preview.next_motion(clock(), 3).unwrap().is_none());
        samples.send(state(3)).unwrap();
        assert!(preview.next_motion(clock(), 30_000_000).unwrap().is_none());
        let mut fresh = state(4);
        fresh.motion.as_mut().unwrap().sender_not_after_ns = 60_000_000;
        samples.send(fresh).unwrap();
        let (_, deadline) = preview.next_motion(clock(), 30_000_001).unwrap().unwrap();
        assert!(preview.next_motion(clock(), deadline).unwrap().is_none());
        drop(samples);
        assert!(preview.next_motion(clock(), deadline + 1).is_err());
    }
}

/// Replace atomically when a new visual commits. Decode-only and rejected
/// frames never replace `presented`; clear motion on a new presentation.
#[derive(Clone, Copy, Debug, Default)]
pub struct PreviewPointerState {
    pub presented: Option<PresentedInputIdentity>,
    pub motion: Option<PreviewPointerSample>,
}

pub struct WindowPreviewInput {
    owner: Id128,
    source: Id128,
    window: Id128,
    selected_geometry_epoch: Option<u64>,
    geometry_generation_floor: Option<u64>,
    origin: Instant,
    samples: watch::Receiver<PreviewPointerState>,
    acknowledgements: watch::Sender<Option<WindowPointerAck>>,
    authorization: Option<WindowPointerAuthorization>,
    authorization_history: std::collections::VecDeque<WindowPointerAuthorization>,
    last_sample: u64,
    sequence: u64,
    pending: Option<(WindowPointerMotion, u64)>,
    // Diagnostic only: sender clock [pump start, event deadline, writer completion].
    pending_timing: Option<[u64; 3]>,
    pending_button: Option<viewflow_protocol::PointerButtonEvent>,
    pending_wheel: Option<viewflow_protocol::PointerWheelEvent>,
    pending_key: Option<viewflow_protocol::WindowKeyboardEvent>,
    keyboard_authorization: Option<viewflow_protocol::WindowKeyboardAuthorization>,
    keyboard_history: std::collections::VecDeque<viewflow_protocol::WindowKeyboardAuthorization>,
    allow_keyboard: bool,
    allow_wheel: bool,
    deferred_receipt: Option<(PreviewPointerEvent, u64)>,
    ordered: Option<PreviewPointerEventReceiver>,
    receipts: Arc<WindowPointerReceiptCounts>,
    recovery_unconfirmed: Arc<AtomicBool>,
}

impl WindowPreviewInput {
    pub(crate) fn recovery_unconfirmed(&self) -> Arc<AtomicBool> {
        self.recovery_unconfirmed.clone()
    }

    fn set_pending(&mut self, pending: Option<(WindowPointerMotion, u64)>) {
        self.pending = pending;
        self.recovery_unconfirmed
            .store(self.pending.is_some(), Ordering::Release);
    }
    /// Identities are supplied by local peer/window selection, not by an
    /// incoming authorization. Call only on that authenticated connection.
    /// # Errors
    /// Rejects empty identities and a route back to the same device.
    pub fn new(
        owner: Id128,
        source: Id128,
        window: Id128,
        origin: Instant,
        samples: watch::Receiver<PreviewPointerState>,
        acknowledgements: watch::Sender<Option<WindowPointerAck>>,
    ) -> Result<Self> {
        if owner.0 == 0 || source.0 == 0 || window.0 == 0 || owner == source {
            bail!("invalid preview route identity");
        }
        Ok(Self {
            owner,
            source,
            window,
            selected_geometry_epoch: None,
            geometry_generation_floor: None,
            origin,
            samples,
            acknowledgements,
            authorization: None,
            authorization_history: std::collections::VecDeque::new(),
            last_sample: 0,
            sequence: 0,
            pending: None,
            pending_timing: None,
            pending_button: None,
            pending_wheel: None,
            pending_key: None,
            keyboard_authorization: None,
            keyboard_history: std::collections::VecDeque::new(),
            allow_keyboard: false,
            allow_wheel: false,
            deferred_receipt: None,
            ordered: None,
            receipts: Arc::new(WindowPointerReceiptCounts::default()),
            recovery_unconfirmed: Arc::new(AtomicBool::new(false)),
        })
    }

    /// Explicit local button forwarding opt-in. Must be configured before
    /// serving or authorizing the route. The queue must include motion too.
    /// # Errors
    /// Rejects replacement of a live or already configured input stream.
    pub fn with_buttons(mut self, events: PreviewPointerEventReceiver) -> Result<Self> {
        if self.ordered.is_some() || self.authorization.is_some() || self.sequence != 0 {
            bail!("cannot replace an active preview input stream");
        }
        self.ordered = Some(events);
        Ok(self)
    }

    /// Explicit local wheel forwarding opt-in; source authority is still required.
    /// # Errors
    /// Rejects replacing an already configured or active stream.
    pub fn with_buttons_and_wheel(self, events: PreviewPointerEventReceiver) -> Result<Self> {
        let mut result = self.with_buttons(events)?;
        result.allow_wheel = true;
        Ok(result)
    }

    #[must_use]
    pub fn receipt_counts(&self) -> Arc<WindowPointerReceiptCounts> {
        self.receipts.clone()
    }

    /// Own the connection's shared control dispatcher/writer and clock probes.
    /// No other reliable reader may run alongside this one. Closing the native
    /// sample owner, cancellation or any uncertain send closes the connection.
    /// # Errors
    /// Returns authentication-context, transport, sample, or ACK failures.
    pub async fn serve(self, connection: &quinn::Connection) -> Result<()> {
        crate::serve_window_preview_connection(connection, self.origin, self).await
    }

    /// Consume controls already sequenced by this connection's atlas receiver.
    /// The atlas pump remains its sole reader; the supplied writer remains the
    /// sole writer. This entry does not accept streams or reset wire sequences.
    /// # Errors
    /// Closed dispatch ownership, foreign writers, clock or native input failure
    /// retire the connection. The caller must supervise the atlas pump with it.
    pub async fn serve_forwarded(
        self,
        connection: &quinn::Connection,
        controls: mpsc::Receiver<viewflow_protocol::DomainControl>,
        writer: crate::shared_control::SharedControlSender,
    ) -> Result<()> {
        crate::window_forwarded_preview::serve(connection, self.origin, self, controls, writer)
            .await
    }

    pub(crate) fn authorize_selection(
        &mut self,
        accepted: viewflow_protocol::AtlasWindowSelectionAccepted,
    ) -> Result<()> {
        accepted
            .validate()
            .map_err(|error| anyhow!("invalid selected authorization: {error:?}"))?;
        let authorization = accepted.authorization;
        if accepted.selection.activate_keyboard
            && self.authorization.is_some_and(|previous| {
                previous.target_window == authorization.target_window
                    && previous.geometry_epoch == authorization.geometry_epoch
                    && previous.presented_frame == authorization.presented_frame
                    && authorization.lease_generation > previous.lease_generation
            })
        {
            // Only this exact selection receipt proves the source completed
            // END/new BEGIN for same-frame activation. Ordinary announcements
            // still cannot renew a generation without a newer captured frame.
            self.pause_for_desktop_move()?;
        }
        self.authorize(authorization)
    }

    pub(crate) fn authorize(&mut self, authorization: WindowPointerAuthorization) -> Result<()> {
        if !self.accepts_selected_geometry(authorization.geometry_epoch)
            || self
                .geometry_generation_floor
                .is_some_and(|floor| authorization.lease_generation <= floor)
        {
            bail!("authorization precedes locally selected geometry");
        }
        if authorization.owner_device != self.owner
            || authorization.target_device != self.source
            || authorization.target_window != self.window
            || authorization.lease_generation == 0
            || authorization.geometry_epoch == 0
            || authorization.presented_frame == 0
            || authorization.source_not_after_ns == 0
        {
            bail!("source authorization does not match selected preview route");
        }
        if let Some(previous) = self.authorization {
            let same_generation = authorization.lease_generation == previous.lease_generation
                && authorization.source_not_after_ns == previous.source_not_after_ns;
            let renewed = authorization.lease_generation > previous.lease_generation
                && authorization.source_not_after_ns > previous.source_not_after_ns
                && authorization.presented_frame > previous.presented_frame;
            if renewed && self.deferred_receipt.is_some() {
                bail!("authorization renewed while an event awaits its receipt");
            }
            if !(same_generation || renewed)
                || authorization.geometry_epoch != previous.geometry_epoch
                || authorization.presented_frame < previous.presented_frame
            {
                bail!("source changed or regressed preview authorization");
            }
        }
        if self
            .authorization
            .is_some_and(|previous| previous.lease_generation != authorization.lease_generation)
        {
            self.authorization_history.clear();
        }
        if self.authorization_history.back() != Some(&authorization) {
            self.authorization_history.push_back(authorization);
            if self.authorization_history.len() > 32 {
                self.authorization_history.pop_front();
            }
        }
        self.authorization = Some(authorization);
        Ok(())
    }

    pub(crate) fn idle_for_selection(&self) -> bool {
        self.pending.is_none()
            && self.deferred_receipt.is_none()
            && self
                .ordered
                .as_ref()
                .is_none_or(|events| events.receiver.is_empty())
    }

    /// Only a locally observed native event may change the selected target.
    pub(crate) fn pause_for_desktop_move(&mut self) -> Result<()> {
        if !self.idle_for_selection() {
            bail!("desktop move has unresolved application input");
        }
        if let Some(auth) = self.authorization {
            self.geometry_generation_floor = Some(auth.lease_generation);
        }
        self.authorization = None;
        self.authorization_history.clear();
        self.keyboard_authorization = None;
        self.keyboard_history.clear();
        Ok(())
    }

    /// Only a locally observed native event may change the selected target.
    /// Keep connection-wide event/ACK sequence counters across window switches.
    pub(crate) fn select_local(&mut self, window: Id128) -> Result<()> {
        if window.0 == 0 || !self.idle_for_selection() {
            bail!("cannot switch preview with unresolved native input");
        }
        if self.window != window {
            self.window = window;
            self.selected_geometry_epoch = None;
            self.geometry_generation_floor = None;
            self.authorization = None;
            self.authorization_history.clear();
            self.keyboard_authorization = None;
            self.keyboard_history.clear();
        }
        Ok(())
    }

    pub(crate) fn accepts_selected_geometry(&self, epoch: u64) -> bool {
        self.selected_geometry_epoch
            .is_none_or(|selected| selected == epoch)
    }

    /// Called only for a native event whose exact atlas frame has committed.
    /// A fresh geometry selection drops old authority; it does not grant input.
    pub(crate) fn select_presented(&mut self, identity: PresentedInputIdentity) -> Result<()> {
        if identity.frame == 0 || identity.geometry_epoch == 0 || !self.idle_for_selection() {
            bail!("invalid or unresolved local geometry selection");
        }
        if self.window == identity.window {
            let previous = self
                .selected_geometry_epoch
                .or(self.authorization.map(|auth| auth.geometry_epoch));
            if previous.is_some_and(|epoch| identity.geometry_epoch < epoch) {
                bail!("local geometry selection regressed");
            }
            if previous.is_some_and(|epoch| identity.geometry_epoch > epoch) {
                if let Some(auth) = self.authorization {
                    self.geometry_generation_floor = Some(auth.lease_generation);
                }
                self.authorization = None;
                self.authorization_history.clear();
                self.keyboard_authorization = None;
                self.keyboard_history.clear();
            }
        }
        self.select_local(identity.window)?;
        self.selected_geometry_epoch = Some(identity.geometry_epoch);
        Ok(())
    }

    pub(crate) fn selected_window(&self) -> Id128 {
        self.window
    }

    pub(crate) fn authorized_presented(&self, identity: PresentedInputIdentity) -> bool {
        self.authorization
            .is_some_and(|auth| self.has_authorized_identity(identity, auth.lease_generation))
    }

    pub(crate) fn acknowledge(&mut self, ack: WindowPointerAck) -> Result<()> {
        use viewflow_protocol::WindowPointerResult;
        if self.pending_key.is_some() {
            bail!("pointer ACK cannot complete a keyboard event");
        }
        if self.pending_wheel.is_some() {
            if ack.result != WindowPointerResult::WheelSent {
                bail!("wheel requires native wheel confirmation");
            }
        } else if self.pending_button.is_some() {
            if ack.result != WindowPointerResult::ButtonSent {
                bail!("button requires native button confirmation");
            }
        } else if !matches!(
            ack.result,
            WindowPointerResult::MotionSent | WindowPointerResult::Rejected
        ) {
            bail!("non-motion acknowledgement cannot complete a pending motion");
        }
        let (event, deadline) = self
            .pending
            .ok_or_else(|| anyhow!("unsolicited window ACK"))?;
        if WindowPointerAck::for_motion(event, ack.result) != ack {
            bail!("mismatched window ACK");
        }
        let received = self.now_ns()?;
        if received >= deadline.saturating_add(crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS) {
            bail!(
                "late window ACK: sequence={} overdue_ns={} timing={:?}",
                event.sequence,
                received - deadline,
                self.pending_timing
            );
        }
        self.receipts
            .record(ack.result, self.pending_button, self.pending_wheel)?;
        self.set_pending(None);
        self.pending_button = None;
        self.pending_wheel = None;
        self.acknowledgements
            .send(Some(ack))
            .map_err(|_| anyhow!("preview ACK owner disappeared"))
    }

    fn now_ns(&self) -> Result<u64> {
        Ok(u64::try_from(self.origin.elapsed().as_nanos())?)
    }

    fn has_authorized_identity(&self, identity: PresentedInputIdentity, generation: u64) -> bool {
        self.authorization_history.iter().any(|receipt| {
            receipt.lease_generation == generation
                && receipt.target_window == identity.window
                && receipt.geometry_epoch == identity.geometry_epoch
                && receipt.presented_frame == identity.frame
        })
    }

    fn current_context_matches(
        current: Option<PresentedInputIdentity>,
        identity: PresentedInputIdentity,
    ) -> bool {
        current.is_some_and(|visual| {
            visual.window == identity.window
                && visual.geometry_epoch == identity.geometry_epoch
                && visual.frame >= identity.frame
        })
    }

    fn take_sample(
        &mut self,
        state: PreviewPointerState,
    ) -> Result<Option<(PreviewPointerEvent, bool)>> {
        if let Some((event, generation)) = self.deferred_receipt.take() {
            if self.authorization.map(|grant| grant.lease_generation) != Some(generation) {
                bail!("deferred event authorization changed");
            }
            return Ok(Some((event, true)));
        }
        if let Some(events) = &mut self.ordered {
            return match events.receiver.try_recv() {
                Ok(event) => Ok(Some((event, false))),
                Err(mpsc::error::TryRecvError::Empty) => Ok(None),
                Err(mpsc::error::TryRecvError::Disconnected) => {
                    Err(anyhow!("native pointer event owner disappeared"))
                }
            };
        }
        Ok(state.motion.map(|sample| {
            (
                PreviewPointerEvent {
                    key: None,
                    wheel: None,
                    sample,
                    button: None,
                },
                false,
            )
        }))
    }

    fn defer_for_receipt(
        &mut self,
        event: PreviewPointerEvent,
        authorization: WindowPointerAuthorization,
        snapshot: Option<ClockSnapshot>,
        now: u64,
    ) -> bool {
        event.sample.presented.frame > authorization.presented_frame
            && self.defer_fresh_event(event, authorization, snapshot, now)
    }

    fn defer_fresh_event(
        &mut self,
        event: PreviewPointerEvent,
        authorization: WindowPointerAuthorization,
        snapshot: Option<ClockSnapshot>,
        now: u64,
    ) -> bool {
        let sample = event.sample;
        if self.ordered.is_none()
            || sample.presented.window != authorization.target_window
            || sample.presented.geometry_epoch != authorization.geometry_epoch
            || now >= sample.sender_not_after_ns
            || sample.sender_not_after_ns - now
                > if event.is_motion() {
                    33_333_334
                } else {
                    crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS
                }
            || (event.key.is_none()
                && (sample.x_pixels >= sample.viewport_width
                    || sample.y_pixels >= sample.viewport_height))
            || conservative_authorization_deadline(authorization.source_not_after_ns, snapshot, now)
                .is_err()
        {
            return false;
        }
        self.deferred_receipt = Some((event, authorization.lease_generation));
        true
    }

    fn awaiting_confirmation(&self, now: u64) -> Result<bool> {
        let Some((_, deadline)) = self.pending else {
            return Ok(false);
        };
        let wait_deadline =
            deadline.saturating_add(crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS);
        if now >= wait_deadline {
            bail!(
                "window motion confirmation timed out: overdue_ns={} timing={:?}",
                now - deadline,
                self.pending_timing
            );
        }
        Ok(true)
    }

    fn check_native_owner(&self) -> Result<()> {
        if self.samples.has_changed().is_err() || self.acknowledgements.is_closed() {
            bail!("native preview owner disappeared");
        }
        if let Some(events) = &self.ordered {
            if events.failed.load(Ordering::Acquire) || events.receiver.is_closed() {
                bail!("ordered native pointer stream ended or overflowed");
            }
        }
        Ok(())
    }

    fn check_event_kind(&self, queued: PreviewPointerEvent) -> Result<()> {
        if !queued.valid_kind()
            || (queued.wheel.is_some() && !self.allow_wheel)
            || (queued.key.is_some() && !self.allow_keyboard)
        {
            bail!("input kind is ambiguous or not locally enabled on this preview route");
        }
        Ok(())
    }

    fn next_motion(
        &mut self,
        snapshot: Option<ClockSnapshot>,
        now: u64,
    ) -> Result<Option<(WindowPointerMotion, u64)>> {
        self.check_native_owner()?;
        if self.awaiting_confirmation(now)? {
            return Ok(None);
        }
        let state = *self.samples.borrow_and_update();
        let Some((queued, resumed)) = self.take_sample(state)? else {
            return Ok(None);
        };
        self.check_event_kind(queued)?;
        let sample = queued.sample;
        if sample.sample_sequence == 0 || sample.sample_sequence < self.last_sample {
            bail!("native preview sample sequence regressed");
        }
        if sample.sample_sequence == self.last_sample && !resumed {
            if self.ordered.is_some() {
                bail!("ordered pointer sequence replayed");
            }
            return Ok(None);
        }
        // Consume samples even when not authorized. A later grant/clock update
        // must not turn an earlier unadmitted movement into new input.
        self.last_sample = sample.sample_sequence;
        let Some(authorization) = self.authorization else {
            if !queued.is_motion() {
                bail!("button arrived without source authorization");
            }
            return Ok(None);
        };
        let current_identity = PresentedInputIdentity {
            window: authorization.target_window,
            geometry_epoch: authorization.geometry_epoch,
            frame: authorization.presented_frame,
        };
        let identity = sample.presented;
        let verified = self.has_authorized_identity(identity, authorization.lease_generation);
        // Native completion clears the published visual until its full tag
        // passes media validation. A previously authorized FIFO event may
        // wait through that gap, but cannot be forwarded while it is absent.
        // Keep the original event/generation/deadline; close, expiry, changed
        // geometry and changed authorization still fail their existing gates.
        if state.presented.is_none()
            && verified
            && self.defer_fresh_event(queued, authorization, snapshot, now)
        {
            return Ok(None);
        }
        let current_context_matches = Self::current_context_matches(state.presented, identity);
        if !verified
            && current_context_matches
            && self.defer_for_receipt(queued, authorization, snapshot, now)
        {
            return Ok(None);
        }
        if !current_context_matches
            || !verified
            || now >= sample.sender_not_after_ns
            || sample.sender_not_after_ns - now
                > if queued.is_motion() {
                    33_333_334
                } else {
                    crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS
                }
            || (queued.key.is_none()
                && (sample.x_pixels >= sample.viewport_width
                    || sample.y_pixels >= sample.viewport_height))
        {
            if !queued.is_motion() {
                bail!(
                    "button has stale or invalid presentation context: visual={:?} authorization={current_identity:?} sample={identity:?} verified={verified} now_ns={now} deadline_ns={}",
                    state.presented,
                    sample.sender_not_after_ns
                );
            }
            return Ok(None);
        }
        let Ok(lease_deadline) =
            conservative_authorization_deadline(authorization.source_not_after_ns, snapshot, now)
        else {
            if !queued.is_motion() {
                bail!("button lacks valid source clock or lease");
            }
            return Ok(None);
        };
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or_else(|| anyhow!("window event sequence exhausted"))?;
        let event = WindowPointerMotion {
            lease_generation: authorization.lease_generation,
            target_device: self.source,
            target_window: self.window,
            geometry_epoch: identity.geometry_epoch,
            presented_frame: identity.frame,
            sequence: self.sequence,
            sender_not_after_ns: sample.sender_not_after_ns,
            x_pixels: sample.x_pixels,
            y_pixels: sample.y_pixels,
            viewport_width: sample.viewport_width,
            viewport_height: sample.viewport_height,
        };
        let deadline = sample
            .sender_not_after_ns
            .min(lease_deadline)
            .min(self.bind_keyboard(event, queued.key, snapshot, now)?);
        self.set_pending(Some((event, deadline)));
        self.pending_button = queued.button;
        self.pending_wheel = queued.wheel;
        Ok(Some((event, deadline)))
    }

    pub(crate) async fn pump(
        &mut self,
        snapshot: Option<ClockSnapshot>,
        outbound: &crate::OutboundSender,
    ) -> Result<()> {
        let Some((event, local_deadline)) = self.next_motion(snapshot, self.now_ns()?)? else {
            return Ok(());
        };
        self.pending_timing = Some([self.now_ns()?, local_deadline, 0]);
        // Payload expiry governs whether the source may apply this event.
        // Transport/ACK completion has a separate watchdog: finishing a send
        // after the motion target is not a connection failure.
        let deadline = tokio::time::Instant::now()
            + Duration::from_nanos(crate::input_runtime::INPUT_OPERATION_TIMEOUT_NS);
        let gate = crate::InputSendGate::new(deadline);
        let mut cancel = crate::InputSendCancelGuard::new(gate.clone());
        let (sent, confirmation) = tokio::sync::oneshot::channel();
        crate::run_until_deadline(
            deadline,
            outbound.controls.send(crate::OutboundControl {
                payload: if let Some(key) = self.pending_key {
                    viewflow_protocol::wire::control_envelope::Payload::WindowKeyboardEvent(
                        key.into(),
                    )
                } else if let Some(delta) = self.pending_wheel {
                    viewflow_protocol::wire::control_envelope::Payload::WindowPointerWheel(
                        viewflow_protocol::WindowPointerWheel {
                            position: event,
                            delta,
                        }
                        .into(),
                    )
                } else if let Some(transition) = self.pending_button {
                    viewflow_protocol::wire::control_envelope::Payload::WindowPointerButton(
                        viewflow_protocol::WindowPointerButton {
                            position: event,
                            transition,
                        }
                        .into(),
                    )
                } else {
                    viewflow_protocol::wire::control_envelope::Payload::WindowPointerMotion(
                        event.into(),
                    )
                },
                sent: Some(sent),
                input_gate: Some(gate),
            }),
        )
        .await
        .ok_or_else(|| anyhow!("preview input queue deadline expired"))??;
        crate::run_until_deadline(deadline, confirmation)
            .await
            .ok_or_else(|| anyhow!("preview input writer deadline expired"))??
            .map_err(|error| anyhow!("preview input writer failed: {error}"))?;
        cancel.disarm();
        let completed = self.now_ns()?;
        if let Some(timing) = &mut self.pending_timing {
            timing[2] = completed;
        }
        Ok(())
    }
}
