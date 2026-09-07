//! Source-owned keyboard admission and conservative native cleanup bookkeeping.
//! No native injection, focus acquisition, or authority from incoming messages.

use crate::PresentedInputIdentity;
use std::collections::{BTreeSet, VecDeque};
use viewflow_protocol::{DeviceId, InputSwitchState, WindowKeyboardEvent};

/// Construct only after local keyboard policy and an exact native window binding
/// have been approved. A pointer grant is not a keyboard grant. All calls are
/// connection-local; reconnect requires a new grant and native cleanup first.
#[derive(Debug)]
pub struct WindowKeyboardGrant {
    owner: DeviceId,
    target: DeviceId,
    generation: u64,
    presented: VecDeque<PresentedInputIdentity>,
    expires_local_ns: u64,
    last_sequence: u64,
    pending: Option<(WindowKeyboardEvent, u64)>,
    possibly_pressed: BTreeSet<(u16, u16)>,
    revoked: bool,
}

impl WindowKeyboardGrant {
    /// Announce only after the caller has confirmed the native keyboard begin.
    /// Construction/this method alone do not prove native focus or permission.
    #[must_use]
    pub fn authorization(
        &self,
        now_local_ns: u64,
    ) -> Option<viewflow_protocol::WindowKeyboardAuthorization> {
        if self.revoked || now_local_ns >= self.expires_local_ns {
            return None;
        }
        let presented = self.presented.back()?;
        Some(viewflow_protocol::WindowKeyboardAuthorization {
            lease_generation: self.generation,
            owner_device: self.owner,
            target_device: self.target,
            target_window: presented.window,
            geometry_epoch: presented.geometry_epoch,
            presented_frame: presented.frame,
            source_not_after_ns: self.expires_local_ns,
            mode: viewflow_protocol::WindowKeyboardMode::DirectApplication,
        })
    }

    /// Install a fresh LOCAL decision after exact native binding checks. Keeps
    /// pressed keys and replay state; generation changes never authorize retry
    /// of an old key sequence. Native renewal must complete before publication.
    pub fn renew(
        &mut self,
        owner: DeviceId,
        target: DeviceId,
        generation: u64,
        presented: PresentedInputIdentity,
        expires_local_ns: u64,
        now_local_ns: u64,
    ) -> bool {
        let Some(previous) = self.authorization(now_local_ns) else {
            return false;
        };
        if self.pending.is_some()
            || owner != self.owner
            || target != self.target
            || generation <= self.generation
            || presented.window != previous.target_window
            || presented.geometry_epoch != previous.geometry_epoch
            || presented.frame <= previous.presented_frame
            || expires_local_ns <= self.expires_local_ns
        {
            return false;
        }
        self.generation = generation;
        self.expires_local_ns = expires_local_ns;
        self.presented.clear();
        self.presented.push_back(presented);
        true
    }
    #[must_use]
    pub fn new(
        owner: DeviceId,
        target: DeviceId,
        generation: u64,
        presented: PresentedInputIdentity,
        expires_local_ns: u64,
    ) -> Option<Self> {
        if owner.0 == 0
            || target.0 == 0
            || generation == 0
            || expires_local_ns == 0
            || presented.window.0 == 0
            || presented.geometry_epoch == 0
            || presented.frame == 0
        {
            return None;
        }
        Some(Self {
            owner,
            target,
            generation,
            presented: VecDeque::from([presented]),
            expires_local_ns,
            last_sequence: 0,
            pending: None,
            possibly_pressed: BTreeSet::new(),
            revoked: false,
        })
    }

    /// Source-verified receipt only; frame advance never renews the lease or
    /// silently transfers held keys to a new window/geometry epoch.
    pub fn advance_presented(&mut self, presented: PresentedInputIdentity) -> bool {
        let Some(current) = self.presented.back() else {
            return false;
        };
        if self.revoked
            || presented.window != current.window
            || presented.geometry_epoch != current.geometry_epoch
            || presented.frame <= current.frame
        {
            return false;
        }
        self.presented.push_back(presented);
        if self.presented.len() > 32 {
            self.presented.pop_front();
        }
        true
    }

