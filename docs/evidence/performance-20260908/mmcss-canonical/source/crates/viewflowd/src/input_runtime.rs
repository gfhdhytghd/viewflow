use std::{collections::BTreeSet, error::Error, fmt, fs, path::Path, str::FromStr};

use anyhow::{Context, Result, anyhow, bail};
use viewflow_protocol::{
    Id128, InputAppliedResult, InputEvent, InputEventKind, InputLease, InputLeaseRevoke,
    InputLeaseRevokedAck, InputLeaseRevokedResult, InputLeaseState, InputSwitchState,
    PointerButton, wire,
};
use viewflow_transport::ClockEstimate;

pub(crate) const MAX_CLOCK_UNCERTAINTY_NS: u64 = 4_000_000;
pub(crate) const MAX_CLOCK_SAMPLE_AGE_NS: u64 = 3_000_000_000;
// Ordered input may span focus activation or a scheduler stall. This bounds an
// operation, not the frame performance target. Motion keeps its shorter expiry.
pub(crate) const INPUT_OPERATION_TIMEOUT_NS: u64 = 5_000_000_000;
const MAX_INPUT_FUTURE_HORIZON_NS: u64 = INPUT_OPERATION_TIMEOUT_NS;
pub(crate) const CLOCK_DRIFT_PPM: u64 = 500;
// Sender headroom for the receiver's existing clock-quality bounds. This
// shortens the wire expiry; it never changes the receiver's hard horizon.
pub(crate) const INPUT_CLOCK_MAPPING_HEADROOM_NS: u64 =
    MAX_CLOCK_UNCERTAINTY_NS + (MAX_CLOCK_SAMPLE_AGE_NS * CLOCK_DRIFT_PPM).div_ceil(1_000_000);

/// Safe diagnostic labels deliberately omit HID usages and button/key states.
pub(crate) fn input_event_diagnostic(event: &InputEvent) -> String {
    let (kind, position) = match event.event {
        InputEventKind::DesktopPointerPosition(point) => ("desktop-position", Some(point)),
        InputEventKind::PointerMotion(_) => ("relative-motion", None),
        InputEventKind::PointerButton(_) => ("button", None),
        InputEventKind::PointerWheel(_) => ("wheel", None),
        InputEventKind::KeyboardHidUsage(_) => ("keyboard", None),
        InputEventKind::ReleaseAll => ("release-all", None),
        InputEventKind::Touchpad(_) => ("touchpad", None),
    };
    let mut result = format!(
        "kind={kind} generation={} sequence={}",
        event.lease_generation, event.sequence
    );
    if let Some(point) = position {
        use std::fmt::Write;
        let _ = write!(
            result,
            " x_millidip={} y_millidip={}",
            point.x_millidip, point.y_millidip
        );
    }
    result
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ClockSnapshot {
    pub(crate) estimate: ClockEstimate,
    pub(crate) measured_at_local_ns: u64,
}

#[cfg(windows)]
use viewflow_platform::windows_input::WindowsInputBackend;
#[cfg(any(windows, test))]
use viewflow_platform::windows_input::WindowsInputError;
#[cfg(target_os = "macos")]
use viewflow_platform::macos_input::{MacOsInputBackend, MacOsInputError};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum InputBackendMode {
    #[default]
    Disabled,
    Native,
}

impl FromStr for InputBackendMode {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "disabled" => Ok(Self::Disabled),
            "native" => Ok(Self::Native),
            _ => bail!("invalid --input-backend {value:?}: expected disabled or native"),
        }
    }
}

pub(crate) fn ensure_backend_available(mode: InputBackendMode) -> Result<()> {
    if mode == InputBackendMode::Native && !cfg!(any(windows, target_os = "macos")) {
        bail!("native input injection is only available on Windows and macOS");
    }
    Ok(())
}

#[derive(Debug)]
enum InputBackend {
    Disabled,
    #[cfg(windows)]
    Native(WindowsInputBackend),
    #[cfg(target_os = "macos")]
    MacOs(MacOsInputBackend),
}

impl InputBackend {
    fn new(mode: InputBackendMode) -> Result<Self> {
        match mode {
            InputBackendMode::Disabled => Ok(Self::Disabled),
            #[cfg(windows)]
            InputBackendMode::Native => Ok(Self::Native(WindowsInputBackend::new())),
            #[cfg(target_os = "macos")]
            InputBackendMode::Native => Ok(Self::MacOs(MacOsInputBackend::new())),
            #[cfg(not(any(windows, target_os = "macos")))]
            InputBackendMode::Native => {
                bail!("native input injection is only available on Windows and macOS")
            }
        }
    }

    #[allow(clippy::unnecessary_wraps)]
    fn apply(&mut self, event: &InputEvent) -> std::result::Result<(), InputApplyError> {
        #[cfg(not(any(windows, target_os = "macos")))]
        let _ = event;
        match self {
            Self::Disabled => Ok(()),
            #[cfg(target_os = "macos")]
            Self::MacOs(backend) => backend.apply(event).map_err(|error| {
                eprintln!("macos-input-rejected {} reason={error}", input_event_diagnostic(event));
                match error {
                    MacOsInputError::UnsupportedHidUsage | MacOsInputError::UnsupportedInput => InputApplyError::UnsupportedInput,
                    MacOsInputError::InvalidCoordinate => InputApplyError::InvalidInput,
                    MacOsInputError::PermissionDenied | MacOsInputError::EventCreationFailed => InputApplyError::InjectionFailed,
                }
            }),
            #[cfg(windows)]
            Self::Native(backend) => backend.apply(event).map_err(|error| {
                let reason = match error {
                    WindowsInputError::UnsupportedHidUsage { .. } => "unsupported-hid",
                    WindowsInputError::NonFiniteDelta => "nonfinite-delta",
                    WindowsInputError::DeltaOutOfRange => "coordinate-or-delta-range",
                    WindowsInputError::SendInputFailed => "send-input-failed",
                };
                eprintln!(
                    "atlas-input-rejected stage=native {} reason={reason}",
                    input_event_diagnostic(event)
                );
                InputApplyError::from(error)
            }),
        }
    }

    #[allow(clippy::unnecessary_wraps)]
    fn release_all(&mut self) -> Result<()> {
        match self {
            Self::Disabled => Ok(()),
            #[cfg(target_os = "macos")]
            Self::MacOs(backend) => backend.release_all().map_err(anyhow::Error::from),
            #[cfg(windows)]
            Self::Native(backend) => backend
                .release_all()
                .map_err(|error| anyhow!("Windows input release failed: {error:?}")),
        }
    }
}

#[cfg_attr(not(any(windows, test)), allow(dead_code))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum InputApplyError {
    NoLease,
    LeaseNotActive,
    LeaseGeneration,
    TargetDevice,
    EventSequence,
    UnsupportedInput,
    InvalidInput,
    InjectionFailed,
    Expired,
    ClockUnsynchronized,
}

