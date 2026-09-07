//! Source-side, per-application audio routing boundary.
//!
//! This module deliberately owns *only* an explicitly registered application
//! stream.  It never enumerates a host's default sink, changes a default sink,
//! or treats a process ID as sufficient application identity.  A platform
//! implementation must associate an observed native stream with a Viewflow
//! [`WindowDescriptor`] before calling [`ApplicationAudioRuntime::register_input`].
//!
//! The transport and decoder are intentionally outside this boundary.  The
//! runtime admits timestamped PCM metadata only after verifying the active
//! family generation and a monotonic source clock, then hands the caller the
//! already-selected remote output.  This prevents a delayed source callback
//! from resurrecting a revoked route, but it is not evidence of clock mapping,
//! encoded transport, playback, or A/V synchronization.

use std::collections::BTreeMap;
use std::fmt;

use viewflow_protocol::{AudioRoute, DeviceId, WindowDescriptor, WindowFamilyId};

/// The maximum channel count accepted by the source-side safety boundary.
pub const MAX_APPLICATION_AUDIO_CHANNELS: u8 = 8;
/// The highest sample rate accepted before handing an audio block to transport.
pub const MAX_APPLICATION_AUDIO_SAMPLE_RATE_HZ: u32 = 192_000;
/// A single block larger than this is rejected instead of becoming an
/// unbounded queued capture request.
pub const MAX_APPLICATION_AUDIO_FRAMES_PER_BLOCK: u32 = 96_000;

/// Platform operations needed to isolate one application's audio from the
/// host mix.  Native implementations can use `PipeWire`, `PulseAudio`,
/// `CoreAudio`, or `WASAPI`, but must implement the operations with
/// application-stream scope.
///
/// `create_viewflow_sink` must create a private, non-default sink.  It must
/// not alter the system default device.  `current_sink` is queried before any
/// move so cleanup can restore exactly the observed input rather than an
/// assumed host default.
pub trait ApplicationAudioControl {
    type Error;

    /// # Errors
    ///
    /// Returns the native-control error when the private sink cannot be
    /// created without changing the host default sink.
    fn create_viewflow_sink(&mut self, sink_id: &str) -> Result<(), Self::Error>;
    /// # Errors
    ///
    /// Returns the native-control error when this exact private sink cannot be
    /// retired.
    fn destroy_viewflow_sink(&mut self, sink_id: &str) -> Result<(), Self::Error>;
    /// # Errors
    ///
    /// Returns the native-control error when the selected application input
    /// cannot be resolved to an exact current sink.
    fn current_sink(&mut self, native_input_id: &str) -> Result<String, Self::Error>;
    /// # Errors
    ///
    /// Returns the native-control error when the selected application input
    /// cannot be moved to the supplied route-owned or observed restore sink.
    fn move_input_to_sink(
        &mut self,
        native_input_id: &str,
        sink_id: &str,
    ) -> Result<(), Self::Error>;
}

/// An observed native application stream already authorized for one window
/// family.  The adapter intentionally carries no PID-only matching API: PID
/// reuse and multi-window processes are both ambiguous.
#[derive(Clone, Debug, PartialEq)]
pub struct RegisteredApplicationInput {
    pub native_input_id: String,
    pub window: WindowDescriptor,
}

/// Metadata attached to PCM which remains in a native buffer owned by the
/// caller.  Keeping raw sample ownership outside this module prevents the
/// control plane from accidentally becoming a whole-system recorder.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CapturedApplicationAudioBlock {
    pub family_id: WindowFamilyId,
    pub generation: u64,
    /// Start time on the source's `CLOCK_MONOTONIC` time base.
    pub first_sample_monotonic_ns: u64,
    pub sample_rate_hz: u32,
    pub channels: u8,
    pub frame_count: u32,
}

