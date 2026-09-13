//! Geometry binding for input sampled from an actually presented window frame.
//! This does not grant an input lease or perform native injection.

use std::collections::VecDeque;
use viewflow_protocol::{DeviceId, Point, Size, WindowId, WindowPointerMotion};

use crate::{CaptureGeometry, CaptureSlice};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PresentedInputIdentity {
    pub window: WindowId,
    pub geometry_epoch: u64,
    pub frame: u64,
}

/// Immutable context installed only after the corresponding visual commits.
/// Keep the identity and geometry together, never combine a stale event with
/// the newest crop after a resize. Authorization remains the caller's job.
#[derive(Clone, Copy, Debug)]
pub struct PresentedInputGeometry {
    identity: PresentedInputIdentity,
    capture: CaptureGeometry,
    slice: CaptureSlice,
}

impl PresentedInputGeometry {
    /// A control-channel placeholder for an empty desktop. It is not a
    /// presentation and cannot map input or produce a window grant.
    #[must_use]
    pub fn unbound() -> Self {
        let rect = viewflow_protocol::Rect {
            origin: Point::default(),
            size: Size {
                width: 1.,
                height: 1.,
            },
        };
        let capture = CaptureGeometry::new(rect, rect, 1, 1).expect("unit geometry");
        Self {
            identity: PresentedInputIdentity {
                window: viewflow_protocol::Id128(0),
                geometry_epoch: 0,
                frame: 0,
            },
            capture,
            slice: capture
                .slice_for_display(Point::default(), rect)
                .expect("unit slice"),
        }
    }

    /// Identity of this immutable source-verified presentation, not authority.
    #[must_use]
    pub fn identity(self) -> PresentedInputIdentity {
        self.identity
    }
}

/// Connection-local grant created by the source's authorization layer, never
/// from an incoming motion or a device-wide HID lease. Dropping/revoking it
/// invalidates the route; a new connection needs a freshly authorized grant.
#[derive(Debug)]
pub struct WindowPointerGrant {
    owner: DeviceId,
    target_device: DeviceId,
    generation: u64,
    geometry: PresentedInputGeometry,
    presented_history: VecDeque<PresentedInputGeometry>,
    expires_local_ns: u64,
    last_sequence: u64,
    revoked: bool,
}

impl WindowPointerGrant {
    /// Holds only the paired device identity until a real window is selected.
    pub fn idle(owner: DeviceId, target_device: DeviceId) -> Option<Self> {
        if owner.0 == 0 || target_device.0 == 0 || owner == target_device {
            return None;
        }
        Some(Self {
            owner,
            target_device,
            generation: 0,
            geometry: PresentedInputGeometry::unbound(),
            presented_history: VecDeque::new(),
            expires_local_ns: 0,
            last_sequence: 0,
            revoked: true,
        })
    }

    pub fn devices(&self) -> (DeviceId, DeviceId) {
        (self.owner, self.target_device)
    }

    #[must_use]
    pub fn new(
        owner: DeviceId,
        target_device: DeviceId,
        generation: u64,
        geometry: PresentedInputGeometry,
        expires_local_ns: u64,
    ) -> Option<Self> {
        if owner.0 == 0
            || target_device.0 == 0
            || generation == 0
            || expires_local_ns == 0
            || geometry.identity.window.0 == 0
        {
            return None;
        }
        Some(Self {
            owner,
            target_device,
            generation,
            geometry,
            presented_history: VecDeque::from([geometry]),
            expires_local_ns,
            last_sequence: 0,
            revoked: false,
        })
    }

    pub fn revoke(&mut self) {
        self.revoked = true;
        self.presented_history.clear();
    }

    /// Advertise only this source-owned grant. Native binding must additionally
    /// be confirmed by the caller before this announcement leaves the process.
    #[must_use]
    pub fn authorization(
        &self,
        now_local_ns: u64,
    ) -> Option<viewflow_protocol::WindowPointerAuthorization> {
        if self.revoked || now_local_ns >= self.expires_local_ns {
            return None;
        }
        Some(viewflow_protocol::WindowPointerAuthorization {
            lease_generation: self.generation,
            owner_device: self.owner,
            target_device: self.target_device,
            target_window: self.geometry.identity.window,
            geometry_epoch: self.geometry.identity.geometry_epoch,
            presented_frame: self.geometry.identity.frame,
            source_not_after_ns: self.expires_local_ns,
        })
    }