impl InputApplyError {
    pub(crate) const fn result(self) -> InputAppliedResult {
        match self {
            Self::NoLease => InputAppliedResult::RejectedNoLease,
            Self::LeaseNotActive => InputAppliedResult::RejectedLeaseNotActive,
            Self::LeaseGeneration => InputAppliedResult::RejectedLeaseGeneration,
            Self::TargetDevice => InputAppliedResult::RejectedTargetDevice,
            Self::EventSequence => InputAppliedResult::RejectedEventSequence,
            Self::UnsupportedInput => InputAppliedResult::RejectedUnsupportedInput,
            Self::InvalidInput => InputAppliedResult::RejectedInvalidInput,
            Self::InjectionFailed => InputAppliedResult::InjectionFailed,
            Self::Expired => InputAppliedResult::RejectedExpired,
            Self::ClockUnsynchronized => InputAppliedResult::RejectedClockUnsynchronized,
        }
    }
}

impl fmt::Display for InputApplyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:?}", self.result())
    }
}

impl Error for InputApplyError {}

#[cfg(any(windows, test))]
impl From<WindowsInputError> for InputApplyError {
    fn from(error: WindowsInputError) -> Self {
        match error {
            WindowsInputError::UnsupportedHidUsage { .. } => Self::UnsupportedInput,
            WindowsInputError::NonFiniteDelta | WindowsInputError::DeltaOutOfRange => {
                Self::InvalidInput
            }
            WindowsInputError::SendInputFailed => Self::InjectionFailed,
        }
    }
}

/// Connection-local gate for generation, target, and event sequence validation.
#[derive(Debug)]
pub(crate) struct InputReceiver {
    backend: InputBackend,
    local_device: Option<Id128>,
    lease: Option<InputLease>,
    previous_event_sequence: Option<u64>,
    #[cfg(test)]
    applied_event_count: usize,
}

impl InputReceiver {
    pub(crate) fn new(mode: InputBackendMode, local_device: Option<Id128>) -> Result<Self> {
        if mode == InputBackendMode::Native && local_device.is_none() {
            bail!("native input injection requires a local device id");
        }
        Ok(Self {
            backend: InputBackend::new(mode)?,
            local_device,
            lease: None,
            previous_event_sequence: None,
            #[cfg(test)]
            applied_event_count: 0,
        })
    }

    #[cfg(windows)]
    pub(crate) fn with_desktop_display(
        mut self,
        display: viewflow_platform::windows_input::DesktopPointerDisplay,
    ) -> Self {
        if let InputBackend::Native(backend) = &mut self.backend {
            backend.set_desktop_display(display);
        }
        self
    }

    pub(crate) fn apply_lease(&mut self, lease: InputLease) -> Result<()> {
        if lease.generation == 0 {
            bail!("input lease generation zero is reserved");
        }
        if lease.owner == lease.route_to {
            bail!("input lease cannot route back to its owner");
        }
        if self
            .local_device
            .is_some_and(|local_device| lease.route_to != local_device)
        {
            bail!("input lease route does not match the local device");
        }
        if let Some(current) = self.lease {
            if lease.generation <= current.generation {
                bail!(
                    "input lease generation {} is not newer than {}",
                    lease.generation,
                    current.generation
                );
            }
            if current.state != InputLeaseState::Revoked
                && (lease.owner != current.owner || lease.route_to != current.route_to)
            {
                bail!("input lease identity changed before revocation");
            }
            let transition_is_valid = matches!(
                (current.state, lease.state),
                (
                    InputLeaseState::Offered,
                    InputLeaseState::Active | InputLeaseState::Revoked
                ) | (InputLeaseState::Active, InputLeaseState::Revoked)
                    | (InputLeaseState::Revoked, InputLeaseState::Offered)
            );
            if !transition_is_valid {
                bail!("invalid input lease state transition");
            }
        } else if lease.state != InputLeaseState::Offered {
            bail!("the first input lease state must be offered");
        }

        if self
            .lease
            .is_some_and(|current| current.state == InputLeaseState::Active)
        {
            self.backend.release_all()?;
        }
        self.previous_event_sequence = None;
        self.lease = Some(lease);
        Ok(())
    }

    pub(crate) fn apply_lease_revoke(
        &mut self,
        revoke: InputLeaseRevoke,
    ) -> Result<InputLeaseRevokedAck> {
        let current = self
            .lease
            .ok_or_else(|| anyhow!("cannot revoke a missing input lease"))?;
        if current.state != InputLeaseState::Active {
            bail!("only an active input lease can be revoked");
        }
        if revoke.owner_device != current.owner || revoke.target_device != current.route_to {
            bail!("input lease revoke identity does not match the active lease");
        }
        if revoke.state != InputLeaseState::Revoked {
            bail!("input lease revoke must request the revoked state");
        }
        let expected_generation = current
            .generation
            .checked_add(1)
            .ok_or_else(|| anyhow!("input lease generation exhausted"))?;
        if revoke.lease_generation != expected_generation {
            bail!(
                "input lease revoke generation {} does not immediately follow active generation {}",
                revoke.lease_generation,
                current.generation
            );
        }

        // Do not publish the revoked state until the native backend confirms
        // that all held input has actually been released.
        self.backend.release_all()?;
        self.previous_event_sequence = None;
        self.lease = Some(revoke.lease());

        Ok(InputLeaseRevokedAck {
            operation_id: revoke.operation_id,
            lease_generation: revoke.lease_generation,
            owner_device: revoke.owner_device,
            target_device: revoke.target_device,
            state: revoke.state,
            result: InputLeaseRevokedResult::Applied,
        })
    }

    pub(crate) fn apply_event(
        &mut self,
        event: &InputEvent,
        clock: Option<ClockSnapshot>,
        local_now_ns: u64,
    ) -> std::result::Result<(), InputApplyError> {
        self.apply_event_inner(event, Some((clock, local_now_ns)))
    }

    /// Atlas desktop input already uses a live, ordered transport and lease.
    /// Preserve button/key transitions through congestion without a time cutoff.
    pub(crate) fn apply_ordered_event(
        &mut self,
        event: &InputEvent,
    ) -> std::result::Result<(), InputApplyError> {
        self.apply_event_inner(event, None)
    }