/// Delivery information returned after a block passes source-side admission.
/// It is deliberately not a claim that the remote clock mapping has been
/// performed or that the block has played.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdmittedApplicationAudioBlock {
    pub block: CapturedApplicationAudioBlock,
    pub target_device: DeviceId,
    pub target_output_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActiveApplicationAudioRoute {
    pub generation: u64,
    pub family_id: WindowFamilyId,
    pub target_device: DeviceId,
    pub target_output_id: String,
    /// Private route-owned capture sink, never a host default output.
    pub capture_sink_id: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ShutdownReport {
    pub routes_released: usize,
    pub retired_sinks_released: usize,
    pub routes_remaining: usize,
    pub retired_sinks_remaining: usize,
}

/// Errors are specific about whether a route was rejected before native state
/// changed, or whether a native control operation itself failed.
#[derive(Debug)]
pub enum ApplicationAudioError<E> {
    Native(E),
    StaleGeneration,
    WrongSourceDevice,
    InvalidTargetOutput,
    EmptyNativeInputId,
    InputAlreadyBound,
    InputAlreadyOnViewflowSink,
    MissingRestoreSink,
    InactiveRoute,
    StaleCaptureGeneration,
    InvalidAudioFormat,
    NonMonotonicCaptureClock,
    ClockOverflow,
    RollbackFailed {
        primary: E,
        rollback: E,
    },
    /// A replacement route is active, but an old private sink could not yet be
    /// destroyed. The runtime retains it for a later explicit shutdown.
    RetirementPending(E),
}

impl<E: fmt::Display> fmt::Display for ApplicationAudioError<E> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Native(error) => write!(
                formatter,
                "native application-audio operation failed: {error}"
            ),
            Self::StaleGeneration => formatter.write_str("audio route generation did not advance"),
            Self::WrongSourceDevice => {
                formatter.write_str("audio route is not owned by this source device")
            }
            Self::InvalidTargetOutput => {
                formatter.write_str("audio route target output is invalid")
            }
            Self::EmptyNativeInputId => formatter.write_str("native application input id is empty"),
            Self::InputAlreadyBound => {
                formatter.write_str("native application input is already bound")
            }
            Self::InputAlreadyOnViewflowSink => formatter.write_str(
                "cannot bind an input already on a Viewflow sink without a restore sink",
            ),
            Self::MissingRestoreSink => {
                formatter.write_str("route-owned input has no recorded restore sink")
            }
            Self::InactiveRoute => formatter.write_str("application audio route is not active"),
            Self::StaleCaptureGeneration => {
                formatter.write_str("captured audio block belongs to an old route generation")
            }
            Self::InvalidAudioFormat => {
                formatter.write_str("captured audio block format is outside the bounded contract")
            }
            Self::NonMonotonicCaptureClock => formatter
                .write_str("captured audio block overlaps a prior source monotonic interval"),
            Self::ClockOverflow => {
                formatter.write_str("captured audio block clock interval overflowed")
            }
            Self::RollbackFailed { primary, rollback } => write!(
                formatter,
                "native application-audio operation failed ({primary}) and rollback failed ({rollback})"
            ),
            Self::RetirementPending(error) => write!(
                formatter,
                "new application-audio route is active but private-sink retirement is pending: {error}"
            ),
        }
    }
}

impl<E: fmt::Debug + fmt::Display> std::error::Error for ApplicationAudioError<E> {}

#[derive(Clone, Debug)]
struct RegisteredInput {
    input: RegisteredApplicationInput,
    /// The non-Viewflow sink observed before the first route-owned move.
    restore_sink_id: Option<String>,
}

/// Runtime state for one local source device.  It is intentionally separate
/// from the coordinator: the coordinator decides *which* route is current;
/// this type applies only source-local, reversible native stream operations.
#[derive(Debug)]
pub struct ApplicationAudioRuntime<C> {
    local_device: DeviceId,
    control: C,
    generations: BTreeMap<WindowFamilyId, u64>,
    active: BTreeMap<WindowFamilyId, ActiveApplicationAudioRoute>,
    /// Sinks from committed replacements whose destruction failed. They are
    /// private and no longer receive bound inputs, but must be retried during
    /// explicit owner shutdown instead of being forgotten.
    retired_sinks: Vec<String>,
    inputs: BTreeMap<String, RegisteredInput>,
    last_capture_end_ns: BTreeMap<WindowFamilyId, u64>,
}

