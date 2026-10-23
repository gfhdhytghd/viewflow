//! Source-local policy. A remote selection requests a target, never a lease.
use crate::window_input_runtime::{AtlasCommittedInput, AuthorizedWindow};
use anyhow::{Context, Result, ensure};
use std::collections::BTreeMap;
use viewflow_protocol::{AtlasWindowSelection, DeviceId, WindowId};

#[derive(Clone, Copy)]
pub struct AtlasSelectionContext {
    pub now_local_ns: u64,
    pub now_native_ns: u64,
    pub max_capture_age_ns: u64,
    /// Estimate and measurement time supplied by this authenticated input route.
    pub clock: Option<(viewflow_transport::ClockEstimate, u64)>,
}

impl AtlasSelectionContext {
    fn require_fresh_capture(self, captured_ns: u64) -> Result<()> {
        let age = self
            .now_native_ns
            .checked_sub(captured_ns)
            .context("atlas capture timestamp is in the future")?;
        ensure!(
            self.max_capture_age_ns > 0,
            "invalid atlas capture age limit"
        );
        if age >= self.max_capture_age_ns {
            return Err(AtlasSelectionUnavailable {
                age_ns: age,
                max_age_ns: self.max_capture_age_ns,
            }
            .into());
        }
        Ok(())
    }
}

pub struct AtlasInputPolicy {
    owner: DeviceId,
    target: DeviceId,
    allowed: BTreeMap<WindowId, u64>,
    lease_duration_ns: u64,
    last_selection: u64,
    generation: u64,
    current: Option<AuthorizedWindow>,
    keyboard_window: Option<WindowId>,
    selection_required: bool,
}

#[derive(Debug)]
pub(crate) struct AtlasSelectionUnavailable {
    pub age_ns: u64,
    pub max_age_ns: u64,
}

impl std::fmt::Display for AtlasSelectionUnavailable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "atlas selected capture expired: age_ns={} max_age_ns={}",
            self.age_ns, self.max_age_ns
        )
    }
}

impl std::error::Error for AtlasSelectionUnavailable {}

#[derive(Debug)]
pub(crate) struct AtlasSelectionSuperseded;
impl std::fmt::Display for AtlasSelectionSuperseded {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("atlas selection references superseded input geometry")
    }
}
impl std::error::Error for AtlasSelectionSuperseded {}

impl AtlasInputPolicy {
    pub(crate) fn retire_local_window(&mut self, window: WindowId) {
        self.allowed.remove(&window);
        if self.keyboard_window == Some(window) {
            self.keyboard_window = None;
        }
        if self
            .current
            .as_ref()
            .is_some_and(|current| current.geometry.identity().window == window)
        {
            self.invalidate_current();
        }
    }

    pub(crate) fn observe_membership(&mut self, windows: &std::collections::BTreeSet<WindowId>) {
        if self
            .keyboard_window
            .is_some_and(|window| !windows.contains(&window))
        {
            self.keyboard_window = None;
        }
        if self
            .current
            .as_ref()
            .is_some_and(|current| !windows.contains(&current.geometry.identity().window))
        {
            self.invalidate_current();
        }
    }

    pub(crate) fn discard_withdrawn_selection(&mut self, sequence: u64) -> Result<()> {
        self.consume_selection(sequence)
    }

    /// A desktop END/CANCEL revokes the old source authority permanently.
    /// Later input must arrive as a newly sequenced selection over a fresh
    /// committed frame; maintenance may not revive this grant.
    pub(crate) fn invalidate_current(&mut self) {
        self.current = None;
        self.selection_required = true;
    }

    /// Admit an already locally authenticated native address after its capture
    /// source was enrolled at a frame boundary. Network requests alone can
    /// never call this method, so a remote peer cannot widen the allowlist.
    pub(crate) fn enroll_local_window(&mut self, window: WindowId, address: u64) -> Result<()> {
        ensure!(
            window.0 != 0 && address != 0,
            "invalid atlas local window binding"
        );
        ensure!(
            self.allowed.len() < 4096,
            "atlas input window capacity exhausted"
        );
        match self.allowed.insert(window, address) {
            None => Ok(()),
            Some(previous) if previous == address => {
                anyhow::bail!("atlas local window already enrolled")
            }
            Some(previous) => {
                self.allowed.insert(window, previous);
                anyhow::bail!("atlas local window binding changed")
            }
        }
    }

