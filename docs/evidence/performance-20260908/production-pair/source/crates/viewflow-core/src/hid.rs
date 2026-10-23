//! Exclusive, generation-numbered HID forwarding leases.

use std::collections::HashMap;

use viewflow_protocol::{DeviceId, HidDeviceLease, HidDeviceOffer, HidLeaseState, Id128};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HidLeaseError {
    InvalidInterfaceCount,
    DuplicateDevice,
    UnknownDevice,
    OwnerMismatch,
    LoopbackRoute,
    StaleGeneration,
    InvalidTransition,
    LeaseIdentityChanged,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ActiveHidRoute {
    pub hid_device_id: Id128,
    pub owner: DeviceId,
    pub route_to: DeviceId,
    pub generation: u64,
}

#[derive(Debug, Default)]
pub struct HidLeaseManager {
    devices: HashMap<Id128, HidDeviceOffer>,
    leases: HashMap<Id128, HidDeviceLease>,
}

impl HidLeaseManager {
    /// Registers immutable physical HID metadata under its owning peer.
    ///
    /// # Errors
    ///
    /// Rejects devices without interfaces and duplicate identifiers.
    pub fn register_device(&mut self, offer: HidDeviceOffer) -> Result<(), HidLeaseError> {
        if offer.interface_count == 0 {
            return Err(HidLeaseError::InvalidInterfaceCount);
        }
        if self.devices.contains_key(&offer.id) {
            return Err(HidLeaseError::DuplicateDevice);
        }
        self.devices.insert(offer.id, offer);
        Ok(())
    }

    /// Applies one lease transition for a physical HID device.
    ///
    /// A lease is exclusive because each device has exactly one current lease.
    /// Every transition must strictly advance its generation. Activation and
    /// revocation must retain the owner and destination established by the
    /// offered lease, preventing a stale peer from redirecting an active device.
    ///
    /// # Errors
    ///
    /// Rejects unknown devices, owner mismatch, local loopback, stale
    /// generations, identity changes, and invalid state transitions.
    pub fn apply_lease(&mut self, lease: HidDeviceLease) -> Result<(), HidLeaseError> {
        let registered = self
            .devices
            .get(&lease.device_id)
            .ok_or(HidLeaseError::UnknownDevice)?;
        if registered.owner != lease.owner {
            return Err(HidLeaseError::OwnerMismatch);
        }
        if lease.owner == lease.route_to {
            return Err(HidLeaseError::LoopbackRoute);
        }

        if let Some(current) = self.leases.get(&lease.device_id) {
            if lease.generation <= current.generation {
                return Err(HidLeaseError::StaleGeneration);
            }
            let valid_transition = matches!(
                (current.state, lease.state),
                (
                    HidLeaseState::Offered,
                    HidLeaseState::Active | HidLeaseState::Revoked
                ) | (HidLeaseState::Active, HidLeaseState::Revoked)
                    | (HidLeaseState::Revoked, HidLeaseState::Offered)
            );
            if !valid_transition {
                return Err(HidLeaseError::InvalidTransition);
            }
            if current.state != HidLeaseState::Revoked
                && (current.owner != lease.owner || current.route_to != lease.route_to)
            {
                return Err(HidLeaseError::LeaseIdentityChanged);
            }
        } else if lease.state != HidLeaseState::Offered {
            return Err(HidLeaseError::InvalidTransition);
        }

        self.leases.insert(lease.device_id, lease);
        Ok(())
    }

    #[must_use]
    pub fn device(&self, id: Id128) -> Option<&HidDeviceOffer> {
        self.devices.get(&id)
    }

    #[must_use]
    pub fn lease(&self, id: Id128) -> Option<HidDeviceLease> {
        self.leases.get(&id).copied()
    }

    #[must_use]
    pub fn active_route(&self, id: Id128) -> Option<ActiveHidRoute> {
        self.leases.get(&id).and_then(|lease| {
            (lease.state == HidLeaseState::Active).then_some(ActiveHidRoute {
                hid_device_id: lease.device_id,
                owner: lease.owner,
                route_to: lease.route_to,
                generation: lease.generation,
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn offer(id: u128) -> HidDeviceOffer {
        HidDeviceOffer {
            id: Id128(id),
            owner: Id128(1),
            vendor_id: 0x05ac,
            product_id: 0x0324,
            interface_count: 4,
        }
    }

    fn lease(generation: u64, state: HidLeaseState) -> HidDeviceLease {
        HidDeviceLease {
            generation,
            device_id: Id128(10),
            owner: Id128(1),
            route_to: Id128(2),
            state,
        }
    }

    #[test]
    fn offered_active_revoked_lifecycle_is_exclusive() {
        let mut manager = HidLeaseManager::default();
        manager.register_device(offer(10)).unwrap();
        manager
            .apply_lease(lease(1, HidLeaseState::Offered))
            .unwrap();
        assert_eq!(manager.active_route(Id128(10)), None);
        manager
            .apply_lease(lease(2, HidLeaseState::Active))
            .unwrap();
        assert_eq!(
            manager.active_route(Id128(10)),
            Some(ActiveHidRoute {
                hid_device_id: Id128(10),
                owner: Id128(1),
                route_to: Id128(2),
                generation: 2,
            })
        );
        manager
            .apply_lease(lease(3, HidLeaseState::Revoked))
            .unwrap();
        assert_eq!(manager.active_route(Id128(10)), None);
    }

    #[test]
    fn generation_and_identity_are_immutable_within_lease() {
        let mut manager = HidLeaseManager::default();
        manager.register_device(offer(10)).unwrap();
        manager
            .apply_lease(lease(5, HidLeaseState::Offered))
            .unwrap();
        assert_eq!(
            manager.apply_lease(lease(5, HidLeaseState::Active)),
            Err(HidLeaseError::StaleGeneration)
        );
        let mut redirected = lease(6, HidLeaseState::Active);
        redirected.route_to = Id128(3);
        assert_eq!(
            manager.apply_lease(redirected),
            Err(HidLeaseError::LeaseIdentityChanged)
        );
        manager
            .apply_lease(lease(6, HidLeaseState::Active))
            .unwrap();
    }

    #[test]
    fn revoked_device_can_be_reoffered_to_another_target() {
        let mut manager = HidLeaseManager::default();
        manager.register_device(offer(10)).unwrap();
        manager
            .apply_lease(lease(1, HidLeaseState::Offered))
            .unwrap();
        manager
            .apply_lease(lease(2, HidLeaseState::Revoked))
            .unwrap();
        let mut reoffered = lease(3, HidLeaseState::Offered);
        reoffered.route_to = Id128(3);
        manager.apply_lease(reoffered).unwrap();
        let mut active = reoffered;
        active.generation = 4;
        active.state = HidLeaseState::Active;
        manager.apply_lease(active).unwrap();
        assert_eq!(
            manager.active_route(Id128(10)).map(|route| route.route_to),
            Some(Id128(3))
        );
    }

    #[test]
    fn validates_registered_owner_and_interfaces() {
        let mut manager = HidLeaseManager::default();
        let mut invalid = offer(10);
        invalid.interface_count = 0;
        assert_eq!(
            manager.register_device(invalid),
            Err(HidLeaseError::InvalidInterfaceCount)
        );
        manager.register_device(offer(10)).unwrap();
        let mut wrong_owner = lease(1, HidLeaseState::Offered);
        wrong_owner.owner = Id128(9);
        assert_eq!(
            manager.apply_lease(wrong_owner),
            Err(HidLeaseError::OwnerMismatch)
        );
    }

    #[test]
    fn requires_offer_before_activation_and_rejects_loopback() {
        let mut manager = HidLeaseManager::default();
        manager.register_device(offer(10)).unwrap();
        assert_eq!(
            manager.apply_lease(lease(1, HidLeaseState::Active)),
            Err(HidLeaseError::InvalidTransition)
        );
        let mut loopback = lease(1, HidLeaseState::Offered);
        loopback.route_to = loopback.owner;
        assert_eq!(
            manager.apply_lease(loopback),
            Err(HidLeaseError::LoopbackRoute)
        );
    }
}