impl<C> ApplicationAudioRuntime<C>
where
    C: ApplicationAudioControl,
{
    #[must_use]
    pub fn new(local_device: DeviceId, control: C) -> Self {
        Self {
            local_device,
            control,
            generations: BTreeMap::new(),
            active: BTreeMap::new(),
            retired_sinks: Vec::new(),
            inputs: BTreeMap::new(),
            last_capture_end_ns: BTreeMap::new(),
        }
    }

    #[must_use]
    pub fn control(&self) -> &C {
        &self.control
    }

    pub fn control_mut(&mut self) -> &mut C {
        &mut self.control
    }

    #[must_use]
    pub fn active_route(&self, family_id: WindowFamilyId) -> Option<&ActiveApplicationAudioRoute> {
        self.active.get(&family_id)
    }

    #[must_use]
    pub fn latest_generation(&self, family_id: WindowFamilyId) -> Option<u64> {
        self.generations.get(&family_id).copied()
    }

    /// Registers one platform-observed stream.  A caller must supply the
    /// window descriptor which made the association; bounds changes do not
    /// alter this family binding.
    ///
    /// # Errors
    ///
    /// Returns an error for an ambiguous input binding or if moving a late
    /// stream to its active family route fails.
    pub fn register_input(
        &mut self,
        input: RegisteredApplicationInput,
    ) -> Result<(), ApplicationAudioError<C::Error>> {
        if input.native_input_id.trim().is_empty() {
            return Err(ApplicationAudioError::EmptyNativeInputId);
        }
        if self.inputs.contains_key(&input.native_input_id) {
            return Err(ApplicationAudioError::InputAlreadyBound);
        }

        let family_id = input.window.family_id;
        let mut registered = RegisteredInput {
            input,
            restore_sink_id: None,
        };
        if let Some(route) = self.active.get(&family_id) {
            let current = self
                .control
                .current_sink(&registered.input.native_input_id)
                .map_err(ApplicationAudioError::Native)?;
            if current == route.capture_sink_id {
                return Err(ApplicationAudioError::InputAlreadyOnViewflowSink);
            }
            self.control
                .move_input_to_sink(&registered.input.native_input_id, &route.capture_sink_id)
                .map_err(ApplicationAudioError::Native)?;
            registered.restore_sink_id = Some(current);
        }
        self.inputs
            .insert(registered.input.native_input_id.clone(), registered);
        Ok(())
    }

    /// Applies an enabled route or a disabled route tombstone.  A route may
    /// affect only this runtime's `local_device`; remote routes must be applied
    /// by their own source runtime.
    ///
    /// # Errors
    ///
    /// Returns an error for a stale/remote route, a native operation failure,
    /// or an unresolved private-sink retirement.
    pub fn apply_route(
        &mut self,
        route: AudioRoute,
    ) -> Result<(), ApplicationAudioError<C::Error>> {
        self.validate_route(&route)?;
        if !route.enabled {
            return self.disable_route(route.family_id, route.generation);
        }

        let capture_sink_id = private_sink_id(route.family_id, route.generation);
        self.control
            .create_viewflow_sink(&capture_sink_id)
            .map_err(ApplicationAudioError::Native)?;

        let old_route = self.active.get(&route.family_id).cloned();
        let moved = match self.move_family_to_sink(route.family_id, &capture_sink_id) {
            Ok(moved) => moved,
            Err(error) => {
                let cleanup = self.control.destroy_viewflow_sink(&capture_sink_id);
                return match cleanup {
                    Ok(()) => Err(error),
                    Err(rollback) => match error {
                        ApplicationAudioError::Native(primary) => {
                            Err(ApplicationAudioError::RollbackFailed { primary, rollback })
                        }
                        other => Err(other),
                    },
                };
            }
        };

        let active = ActiveApplicationAudioRoute {
            generation: route.generation,
            family_id: route.family_id,
            target_device: route.target_device,
            target_output_id: route.target_output_id,
            capture_sink_id,
        };
        self.active.insert(route.family_id, active);
        self.generations.insert(route.family_id, route.generation);
        self.last_capture_end_ns.remove(&route.family_id);

        if let Some(old_route) = old_route {
            if let Err(error) = self
                .control
                .destroy_viewflow_sink(&old_route.capture_sink_id)
            {
                // The replacement is live and owns the moved inputs.  Preserve
                // that state so a later explicit shutdown can retry retirement.
                // The old sink is private and contains no bound inputs now.
                self.retain_retired_sink(old_route.capture_sink_id);
                return Err(ApplicationAudioError::RetirementPending(error));
            }
        }

        debug_assert!(moved.iter().all(|input| self.inputs.contains_key(input)));
        Ok(())
    }

    /// Revokes all active routes, restoring only stream destinations that are
    /// still owned by the matching private sink.  Native shutdown must call
    /// this explicitly; `Drop` intentionally does not attempt fallible audio
    /// operations.
    ///
    /// # Errors
    ///
    /// Returns an error if a route cannot be restored or any retained private
    /// sink cannot be retired.
    pub fn shutdown(&mut self) -> Result<ShutdownReport, ApplicationAudioError<C::Error>> {
        let families = self.active.keys().copied().collect::<Vec<_>>();
        let mut released = 0;
        for family_id in families {
            let Some(route) = self.active.get(&family_id).cloned() else {
                continue;
            };
            // Use the existing generation: shutdown releases native resources
            // but does not fabricate a coordinator route update.
            self.release_active_route(&route)?;
            self.active.remove(&family_id);
            self.last_capture_end_ns.remove(&family_id);
            released += 1;
        }
        let retired_sinks_released = self.release_retired_sinks()?;
        Ok(ShutdownReport {
            routes_released: released,
            retired_sinks_released,
            routes_remaining: self.active.len(),
            retired_sinks_remaining: self.retired_sinks.len(),
        })
    }

    /// Verifies capture scope and source-clock ordering before an external
    /// encoder/transport accesses the caller-owned PCM bytes.
    ///
    /// # Errors
    ///
    /// Returns an error for an inactive/stale route, invalid format, or an
    /// overlapping source-clock interval.
    pub fn admit_capture_block(
        &mut self,
        block: CapturedApplicationAudioBlock,
    ) -> Result<AdmittedApplicationAudioBlock, ApplicationAudioError<C::Error>> {
        validate_block_format(&block)?;
        let Some(route) = self.active.get(&block.family_id) else {
            return Err(ApplicationAudioError::InactiveRoute);
        };
        if route.generation != block.generation {
            return Err(ApplicationAudioError::StaleCaptureGeneration);
        }
        let duration_ns = block_duration_ns(&block)?;
        let end_ns = block
            .first_sample_monotonic_ns
            .checked_add(duration_ns)
            .ok_or(ApplicationAudioError::ClockOverflow)?;
        if self
            .last_capture_end_ns
            .get(&block.family_id)
            .is_some_and(|last_end| block.first_sample_monotonic_ns < *last_end)
        {
            return Err(ApplicationAudioError::NonMonotonicCaptureClock);
        }
        self.last_capture_end_ns.insert(block.family_id, end_ns);
        Ok(AdmittedApplicationAudioBlock {
            block,
            target_device: route.target_device,
            target_output_id: route.target_output_id.clone(),
        })
    }

    fn validate_route(&self, route: &AudioRoute) -> Result<(), ApplicationAudioError<C::Error>> {
        if route.source_device != self.local_device {
            return Err(ApplicationAudioError::WrongSourceDevice);
        }
        if self
            .generations
            .get(&route.family_id)
            .is_some_and(|generation| route.generation <= *generation)
        {
            return Err(ApplicationAudioError::StaleGeneration);
        }
        if route.enabled
            && (route.target_output_id.trim().is_empty()
                || route.target_output_id.chars().any(char::is_control))
        {
            return Err(ApplicationAudioError::InvalidTargetOutput);
        }
        Ok(())
    }

    fn disable_route(
        &mut self,
        family_id: WindowFamilyId,
        generation: u64,
    ) -> Result<(), ApplicationAudioError<C::Error>> {
        if let Some(route) = self.active.get(&family_id).cloned() {
            self.release_active_route(&route)?;
            self.active.remove(&family_id);
            self.last_capture_end_ns.remove(&family_id);
        }
        self.generations.insert(family_id, generation);
        Ok(())
    }

    fn move_family_to_sink(
        &mut self,
        family_id: WindowFamilyId,
        sink_id: &str,
    ) -> Result<Vec<String>, ApplicationAudioError<C::Error>> {
        let ids = self
            .inputs
            .iter()
            .filter_map(|(id, registered)| {
                (registered.input.window.family_id == family_id).then_some(id.clone())
            })
            .collect::<Vec<_>>();
        let mut moved = Vec::<(String, String, Option<String>)>::new();

        for id in ids {
            let current = match self.control.current_sink(&id) {
                Ok(current) => current,
                Err(error) => return self.rollback_moves(&moved, error),
            };
            if current == sink_id {
                continue;
            }
            let previous_restore = self
                .inputs
                .get(&id)
                .and_then(|registered| registered.restore_sink_id.clone());
            if let Err(error) = self.control.move_input_to_sink(&id, sink_id) {
                return self.rollback_moves(&moved, error);
            }
            moved.push((id, current, previous_restore));
        }

        for (id, observed_sink, _) in &moved {
            let observed_is_owned = self.owned_sink(observed_sink);
            let Some(registered) = self.inputs.get_mut(id) else {
                unreachable!("registered input vanished during synchronous routing");
            };
            if !observed_is_owned {
                registered.restore_sink_id = Some(observed_sink.clone());
            }
        }
        Ok(moved.into_iter().map(|(id, _, _)| id).collect())
    }

    fn rollback_moves(
        &mut self,
        moved: &[(String, String, Option<String>)],
        primary: C::Error,
    ) -> Result<Vec<String>, ApplicationAudioError<C::Error>> {
        for (id, observed_sink, _) in moved.iter().rev() {
            if let Err(rollback) = self.control.move_input_to_sink(id, observed_sink) {
                return Err(ApplicationAudioError::RollbackFailed { primary, rollback });
            }
        }
        Err(ApplicationAudioError::Native(primary))
    }

    fn release_active_route(
        &mut self,
        route: &ActiveApplicationAudioRoute,
    ) -> Result<(), ApplicationAudioError<C::Error>> {
        let ids = self
            .inputs
            .iter()
            .filter_map(|(id, registered)| {
                (registered.input.window.family_id == route.family_id).then_some(id.clone())
            })
            .collect::<Vec<_>>();
        // Query every route-owned input before moving any of them. A failed
        // query must leave the route untouched rather than partially restoring
        // its family and making subsequent retry semantics ambiguous.
        let mut restore_plan = Vec::<(String, String)>::new();
        for id in &ids {
            let current = self
                .control
                .current_sink(id)
                .map_err(ApplicationAudioError::Native)?;
            if current != route.capture_sink_id {
                continue;
            }
            let restore = self
                .inputs
                .get(id)
                .and_then(|registered| registered.restore_sink_id.clone())
                .ok_or(ApplicationAudioError::MissingRestoreSink)?;
            restore_plan.push((id.clone(), restore));
        }
        let mut moved = Vec::<(String, String)>::new();

        for (id, restore) in restore_plan {
            if let Err(primary) = self.control.move_input_to_sink(&id, &restore) {
                for (moved_id, _) in moved.iter().rev() {
                    if let Err(rollback) = self
                        .control
                        .move_input_to_sink(moved_id, &route.capture_sink_id)
                    {
                        return Err(ApplicationAudioError::RollbackFailed { primary, rollback });
                    }
                }
                return Err(ApplicationAudioError::Native(primary));
            }
            moved.push((id, restore));
        }

        self.control
            .destroy_viewflow_sink(&route.capture_sink_id)
            .map_err(ApplicationAudioError::Native)?;
        for id in ids {
            if let Some(registered) = self.inputs.get_mut(&id) {
                registered.restore_sink_id = None;
            }
        }
        Ok(())
    }

    fn owned_sink(&self, sink_id: &str) -> bool {
        self.active
            .values()
            .any(|route| route.capture_sink_id == sink_id)
    }

    fn retain_retired_sink(&mut self, sink_id: String) {
        if !self.retired_sinks.iter().any(|known| known == &sink_id) {
            self.retired_sinks.push(sink_id);
        }
    }

    fn release_retired_sinks(&mut self) -> Result<usize, ApplicationAudioError<C::Error>> {
        let retired_sinks = std::mem::take(&mut self.retired_sinks);
        let mut released = 0;
        for (index, sink_id) in retired_sinks.iter().enumerate() {
            if let Err(error) = self.control.destroy_viewflow_sink(sink_id) {
                self.retired_sinks
                    .extend_from_slice(&retired_sinks[index..]);
                return Err(ApplicationAudioError::RetirementPending(error));
            }
            released += 1;
        }
        Ok(released)
    }
}