    fn consume_selection(&mut self, sequence: u64) -> Result<()> {
        ensure!(sequence > self.last_selection, "atlas selection replay");
        self.last_selection = sequence;
        Ok(())
    }

    /// Discard a request with temporarily unusable timing without granting input.
    /// A discarded sequence is consumed; a usable one is consumed by `select`.
    pub(crate) fn discard_unusable_selection(
        &mut self,
        request: AtlasWindowSelection,
        clock: Option<(viewflow_transport::ClockEstimate, u64)>,
        now: u64,
    ) -> Result<bool> {
        ensure!(
            request.sequence > self.last_selection,
            "atlas selection replay"
        );
        match crate::input_runtime::conservative_input_deadline(
            request.sender_not_after_ns,
            clock.map(
                |(estimate, measured_at_local_ns)| crate::input_runtime::ClockSnapshot {
                    estimate,
                    measured_at_local_ns,
                },
            ),
            now,
        ) {
            Ok(_) => Ok(false),
            Err(
                crate::input_runtime::InputApplyError::ClockUnsynchronized
                | crate::input_runtime::InputApplyError::Expired,
            ) => {
                self.consume_selection(request.sequence)?;
                Ok(true)
            }
            Err(error) => anyhow::bail!("invalid atlas selection deadline: {error:?}"),
        }
    }
    /// Bootstrap/renew the locally selected capture while idle. Configured
    /// capture membership supplies policy; this is not a remote selection.
    /// Stale captures yield no authorization; callers may await fresh evidence
    /// within their existing startup deadline or unextended native lease.
    /// # Errors
    /// Rejects rebound/future captures, invalid age limits and expired sessions.
    pub fn maintain_capture(
        &mut self,
        committed: &AtlasCommittedInput,
        initial_window: WindowId,
        now_local_ns: u64,
        now_native_ns: u64,
        max_age_ns: u64,
    ) -> Result<Option<AuthorizedWindow>> {
        if self.selection_required {
            return Ok(None);
        }
        let window = self
            .current
            .as_ref()
            .map_or(initial_window, |current| current.geometry.identity().window);
        if committed.snapshot(window).is_none() {
            if self.current.is_some() {
                self.invalidate_current();
            }
            return Ok(None);
        }
        let previous = self.current.as_ref();
        let previous_identity = previous
            .map(|current| {
                viewflow_core::WindowPointerGrant::new(
                    current.owner,
                    current.target_device,
                    current.generation,
                    current.geometry,
                    current.expires_local_ns,
                )
                .and_then(|grant| grant.authorization(now_local_ns))
                .context("atlas input session expired")
            })
            .transpose()?;
        let window = previous_identity.map_or(initial_window, |current| current.target_window);
        if let Some(current) = previous {
            ensure!(
                now_local_ns < current.expires_local_ns,
                "atlas input session expired"
            );
            if current.expires_local_ns - now_local_ns > self.lease_duration_ns / 2 {
                return Ok(None);
            }
        }
        let snapshot = committed
            .snapshot(window)
            .context("selected captured window disappeared")?;
        let age = now_native_ns
            .checked_sub(snapshot.capture_monotonic_ns())
            .context("future input capture")?;
        ensure!(max_age_ns > 0, "invalid atlas input capture age limit");
        if age >= max_age_ns {
            return Ok(None);
        }
        let tile = committed
            .manifest()
            .tiles
            .iter()
            .find(|tile| tile.window_id == window)
            .context("selected atlas tile missing")?;
        let generation = self
            .generation
            .checked_add(1)
            .context("atlas input generation exhausted")?;
        let expires = now_local_ns
            .checked_add(self.lease_duration_ns)
            .context("atlas input expiry overflow")?;
        let authorized = snapshot.authorize(
            self.owner,
            self.target,
            generation,
            expires,
            viewflow_core::PresentedInputIdentity {
                window,
                frame: tile.source_frame_id,
                geometry_epoch: tile.geometry_epoch,
            },
        )?;
        ensure!(
            self.allowed.get(&window) == Some(&authorized.native_address),
            "atlas captured native binding changed"
        );
        if let Some(current) = previous {
            let identity = previous_identity.context("atlas input renewal identity missing")?;
            ensure!(
                authorized.native_surface == current.native_surface
                    && authorized.native_pid == current.native_pid
                    && tile.geometry_epoch >= identity.geometry_epoch
                    && tile.source_frame_id >= identity.presented_frame,
                "atlas input renewal capture rebound or regressed"
            );
            if tile.geometry_epoch > identity.geometry_epoch {
                ensure!(
                    tile.source_frame_id > identity.presented_frame,
                    "atlas resize capture did not advance frame"
                );
                // Fresh geometry needs an explicit frame-bound selection, not
                // automatic maintenance renewal. Preserve the old expiry.
                return Ok(None);
            }
            // Polling may revisit the last committed capture before another
            // visual receipt arrives. It cannot renew the lease, but is not a
            // rebind or regression. Leave generation, geometry and expiry intact;
            // the existing native lease still expires on its original deadline.
            if tile.source_frame_id == identity.presented_frame {
                return Ok(None);
            }
        }
        self.generation = generation;
        self.current = Some(authorized.clone());
        Ok(Some(authorized))
    }

