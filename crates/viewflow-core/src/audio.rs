//! Per-window-family application audio routing.

use std::collections::HashMap;

use viewflow_protocol::{AudioRoute, DeviceId, WindowDescriptor, WindowFamilyId};

/// User-selected playback policy. Device identifiers refer to paired machines,
/// not sound cards. The selected machine uses its current normal output.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum AudioPlaybackMode {
    #[default]
    NoForwarding,
    FollowWindow,
    DesignatedDevice(DeviceId),
}

/// A resolved route never forwards a received stream again. System capture
/// adapters must exclude Viewflow playback to prevent feedback between peers.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AudioCaptureScope {
    Application(WindowFamilyId),
    System,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AudioForwardingDecision {
    pub source: DeviceId,
    pub target: DeviceId,
    pub scope: AudioCaptureScope,
}

impl AudioPlaybackMode {
    /// Resolve application audio using the application's owner and the current
    /// committed window location. Hover and keyboard focus do not affect audio.
    #[must_use]
    pub fn for_window(
        self,
        source: DeviceId,
        location: DeviceId,
        family: WindowFamilyId,
    ) -> Option<AudioForwardingDecision> {
        match self {
            Self::NoForwarding => None,
            Self::FollowWindow if source != location => Some(AudioForwardingDecision {
                source,
                target: location,
                scope: AudioCaptureScope::Application(family),
            }),
            // System mode produces one stream per source, never one duplicate
            // system capture for each exported window.
            Self::FollowWindow | Self::DesignatedDevice(_) => None,
        }
    }

    /// Includes system sounds and applications without shared windows. The
    /// destination's own audio keeps playing locally and is never looped back.
    #[must_use]
    pub fn for_system(self, source: DeviceId) -> Option<AudioForwardingDecision> {
        match self {
            Self::DesignatedDevice(target) if source != target => Some(AudioForwardingDecision {
                source,
                target,
                scope: AudioCaptureScope::System,
            }),
            _ => None,
        }
    }
}

/// Application identity must be stable for a process lifetime (PID alone is
/// reusable). Main-window moves choose one output for the entire application.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct AudioApplicationId {
    pub source: DeviceId,
    pub instance: u128,
}

#[derive(Debug, Default)]
pub struct ApplicationAudioLocations {
    locations: HashMap<AudioApplicationId, HashMap<WindowFamilyId, (u64, DeviceId)>>,
}
impl ApplicationAudioLocations {
    /// Called for committed main-window moves, including moves back home.
    /// The move order is source-wide and must increase for each real move;
    /// replicated or delayed inventory must not override a more recent move.
    pub fn main_window_moved(
        &mut self,
        app: AudioApplicationId,
        family: WindowFamilyId,
        location: DeviceId,
        move_order: u64,
    ) {
        let windows = self.locations.entry(app).or_default();
        if windows
            .get(&family)
            .is_some_and(|(order, _)| *order >= move_order)
        {
            return;
        }
        windows.insert(family, (move_order, location));
    }

    pub fn main_window_closed(&mut self, app: AudioApplicationId, family: WindowFamilyId) {
        if let Some(windows) = self.locations.get_mut(&app) {
            windows.remove(&family);
            if windows.is_empty() {
                self.locations.remove(&app);
            }
        }
    }

    pub fn application_stopped(&mut self, app: AudioApplicationId) {
        self.locations.remove(&app);
    }