    /// Install only a source-verified presentation receipt. Resize invalidates
    /// this grant: it cannot silently acquire a different geometry epoch.
    pub fn advance_presented(&mut self, geometry: PresentedInputGeometry) -> bool {
        if self.revoked
            || geometry.identity.window != self.geometry.identity.window
            || geometry.identity.geometry_epoch != self.geometry.identity.geometry_epoch
            || geometry.identity.frame <= self.geometry.identity.frame
        {
            return false;
        }
        self.geometry = geometry;
        self.presented_history.push_back(geometry);
        if self.presented_history.len() > 32 {
            self.presented_history.pop_front();
        }
        true
    }

    /// `authenticated_owner` comes from the connection, not the message.
    /// `conservative_deadline_local_ns` must be clock-mapped from this event's
    /// sender deadline with uncertainty subtracted. Missing clock evidence is
    /// rejected. Once peer/target/geometry and payload are valid, the sequence
    /// is consumed even on timing rejection. An ambiguous backend failure or
    /// a later clock correction must not allow retrying the same event.
    pub fn admit_motion(
        &mut self,
        authenticated_owner: DeviceId,
        event: WindowPointerMotion,
        conservative_deadline_local_ns: Option<u64>,
        now_local_ns: u64,
    ) -> Option<Point> {
        if self.revoked
            || authenticated_owner != self.owner
            || event.target_device != self.target_device
            || event.lease_generation != self.generation
            || event.sequence <= self.last_sequence
            || event.sender_not_after_ns == 0
        {
            return None;
        }
        let identity = PresentedInputIdentity {
            window: event.target_window,
            geometry_epoch: event.geometry_epoch,
            frame: event.presented_frame,
        };
        // Only source-verified receipts enter this bounded history. Never infer
        // admission from an older frame number or remap it with the latest crop.
        let geometry = self
            .presented_history
            .iter()
            .find(|entry| entry.identity == identity)?;
        let point = geometry.map_pointer(
            identity,
            Size {
                width: f64::from(event.viewport_width),
                height: f64::from(event.viewport_height),
            },
            Point {
                x: f64::from(event.x_pixels),
                y: f64::from(event.y_pixels),
            },
        )?;
        // A structurally valid event from this authorized target is spent even
        // when timing cannot be proven. A later clock correction must not make
        // a replay of this same event eligible for native injection.
        self.last_sequence = event.sequence;
        let deadline = conservative_deadline_local_ns?;
        if now_local_ns >= self.expires_local_ns || now_local_ns >= deadline {
            return None;
        }
        Some(point)
    }
}

impl PresentedInputGeometry {
    #[must_use]
    pub fn new(
        identity: PresentedInputIdentity,
        capture: CaptureGeometry,
        slice: CaptureSlice,
    ) -> Option<Self> {
        if identity.window.0 == 0 || identity.geometry_epoch == 0 || identity.frame == 0 {
            return None;
        }
        Some(Self {
            identity,
            capture,
            slice,
        })
    }

