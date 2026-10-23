use std::{error::Error, fmt};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClockSyncError {
    LocalClockWentBackwards,
    RemoteClockWentBackwards,
    InvalidRoundTrip,
    OffsetOutOfRange,
}

impl fmt::Display for ClockSyncError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "clock synchronization error: {self:?}")
    }
}

impl Error for ClockSyncError {}

/// One NTP-style estimate between a local monotonic clock and a peer clock.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ClockEstimate {
    /// Remote clock minus local clock, in nanoseconds.
    pub remote_offset_ns: i64,
    /// Network-only round trip after removing time spent at the responder.
    pub network_round_trip_ns: u64,
    /// Maximum one-way error under the symmetric-path assumption.
    pub uncertainty_ns: u64,
}

impl ClockEstimate {
    /// Computes an estimate from local `t0`/`t3` and remote `t1`/`t2`.
    ///
    /// # Errors
    ///
    /// Rejects clocks moving backwards, a responder interval larger than the
    /// complete exchange, and offsets that cannot be represented as `i64`.
    pub fn from_exchange(
        local_t0_ns: u64,
        remote_t1_ns: u64,
        remote_t2_ns: u64,
        local_t3_ns: u64,
    ) -> Result<Self, ClockSyncError> {
        let local_elapsed = local_t3_ns
            .checked_sub(local_t0_ns)
            .ok_or(ClockSyncError::LocalClockWentBackwards)?;
        let remote_elapsed = remote_t2_ns
            .checked_sub(remote_t1_ns)
            .ok_or(ClockSyncError::RemoteClockWentBackwards)?;
        let network_round_trip_ns = local_elapsed
            .checked_sub(remote_elapsed)
            .ok_or(ClockSyncError::InvalidRoundTrip)?;
        let first_leg = i128::from(remote_t1_ns) - i128::from(local_t0_ns);
        let second_leg = i128::from(remote_t2_ns) - i128::from(local_t3_ns);
        let remote_offset_ns = i64::try_from((first_leg + second_leg) / 2)
            .map_err(|_| ClockSyncError::OffsetOutOfRange)?;

        Ok(Self {
            remote_offset_ns,
            network_round_trip_ns,
            uncertainty_ns: network_round_trip_ns.div_ceil(2),
        })
    }

    /// Express this estimate from the other endpoint's perspective.
    /// RTT and uncertainty are symmetric; the signed clock offset is not.
    ///
    /// # Errors
    /// Rejects the single offset whose negation cannot fit in `i64`.
    pub fn inverse(self) -> Result<Self, ClockSyncError> {
        Ok(Self {
            remote_offset_ns: self
                .remote_offset_ns
                .checked_neg()
                .ok_or(ClockSyncError::OffsetOutOfRange)?,
            ..self
        })
    }

    #[must_use]
    pub fn remote_to_local_ns(self, remote_ns: u64) -> u64 {
        let local = i128::from(remote_ns) - i128::from(self.remote_offset_ns);
        if local <= 0 {
            0
        } else {
            u64::try_from(local).unwrap_or(u64::MAX)
        }
    }

    /// Returns a conservative event age including clock/path uncertainty.
    #[must_use]
    pub fn age_upper_bound_ns(self, remote_event_ns: u64, local_now_ns: u64) -> u64 {
        local_now_ns
            .saturating_add(self.uncertainty_ns)
            .saturating_sub(self.remote_to_local_ns(remote_event_ns))
    }
}

/// Keeps the lowest-RTT sample, which is least affected by queueing delay.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ClockDiscipline {
    best: Option<ClockEstimate>,
}

impl ClockDiscipline {
    #[must_use]
    pub fn estimate(self) -> Option<ClockEstimate> {
        self.best
    }

    pub fn update(&mut self, sample: ClockEstimate) -> bool {
        if self
            .best
            .is_some_and(|current| current.network_round_trip_ns <= sample.network_round_trip_ns)
        {
            return false;
        }
        self.best = Some(sample);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_remote_clock_and_excludes_responder_time_from_rtt() {
        // Remote clock is 5 ms ahead. Network legs are 2 ms and 4 ms, while
        // the responder spends 1 ms processing the probe.
        let estimate =
            ClockEstimate::from_exchange(10_000_000, 17_000_000, 18_000_000, 17_000_000).unwrap();
        assert_eq!(estimate.remote_offset_ns, 4_000_000);
        assert_eq!(estimate.network_round_trip_ns, 6_000_000);
        assert_eq!(estimate.uncertainty_ns, 3_000_000);
        assert_eq!(estimate.remote_to_local_ns(24_000_000), 20_000_000);
        assert_eq!(
            estimate.age_upper_bound_ns(24_000_000, 22_000_000),
            5_000_000
        );
    }

    #[test]
    fn discipline_keeps_the_least_queued_sample() {
        let slow = ClockEstimate::from_exchange(0, 8, 9, 11).unwrap();
        let fast = ClockEstimate::from_exchange(20, 27, 28, 25).unwrap();
        let mut discipline = ClockDiscipline::default();
        assert!(discipline.update(slow));
        assert!(discipline.update(fast));
        assert!(!discipline.update(slow));
        assert_eq!(discipline.estimate(), Some(fast));
    }

    #[test]
    fn inverse_preserves_event_age_for_both_offset_signs() {
        for offset in [-4_000_000_i64, 4_000_000] {
            let a = ClockEstimate {
                remote_offset_ns: offset,
                network_round_trip_ns: 200,
                uncertainty_ns: 100,
            };
            let b = a.inverse().unwrap();
            let a_event = 20_000_000_u64;
            let b_event = u64::try_from(i128::from(a_event) + i128::from(offset)).unwrap();
            assert_eq!(a.remote_to_local_ns(b_event), a_event);
            assert_eq!(b.remote_to_local_ns(a_event), b_event);
            assert_eq!(b.age_upper_bound_ns(a_event, b_event + 7), 107);
            assert_eq!(b.inverse().unwrap(), a);
        }
        assert_eq!(
            ClockEstimate {
                remote_offset_ns: i64::MIN,
                network_round_trip_ns: 0,
                uncertainty_ns: 0,
            }
            .inverse(),
            Err(ClockSyncError::OffsetOutOfRange)
        );
    }

    #[test]
    fn rejects_impossible_exchange_ordering() {
        assert_eq!(
            ClockEstimate::from_exchange(10, 20, 21, 9),
            Err(ClockSyncError::LocalClockWentBackwards)
        );
        assert_eq!(
            ClockEstimate::from_exchange(10, 22, 20, 30),
            Err(ClockSyncError::RemoteClockWentBackwards)
        );
        assert_eq!(
            ClockEstimate::from_exchange(10, 20, 40, 20),
            Err(ClockSyncError::InvalidRoundTrip)
        );
    }
}