    /// Prepare exactly one native operation. The returned deadline is the
    /// stricter of the source lease and uncertainty-subtracted event deadline.
    /// The native backend must recheck it and its exact bound surface before
    /// injecting. `authenticated_owner` is connection evidence, never wire data.
    ///
    /// An attempted press enters cleanup bookkeeping BEFORE native dispatch.
    /// An attempted release stays there until exact native confirmation. Failure
    /// or uncertainty requires revoke + native cleanup, never a device fallback.
    /// Timing/transition rejection spends a structurally bound sequence.
    #[must_use]
    pub fn prepare(
        &mut self,
        authenticated_owner: DeviceId,
        event: WindowKeyboardEvent,
        conservative_deadline_local_ns: Option<u64>,
        now_local_ns: u64,
    ) -> Option<u64> {
        if self.revoked
            || self.pending.is_some()
            || event.validate().is_err()
            || authenticated_owner != self.owner
            || event.target_device != self.target
            || event.lease_generation != self.generation
            || event.sequence <= self.last_sequence
            || !self.presented.contains(&PresentedInputIdentity {
                window: event.target_window,
                geometry_epoch: event.geometry_epoch,
                frame: event.presented_frame,
            })
        {
            return None;
        }
        self.last_sequence = event.sequence;
        let deadline = conservative_deadline_local_ns?.min(self.expires_local_ns);
        if now_local_ns >= deadline {
            return None;
        }
        let usage = (event.key.usage_page, event.key.usage_id);
        let held = self.possibly_pressed.contains(&usage);
        match (event.key.state, event.key.repeat, held) {
            (InputSwitchState::Pressed, false, false) => {
                if self.possibly_pressed.len() >= 256 {
                    return None;
                }
                self.possibly_pressed.insert(usage);
            }
            (InputSwitchState::Pressed, true, true) | (InputSwitchState::Released, false, true) => {
            }
            _ => return None,
        }
        self.pending = Some((event, deadline));
        Some(deadline)
    }

    /// Called only after the native backend confirms this EXACT operation.
    /// Late/mismatched confirmations cannot clear cleanup state or free the FIFO.
    pub fn confirm(&mut self, event: WindowKeyboardEvent, now_local_ns: u64) -> bool {
        let Some((pending, deadline)) = self.pending else {
            return false;
        };
        if self.revoked || pending != event || now_local_ns >= deadline {
            return false;
        }
        if event.key.state == InputSwitchState::Released {
            self.possibly_pressed
                .remove(&(event.key.usage_page, event.key.usage_id));
        }
        self.pending = None;
        true
    }

    /// Revocation prevents further input, but must NOT forget possibly held
    /// usages. The owner must release these on the original native binding,
    /// retain cleanup failure, and fence reuse. Dropping Rust state is no release.
    pub fn revoke(&mut self) {
        self.revoked = true;
    }

    pub fn possibly_pressed(&self) -> impl Iterator<Item = (u16, u16)> + '_ {
        self.possibly_pressed.iter().copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::{Id128, KeyboardHidUsage};

    #[test]
    fn keyboard_renewal_keeps_held_keys_without_reviving_old_events() {
        let (mut grant, mut event) = fixture();
        assert!(grant.prepare(Id128(1), event, Some(90), 10).is_some());
        let next = PresentedInputIdentity {
            window: Id128(3),
            geometry_epoch: 4,
            frame: 6,
        };
        assert!(!grant.renew(Id128(1), Id128(2), 7, next, 200, 11));
        assert!(grant.confirm(event, 12));
        assert!(grant.renew(Id128(1), Id128(2), 7, next, 200, 99));
        let auth = grant.authorization(100).unwrap();
        assert_eq!(auth.lease_generation, 7);
        assert_eq!(auth.source_not_after_ns, 200);
        assert_eq!(grant.possibly_pressed().collect::<Vec<_>>(), [(7, 4)]);
        event.lease_generation = 7;
        event.presented_frame = 6;
        event.key.state = InputSwitchState::Released;
        assert!(grant.prepare(Id128(1), event, Some(190), 100).is_none());
        event.sequence += 1;
        assert!(grant.prepare(Id128(1), event, Some(190), 101).is_some());
        assert!(grant.confirm(event, 102));
        assert_eq!(grant.possibly_pressed().count(), 0);
        assert!(grant.authorization(200).is_none());
        assert!(!grant.renew(
            Id128(1),
            Id128(2),
            8,
            PresentedInputIdentity { frame: 7, ..next },
            300,
            200
        ));
    }