    /// # Errors
    /// Requires explicit distinct devices, unique local window/address bindings,
    /// and a source-decided lease duration no longer than five seconds.
    pub fn new(
        owner: DeviceId,
        target: DeviceId,
        allowed: Vec<(WindowId, u64)>,
        lease_duration_ns: u64,
    ) -> Result<Self> {
        ensure!(
            owner.0 != 0 && target.0 != 0 && owner != target,
            "invalid atlas input device policy"
        );
        ensure!(
            allowed.len() <= 4096
                && allowed
                    .iter()
                    .all(|(id, address)| id.0 != 0 && *address != 0),
            "invalid atlas input window policy"
        );
        ensure!(
            lease_duration_ns > 0 && lease_duration_ns <= 5_000_000_000,
            "invalid atlas input lease duration"
        );
        let count = allowed.len();
        let allowed: BTreeMap<_, _> = allowed.into_iter().collect();
        ensure!(allowed.len() == count, "duplicate atlas input window");
        Ok(Self {
            owner,
            target,
            allowed,
            lease_duration_ns,
            last_selection: 0,
            generation: 0,
            current: None,
            keyboard_window: None,
            selection_required: false,
        })
    }

    /// Apply only while the capture and authenticated connection remain owned.
    /// The supervisor must revoke the result on retirement; the request deadline
    /// bounds selection processing, not the locally decided native lease length.
    /// # Errors
    /// Consumes each request sequence even when denied. Rejects disallowed or
    /// rebound windows, stale/uncommitted captures, expired requests and replay.
    pub fn select(
        &mut self,
        request: AtlasWindowSelection,
        committed: &AtlasCommittedInput,
        context: AtlasSelectionContext,
    ) -> Result<AuthorizedWindow> {
        self.consume_selection(request.sequence)?;
        crate::input_runtime::conservative_input_deadline(
            request.sender_not_after_ns,
            context.clock.map(|(estimate, measured_at_local_ns)| {
                crate::input_runtime::ClockSnapshot {
                    estimate,
                    measured_at_local_ns,
                }
            }),
            context.now_local_ns,
        )
        .map_err(|error| anyhow::anyhow!("atlas selection clock/deadline: {error:?}"))?;
        ensure!(
            request.matches(committed.manifest()),
            "atlas selection does not match committed frame"
        );
        let address = self
            .allowed
            .get(&request.window_id)
            .context("atlas window is not locally authorized")?;
        let snapshot = committed
            .snapshot(request.window_id)
            .context("atlas capture snapshot missing")?;
        context.require_fresh_capture(snapshot.capture_monotonic_ns())?;
        let mut generation = self
            .generation
            .checked_add(1)
            .context("atlas input generation exhausted")?;
        let mut expires = context
            .now_local_ns
            .checked_add(self.lease_duration_ns)
            .context("atlas input deadline overflow")?;
        let mut same_window = false;
        if let Some(current) = &self.current {
            let previous = viewflow_core::WindowPointerGrant::new(
                current.owner,
                current.target_device,
                current.generation,
                current.geometry,
                current.expires_local_ns,
            )
            .and_then(|grant| grant.authorization(context.now_local_ns))
            .context("atlas native lease expired; new input session required")?;
            same_window = previous.target_window == request.window_id;
            if same_window {
                if request.source_geometry_epoch < previous.geometry_epoch
                    || request.source_frame_id < previous.presented_frame {
                    return Err(AtlasSelectionSuperseded.into());
                }
                if request.source_geometry_epoch > previous.geometry_epoch {
                    ensure!(
                        request.source_frame_id > previous.presented_frame,
                        "new atlas geometry requires a newer captured frame"
                    );
                } else if !(request.activate_keyboard
                    && self.keyboard_window != Some(request.window_id))
                    && (previous.source_not_after_ns - context.now_local_ns
                        > self.lease_duration_ns / 2
                        || request.source_frame_id == previous.presented_frame)
                {
                    generation = previous.lease_generation;
                    expires = previous.source_not_after_ns;
                }
            }
        }
        let authorized = snapshot.authorize(
            self.owner,
            self.target,
            generation,
            expires,
            viewflow_core::PresentedInputIdentity {
                window: request.window_id,
                frame: request.source_frame_id,
                geometry_epoch: request.source_geometry_epoch,
            },
        )?;
        ensure!(
            authorized.native_address == *address,
            "atlas input native binding changed"
        );
        if same_window {
            let current = self
                .current
                .as_ref()
                .context("active atlas selection disappeared")?;
            ensure!(
                authorized.native_surface == current.native_surface
                    && authorized.native_pid == current.native_pid,
                "atlas selected native surface was replaced"
            );
        }
        self.generation = generation;
        self.keyboard_window = (request.activate_keyboard
            || self.keyboard_window == Some(request.window_id))
        .then_some(request.window_id);
        self.current = Some(authorized.clone());
        self.selection_required = false;
        Ok(authorized)
    }
}

