//! Keep useful clock evidence through a compatible high-RTT probe without
//! renewing its measurement time or relaxing any input deadline checks.
use crate::input_runtime::{
    CLOCK_DRIFT_PPM, ClockSnapshot, MAX_CLOCK_SAMPLE_AGE_NS, MAX_CLOCK_UNCERTAINTY_NS,
};
use anyhow::{Result, ensure};

#[derive(Default)]
pub(crate) struct ClockRetention {
    active: Option<ClockSnapshot>,
    last_sample: Option<ClockSnapshot>,
    last_remote_t2: Option<u64>,
}

fn uncertainty_at(sample: ClockSnapshot, now: u64) -> Result<u128> {
    let age = now
        .checked_sub(sample.measured_at_local_ns)
        .ok_or_else(|| anyhow::anyhow!("clock sample measurement went backwards"))?;
    Ok(u128::from(sample.estimate.uncertainty_ns)
        + (u128::from(age) * u128::from(CLOCK_DRIFT_PPM)).div_ceil(1_000_000))
}

fn usable_at(sample: ClockSnapshot, now: u64) -> Result<bool> {
    let uncertainty = uncertainty_at(sample, now)?;
    Ok(now - sample.measured_at_local_ns <= MAX_CLOCK_SAMPLE_AGE_NS
        && uncertainty <= u128::from(MAX_CLOCK_UNCERTAINTY_NS))
}

fn compatible(old: ClockSnapshot, candidate: ClockSnapshot) -> Result<bool> {
    let radius = uncertainty_at(old, candidate.measured_at_local_ns)?
        + u128::from(candidate.estimate.uncertainty_ns);
    let difference = (i128::from(candidate.estimate.remote_offset_ns)
        - i128::from(old.estimate.remote_offset_ns))
    .unsigned_abs();
    Ok(difference <= radius)
}