    fn apply_event_inner(
        &mut self,
        event: &InputEvent,
        freshness: Option<(Option<ClockSnapshot>, u64)>,
    ) -> std::result::Result<(), InputApplyError> {
        let lease = self.lease.ok_or(InputApplyError::NoLease)?;
        if lease.state != InputLeaseState::Active {
            return Err(InputApplyError::LeaseNotActive);
        }
        if event.lease_generation != lease.generation {
            return Err(InputApplyError::LeaseGeneration);
        }
        if event.target_device != lease.route_to {
            return Err(InputApplyError::TargetDevice);
        }
        if event.sequence == 0
            || self
                .previous_event_sequence
                .is_some_and(|previous| event.sequence <= previous)
        {
            return Err(InputApplyError::EventSequence);
        }

        if let Some((clock, local_now_ns)) = freshness {
        if let Err(error) = validate_event_freshness(event, clock, local_now_ns) {
            let mapped_horizon_ns = clock.map(|snapshot| {
                i128::from(
                    snapshot
                        .estimate
                        .remote_to_local_ns(event.sender_not_after_ns),
                ) - i128::from(local_now_ns)
            });
            let uncertainty_ns = clock.map(|snapshot| snapshot.estimate.uncertainty_ns);
            let sample_age_ns =
                clock.map(|snapshot| local_now_ns.saturating_sub(snapshot.measured_at_local_ns));
            eprintln!(
                "atlas-input-rejected stage=freshness {} result={error:?} mapped_horizon_ns={mapped_horizon_ns:?} uncertainty_ns={uncertainty_ns:?} sample_age_ns={sample_age_ns:?}",
                input_event_diagnostic(event)
            );
            // A time-invalid identity is terminal. Consuming it prevents the
            // same stale event from becoming injectable after a later probe.
            self.previous_event_sequence = Some(event.sequence);
            return Err(error);
        }
        }
        self.backend.apply(event)?;
        self.previous_event_sequence = Some(event.sequence);
        #[cfg(test)]
        {
            self.applied_event_count += 1;
        }
        Ok(())
    }

    pub(crate) fn release_all(&mut self) -> Result<()> {
        self.backend.release_all()
    }
}

fn validate_event_freshness(
    event: &InputEvent,
    clock: Option<ClockSnapshot>,
    local_now_ns: u64,
) -> std::result::Result<(), InputApplyError> {
    if matches!(event.event, InputEventKind::ReleaseAll) && event.sender_not_after_ns == 0 {
        return Ok(());
    }
    conservative_input_deadline(event.sender_not_after_ns, clock, local_now_ns).map(|_| ())
}

#[cfg(all(test, target_os = "macos"))]
#[test]
fn macos_native_receiver_initializes_without_posting_input() {
    ensure_backend_available(InputBackendMode::Native).unwrap();
    let mut receiver = InputReceiver::new(InputBackendMode::Native, Some(Id128(2))).unwrap();
    assert!(matches!(receiver.backend, InputBackend::MacOs(_)));
    // No held inputs: cleanup must be a no-op even without OS authorization.
    receiver.release_all().unwrap();
}

/// Shared by device input and window-scoped input. The returned timestamp is
/// on the local monotonic clock with uncertainty/drift already subtracted.
/// Safety `ReleaseAll` bypass is deliberately kept in the device wrapper above;
/// a window pointer event can never acquire that exception.
pub(crate) fn conservative_input_deadline(
    sender_not_after_ns: u64,
    clock: Option<ClockSnapshot>,
    local_now_ns: u64,
) -> std::result::Result<u64, InputApplyError> {
    conservative_remote_deadline(
        sender_not_after_ns,
        clock,
        local_now_ns,
        Some(MAX_INPUT_FUTURE_HORIZON_NS),
    )
}

/// Window-manager operations can span several frames. Their watchdog is
/// distinct from a pointer sample's freshness target.
pub(crate) fn conservative_operation_deadline(
    sender_not_after_ns: u64,
    clock: Option<ClockSnapshot>,
    local_now_ns: u64,
) -> std::result::Result<u64, InputApplyError> {
    conservative_remote_deadline(sender_not_after_ns, clock, local_now_ns,
        Some(INPUT_OPERATION_TIMEOUT_NS + MAX_CLOCK_UNCERTAINTY_NS))
}

/// A lease expiry is not an event budget. It uses the same clock quality and
/// drift checks but can legitimately be more than one frame in the future.
pub(crate) fn conservative_authorization_deadline(
    remote_not_after_ns: u64,
    clock: Option<ClockSnapshot>,
    local_now_ns: u64,
) -> std::result::Result<u64, InputApplyError> {
    conservative_remote_deadline(remote_not_after_ns, clock, local_now_ns, None)
}

fn conservative_remote_deadline(
    sender_not_after_ns: u64,
    clock: Option<ClockSnapshot>,
    local_now_ns: u64,
    future_horizon_ns: Option<u64>,
) -> std::result::Result<u64, InputApplyError> {
    if sender_not_after_ns == 0 {
        return Err(InputApplyError::InvalidInput);
    }

    let snapshot = clock.ok_or(InputApplyError::ClockUnsynchronized)?;
    if snapshot.estimate.uncertainty_ns > MAX_CLOCK_UNCERTAINTY_NS
        || local_now_ns < snapshot.measured_at_local_ns
    {
        return Err(InputApplyError::ClockUnsynchronized);
    }
    let sample_age_ns = local_now_ns - snapshot.measured_at_local_ns;
    if sample_age_ns > MAX_CLOCK_SAMPLE_AGE_NS {
        return Err(InputApplyError::ClockUnsynchronized);
    }

    // Saturation above u64::MAX shortens the mapped deadline; preserve the
    // existing event boundary semantics while sharing clock-quality checks.
    let mapped_not_after_ns = snapshot.estimate.remote_to_local_ns(sender_not_after_ns);
    if future_horizon_ns
        .is_some_and(|horizon| mapped_not_after_ns.saturating_sub(local_now_ns) > horizon)
    {
        return Err(InputApplyError::InvalidInput);
    }
    let drift_uncertainty_ns = u64::try_from(
        (u128::from(sample_age_ns) * u128::from(CLOCK_DRIFT_PPM)).div_ceil(1_000_000),
    )
    .unwrap_or(u64::MAX);
    let effective_uncertainty_ns = snapshot
        .estimate
        .uncertainty_ns
        .saturating_add(drift_uncertainty_ns);
    if effective_uncertainty_ns > MAX_CLOCK_UNCERTAINTY_NS {
        return Err(InputApplyError::ClockUnsynchronized);
    }
    let safe_local_not_after_ns = mapped_not_after_ns.saturating_sub(effective_uncertainty_ns);
    if local_now_ns >= safe_local_not_after_ns {
        return Err(InputApplyError::Expired);
    }
    Ok(safe_local_not_after_ns)
}