#[cfg(test)]
mod rejection_regression {
    use super::*;
    #[test]
    fn interactive_capture_age_is_not_a_performance_authorization_cutoff() {
        let context = AtlasSelectionContext {
            now_local_ns: 1_000_000,
            now_native_ns: 10_000_000_000,
            max_capture_age_ns: u64::MAX,
            clock: None,
        };
        for age in [33_333_334, 41_924_882, 500_000_000, 5_000_000_000] {
            context
                .require_fresh_capture(context.now_native_ns - age)
                .unwrap();
        }
        assert!(
            context
                .require_fresh_capture(context.now_native_ns + 1)
                .is_err()
        );
    }
    #[test]
    fn capture_419ms_is_rejected_even_with_2339ms_of_event_lifetime_remaining() {
        let context = AtlasSelectionContext {
            now_local_ns: 1_000_000,
            now_native_ns: 100_000_000,
            max_capture_age_ns: 33_333_333,
            clock: None,
        };
        let event_deadline = 24_390_000u64;
        assert_eq!(event_deadline - context.now_local_ns, 23_390_000);
        let error = context.require_fresh_capture(58_075_118).unwrap_err();
        let expired = error.downcast_ref::<AtlasSelectionUnavailable>().unwrap();
        assert_eq!(expired.age_ns, 41_924_882);
        assert_eq!(expired.max_age_ns, 33_333_333);
        assert!(context.require_fresh_capture(66_666_667).is_err());
    }
}