    /// Match the exact presented context before mapping client pixels. A
    /// rejected/expired frame must never replace this context. Viewport pixels
    /// come from the same native event, excluding any letterboxing.
    #[must_use]
    pub fn map_pointer(
        self,
        identity: PresentedInputIdentity,
        viewport_pixels: Size,
        point: Point,
    ) -> Option<Point> {
        if identity.window.0 == 0 || identity != self.identity {
            return None;
        }
        self.capture
            .slice_pixel_to_content(self.slice, viewport_pixels, point)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::{Id128, Rect};

    #[test]
    fn empty_desktop_has_no_window_authority_or_pointer_mapping() {
        let empty = PresentedInputGeometry::unbound();
        let mut grant =
            WindowPointerGrant::idle(viewflow_protocol::Id128(1), viewflow_protocol::Id128(2))
                .unwrap();
        assert!(grant.authorization(0).is_none());
        assert!(!grant.advance_presented(grant_fixture().0.geometry));
        assert!(
            WindowPointerGrant::new(
                viewflow_protocol::Id128(1),
                viewflow_protocol::Id128(2),
                1,
                empty,
                100
            )
            .is_none()
        );
        assert!(
            empty
                .map_pointer(
                    empty.identity(),
                    Size {
                        width: 1.,
                        height: 1.
                    },
                    Point::default()
                )
                .is_none()
        );
    }

    fn grant_fixture() -> (WindowPointerGrant, WindowPointerMotion) {
        let rect = Rect {
            origin: Point::default(),
            size: Size {
                width: 100.0,
                height: 50.0,
            },
        };
        let capture = CaptureGeometry::new(rect, rect, 200, 100).unwrap();
        let geometry = PresentedInputGeometry::new(
            PresentedInputIdentity {
                window: Id128(3),
                geometry_epoch: 4,
                frame: 5,
            },
            capture,
            capture.slice_for_display(Point::default(), rect).unwrap(),
        )
        .unwrap();
        let grant = WindowPointerGrant::new(Id128(1), Id128(2), 7, geometry, 100).unwrap();
        let event = WindowPointerMotion {
            lease_generation: 7,
            target_device: Id128(2),
            target_window: Id128(3),
            geometry_epoch: 4,
            presented_frame: 5,
            sequence: 1,
            sender_not_after_ns: 200,
            x_pixels: 100,
            y_pixels: 40,
            viewport_width: 200,
            viewport_height: 100,
        };
        (grant, event)
    }

    #[test]
    fn authorization_preserves_source_identity_and_never_renews_expiry() {
        let (mut grant, _) = grant_fixture();
        let first = grant.authorization(1).unwrap();
        assert_eq!(first.owner_device, Id128(1));
        assert_eq!(first.target_device, Id128(2));
        assert_eq!(first.target_window, Id128(3));
        assert_eq!(first.geometry_epoch, 4);
        assert_eq!(first.presented_frame, 5);
        assert_eq!(first.lease_generation, 7);
        assert_eq!(first.source_not_after_ns, 100);
        assert_eq!(grant.authorization(99), Some(first));
        assert!(grant.authorization(100).is_none());
        grant.revoke();
        assert!(grant.authorization(1).is_none());
    }

    #[test]
    fn window_grant_rejects_wrong_binding_without_consuming_valid_sequence() {
        for field in 0..8 {
            let (mut grant, event) = grant_fixture();
            let mut wrong = event;
            match field {
                0 => wrong.target_device = Id128(9),
                1 => wrong.target_window = Id128(9),
                2 => wrong.lease_generation += 1,
                3 => wrong.geometry_epoch += 1,
                4 => wrong.presented_frame += 1,
                5 => wrong.sequence = 0,
                6 => wrong.sender_not_after_ns = 0,
                _ => wrong.x_pixels = wrong.viewport_width,
            }
            assert!(grant.admit_motion(Id128(1), wrong, Some(90), 80).is_none());
            assert_eq!(
                grant.admit_motion(Id128(1), event, Some(90), 80),
                Some(Point { x: 50.0, y: 20.0 })
            );
            assert!(grant.admit_motion(Id128(1), event, Some(90), 80).is_none());
        }
    }

    #[test]
    fn window_grant_requires_peer_clock_and_unexpired_authority() {
        for (owner, deadline, now) in [
            (Id128(9), Some(90), 80),
            (Id128(1), None, 80),
            (Id128(1), Some(80), 80),
            (Id128(1), Some(200), 100),
        ] {
            let (mut grant, event) = grant_fixture();
            assert!(grant.admit_motion(owner, event, deadline, now).is_none());
        }
        let (mut grant, event) = grant_fixture();
        grant.revoke();
        assert!(grant.admit_motion(Id128(1), event, Some(90), 80).is_none());
        let mut next = grant.geometry;
        next.identity.frame += 1;
        assert!(!grant.advance_presented(next));
    }

    #[test]
    fn timing_rejection_spends_sequence_before_clock_recovery() {
        for deadline in [None, Some(80)] {
            let (mut grant, mut event) = grant_fixture();
            assert!(grant.admit_motion(Id128(1), event, deadline, 80).is_none());
            assert!(grant.admit_motion(Id128(1), event, Some(95), 81).is_none());
            event.sequence += 1;
            assert!(grant.admit_motion(Id128(1), event, Some(95), 81).is_some());
        }
    }

    #[test]
    fn presentation_advances_without_retargeting_or_resizing_grant() {
        let (mut grant, mut event) = grant_fixture();
        let mut next = grant.geometry;
        assert!(!grant.advance_presented(next));
        next.identity.frame += 1;
        next.identity.geometry_epoch += 1;
        assert!(!grant.advance_presented(next));
        next.identity.geometry_epoch -= 1;
        next.identity.window = Id128(99);
        assert!(!grant.advance_presented(next));
        next.identity.window = Id128(3);
        assert!(grant.advance_presented(next));
        assert!(grant.admit_motion(Id128(1), event, Some(90), 80).is_some());
        event.sequence += 1;
        event.presented_frame += 1;
        assert!(grant.admit_motion(Id128(1), event, Some(90), 80).is_some());
    }

    #[test]
    fn verified_history_is_bounded_and_does_not_admit_missing_receipts() {
        let (mut grant, mut event) = grant_fixture();
        let mut next = grant.geometry;
        for frame in 7..=37 {
            next.identity.frame = frame;
            assert!(grant.advance_presented(next));
        }
        // Initial frame 5 remains at the exact 32-entry boundary; frame 6 was
        // never verified even though it lies between two verified receipts.
        event.presented_frame = 6;
        assert!(grant.admit_motion(Id128(1), event, Some(90), 80).is_none());
        event.presented_frame = 5;
        assert!(grant.admit_motion(Id128(1), event, Some(90), 80).is_some());
        event.sequence += 1;
        next.identity.frame = 38;
        assert!(grant.advance_presented(next));
        assert!(grant.admit_motion(Id128(1), event, Some(90), 80).is_none());
        event.presented_frame = 7;
        assert!(grant.admit_motion(Id128(1), event, Some(90), 80).is_some());
        grant.revoke();
        assert!(grant.presented_history.is_empty());
        event.sequence += 1;
        assert!(grant.admit_motion(Id128(1), event, Some(90), 80).is_none());
    }

    #[test]
    fn stale_frame_epoch_and_other_window_cannot_use_current_geometry() {
        let rect = Rect {
            origin: Point::default(),
            size: Size {
                width: 100.0,
                height: 50.0,
            },
        };
        let capture = CaptureGeometry::new(rect, rect, 200, 100).unwrap();
        let slice = capture.slice_for_display(Point::default(), rect).unwrap();
        let identity = PresentedInputIdentity {
            window: Id128(1),
            geometry_epoch: 7,
            frame: 42,
        };
        let context = PresentedInputGeometry::new(identity, capture, slice).unwrap();
        let viewport = Size {
            width: 150.0,
            height: 75.0,
        };
        let point = Point { x: 75.0, y: 30.0 };
        assert_eq!(
            context.map_pointer(identity, viewport, point),
            Some(Point { x: 50.0, y: 20.0 })
        );
        for wrong in [
            PresentedInputIdentity {
                window: Id128(2),
                ..identity
            },
            PresentedInputIdentity {
                geometry_epoch: 6,
                ..identity
            },
            PresentedInputIdentity {
                frame: 41,
                ..identity
            },
        ] {
            assert_eq!(context.map_pointer(wrong, viewport, point), None);
        }
        for invalid in [
            PresentedInputIdentity {
                window: Id128(0),
                ..identity
            },
            PresentedInputIdentity {
                geometry_epoch: 0,
                ..identity
            },
            PresentedInputIdentity {
                frame: 0,
                ..identity
            },
        ] {
            assert!(PresentedInputGeometry::new(invalid, capture, slice).is_none());
        }
    }
}