    #[test]
    fn invalid_keyboard_renewals_do_not_change_authority() {
        for field in 0..8 {
            let (mut grant, _) = fixture();
            let before = grant.authorization(10).unwrap();
            let (mut owner, mut target, mut generation, mut expiry, mut now) =
                (Id128(1), Id128(2), 7, 200, 99);
            let mut next = PresentedInputIdentity {
                window: Id128(3),
                geometry_epoch: 4,
                frame: 6,
            };
            match field {
                0 => owner = Id128(9),
                1 => target = Id128(9),
                2 => generation = 6,
                3 => expiry = 100,
                4 => next.window = Id128(9),
                5 => next.geometry_epoch = 9,
                6 => next.frame = 5,
                _ => now = 100,
            }
            assert!(!grant.renew(owner, target, generation, next, expiry, now));
            assert_eq!(grant.authorization(10).unwrap(), before);
        }
        let (mut grant, _) = fixture();
        grant.revoke();
        assert!(grant.authorization(10).is_none());
    }

    fn fixture() -> (WindowKeyboardGrant, WindowKeyboardEvent) {
        let identity = PresentedInputIdentity {
            window: Id128(3),
            geometry_epoch: 4,
            frame: 5,
        };
        (
            WindowKeyboardGrant::new(Id128(1), Id128(2), 6, identity, 100).unwrap(),
            WindowKeyboardEvent {
                lease_generation: 6,
                target_device: Id128(2),
                target_window: Id128(3),
                geometry_epoch: 4,
                presented_frame: 5,
                sequence: 1,
                sender_not_after_ns: 90,
                key: KeyboardHidUsage {
                    usage_page: 7,
                    usage_id: 4,
                    state: InputSwitchState::Pressed,
                    repeat: false,
                },
            },
        )
    }

    #[test]
    fn balanced_keys_repeat_and_exact_confirmations() {
        let (mut grant, mut event) = fixture();
        assert_eq!(grant.prepare(Id128(1), event, Some(90), 10), Some(90));
        assert_eq!(grant.possibly_pressed().collect::<Vec<_>>(), [(7, 4)]);
        let mut wrong = event;
        wrong.key.usage_id = 5;
        assert!(!grant.confirm(wrong, 11));
        assert_eq!(grant.prepare(Id128(1), wrong, Some(90), 12), None);
        assert!(grant.confirm(event, 13));
        event.sequence += 1;
        event.key.repeat = true;
        assert_eq!(grant.prepare(Id128(1), event, Some(90), 14), Some(90));
        assert!(grant.confirm(event, 15));
        event.sequence += 1;
        event.key.repeat = false;
        event.key.state = InputSwitchState::Released;
        assert_eq!(grant.prepare(Id128(1), event, Some(90), 16), Some(90));
        assert_eq!(grant.possibly_pressed().count(), 1);
        assert!(grant.confirm(event, 17));
        assert_eq!(grant.possibly_pressed().count(), 0);
        assert_eq!(grant.prepare(Id128(1), event, Some(90), 18), None);
    }

    #[test]
    fn uncertain_press_and_release_remain_in_cleanup_after_revocation() {
        for release in [false, true] {
            let (mut grant, mut event) = fixture();
            assert!(grant.prepare(Id128(1), event, Some(90), 10).is_some());
            if release {
                assert!(grant.confirm(event, 11));
                event.sequence += 1;
                event.key.state = InputSwitchState::Released;
                assert!(grant.prepare(Id128(1), event, Some(90), 12).is_some());
            }
            assert!(!grant.confirm(event, 90));
            grant.revoke();
            grant.revoke();
            assert_eq!(grant.possibly_pressed().collect::<Vec<_>>(), [(7, 4)]);
            assert!(!grant.confirm(event, 13));
            event.sequence += 1;
            assert!(grant.prepare(Id128(1), event, Some(90), 14).is_none());
        }
    }

    #[test]
    fn timing_rejection_spends_sequence_and_never_extends_lease() {
        for deadline in [None, Some(10), Some(9)] {
            let (mut grant, event) = fixture();
            assert_eq!(grant.prepare(Id128(1), event, deadline, 10), None);
            assert_eq!(grant.prepare(Id128(1), event, Some(90), 11), None);
            assert_eq!(grant.possibly_pressed().count(), 0);
        }
        let (mut grant, event) = fixture();
        assert_eq!(grant.prepare(Id128(1), event, Some(200), 99), Some(100));
        assert!(!grant.confirm(event, 100));
        let (mut grant, event) = fixture();
        assert_eq!(grant.prepare(Id128(1), event, Some(200), 100), None);
    }