impl ClockRetention {
    /// Called only after the full four-timestamp exchange and probe identity
    /// have been validated. Cross-probe monotonicity is checked independently
    /// of which sample is retained, so broad RTT intervals cannot hide rollback.
    pub(crate) fn observe(
        &mut self,
        candidate: ClockSnapshot,
        local_t0: u64,
        remote_t1: u64,
        remote_t2: u64,
    ) -> Result<Option<ClockSnapshot>> {
        ensure!(
            candidate.measured_at_local_ns >= local_t0 && remote_t2 >= remote_t1,
            "clock exchange timestamp went backwards"
        );
        if let Some(last) = self.last_sample {
            ensure!(
                local_t0 >= last.measured_at_local_ns,
                "local clock went backwards between probes"
            );
            ensure!(
                remote_t1 >= self.last_remote_t2.expect("previous exchange timestamp"),
                "remote clock went backwards between probes"
            );
            ensure!(
                compatible(last, candidate)?,
                "clock probe offset intervals conflict"
            );
        }
        if let Some(active) = self.active {
            ensure!(
                compatible(active, candidate)?,
                "retained clock offset interval conflicts with probe"
            );
        }
        let active = if usable_at(candidate, candidate.measured_at_local_ns)? {
            Some(candidate)
        } else if let Some(old) = self.active {
            usable_at(old, candidate.measured_at_local_ns)?.then_some(old)
        } else {
            None
        };
        self.active = active;
        self.last_sample = Some(candidate);
        self.last_remote_t2 = Some(remote_t2);
        Ok(active)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample(at: u64, offset: i64, uncertainty: u64) -> ClockSnapshot {
        ClockSnapshot {
            estimate: viewflow_transport::ClockEstimate {
                remote_offset_ns: offset,
                uncertainty_ns: uncertainty,
                network_round_trip_ns: uncertainty.saturating_mul(2),
            },
            measured_at_local_ns: at,
        }
    }
    fn observe(guard: &mut ClockRetention, value: ClockSnapshot) -> Result<Option<ClockSnapshot>> {
        guard.observe(
            value,
            value.measured_at_local_ns,
            value.measured_at_local_ns,
            value.measured_at_local_ns,
        )
    }
    #[test]
    fn clock_retention_preserves_original_evidence_through_high_rtt() {
        let mut guard = ClockRetention::default();
        let old = sample(1_000_000_000, 100_000, 203_000);
        assert_eq!(observe(&mut guard, old).unwrap(), Some(old));
        for step in 1..=12 {
            let noisy = sample(
                old.measured_at_local_ns + step * 250_000_000,
                2_000_000,
                4_437_000,
            );
            assert_eq!(observe(&mut guard, noisy).unwrap(), Some(old));
        }
        assert_eq!(
            observe(
                &mut guard,
                sample(
                    old.measured_at_local_ns + MAX_CLOCK_SAMPLE_AGE_NS + 1,
                    2_000_000,
                    4_437_000
                )
            )
            .unwrap(),
            None
        );
        // A later good compatible probe establishes new evidence, without ever
        // having extended the old evidence's measured_at timestamp.
        let fresh = sample(4_250_000_000, 200_000, 100_000);
        assert_eq!(observe(&mut guard, fresh).unwrap(), Some(fresh));
    }
    #[test]
    fn clock_retention_effective_uncertainty_and_missing_evidence_fail_closed() {
        let mut guard = ClockRetention::default();
        let old = sample(1, 0, 3_500_000);
        assert_eq!(observe(&mut guard, old).unwrap(), Some(old));
        assert_eq!(
            observe(&mut guard, sample(1_000_000_001, 0, 4_437_000)).unwrap(),
            Some(old)
        );
        assert_eq!(
            observe(&mut guard, sample(1_000_000_002, 0, 4_437_000)).unwrap(),
            None
        );
        let mut empty = ClockRetention::default();
        assert_eq!(observe(&mut empty, sample(1, 0, 4_000_001)).unwrap(), None);
    }
    #[test]
    fn clock_retention_rejects_conflicting_offsets_and_cross_probe_rollback() {
        for candidate in [
            sample(1_000_000_100, 20_000_000, 4_437_000),
            sample(1_000_000_100, 20_000_000, 100),
        ] {
            let mut guard = ClockRetention::default();
            observe(&mut guard, sample(100, 0, 203_000)).unwrap();
            assert!(observe(&mut guard, candidate).is_err());
        }
        for (local_t0, remote_t1, remote_t2) in [(99, 200, 201), (100, 99, 201), (201, 200, 199)] {
            let mut guard = ClockRetention::default();
            observe(&mut guard, sample(100, 0, 203_000)).unwrap();
            assert!(
                guard
                    .observe(sample(200, 0, 4_437_000), local_t0, remote_t1, remote_t2)
                    .is_err()
            );
        }
    }
    #[test]
    fn clock_retention_noisy_probe_does_not_hide_rollback_or_interval_conflict() {
        let old = sample(100, 0, 203_000);
        let noisy = sample(200, 0, 4_437_000);
        let mut guard = ClockRetention::default();
        observe(&mut guard, old).unwrap();
        assert_eq!(observe(&mut guard, noisy).unwrap(), Some(old));
        assert!(
            guard
                .observe(sample(300, 0, 4_437_000), 300, 150, 300)
                .is_err()
        );
        // A broad last probe overlaps this jump; retained precise evidence
        // still contradicts it and must not be silently replaced.
        assert!(observe(&mut guard, sample(300, 4_000_000, 100)).is_err());
    }

    #[test]
    fn clock_retention_uses_wide_checked_interval_arithmetic() {
        assert!(!compatible(sample(1, i64::MIN, 0), sample(2, i64::MAX, 0)).unwrap());
        assert!(
            compatible(
                sample(0, i64::MIN, u64::MAX),
                sample(u64::MAX, i64::MAX, u64::MAX)
            )
            .unwrap()
        );
        assert!(uncertainty_at(sample(10, 0, 0), 9).is_err());
    }
}