impl Drop for InputReceiver {
    fn drop(&mut self) {
        let _ = self.backend.release_all();
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct InputScript {
    owner: Id128,
    target: Id128,
    offered_generation: u64,
    events: Vec<InputEventKind>,
}

impl InputScript {
    pub(crate) fn from_path(path: &Path) -> Result<Self> {
        let contents = fs::read_to_string(path)
            .with_context(|| format!("failed to read input script {}", path.display()))?;
        Self::parse(&contents).with_context(|| format!("invalid input script {}", path.display()))
    }

    pub(crate) fn payloads(&self) -> Result<Vec<wire::control_envelope::Payload>> {
        let active_generation = self
            .offered_generation
            .checked_add(1)
            .ok_or_else(|| anyhow!("input lease generation exhausted"))?;
        let revoked_generation = active_generation
            .checked_add(1)
            .ok_or_else(|| anyhow!("input lease generation exhausted"))?;
        let mut payloads = vec![
            input_lease_payload(InputLease {
                generation: self.offered_generation,
                owner: self.owner,
                route_to: self.target,
                state: InputLeaseState::Offered,
            }),
            input_lease_payload(InputLease {
                generation: active_generation,
                owner: self.owner,
                route_to: self.target,
                state: InputLeaseState::Active,
            }),
        ];
        for (index, event) in self.events.iter().enumerate() {
            payloads.push(input_event_payload(InputEvent {
                lease_generation: active_generation,
                target_device: self.target,
                sequence: u64::try_from(index + 1).context("input script has too many events")?,
                sender_not_after_ns: u64::from(!matches!(*event, InputEventKind::ReleaseAll)),
                event: *event,
            }));
        }
        payloads.push(input_lease_payload(InputLease {
            generation: revoked_generation,
            owner: self.owner,
            route_to: self.target,
            state: InputLeaseState::Revoked,
        }));
        Ok(payloads)
    }

    #[allow(clippy::too_many_lines)]
    fn parse(contents: &str) -> Result<Self> {
        let mut header = None;
        let mut events = Vec::new();
        let mut pressed_buttons = Vec::new();
        let mut pressed_keys = BTreeSet::new();

        for (line_index, raw_line) in contents.lines().enumerate() {
            let line_number = line_index + 1;
            let line = raw_line.split('#').next().unwrap_or_default().trim();
            if line.is_empty() {
                continue;
            }
            let fields = line.split_whitespace().collect::<Vec<_>>();
            match fields.as_slice() {
                ["lease", owner, target, generation] if header.is_none() && events.is_empty() => {
                    let owner = parse_id(owner, line_number)?;
                    let target = parse_id(target, line_number)?;
                    if owner == target {
                        bail!("line {line_number}: lease owner and target must differ");
                    }
                    let generation = parse_u64(generation, line_number, "generation")?;
                    if generation == 0 || generation > u64::MAX - 2 {
                        bail!(
                            "line {line_number}: offered generation must leave room for active and revoked leases"
                        );
                    }
                    header = Some((owner, target, generation));
                }
                ["lease", ..] => bail!("line {line_number}: lease must be the first command"),
                ["motion", delta_x, delta_y] => {
                    require_header(header, line_number)?;
                    events.push(InputEventKind::PointerMotion(
                        viewflow_protocol::RelativePointerMotion {
                            delta_x_dip: parse_f64(delta_x, line_number, "delta_x")?,
                            delta_y_dip: parse_f64(delta_y, line_number, "delta_y")?,
                        },
                    ));
                }
                ["wheel", vertical, horizontal] => {
                    require_header(header, line_number)?;
                    events.push(InputEventKind::PointerWheel(
                        viewflow_protocol::PointerWheelEvent {
                            vertical_delta_detents: parse_f64(vertical, line_number, "vertical")?,
                            horizontal_delta_detents: parse_f64(
                                horizontal,
                                line_number,
                                "horizontal",
                            )?,
                        },
                    ));
                }
                ["button", button, state] => {
                    require_header(header, line_number)?;
                    let button = parse_button(button, line_number)?;
                    let state = parse_switch(state, line_number)?;
                    update_button_state(&mut pressed_buttons, button, state, line_number)?;
                    events.push(InputEventKind::PointerButton(
                        viewflow_protocol::PointerButtonEvent { button, state },
                    ));
                }
                ["key", usage_page, usage_id, state] => {
                    require_header(header, line_number)?;
                    let usage_page = parse_u16(usage_page, line_number, "usage_page")?;
                    let usage_id = parse_u16(usage_id, line_number, "usage_id")?;
                    if usage_page == 0 || usage_id == 0 {
                        bail!("line {line_number}: HID usage page and id must be non-zero");
                    }
                    let state = parse_switch(state, line_number)?;
                    update_key_state(
                        &mut pressed_keys,
                        (usage_page, usage_id),
                        state,
                        line_number,
                    )?;
                    events.push(InputEventKind::KeyboardHidUsage(
                        viewflow_protocol::KeyboardHidUsage {
                            usage_page,
                            usage_id,
                            state,
                            repeat: false,
                        },
                    ));
                }
                ["release-all"] => {
                    require_header(header, line_number)?;
                    pressed_buttons.clear();
                    pressed_keys.clear();
                    events.push(InputEventKind::ReleaseAll);
                }
                _ => bail!("line {line_number}: unknown command or wrong field count"),
            }
        }

        let (owner, target, offered_generation) =
            header.ok_or_else(|| anyhow!("missing lease header"))?;
        if events.is_empty() {
            bail!("input script must contain at least one event");
        }
        if !pressed_buttons.is_empty() || !pressed_keys.is_empty() {
            bail!("input script leaves a key or pointer button pressed");
        }
        if !matches!(events.last(), Some(InputEventKind::ReleaseAll)) {
            events.push(InputEventKind::ReleaseAll);
        }
        Ok(Self {
            owner,
            target,
            offered_generation,
            events,
        })
    }
}

fn require_header(header: Option<(Id128, Id128, u64)>, line: usize) -> Result<()> {
    if header.is_none() {
        bail!("line {line}: lease must be declared before input events");
    }
    Ok(())
}

fn parse_id(value: &str, line: usize) -> Result<Id128> {
    let digits = value.strip_prefix("0x").unwrap_or(value);
    if digits.len() != 32 || !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("line {line}: device ids must contain exactly 32 hexadecimal digits");
    }
    let value = u128::from_str_radix(digits, 16).context("invalid device id")?;
    if value == 0 {
        bail!("line {line}: device id zero is reserved");
    }
    Ok(Id128(value))
}

fn parse_u64(value: &str, line: usize, name: &str) -> Result<u64> {
    parse_integer(value).with_context(|| format!("line {line}: invalid {name}"))
}

fn parse_u16(value: &str, line: usize, name: &str) -> Result<u16> {
    let parsed: u64 =
        parse_integer(value).with_context(|| format!("line {line}: invalid {name}"))?;
    u16::try_from(parsed).with_context(|| format!("line {line}: {name} exceeds u16"))
}

fn parse_integer<T>(value: &str) -> Result<T>
where
    T: TryFrom<u64>,
    T::Error: std::error::Error + Send + Sync + 'static,
{
    let parsed = if let Some(hex) = value.strip_prefix("0x") {
        u64::from_str_radix(hex, 16)?
    } else {
        value.parse::<u64>()?
    };
    Ok(T::try_from(parsed)?)
}

fn parse_f64(value: &str, line: usize, name: &str) -> Result<f64> {
    let parsed = value
        .parse::<f64>()
        .with_context(|| format!("line {line}: invalid {name}"))?;
    if !parsed.is_finite() {
        bail!("line {line}: {name} must be finite");
    }
    Ok(parsed)
}

fn parse_button(value: &str, line: usize) -> Result<PointerButton> {
    match value {
        "left" => Ok(PointerButton::Left),
        "middle" => Ok(PointerButton::Middle),
        "right" => Ok(PointerButton::Right),
        "back" => Ok(PointerButton::Back),
        "forward" => Ok(PointerButton::Forward),
        _ => bail!("line {line}: unknown pointer button {value:?}"),
    }
}

fn parse_switch(value: &str, line: usize) -> Result<InputSwitchState> {
    match value {
        "down" => Ok(InputSwitchState::Pressed),
        "up" => Ok(InputSwitchState::Released),
        _ => bail!("line {line}: input state must be down or up"),
    }
}

fn update_button_state(
    pressed: &mut Vec<PointerButton>,
    button: PointerButton,
    state: InputSwitchState,
    line: usize,
) -> Result<()> {
    let position = pressed.iter().position(|value| *value == button);
    match (state, position) {
        (InputSwitchState::Pressed, None) => pressed.push(button),
        (InputSwitchState::Released, Some(index)) => {
            pressed.remove(index);
        }
        (InputSwitchState::Pressed, Some(_)) => bail!("line {line}: pointer button already down"),
        (InputSwitchState::Released, None) => bail!("line {line}: pointer button is not down"),
    }
    Ok(())
}

fn update_key_state(
    pressed: &mut BTreeSet<(u16, u16)>,
    key: (u16, u16),
    state: InputSwitchState,
    line: usize,
) -> Result<()> {
    match (state, pressed.contains(&key)) {
        (InputSwitchState::Pressed, false) => {
            pressed.insert(key);
        }
        (InputSwitchState::Released, true) => {
            pressed.remove(&key);
        }
        (InputSwitchState::Pressed, true) => bail!("line {line}: key is already down"),
        (InputSwitchState::Released, false) => bail!("line {line}: key is not down"),
    }
    Ok(())
}

fn wire_id(value: Id128) -> wire::Id128 {
    wire::Id128 {
        high: u64::try_from(value.0 >> 64).expect("the shifted ID fits in u64"),
        low: u64::try_from(value.0 & u128::from(u64::MAX)).expect("the masked ID fits in u64"),
    }
}

pub(crate) fn input_lease_payload(lease: InputLease) -> wire::control_envelope::Payload {
    wire::control_envelope::Payload::InputLease(wire::InputLease {
        generation: lease.generation,
        owner: Some(wire_id(lease.owner)),
        route_to: Some(wire_id(lease.route_to)),
        state: match lease.state {
            InputLeaseState::Offered => wire::InputLeaseState::Offered.into(),
            InputLeaseState::Active => wire::InputLeaseState::Active.into(),
            InputLeaseState::Revoked => wire::InputLeaseState::Revoked.into(),
        },
    })
}

pub(crate) fn input_lease_revoke_payload(
    revoke: InputLeaseRevoke,
) -> wire::control_envelope::Payload {
    debug_assert_eq!(revoke.state, InputLeaseState::Revoked);
    wire::control_envelope::Payload::InputLeaseRevoke(wire::InputLeaseRevoke {
        operation_id: Some(wire_id(revoke.operation_id)),
        lease_generation: revoke.lease_generation,
        owner_device: Some(wire_id(revoke.owner_device)),
        target_device: Some(wire_id(revoke.target_device)),
        state: wire::InputLeaseState::Revoked.into(),
    })
}

pub(crate) fn input_event_payload(event: InputEvent) -> wire::control_envelope::Payload {
    wire::control_envelope::Payload::InputEvent(wire::InputEvent {
        lease_generation: event.lease_generation,
        target_device: Some(wire_id(event.target_device)),
        event_sequence: event.sequence,
        sender_not_after_ns: event.sender_not_after_ns,
        event: Some(event_to_wire(event.event)),
    })
}

pub(crate) fn input_applied_ack_payload(
    event: &InputEvent,
    result: InputAppliedResult,
) -> wire::control_envelope::Payload {
    wire::control_envelope::Payload::InputAppliedAck(wire::InputAppliedAck {
        lease_generation: event.lease_generation,
        target_device: Some(wire_id(event.target_device)),
        event_sequence: event.sequence,
        result: wire::InputAppliedResult::from(result).into(),
    })
}

pub(crate) fn input_lease_revoked_ack_payload(
    ack: InputLeaseRevokedAck,
) -> wire::control_envelope::Payload {
    debug_assert_eq!(ack.state, InputLeaseState::Revoked);
    wire::control_envelope::Payload::InputLeaseRevokedAck(wire::InputLeaseRevokedAck {
        operation_id: Some(wire_id(ack.operation_id)),
        lease_generation: ack.lease_generation,
        owner_device: Some(wire_id(ack.owner_device)),
        target_device: Some(wire_id(ack.target_device)),
        state: wire::InputLeaseState::Revoked.into(),
        result: match ack.result {
            viewflow_protocol::InputLeaseRevokedResult::Applied => {
                wire::InputLeaseRevokedResult::Applied.into()
            }
        },
    })
}

fn event_to_wire(event: InputEventKind) -> wire::input_event::Event {
    match event {
        InputEventKind::DesktopPointerPosition(position) => {
            wire::input_event::Event::DesktopPointerPosition(wire::DesktopPointerPosition {
                x_millidip: position.x_millidip,
                y_millidip: position.y_millidip,
            })
        }
        InputEventKind::PointerMotion(motion) => {
            wire::input_event::Event::PointerMotion(wire::RelativePointerMotion {
                delta_x_dip: motion.delta_x_dip,
                delta_y_dip: motion.delta_y_dip,
            })
        }
        InputEventKind::PointerButton(button) => {
            wire::input_event::Event::PointerButton(wire::PointerButtonEvent {
                button: match button.button {
                    PointerButton::Left => wire::PointerButton::Left.into(),
                    PointerButton::Middle => wire::PointerButton::Middle.into(),
                    PointerButton::Right => wire::PointerButton::Right.into(),
                    PointerButton::Back => wire::PointerButton::Back.into(),
                    PointerButton::Forward => wire::PointerButton::Forward.into(),
                },
                state: switch_to_wire(button.state),
            })
        }
        InputEventKind::PointerWheel(wheel) => {
            wire::input_event::Event::PointerWheel(wire::PointerWheelEvent {
                vertical_delta_detents: wheel.vertical_delta_detents,
                horizontal_delta_detents: wheel.horizontal_delta_detents,
            })
        }
        InputEventKind::KeyboardHidUsage(key) => {
            wire::input_event::Event::KeyboardHidUsage(wire::KeyboardHidUsage {
                usage_page: u32::from(key.usage_page),
                usage_id: u32::from(key.usage_id),
                state: switch_to_wire(key.state),
                repeat: key.repeat,
            })
        }
        InputEventKind::Touchpad(frame) => wire::input_event::Event::Touchpad(wire::TouchpadFrame {
            width: frame.width, height: frame.height,
            contacts: frame.contacts[..usize::from(frame.count)].iter().map(|c| wire::TouchpadContact { id: c.id, x: c.x, y: c.y }).collect(),
        }),
        InputEventKind::ReleaseAll => {
            wire::input_event::Event::ReleaseAll(wire::ReleaseAllInput {})
        }
    }
}

fn switch_to_wire(state: InputSwitchState) -> i32 {
    match state {
        InputSwitchState::Pressed => wire::InputSwitchState::Pressed.into(),
        InputSwitchState::Released => wire::InputSwitchState::Released.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEADER: &str =
        "lease 00000000000000000000000000000001 00000000000000000000000000000002 5\n";

    #[test]
    fn parses_balanced_script_and_builds_lease_then_events() {
        let script = InputScript::parse(&format!(
            "{HEADER}motion 12.5 -3\nbutton left down\nbutton left up\nkey 0x07 0x04 down\nkey 7 4 up\nwheel -1 0\n"
        ))
        .unwrap();
        let payloads = script.payloads().unwrap();
        assert_eq!(payloads.len(), 10);
        let wire::control_envelope::Payload::InputLease(offered) = &payloads[0] else {
            panic!("expected offered lease");
        };
        assert_eq!(offered.generation, 5);
        let wire::control_envelope::Payload::InputLease(active) = &payloads[1] else {
            panic!("expected active lease");
        };
        assert_eq!(active.generation, 6);
        let wire::control_envelope::Payload::InputEvent(release_all) = &payloads[8] else {
            panic!("expected final input event");
        };
        assert!(matches!(
            release_all.event,
            Some(wire::input_event::Event::ReleaseAll(_))
        ));
        let wire::control_envelope::Payload::InputLease(revoked) = &payloads[9] else {
            panic!("expected revoked lease after final input event");
        };
        assert_eq!(revoked.generation, 7);
        assert_eq!(revoked.state, i32::from(wire::InputLeaseState::Revoked));
    }

    #[test]
    fn rejects_unbalanced_duplicate_and_malformed_input() {
        assert!(InputScript::parse(&format!("{HEADER}button left down\n")).is_err());
        assert!(
            InputScript::parse(&format!(
                "{HEADER}button left down\nbutton left down\nrelease-all\n"
            ))
            .is_err()
        );
        assert!(InputScript::parse("motion 1 2\n").is_err());
        assert!(InputScript::parse(&format!("{HEADER}motion NaN 2\n")).is_err());
        assert!(InputScript::parse(&format!("{HEADER}key 7 0 down\nrelease-all\n")).is_err());
        assert!(
            InputScript::parse(
                "lease 00000000000000000000000000000001 \
                 00000000000000000000000000000002 18446744073709551614\n\
                 release-all\n"
            )
            .is_err()
        );
    }

    #[test]
    fn input_receiver_enforces_lease_target_generation_and_sequence() {
        let mut receiver = InputReceiver::new(InputBackendMode::Disabled, Some(Id128(2))).unwrap();
        let offered = InputLease {
            generation: 1,
            owner: Id128(1),
            route_to: Id128(2),
            state: InputLeaseState::Offered,
        };
        receiver.apply_lease(offered).unwrap();
        receiver
            .apply_lease(InputLease {
                generation: 2,
                state: InputLeaseState::Active,
                ..offered
            })
            .unwrap();
        let event = InputEvent {
            lease_generation: 2,
            target_device: Id128(2),
            sequence: 1,
            sender_not_after_ns: 0,
            event: InputEventKind::ReleaseAll,
        };
        receiver.apply_event(&event, None, 0).unwrap();
        assert_eq!(
            receiver.apply_event(&event, None, 0),
            Err(InputApplyError::EventSequence)
        );
        assert_eq!(
            receiver.apply_event(
                &InputEvent {
                    sequence: 2,
                    target_device: Id128(3),
                    ..event
                },
                None,
                0
            ),
            Err(InputApplyError::TargetDevice)
        );
        receiver.release_all().unwrap();
    }

    #[test]
    fn input_receiver_requires_native_identity_and_rejects_wrong_lease_route() {
        let error = InputReceiver::new(InputBackendMode::Native, None).unwrap_err();
        assert!(error.to_string().contains("requires a local device id"));

        let mut receiver = InputReceiver::new(InputBackendMode::Disabled, Some(Id128(2))).unwrap();
        assert!(
            receiver
                .apply_lease(InputLease {
                    generation: 1,
                    owner: Id128(1),
                    route_to: Id128(3),
                    state: InputLeaseState::Offered,
                })
                .unwrap_err()
                .to_string()
                .contains("does not match the local device")
        );
    }

    #[test]
    fn windows_backend_errors_map_to_stable_input_results() {
        assert_eq!(
            InputApplyError::from(WindowsInputError::UnsupportedHidUsage {
                usage_page: 0x0c,
                usage_id: 0x00e9,
            }),
            InputApplyError::UnsupportedInput
        );
        assert_eq!(
            InputApplyError::from(WindowsInputError::DeltaOutOfRange),
            InputApplyError::InvalidInput
        );
        assert_eq!(
            InputApplyError::from(WindowsInputError::SendInputFailed),
            InputApplyError::InjectionFailed
        );
    }

    #[test]
    fn failure_diagnostics_include_position_but_never_key_usage_or_state() {
        let mut event = InputEvent {
            lease_generation: 5,
            target_device: Id128(2),
            sequence: 19,
            sender_not_after_ns: 123,
            event: InputEventKind::KeyboardHidUsage(viewflow_protocol::KeyboardHidUsage {
                usage_page: 7,
                usage_id: 225,
                state: InputSwitchState::Pressed,
                repeat: true,
            }),
        };
        assert_eq!(
            input_event_diagnostic(&event),
            "kind=keyboard generation=5 sequence=19"
        );
        event.event =
            InputEventKind::DesktopPointerPosition(viewflow_protocol::DesktopPointerPosition {
                x_millidip: 3_087_000,
                y_millidip: 529_000,
            });
        assert_eq!(
            input_event_diagnostic(&event),
            "kind=desktop-position generation=5 sequence=19 x_millidip=3087000 y_millidip=529000"
        );
    }

    fn clock_snapshot(
        remote_offset_ns: i64,
        uncertainty_ns: u64,
        measured_at_local_ns: u64,
    ) -> ClockSnapshot {
        ClockSnapshot {
            estimate: ClockEstimate {
                remote_offset_ns,
                network_round_trip_ns: uncertainty_ns.saturating_mul(2),
                uncertainty_ns,
            },
            measured_at_local_ns,
        }
    }

    fn motion_event(sequence: u64, sender_not_after_ns: u64) -> InputEvent {
        InputEvent {
            lease_generation: 2,
            target_device: Id128(2),
            sequence,
            sender_not_after_ns,
            event: InputEventKind::PointerMotion(viewflow_protocol::RelativePointerMotion {
                delta_x_dip: 1.0,
                delta_y_dip: 0.0,
            }),
        }
    }

    #[test]
    fn ordered_cursor_preserves_transitions_without_clock_but_rejects_replay_and_wrong_target() {
        let mut receiver = active_receiver();
        let mut event = motion_event(1, 0);
        event.event = InputEventKind::PointerButton(viewflow_protocol::PointerButtonEvent {
            button: viewflow_protocol::PointerButton::Left,
            state: InputSwitchState::Pressed,
        });
        receiver.apply_ordered_event(&event).unwrap();
        assert!(matches!(receiver.apply_ordered_event(&event), Err(InputApplyError::EventSequence)));
        event.sequence = 2;
        event.target_device = Id128(99);
        assert!(matches!(receiver.apply_ordered_event(&event), Err(InputApplyError::TargetDevice)));
        event.target_device = Id128(2);
        if let InputEventKind::PointerButton(button) = &mut event.event { button.state = InputSwitchState::Released; }
        receiver.apply_ordered_event(&event).unwrap();
    }

    #[test]
    fn absolute_desktop_motion_requires_fresh_clock_and_consumes_stale_identity() {
        let mut receiver = active_receiver();
        let mut event = motion_event(1, 20_000_000);
        event.event =
            InputEventKind::DesktopPointerPosition(viewflow_protocol::DesktopPointerPosition {
                x_millidip: -1000,
                y_millidip: 2000,
            });
        assert_eq!(
            receiver.apply_event(&event, None, 10_000_000),
            Err(InputApplyError::ClockUnsynchronized)
        );
        assert_eq!(
            receiver.apply_event(
                &event,
                Some(clock_snapshot(0, 1000, 10_000_000)),
                10_000_000
            ),
            Err(InputApplyError::EventSequence)
        );
        event.sequence = 2;
        assert!(
            receiver
                .apply_event(
                    &event,
                    Some(clock_snapshot(0, 1000, 10_000_000)),
                    10_000_000
                )
                .is_ok()
        );
    }

    fn active_receiver() -> InputReceiver {
        let mut receiver = InputReceiver::new(InputBackendMode::Disabled, Some(Id128(2))).unwrap();
        let offered = InputLease {
            generation: 1,
            owner: Id128(1),
            route_to: Id128(2),
            state: InputLeaseState::Offered,
        };
        receiver.apply_lease(offered).unwrap();
        receiver
            .apply_lease(InputLease {
                generation: 2,
                state: InputLeaseState::Active,
                ..offered
            })
            .unwrap();
        receiver
    }

    fn lease_revoke(generation: u64) -> InputLeaseRevoke {
        InputLeaseRevoke {
            operation_id: Id128(99),
            lease_generation: generation,
            owner_device: Id128(1),
            target_device: Id128(2),
            state: InputLeaseState::Revoked,
        }
    }

    #[test]
    fn exact_lease_revoke_releases_then_publishes_revoked_state_and_ack() {
        let mut receiver = active_receiver();
        receiver.previous_event_sequence = Some(17);

        let revoke = lease_revoke(3);
        let ack = receiver.apply_lease_revoke(revoke).unwrap();

        assert_eq!(receiver.lease, Some(revoke.lease()));
        assert_eq!(receiver.previous_event_sequence, None);
        assert_eq!(
            ack,
            InputLeaseRevokedAck {
                operation_id: revoke.operation_id,
                lease_generation: revoke.lease_generation,
                owner_device: revoke.owner_device,
                target_device: revoke.target_device,
                state: InputLeaseState::Revoked,
                result: InputLeaseRevokedResult::Applied,
            }
        );
    }

    #[test]
    fn lease_revoke_rejects_non_active_generation_jump_and_wrong_identity_without_mutation() {
        let offered = InputLease {
            generation: 1,
            owner: Id128(1),
            route_to: Id128(2),
            state: InputLeaseState::Offered,
        };
        let mut offered_receiver =
            InputReceiver::new(InputBackendMode::Disabled, Some(Id128(2))).unwrap();
        offered_receiver.apply_lease(offered).unwrap();
        assert!(
            offered_receiver
                .apply_lease_revoke(lease_revoke(2))
                .is_err()
        );
        assert_eq!(offered_receiver.lease, Some(offered));

        for invalid in [
            lease_revoke(4),
            InputLeaseRevoke {
                owner_device: Id128(3),
                ..lease_revoke(3)
            },
            InputLeaseRevoke {
                target_device: Id128(3),
                ..lease_revoke(3)
            },
            InputLeaseRevoke {
                state: InputLeaseState::Active,
                ..lease_revoke(3)
            },
        ] {
            let mut receiver = active_receiver();
            receiver.previous_event_sequence = Some(17);
            let active = receiver.lease;

            assert!(receiver.apply_lease_revoke(invalid).is_err());
            assert_eq!(receiver.lease, active);
            assert_eq!(receiver.previous_event_sequence, Some(17));
        }
    }

    #[test]
    fn freshness_gate_maps_both_clock_offset_directions_and_is_fail_closed() {
        let now = 5_000_000_000;
        for offset in [5_000_000_i64, -5_000_000_i64] {
            let remote_deadline =
                u64::try_from(i128::from(now + 10_000_000) + i128::from(offset)).unwrap();
            assert_eq!(
                conservative_input_deadline(
                    remote_deadline,
                    Some(clock_snapshot(offset, 1_000_000, now - 2_000_000)),
                    now,
                ),
                Ok(now + 8_999_000)
            );
            assert_eq!(
                validate_event_freshness(
                    &motion_event(1, remote_deadline),
                    Some(clock_snapshot(offset, 1_000_000, now)),
                    now,
                ),
                Ok(())
            );
        }

        assert_eq!(
            validate_event_freshness(&motion_event(1, now + 1_000_000), None, now),
            Err(InputApplyError::ClockUnsynchronized)
        );
        assert_eq!(
            validate_event_freshness(
                &motion_event(1, now + 10_000_000),
                Some(clock_snapshot(0, MAX_CLOCK_UNCERTAINTY_NS + 1, now)),
                now,
            ),
            Err(InputApplyError::ClockUnsynchronized)
        );
        assert_eq!(
            validate_event_freshness(
                &motion_event(1, now + 10_000_000),
                Some(clock_snapshot(0, 3_000_000, now - MAX_CLOCK_SAMPLE_AGE_NS,)),
                now,
            ),
            Err(InputApplyError::ClockUnsynchronized)
        );
        assert_eq!(
            validate_event_freshness(
                &motion_event(1, now + 10_000_000),
                Some(clock_snapshot(0, 0, now - MAX_CLOCK_SAMPLE_AGE_NS - 1,)),
                now,
            ),
            Err(InputApplyError::ClockUnsynchronized)
        );
    }

    #[test]
    fn desktop_operation_uses_its_own_budget_with_clock_mapping() {
        let now = 10_000_000_000;
        let clock = Some(clock_snapshot(0, 1_000_000, now));
        let deadline = now + INPUT_OPERATION_TIMEOUT_NS + 1_000_000;
        assert_eq!(conservative_input_deadline(deadline, clock, now), Err(InputApplyError::InvalidInput));
        assert_eq!(conservative_operation_deadline(deadline, clock, now), Ok(deadline - 1_000_000));
        assert_eq!(conservative_operation_deadline(deadline, None, now), Err(InputApplyError::ClockUnsynchronized));
        assert_eq!(conservative_operation_deadline(deadline + 1_000_000_000, clock, now), Err(InputApplyError::InvalidInput));
    }

    #[test]
    fn lease_clock_mapping_and_ordered_operation_horizon_are_separate() {
        let now = 4_000_000_000;
        let snapshot = Some(clock_snapshot(0, 1_000_000, now));
        let expiry = now + INPUT_OPERATION_TIMEOUT_NS + 1_000_000_000;
        assert_eq!(
            conservative_authorization_deadline(expiry, snapshot, now),
            Ok(expiry - 1_000_000)
        );
        assert_eq!(
            conservative_input_deadline(expiry, snapshot, now),
            Err(InputApplyError::InvalidInput)
        );
        assert_eq!(
            conservative_authorization_deadline(expiry, None, now),
            Err(InputApplyError::ClockUnsynchronized)
        );
        assert_eq!(
            conservative_authorization_deadline(now + 1_000_000, snapshot, now),
            Err(InputApplyError::Expired)
        );
    }

    #[test]
    fn freshness_gate_subtracts_uncertainty_and_drift_at_the_expiry_boundary() {
        let now = 4_000_000_000;
        let sample_age = 2_000_000_000;
        let uncertainty = 2_000_000;
        let effective = uncertainty + 1_000_000;
        let snapshot = clock_snapshot(0, uncertainty, now - sample_age);
        assert_eq!(
            validate_event_freshness(&motion_event(1, now + effective), Some(snapshot), now,),
            Err(InputApplyError::Expired)
        );
        assert_eq!(
            validate_event_freshness(&motion_event(1, now + effective + 1), Some(snapshot), now,),
            Ok(())
        );
        assert_eq!(
            validate_event_freshness(
                &motion_event(1, now + MAX_INPUT_FUTURE_HORIZON_NS + 1),
                Some(clock_snapshot(0, 0, now)),
                now,
            ),
            Err(InputApplyError::InvalidInput)
        );

        assert_eq!(
            validate_event_freshness(
                &motion_event(1, u64::MAX),
                Some(clock_snapshot(-1, 0, u64::MAX - 1)),
                u64::MAX - 1,
            ),
            Ok(())
        );
        assert_eq!(
            validate_event_freshness(&motion_event(1, 1), Some(clock_snapshot(10, 0, 0)), 0,),
            Err(InputApplyError::Expired)
        );
    }

    #[test]
    fn rejected_timing_consumes_sequence_without_calling_backend() {
        let mut receiver = active_receiver();
        let event = motion_event(1, 100);
        assert_eq!(
            receiver.apply_event(&event, None, 0),
            Err(InputApplyError::ClockUnsynchronized)
        );
        assert_eq!(receiver.applied_event_count, 0);
        assert_eq!(
            receiver.apply_event(&event, Some(clock_snapshot(0, 0, 0)), 0,),
            Err(InputApplyError::EventSequence)
        );

        let fresh = motion_event(2, 10_000_000);
        receiver
            .apply_event(&fresh, Some(clock_snapshot(0, 0, 0)), 0)
            .unwrap();
        assert_eq!(receiver.applied_event_count, 1);
    }

    #[test]
    fn zero_deadline_release_all_bypasses_clock_sync() {
        let mut receiver = active_receiver();
        let release = InputEvent {
            sender_not_after_ns: 0,
            event: InputEventKind::ReleaseAll,
            ..motion_event(1, 1)
        };
        receiver.apply_event(&release, None, u64::MAX).unwrap();
        assert_eq!(receiver.applied_event_count, 1);
        assert_eq!(
            validate_event_freshness(&motion_event(2, 0), None, 0),
            Err(InputApplyError::InvalidInput)
        );
    }
}

#[cfg(test)]
mod touchpad_tests {
    use super::*;
    #[test]
    fn touchpad_round_trip_and_ordered_lease_release() {
        let mut receiver = InputReceiver::new(InputBackendMode::Disabled, Some(Id128(2))).unwrap();
        for (generation, state) in [(1, InputLeaseState::Offered), (2, InputLeaseState::Active)] {
            receiver.apply_lease(InputLease { generation, state, owner: Id128(1), route_to: Id128(2) }).unwrap();
        }
        let mut frame = viewflow_protocol::TouchpadFrame { width: 16000, height: 11000, count: 5, ..Default::default() };
        for (i, c) in frame.contacts.iter_mut().enumerate() { *c = viewflow_protocol::TouchpadContact { id: i as u32, x: 1000, y: 2000 }; }
        let event = InputEvent { lease_generation: 2, target_device: Id128(2), sequence: 1, sender_not_after_ns: 1, event: InputEventKind::Touchpad(frame) };
        let wire::control_envelope::Payload::InputEvent(encoded) = input_event_payload(event) else { panic!() };
        assert_eq!(InputEvent::try_from(encoded).unwrap(), event);
        receiver.apply_ordered_event(&event).unwrap();
        assert_eq!(receiver.apply_ordered_event(&event), Err(InputApplyError::EventSequence));
        receiver.apply_ordered_event(&InputEvent { sequence: 2, event: InputEventKind::Touchpad(viewflow_protocol::TouchpadFrame { count: 0, ..frame }), ..event }).unwrap();
        receiver.apply_lease(InputLease { generation: 3, state: InputLeaseState::Revoked, owner: Id128(1), route_to: Id128(2) }).unwrap();
        assert!(receiver.apply_ordered_event(&InputEvent { sequence: 3, ..event }).is_err());
    }
}