fn private_sink_id(family_id: WindowFamilyId, generation: u64) -> String {
    format!(
        "viewflow.family.{:032x}.generation.{generation:020}",
        family_id.0
    )
}

fn validate_block_format<E>(
    block: &CapturedApplicationAudioBlock,
) -> Result<(), ApplicationAudioError<E>> {
    if block.first_sample_monotonic_ns == 0
        || block.sample_rate_hz == 0
        || block.sample_rate_hz > MAX_APPLICATION_AUDIO_SAMPLE_RATE_HZ
        || block.channels == 0
        || block.channels > MAX_APPLICATION_AUDIO_CHANNELS
        || block.frame_count == 0
        || block.frame_count > MAX_APPLICATION_AUDIO_FRAMES_PER_BLOCK
    {
        return Err(ApplicationAudioError::InvalidAudioFormat);
    }
    Ok(())
}

fn block_duration_ns<E>(
    block: &CapturedApplicationAudioBlock,
) -> Result<u64, ApplicationAudioError<E>> {
    let numerator = u64::from(block.frame_count)
        .checked_mul(1_000_000_000)
        .ok_or(ApplicationAudioError::ClockOverflow)?;
    // Round up so two adjacent blocks cannot share a fractional-nanosecond
    // region and bypass the monotonic interval check.
    Ok(numerator.div_ceil(u64::from(block.sample_rate_hz)))
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use viewflow_protocol::{Id128, Point, Rect, Size, WindowRole};

    #[derive(Clone, Debug, Eq, PartialEq)]
    enum NativeError {
        MissingInput,
        Forced,
    }

    impl fmt::Display for NativeError {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(formatter, "{self:?}")
        }
    }

    #[derive(Debug, Default)]
    struct FakeAudioControl {
        inputs: BTreeMap<String, String>,
        created: Vec<String>,
        destroyed: Vec<String>,
        fail_move_to: Option<String>,
        fail_current_for: Option<String>,
        fail_destroy_for: Option<String>,
    }

    impl ApplicationAudioControl for FakeAudioControl {
        type Error = NativeError;

        fn create_viewflow_sink(&mut self, sink_id: &str) -> Result<(), Self::Error> {
            self.created.push(sink_id.to_owned());
            Ok(())
        }

        fn destroy_viewflow_sink(&mut self, sink_id: &str) -> Result<(), Self::Error> {
            if self.fail_destroy_for.as_deref() == Some(sink_id) {
                return Err(NativeError::Forced);
            }
            self.destroyed.push(sink_id.to_owned());
            Ok(())
        }

        fn current_sink(&mut self, native_input_id: &str) -> Result<String, Self::Error> {
            if self.fail_current_for.as_deref() == Some(native_input_id) {
                return Err(NativeError::Forced);
            }
            self.inputs
                .get(native_input_id)
                .cloned()
                .ok_or(NativeError::MissingInput)
        }

        fn move_input_to_sink(
            &mut self,
            native_input_id: &str,
            sink_id: &str,
        ) -> Result<(), Self::Error> {
            if self.fail_move_to.as_deref() == Some(sink_id) {
                return Err(NativeError::Forced);
            }
            let Some(current) = self.inputs.get_mut(native_input_id) else {
                return Err(NativeError::MissingInput);
            };
            *current = sink_id.to_owned();
            Ok(())
        }
    }

    fn window(id: u128, family: u128) -> WindowDescriptor {
        WindowDescriptor {
            id: Id128(id),
            family_id: Id128(family),
            source_device: Id128(1),
            role: WindowRole::Main,
            bounds_dip: Rect {
                origin: Point::default(),
                size: Size {
                    width: 400.0,
                    height: 300.0,
                },
            },
            min_size_dip: Size::default(),
            max_size_dip: None,
            has_alpha: false,
            blur_radius_dip: None,
        }
    }

    fn route(family: u128, generation: u64, enabled: bool) -> AudioRoute {
        AudioRoute {
            generation,
            family_id: Id128(family),
            source_device: Id128(1),
            target_device: Id128(2),
            target_output_id: "remote-headphones".to_owned(),
            enabled,
        }
    }

    fn runtime() -> ApplicationAudioRuntime<FakeAudioControl> {
        let mut control = FakeAudioControl::default();
        control
            .inputs
            .insert("input-7".to_owned(), "host-speakers".to_owned());
        control
            .inputs
            .insert("input-8".to_owned(), "host-speakers".to_owned());
        ApplicationAudioRuntime::new(Id128(1), control)
    }

    #[test]
    fn route_moves_only_inputs_explicitly_bound_to_its_window_family() {
        let mut runtime = runtime();
        runtime
            .register_input(RegisteredApplicationInput {
                native_input_id: "input-7".to_owned(),
                window: window(10, 50),
            })
            .unwrap();
        runtime
            .register_input(RegisteredApplicationInput {
                native_input_id: "input-8".to_owned(),
                window: window(11, 51),
            })
            .unwrap();

        runtime.apply_route(route(50, 1, true)).unwrap();
        let sink = runtime
            .active_route(Id128(50))
            .unwrap()
            .capture_sink_id
            .clone();
        assert_eq!(runtime.control().inputs["input-7"], sink);
        assert_eq!(runtime.control().inputs["input-8"], "host-speakers");
        assert!(
            runtime
                .control()
                .created
                .iter()
                .all(|sink| sink.starts_with("viewflow.family."))
        );
    }

    #[test]
    fn late_input_is_moved_to_the_current_family_route_and_restored_on_revoke() {
        let mut runtime = runtime();
        runtime.apply_route(route(50, 1, true)).unwrap();
        runtime
            .register_input(RegisteredApplicationInput {
                native_input_id: "input-7".to_owned(),
                window: window(10, 50),
            })
            .unwrap();
        assert!(runtime.control().inputs["input-7"].starts_with("viewflow.family."));

        runtime.apply_route(route(50, 2, false)).unwrap();
        assert_eq!(runtime.control().inputs["input-7"], "host-speakers");
        assert!(runtime.active_route(Id128(50)).is_none());
        assert_eq!(runtime.latest_generation(Id128(50)), Some(2));
    }

    #[test]
    fn route_update_keeps_original_host_restore_sink_not_the_old_private_sink() {
        let mut runtime = runtime();
        runtime
            .register_input(RegisteredApplicationInput {
                native_input_id: "input-7".to_owned(),
                window: window(10, 50),
            })
            .unwrap();
        runtime.apply_route(route(50, 1, true)).unwrap();
        let old_sink = runtime
            .active_route(Id128(50))
            .unwrap()
            .capture_sink_id
            .clone();
        runtime.apply_route(route(50, 2, true)).unwrap();
        let new_sink = runtime
            .active_route(Id128(50))
            .unwrap()
            .capture_sink_id
            .clone();
        assert_ne!(old_sink, new_sink);
        assert_eq!(runtime.control().inputs["input-7"], new_sink);
        assert!(runtime.control().destroyed.contains(&old_sink));

        runtime.apply_route(route(50, 3, false)).unwrap();
        assert_eq!(runtime.control().inputs["input-7"], "host-speakers");
    }

    #[test]
    fn stale_or_remote_routes_cannot_touch_native_audio() {
        let mut runtime = runtime();
        runtime.apply_route(route(50, 1, true)).unwrap();
        assert!(matches!(
            runtime.apply_route(route(50, 1, true)),
            Err(ApplicationAudioError::StaleGeneration)
        ));
        let mut remote = route(51, 1, true);
        remote.source_device = Id128(99);
        assert!(matches!(
            runtime.apply_route(remote),
            Err(ApplicationAudioError::WrongSourceDevice)
        ));
        assert_eq!(runtime.control().created.len(), 1);
    }

    #[test]
    fn source_clock_requires_non_overlapping_current_generation_blocks() {
        let mut runtime = runtime();
        runtime.apply_route(route(50, 1, true)).unwrap();
        let first = CapturedApplicationAudioBlock {
            family_id: Id128(50),
            generation: 1,
            first_sample_monotonic_ns: 1_000_000,
            sample_rate_hz: 48_000,
            channels: 2,
            frame_count: 480,
        };
        let admitted = runtime.admit_capture_block(first).unwrap();
        assert_eq!(admitted.target_device, Id128(2));
        assert_eq!(admitted.target_output_id, "remote-headphones");
        let overlap = CapturedApplicationAudioBlock {
            first_sample_monotonic_ns: 5_000_000,
            ..first
        };
        assert!(matches!(
            runtime.admit_capture_block(overlap),
            Err(ApplicationAudioError::NonMonotonicCaptureClock)
        ));
        let stale = CapturedApplicationAudioBlock {
            generation: 0,
            first_sample_monotonic_ns: 20_000_000,
            ..first
        };
        assert!(matches!(
            runtime.admit_capture_block(stale),
            Err(ApplicationAudioError::StaleCaptureGeneration)
        ));
    }

    #[test]
    fn shutdown_restores_active_inputs_and_destroys_private_sinks() {
        let mut runtime = runtime();
        runtime
            .register_input(RegisteredApplicationInput {
                native_input_id: "input-7".to_owned(),
                window: window(10, 50),
            })
            .unwrap();
        runtime.apply_route(route(50, 1, true)).unwrap();
        let report = runtime.shutdown().unwrap();
        assert_eq!(report.routes_released, 1);
        assert_eq!(report.routes_remaining, 0);
        assert_eq!(runtime.control().inputs["input-7"], "host-speakers");
        assert_eq!(runtime.control().destroyed.len(), 1);
    }

    #[test]
    fn failed_retirement_is_retained_and_retried_by_shutdown() {
        let mut runtime = runtime();
        runtime
            .register_input(RegisteredApplicationInput {
                native_input_id: "input-7".to_owned(),
                window: window(10, 50),
            })
            .unwrap();
        runtime.apply_route(route(50, 1, true)).unwrap();
        let old_sink = runtime
            .active_route(Id128(50))
            .unwrap()
            .capture_sink_id
            .clone();
        runtime.control_mut().fail_destroy_for = Some(old_sink.clone());
        assert!(matches!(
            runtime.apply_route(route(50, 2, true)),
            Err(ApplicationAudioError::RetirementPending(
                NativeError::Forced
            ))
        ));
        assert_eq!(runtime.active_route(Id128(50)).unwrap().generation, 2);
        assert!(!runtime.control().destroyed.contains(&old_sink));

        runtime.control_mut().fail_destroy_for = None;
        let report = runtime.shutdown().unwrap();
        assert_eq!(report.routes_released, 1);
        assert_eq!(report.retired_sinks_released, 1);
        assert_eq!(report.retired_sinks_remaining, 0);
        assert!(runtime.control().destroyed.contains(&old_sink));
    }

    #[test]
    fn failed_preflight_does_not_partially_restore_a_family() {
        let mut runtime = runtime();
        for input_id in ["input-7", "input-8"] {
            runtime
                .register_input(RegisteredApplicationInput {
                    native_input_id: input_id.to_owned(),
                    window: window(if input_id == "input-7" { 10 } else { 11 }, 50),
                })
                .unwrap();
        }
        runtime.apply_route(route(50, 1, true)).unwrap();
        let sink = runtime
            .active_route(Id128(50))
            .unwrap()
            .capture_sink_id
            .clone();
        runtime.control_mut().fail_current_for = Some("input-8".to_owned());
        assert!(matches!(
            runtime.apply_route(route(50, 2, false)),
            Err(ApplicationAudioError::Native(NativeError::Forced))
        ));
        assert_eq!(runtime.control().inputs["input-7"], sink);
        assert_eq!(runtime.control().inputs["input-8"], sink);
        assert_eq!(runtime.active_route(Id128(50)).unwrap().generation, 1);
    }
}