    #[must_use]
    pub fn destination(&self, app: AudioApplicationId, mode: AudioPlaybackMode) -> DeviceId {
        match mode {
            AudioPlaybackMode::NoForwarding => app.source,
            AudioPlaybackMode::DesignatedDevice(target) => target,
            AudioPlaybackMode::FollowWindow => self
                .locations
                .get(&app)
                .and_then(|windows| windows.values().max_by_key(|(order, _)| *order))
                .map_or(app.source, |(_, device)| *device),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AudioRouteError {
    StaleGeneration,
    EmptyOutputId,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VersionedAudioRoute {
    pub generation: u64,
    pub route: AudioRoute,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ClearedAudioRoute {
    pub generation: u64,
    pub family_id: WindowFamilyId,
}

#[derive(Debug, Default)]
pub struct AudioRouter {
    routes: HashMap<WindowFamilyId, VersionedAudioRoute>,
    generations: HashMap<WindowFamilyId, u64>,
}

impl AudioRouter {
    /// Sets or atomically replaces the destination for a complete window family.
    ///
    /// # Errors
    ///
    /// Rejects an empty platform output identifier or a generation that does
    /// not strictly advance this family's route state.
    pub fn apply_route(&mut self, route: AudioRoute) -> Result<(), AudioRouteError> {
        self.validate_generation(route.family_id, route.generation)?;
        if route.enabled
            && (route.target_output_id.trim().is_empty()
                || route.target_output_id.chars().any(char::is_control))
        {
            return Err(AudioRouteError::EmptyOutputId);
        }
        self.generations.insert(route.family_id, route.generation);
        if route.enabled {
            self.routes.insert(
                route.family_id,
                VersionedAudioRoute {
                    generation: route.generation,
                    route,
                },
            );
        } else {
            self.routes.remove(&route.family_id);
        }
        Ok(())
    }

    /// Removes a family's explicit route while preserving its generation
    /// tombstone, so a delayed set message cannot resurrect the old route.
    ///
    /// # Errors
    ///
    /// Rejects a generation that does not strictly advance this family.
    pub fn clear_route(
        &mut self,
        generation: u64,
        family_id: WindowFamilyId,
    ) -> Result<ClearedAudioRoute, AudioRouteError> {
        self.validate_generation(family_id, generation)?;
        self.generations.insert(family_id, generation);
        self.routes.remove(&family_id);
        Ok(ClearedAudioRoute {
            generation,
            family_id,
        })
    }

    #[must_use]
    pub fn route_for_family(&self, family_id: WindowFamilyId) -> Option<&VersionedAudioRoute> {
        self.routes.get(&family_id)
    }

    #[must_use]
    pub fn route_for_window(&self, window: &WindowDescriptor) -> Option<&VersionedAudioRoute> {
        self.route_for_family(window.family_id)
    }

    #[must_use]
    pub fn target_for_family(&self, family_id: WindowFamilyId) -> Option<(DeviceId, &str)> {
        self.route_for_family(family_id).map(|versioned| {
            (
                versioned.route.target_device,
                versioned.route.target_output_id.as_str(),
            )
        })
    }

    #[must_use]
    pub fn latest_generation(&self, family_id: WindowFamilyId) -> Option<u64> {
        self.generations.get(&family_id).copied()
    }

    fn validate_generation(
        &self,
        family_id: WindowFamilyId,
        generation: u64,
    ) -> Result<(), AudioRouteError> {
        if self
            .generations
            .get(&family_id)
            .is_some_and(|current| generation <= *current)
        {
            return Err(AudioRouteError::StaleGeneration);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::{Id128, Point, Rect, Size, WindowRole};

    #[test]
    fn playback_modes_distinguish_owner_location_and_system() {
        let owner = Id128(1);
        let location = Id128(2);
        let selected = Id128(3);
        let family = Id128(10);
        assert_eq!(
            AudioPlaybackMode::NoForwarding.for_window(owner, location, family),
            None
        );
        assert_eq!(AudioPlaybackMode::NoForwarding.for_system(owner), None);
        assert_eq!(
            AudioPlaybackMode::FollowWindow.for_window(owner, owner, family),
            None
        );
        assert_eq!(
            AudioPlaybackMode::FollowWindow.for_window(owner, location, family),
            Some(AudioForwardingDecision {
                source: owner,
                target: location,
                scope: AudioCaptureScope::Application(family)
            })
        );
        assert_eq!(AudioPlaybackMode::FollowWindow.for_system(owner), None);
        let mode = AudioPlaybackMode::DesignatedDevice(selected);
        assert_eq!(mode.for_window(owner, location, family), None);
        assert_eq!(
            mode.for_system(owner),
            Some(AudioForwardingDecision {
                source: owner,
                target: selected,
                scope: AudioCaptureScope::System
            })
        );
        assert_eq!(mode.for_system(selected), None);
    }

    #[test]
    fn application_follows_last_moved_main_window_including_return_home() {
        let app = AudioApplicationId {
            source: Id128(1),
            instance: 123,
        };
        let mut locations = ApplicationAudioLocations::default();
        let mode = AudioPlaybackMode::FollowWindow;
        locations.main_window_moved(app, Id128(10), Id128(2), 1);
        locations.main_window_moved(app, Id128(11), Id128(3), 2);
        assert_eq!(locations.destination(app, mode), Id128(3));
        locations.main_window_moved(app, Id128(10), Id128(1), 3);
        assert_eq!(locations.destination(app, mode), Id128(1));
        locations.main_window_moved(app, Id128(10), Id128(2), 1);
        assert_eq!(locations.destination(app, mode), Id128(1));
        locations.main_window_closed(app, Id128(10));
        assert_eq!(locations.destination(app, mode), Id128(3));
        assert_eq!(
            locations.destination(app, AudioPlaybackMode::NoForwarding),
            Id128(1)
        );
        assert_eq!(
            locations.destination(app, AudioPlaybackMode::DesignatedDevice(Id128(4))),
            Id128(4)
        );
        locations.application_stopped(app);
        assert_eq!(locations.destination(app, mode), Id128(1));
        assert_eq!(
            locations.destination(
                AudioApplicationId {
                    instance: 124,
                    ..app
                },
                mode
            ),
            Id128(1)
        );
    }

    fn route(family: u128, device: u128, output: &str) -> AudioRoute {
        AudioRoute {
            generation: 1,
            family_id: Id128(family),
            source_device: Id128(1),
            target_device: Id128(device),
            target_output_id: output.to_owned(),
            enabled: true,
        }
    }

    fn window(family: u128) -> WindowDescriptor {
        WindowDescriptor {
            id: Id128(100),
            family_id: Id128(family),
            source_device: Id128(1),
            role: WindowRole::Dialog,
            bounds_dip: Rect {
                origin: Point::default(),
                size: Size {
                    width: 320.0,
                    height: 240.0,
                },
            },
            min_size_dip: Size::default(),
            max_size_dip: None,
            has_alpha: false,
            blur_radius_dip: None,
        }
    }

    #[test]
    fn every_window_in_family_uses_same_route() {
        let mut router = AudioRouter::default();
        router.apply_route(route(10, 20, "speakers/main")).unwrap();
        let main = window(10);
        let mut dialog = window(10);
        dialog.id = Id128(101);

        assert_eq!(
            router.route_for_window(&main),
            router.route_for_window(&dialog)
        );
        assert_eq!(
            router.target_for_family(Id128(10)),
            Some((Id128(20), "speakers/main"))
        );
    }

    #[test]
    fn families_advance_generations_independently() {
        let mut router = AudioRouter::default();
        let mut family_ten = route(10, 20, "a");
        family_ten.generation = 5;
        router.apply_route(family_ten).unwrap();
        router.apply_route(route(11, 21, "b")).unwrap();
        let mut stale = route(10, 22, "c");
        stale.generation = 5;
        assert_eq!(
            router.apply_route(stale),
            Err(AudioRouteError::StaleGeneration)
        );
        let mut newer = route(11, 23, "d");
        newer.generation = 2;
        router.apply_route(newer).unwrap();
    }

    #[test]
    fn clear_leaves_tombstone_against_delayed_updates() {
        let mut router = AudioRouter::default();
        router.apply_route(route(10, 20, "a")).unwrap();
        router.clear_route(3, Id128(10)).unwrap();
        assert_eq!(router.route_for_family(Id128(10)), None);
        assert_eq!(router.latest_generation(Id128(10)), Some(3));
        assert_eq!(
            router.apply_route({
                let mut delayed = route(10, 21, "b");
                delayed.generation = 2;
                delayed
            }),
            Err(AudioRouteError::StaleGeneration)
        );
    }

    #[test]
    fn invalid_output_does_not_consume_generation() {
        let mut router = AudioRouter::default();
        assert_eq!(
            router.apply_route(route(10, 20, "  ")),
            Err(AudioRouteError::EmptyOutputId)
        );
        router.apply_route(route(10, 20, "valid")).unwrap();
    }

    #[test]
    fn disabled_protocol_route_clears_family() {
        let mut router = AudioRouter::default();
        router.apply_route(route(10, 20, "a")).unwrap();
        let mut disabled = route(10, 20, "");
        disabled.generation = 2;
        disabled.enabled = false;
        router.apply_route(disabled).unwrap();
        assert_eq!(router.route_for_family(Id128(10)), None);
        assert_eq!(router.latest_generation(Id128(10)), Some(2));
    }
}
