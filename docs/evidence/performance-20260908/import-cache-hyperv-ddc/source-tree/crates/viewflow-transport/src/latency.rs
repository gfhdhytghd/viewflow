use std::collections::VecDeque;

use crate::ClockEstimate;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LatencyClass {
    StandardMedia,
    ExactBlur,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LatencyStats {
    pub samples: usize,
    pub p50_ns: u64,
    pub p95_ns: u64,
    pub p99_ns: u64,
    pub maximum_ns: u64,
    pub standard_budget_misses: usize,
}

#[derive(Debug)]
pub struct LatencyWindow {
    capacity: usize,
    samples: VecDeque<(LatencyClass, u64, bool)>,
}

impl LatencyWindow {
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            samples: VecDeque::with_capacity(capacity.max(1)),
        }
    }

    /// Records a peer event after converting its timestamp to the local clock.
    ///
    /// Returns the conservative measured latency. Standard media is compared
    /// against two target refresh periods; exact blur is measured separately.
    pub fn record(
        &mut self,
        class: LatencyClass,
        remote_submitted_ns: u64,
        local_presented_ns: u64,
        clock: ClockEstimate,
        target_refresh_millihz: u32,
    ) -> u64 {
        let latency_ns = clock.age_upper_bound_ns(remote_submitted_ns, local_presented_ns);
        let deadline_ns = 2_000_000_000_000_u64 / u64::from(target_refresh_millihz.max(1));
        let missed = class == LatencyClass::StandardMedia && latency_ns > deadline_ns;
        if self.samples.len() == self.capacity {
            self.samples.pop_front();
        }
        self.samples.push_back((class, latency_ns, missed));
        latency_ns
    }

    #[must_use]
    pub fn stats(&self, class: LatencyClass) -> LatencyStats {
        let mut values = self
            .samples
            .iter()
            .filter_map(|(candidate, latency, _)| (*candidate == class).then_some(*latency))
            .collect::<Vec<_>>();
        if values.is_empty() {
            return LatencyStats::default();
        }
        values.sort_unstable();
        let standard_budget_misses = self
            .samples
            .iter()
            .filter(|(candidate, _, missed)| *candidate == class && *missed)
            .count();
        LatencyStats {
            samples: values.len(),
            p50_ns: percentile(&values, 50),
            p95_ns: percentile(&values, 95),
            p99_ns: percentile(&values, 99),
            maximum_ns: values.last().copied().unwrap_or_default(),
            standard_budget_misses,
        }
    }

    /// Returns true only when at least one standard-media sample exists and
    /// every retained sample was presented within two refresh periods.
    #[must_use]
    pub fn standard_media_within_budget(&self) -> bool {
        let stats = self.stats(LatencyClass::StandardMedia);
        stats.samples > 0 && stats.standard_budget_misses == 0
    }
}

fn percentile(sorted: &[u64], percentage: usize) -> u64 {
    let rank = sorted.len().saturating_mul(percentage).div_ceil(100);
    sorted[rank.saturating_sub(1).min(sorted.len() - 1)]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clock() -> ClockEstimate {
        ClockEstimate {
            remote_offset_ns: 5_000_000,
            network_round_trip_ns: 2_000_000,
            uncertainty_ns: 1_000_000,
        }
    }

    #[test]
    fn reports_nearest_rank_percentiles_and_two_frame_misses() {
        let mut window = LatencyWindow::new(100);
        for latency_ms in 1_u64..=100 {
            // remote 5 ms ahead maps back to zero; uncertainty adds 1 ms.
            window.record(
                LatencyClass::StandardMedia,
                5_000_000,
                (latency_ms - 1) * 1_000_000,
                clock(),
                60_000,
            );
        }
        let stats = window.stats(LatencyClass::StandardMedia);
        assert_eq!(stats.samples, 100);
        assert_eq!(stats.p50_ns, 50_000_000);
        assert_eq!(stats.p95_ns, 95_000_000);
        assert_eq!(stats.p99_ns, 99_000_000);
        assert_eq!(stats.maximum_ns, 100_000_000);
        assert_eq!(stats.standard_budget_misses, 67);
    }

    #[test]
    fn exact_blur_is_measured_but_excluded_from_standard_budget() {
        let mut window = LatencyWindow::new(2);
        window.record(
            LatencyClass::ExactBlur,
            5_000_000,
            100_000_000,
            clock(),
            60_000,
        );
        assert_eq!(
            window.stats(LatencyClass::ExactBlur).standard_budget_misses,
            0
        );
        assert_eq!(window.stats(LatencyClass::StandardMedia).samples, 0);
    }

    #[test]
    fn capacity_evicts_oldest_samples() {
        let mut window = LatencyWindow::new(2);
        for presented in [1_000_000, 2_000_000, 3_000_000] {
            window.record(
                LatencyClass::StandardMedia,
                5_000_000,
                presented,
                clock(),
                60_000,
            );
        }
        let stats = window.stats(LatencyClass::StandardMedia);
        assert_eq!(stats.samples, 2);
        assert_eq!(stats.maximum_ns, 4_000_000);
    }

    #[test]
    fn standard_media_budget_is_an_absolute_retained_window_limit() {
        let mut window = LatencyWindow::new(2);
        assert!(!window.standard_media_within_budget());

        window.record(
            LatencyClass::StandardMedia,
            5_000_000,
            31_000_000,
            clock(),
            60_000,
        );
        assert!(window.standard_media_within_budget());

        window.record(
            LatencyClass::StandardMedia,
            5_000_000,
            34_000_000,
            clock(),
            60_000,
        );
        assert!(!window.standard_media_within_budget());
    }
}