    #[test]
    fn foreign_owner_target_generation_and_visual_cannot_inject() {
        for field in 0..8 {
            let (mut grant, mut event) = fixture();
            let mut owner = Id128(1);
            match field {
                0 => owner = Id128(9),
                1 => event.target_device = Id128(9),
                2 => event.target_window = Id128(9),
                3 => event.lease_generation += 1,
                4 => event.geometry_epoch += 1,
                5 => event.presented_frame += 1,
                6 => event.sender_not_after_ns = 0,
                _ => event.key.usage_id = 0,
            }
            assert!(grant.prepare(owner, event, Some(90), 10).is_none());
            assert_eq!(grant.possibly_pressed().count(), 0);
        }
    }

    #[test]
    fn invalid_transitions_are_spent_without_creating_held_keys() {
        for repeat in [true, false] {
            let (mut grant, mut event) = fixture();
            event.key.repeat = repeat;
            if !repeat {
                event.key.state = InputSwitchState::Released;
            }
            assert!(grant.prepare(Id128(1), event, Some(90), 10).is_none());
            event.key.repeat = false;
            event.key.state = InputSwitchState::Pressed;
            assert!(grant.prepare(Id128(1), event, Some(90), 11).is_none());
            assert_eq!(grant.possibly_pressed().count(), 0);
        }
        let (mut grant, mut event) = fixture();
        assert!(grant.prepare(Id128(1), event, Some(90), 10).is_some());
        assert!(grant.confirm(event, 11));
        event.sequence += 1;
        assert!(grant.prepare(Id128(1), event, Some(90), 12).is_none());
        assert_eq!(grant.possibly_pressed().count(), 1);
    }

    #[test]
    fn presentation_history_is_bounded_exact_and_not_authority_renewal() {
        let (mut grant, mut event) = fixture();
        for frame in 6..=37 {
            assert!(grant.advance_presented(PresentedInputIdentity {
                window: Id128(3),
                geometry_epoch: 4,
                frame
            }));
        }
        assert!(grant.prepare(Id128(1), event, Some(90), 10).is_none());
        for identity in [
            PresentedInputIdentity {
                window: Id128(9),
                geometry_epoch: 4,
                frame: 38,
            },
            PresentedInputIdentity {
                window: Id128(3),
                geometry_epoch: 5,
                frame: 38,
            },
            PresentedInputIdentity {
                window: Id128(3),
                geometry_epoch: 4,
                frame: 37,
            },
        ] {
            assert!(!grant.advance_presented(identity));
        }
        event.presented_frame = 6;
        assert_eq!(grant.prepare(Id128(1), event, Some(200), 99), Some(100));
    }

    #[test]
    fn held_usage_bookkeeping_is_bounded_without_blocking_releases() {
        let (mut grant, mut event) = fixture();
        for usage in 1..=256 {
            event.sequence = u64::from(usage);
            event.key.usage_id = usage;
            assert!(grant.prepare(Id128(1), event, Some(90), 10).is_some());
            assert!(grant.confirm(event, 11));
        }
        event.sequence = 257;
        event.key.usage_id = 257;
        assert!(grant.prepare(Id128(1), event, Some(90), 12).is_none());
        assert_eq!(grant.possibly_pressed().count(), 256);
        event.sequence = 258;
        event.key.usage_id = 1;
        event.key.state = InputSwitchState::Released;
        assert!(grant.prepare(Id128(1), event, Some(90), 13).is_some());
        assert!(grant.confirm(event, 14));
        event.sequence = 259;
        event.key.usage_id = 257;
        event.key.state = InputSwitchState::Pressed;
        assert!(grant.prepare(Id128(1), event, Some(90), 15).is_some());
        grant.revoke();
        assert_eq!(grant.possibly_pressed().count(), 256);
    }

    #[test]
    fn constructor_rejects_empty_source_authority_fields() {
        for field in 0..7 {
            let mut owner = Id128(1);
            let mut target = Id128(2);
            let mut generation = 6;
            let mut expiry = 100;
            let mut identity = PresentedInputIdentity {
                window: Id128(3),
                geometry_epoch: 4,
                frame: 5,
            };
            match field {
                0 => owner = Id128(0),
                1 => target = Id128(0),
                2 => generation = 0,
                3 => expiry = 0,
                4 => identity.window = Id128(0),
                5 => identity.geometry_epoch = 0,
                _ => identity.frame = 0,
            }
            assert!(
                WindowKeyboardGrant::new(owner, target, generation, identity, expiry).is_none()
            );
        }
    }
}
