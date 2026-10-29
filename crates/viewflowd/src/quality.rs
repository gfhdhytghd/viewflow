//! Timer-driven Linux quality policy; wire geometry and input are untouched.
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU64, Ordering};
use viewflow_core::{NetworkSample, QualityMode, QualityTarget, RateControlConfig, RateController};

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SourceQualityMode {
    #[default]
    Auto,
    HighQuality,
    SaveBandwidth,
}
impl SourceQualityMode {
    pub fn core(self) -> QualityMode {
        match self {
            Self::Auto => QualityMode::Auto,
            Self::HighQuality => QualityMode::HighQuality,
            Self::SaveBandwidth => QualityMode::SaveBandwidth,
        }
    }
    pub fn initial_kbps(self) -> u32 {
        match self {
            Self::HighQuality => 0,
            Self::Auto => AUTO_CEILING_KBPS,
            Self::SaveBandwidth => {
                RateControlConfig::new(self.core(), AUTO_CEILING_KBPS, 60).save_bandwidth_kbps
            }
        }
    }
}
// Per encoder; each activity lane can carry a full canvas. See measured W2 evidence.
pub const AUTO_CEILING_KBPS: u32 = 900_000;

pub struct QualityTelemetry {
    origin: std::time::Instant,
    sending: [AtomicU64; 2],
    dropped: AtomicU64,
    epoch: AtomicU64,
    congested: AtomicU64,
    fec_budgeted: AtomicU64,
    network_failed: AtomicU64,
    fec: [AtomicU64; 2],
    fec_updated: [AtomicU64; 2],
}
impl Default for QualityTelemetry {
    fn default() -> Self {
        Self {
            origin: std::time::Instant::now(),
            sending: [AtomicU64::new(0), AtomicU64::new(0)],
            dropped: AtomicU64::new(0),
            epoch: AtomicU64::new(0),
            congested: AtomicU64::new(0),
            fec_budgeted: AtomicU64::new(1),
            network_failed: AtomicU64::new(0),
            fec: [AtomicU64::new(0), AtomicU64::new(0)],
            fec_updated: [AtomicU64::new(0), AtomicU64::new(0)],
        }
    }
}
impl QualityTelemetry {
    pub fn network_failed(&self, total: u64) { self.network_failed.fetch_max(total, Ordering::Relaxed); }
    pub fn fec_suspended(&self) -> bool { self.congested.load(Ordering::Relaxed) != 0 || self.fec_budgeted.load(Ordering::Relaxed) == 0 }
    pub fn fec_overhead(&self, lane: usize, data: usize, parity: usize) {
        self.fec[lane].store((parity as u64 * 1000).div_ceil(data.max(1) as u64), Ordering::Relaxed);
        self.fec_updated[lane].store(self.now_us(), Ordering::Relaxed);
    }

    fn fec_ratio(&self) -> u64 {
        let now = self.now_us();
        self.fec.iter().zip(&self.fec_updated)
            .filter(|(_, updated)| now.saturating_sub(updated.load(Ordering::Relaxed)) <= 5_000_000)
            .map(|(ratio, _)| ratio.load(Ordering::Relaxed)).max().unwrap_or(0)
    }
    pub fn begin(&self, lane: usize) {
        self.epoch.fetch_add(1, Ordering::Relaxed);
        self.sending[lane].store(self.now_us().saturating_add(1), Ordering::Relaxed);
    }
    /// End original media enqueue, before waiting for repair or disposition.
    pub fn enqueued(&self, lane: usize) {
        self.sending[lane].store(0, Ordering::Relaxed);
    }
    pub fn finish(&self, lane: usize, dropped: bool) {
        self.enqueued(lane);
        if dropped {
            self.dropped.fetch_add(1, Ordering::Relaxed);
        }
    }
    fn now_us(&self) -> u64 {
        self.origin.elapsed().as_micros().min(u128::from(u64::MAX)) as u64
    }
    pub fn observe(&self) -> (u64, u64) {
        let now = self.now_us();
        let age = self
            .sending
            .iter()
            .map(|v| v.load(Ordering::Relaxed))
            .filter(|v| *v != 0)
            .map(|v| now.saturating_sub(v - 1))
            .max()
            .unwrap_or(0);
        (age, self.dropped.load(Ordering::Relaxed))
    }
}

/// Confirmed incomplete media needs a burst-recovery budget even if kernel
/// drops keep RTT flat. Presentation/input rejection never feeds this counter.
struct FecRecoveryBudget {
    ceiling: f64,
    previous_failed: u64,
    last_failure_us: u64,
    updated_us: u64,
}
impl Default for FecRecoveryBudget {
    fn default() -> Self { Self { ceiling: f64::from(AUTO_CEILING_KBPS), previous_failed: 0, last_failure_us: 0, updated_us: 0 } }
}
impl FecRecoveryBudget {
    fn update(&mut self, now_us: u64, failed: u64, healthy: bool) -> u32 {
        let failures = failed.saturating_sub(self.previous_failed);
        if failures > 0 {
            // Same heavy-loss multiplier as the rate controller; once per
            // confirmed failed frame, not repeatedly for one old generation.
            self.ceiling = (self.ceiling * 0.7_f64.powi(failures.min(32) as i32)).max(2000.0);
            self.last_failure_us = now_us;
        } else if healthy && now_us.saturating_sub(self.last_failure_us) >= 5_000_000 {
            let elapsed = now_us.saturating_sub(self.updated_us).min(1_000_000) as f64 / 1_000_000.0;
            self.ceiling = (self.ceiling * (1.0 + 0.3 * elapsed)).min(f64::from(AUTO_CEILING_KBPS));
        }
        self.previous_failed = failed;
        self.updated_us = now_us;
        self.ceiling as u32
    }
}

pub struct QualitySampler {
    controller: RateController,
    previous: (u64, u64, u64),
    meter: viewflow_core::SendRateMeter,
    send_kbps: u32,
    backlog_epoch: u64,
    send_millifps: u32,
    send_rate_backlogged: bool,
    congested: bool,
    recovery_healthy: bool,
}
impl QualitySampler {
    pub fn new(mode: SourceQualityMode, fps: u32, lost: u64, sent: u64) -> Self {
        Self {
            controller: RateController::new(RateControlConfig::new(
                mode.core(),
                AUTO_CEILING_KBPS,
                fps,
            )),
            previous: (lost, sent, 0),
            meter: viewflow_core::SendRateMeter::default(),
            send_kbps: 0,
            backlog_epoch: 0,
            send_millifps: 0,
            send_rate_backlogged: false,
            congested: false,
            recovery_healthy: false,
        }
    }
    /// Cumulative bytes sent on the connection; feeds the next sample.
    pub fn record_sent_bytes(&mut self, now_us: u64, total_bytes: u64) {
        self.send_kbps = self.meter.update(now_us, total_bytes);
    }
    pub fn sample(
        &mut self,
        now_us: u64,
        rtt_us: u64,
        lost: u64,
        sent: u64,
        queue_age_us: u64,
        dropped: u64,
    ) -> QualityTarget {
        let sample = NetworkSample {
            now_us,
            rtt_us,
            lost_packets: lost.saturating_sub(self.previous.0),
            sent_packets: sent.saturating_sub(self.previous.1),
            queue_age_us,
            backlog_epoch: self.backlog_epoch,
            send_millifps: self.send_millifps,
            send_rate_backlogged: self.send_rate_backlogged,
            frames_dropped: dropped.saturating_sub(self.previous.2),
            send_kbps: std::mem::take(&mut self.send_kbps),
        };
        self.previous = (lost, sent, dropped);
        let mut target = self.controller.on_sample(sample);
        self.congested = self.controller.is_congested(&sample);
        self.recovery_healthy = self.controller.can_increase_quality(&sample);
        if self.controller.config().mode == QualityMode::HighQuality || target.max_fps == 60 {
            target.max_fps = self.controller.config().max_fps;
        }
        target.scale_permille = 1000; // native tile mappings currently require unscaled pixels
        target
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn confirmed_network_failure_budget_cuts_once_then_recovers_without_an_exit() {
        let mut budget = FecRecoveryBudget::default();
        assert_eq!(budget.update(200_000, 0, true), AUTO_CEILING_KBPS);
        let first = budget.update(400_000, 1, true);
        assert_eq!(first, 630_000);
        assert_eq!(budget.update(600_000, 1, true), first);
        assert_eq!(budget.update(800_000, 2, true), 441_000);
        assert_eq!(budget.update(5_000_000, 2, true), 441_000);
        assert_eq!(budget.update(6_000_000, 2, false), 441_000);
        assert!(budget.update(6_200_000, 2, true) > 441_000);
        assert_eq!(budget.update(7_000_000, 1000, true), 2000);
        for second in 8..80 { budget.update(second * 1_000_000, 1000, true); }
        assert_eq!(budget.update(80_000_000, 1000, true), AUTO_CEILING_KBPS);
    }

    #[test]
    fn fec_budget_counts_tiny_shards_and_expires_idle_lane_overhead() {
        let telemetry = QualityTelemetry { origin: std::time::Instant::now() - std::time::Duration::from_secs(10), ..QualityTelemetry::default() };
        telemetry.fec_overhead(1, 1, 76);
        assert_eq!(telemetry.fec_ratio(), 76_000); // Includes headers; never clamp to a nominal percentage.
        telemetry.fec_overhead(0, 1000, 101);
        assert_eq!(telemetry.fec_ratio(), 76_000);
        telemetry.fec_updated[1].store(0, Ordering::Relaxed);
        assert_eq!(telemetry.fec_ratio(), 101);
        telemetry.fec_overhead(0, 1000, 0);
        assert_eq!(telemetry.fec_ratio(), 0);
    }

    #[test]
    fn stable_rtt_service_backlog_suspends_parity_but_feedback_wait_does_not() {
        let mut sampler = QualitySampler::new(SourceQualityMode::Auto, 60, 0, 0);
        sampler.backlog_epoch = 1;
        sampler.send_millifps = 14_000;
        sampler.send_rate_backlogged = true;
        sampler.sample(200_000, 20_000, 0, 1000, 80_000, 0);
        assert!(sampler.congested);
        sampler.sample(400_000, 20_000, 0, 2000, 0, 0);
        assert!(!sampler.congested);
    }

    #[test]
    fn recovery_wait_is_not_send_backlog() {
        let telemetry = QualityTelemetry {
            origin: std::time::Instant::now() - std::time::Duration::from_secs(1),
            ..QualityTelemetry::default()
        };
        // Simulate original enqueue stalled for 100ms, then waiting for NACK
        // repair/disposition for the same frame. Only the first is backlog.
        telemetry.sending[0].store(900_001, Ordering::Relaxed);
        assert!(telemetry.observe().0 >= 100_000);
        telemetry.enqueued(0);
        assert_eq!(telemetry.observe(), (0, 0));
        telemetry.begin(1);
        telemetry.enqueued(1);
        telemetry.finish(0, true);
        assert_eq!(telemetry.observe(), (0, 1));
    }

    #[test]
    fn config_modes_are_strict_and_default_auto() {
        assert_eq!(
            serde_json::from_str::<SourceQualityMode>("\"auto\"").unwrap(),
            SourceQualityMode::Auto
        );
        assert_eq!(
            serde_json::from_str::<SourceQualityMode>("\"high_quality\"")
                .unwrap()
                .initial_kbps(),
            0
        );
        assert_eq!(
            serde_json::from_str::<SourceQualityMode>("\"save_bandwidth\"")
                .unwrap()
                .initial_kbps(),
            20_000
        );
        assert!(serde_json::from_str::<SourceQualityMode>("\"typo\"").is_err());
    }
    #[test]
    fn deltas_do_not_repeat_loss_and_counter_reset_is_safe() {
        let mut s = QualitySampler::new(SourceQualityMode::Auto, 60, 0, 0);
        let first = s.sample(200_000, 1000, 100, 1000, 0, 0);
        let second = s.sample(400_000, 1000, 100, 2000, 0, 0);
        assert_eq!(first.kbps, second.kbps);
        assert_eq!(s.sample(600_000, 1000, 0, 0, 0, 0).scale_permille, 1000);
    }
    #[test]
    fn high_quality_ignores_congestion_and_retains_nominal_fps() {
        let mut s = QualitySampler::new(SourceQualityMode::HighQuality, 60, 0, 0);
        for t in 1..100 {
            assert_eq!(
                s.sample(t * 200_000, 100_000, t * 100, t * 100, 1_000_000, t)
                    .kbps,
                AUTO_CEILING_KBPS
            );
        }
    }
}

/// Samples independently of an in-flight encode/feedback wait. The owner only
/// reads the latest target at its timer boundary; no per-frame locks are added.
pub struct QualityMonitor {
    target: std::sync::Arc<AtomicU64>,
    task: tokio::task::JoinHandle<()>,
}
fn pack(target: QualityTarget) -> u64 {
    u64::from(target.kbps) | (u64::from(target.max_fps) << 32)
}
impl QualityMonitor {
    pub fn start(
        connection: quinn::Connection,
        telemetry: std::sync::Arc<QualityTelemetry>,
        mode: SourceQualityMode,
        fps: u32,
        label: &'static str,
    ) -> Self {
        telemetry.fec_budgeted.store(u64::from(mode != SourceQualityMode::HighQuality), Ordering::Relaxed);
        let stats = connection.stats();
        let mut sampler =
            QualitySampler::new(mode, fps, stats.path.lost_packets, stats.path.sent_packets);
        let initial = sampler.sample(0, 0, stats.path.lost_packets, stats.path.sent_packets, 0, 0);
        let target = std::sync::Arc::new(AtomicU64::new(pack(initial)));
        let output = target.clone();
        let initial_buffer_space = connection.datagram_send_buffer_space();
        let task = tokio::spawn(async move {
            let origin = tokio::time::Instant::now();
            // Observe buffer peaks independently of frame timing. Sampling
            // only every 200ms can alias with stop-and-wait and always see an
            // empty buffer even while each original frame drains for 100ms.
            let mut timer = tokio::time::interval(std::time::Duration::from_millis(10));
            timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            // At startup the media queue is empty. Track its high-water free
            // space as well, for callers starting after a first enqueue.
            let mut buffer_capacity = initial_buffer_space;
            let mut previous_bytes = connection.stats().udp_tx.bytes;
            let mut previous_epoch = 0;
            let mut peak_buffered = 0;
            let mut peak_dispatch_age = 0;
            let mut sampled = false;
            let mut interval_backlogged = true;
            let mut previous_us = 0_u64;
            let mut recovery_budget = FecRecoveryBudget::default();
            let mut previous = None;
            let mut summary = origin;
            loop {
                timer.tick().await;
                if connection.close_reason().is_some() {
                    break;
                }
                let free = connection.datagram_send_buffer_space();
                buffer_capacity = buffer_capacity.max(free);
                if free == buffer_capacity {
                    interval_backlogged = false;
                }
                peak_buffered = peak_buffered.max(buffer_capacity.saturating_sub(free) as u64);
                let (dispatch_age, dropped) = telemetry.observe();
                peak_dispatch_age = peak_dispatch_age.max(dispatch_age);
                let now_us = origin.elapsed().as_micros() as u64;
                if sampled && now_us.saturating_sub(previous_us) < 200_000 {
                    continue;
                }
                sampled = true;
                let stats = connection.stats();
                sampler.record_sent_bytes(now_us, stats.udp_tx.bytes);
                sampler.send_rate_backlogged = interval_backlogged;
                interval_backlogged = true;
                let buffered = std::mem::take(&mut peak_buffered);
                let dispatch_age = std::mem::take(&mut peak_dispatch_age);
                let sent_bytes = stats.udp_tx.bytes.saturating_sub(previous_bytes);
                let interval = now_us.saturating_sub(previous_us);
                // Estimated drain time of real queued bytes, not frame ACK age.
                let drain_us = if buffered == 0 {
                    0
                } else if sent_bytes == 0 {
                    interval
                } else {
                    buffered.saturating_mul(interval) / sent_bytes
                };
                let age = dispatch_age.max(drain_us);
                sampler.backlog_epoch = telemetry.epoch.load(Ordering::Relaxed);
                let frames = sampler.backlog_epoch.saturating_sub(previous_epoch);
                sampler.send_millifps =
                    u32::try_from(frames.saturating_mul(1_000_000_000) / interval.max(1))
                        .unwrap_or(u32::MAX);
                if frames == 0 {
                    sampler.send_kbps = 0;
                }
                previous_epoch = sampler.backlog_epoch;
                previous_us = now_us;
                previous_bytes = stats.udp_tx.bytes;
                let mut next = sampler.sample(
                    now_us,
                    stats.path.rtt.as_micros().min(u128::from(u64::MAX)) as u64,
                    stats.path.lost_packets,
                    stats.path.sent_packets,
                    age,
                    dropped,
                );
                telemetry.congested.store(u64::from(sampler.congested), Ordering::Relaxed);
                let overhead = telemetry.fec_ratio();
                if mode != SourceQualityMode::HighQuality {
                    next.kbps = next.kbps.min(recovery_budget.update(now_us, telemetry.network_failed.load(Ordering::Relaxed), sampler.recovery_healthy));
                }
                next.kbps = (u64::from(next.kbps) * 1000 / (1000 + overhead)) as u32;
                output.store(pack(next), Ordering::Relaxed);
                let now = tokio::time::Instant::now();
                if previous != Some(next) || now >= summary {
                    eprintln!(
                        "{label}-quality mode={mode:?} kbps={} fps={} scale=1000 rtt_us={} queue_us={age} dispatch_us={dispatch_age} buffered={buffered} rate_busy={} dropped={dropped} changed={} fec_permille={overhead} congested={}",
                        next.kbps,
                        next.max_fps,
                        stats.path.rtt.as_micros(),
                        sampler.send_rate_backlogged,
                        previous != Some(next), sampler.congested
                    );
                    summary = now + std::time::Duration::from_secs(5);
                }
                previous = Some(next);
            }
        });
        Self { target, task }
    }
    pub fn target(&self) -> QualityTarget {
        let packed = self.target.load(Ordering::Relaxed);
        QualityTarget {
            kbps: packed as u32,
            max_fps: (packed >> 32) as u32,
            scale_permille: 1000,
        }
    }
}
impl Drop for QualityMonitor {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Apply a changed bitrate atomically with respect to the owner: failed native
/// updates leave the remembered setting unchanged and can be retried later.
pub(crate) fn apply_bitrate(
    current: &mut u32,
    next: u32,
    mut apply: impl FnMut(u32) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        next <= 1_000_000,
        "bitrate exceeds native rate-control range"
    );
    if *current != next {
        apply(next)?;
        *current = next;
    }
    Ok(())
}

#[cfg(test)]
mod application_tests {
    use super::*;
    #[test]
    fn mock_encoder_applies_changes_once_and_retains_setting_on_failure() {
        let mut calls = Vec::new();
        let mut current = 900_000;
        apply_bitrate(&mut current, 900_000, |rate| {
            calls.push(rate);
            Ok(())
        })
        .unwrap();
        assert!(calls.is_empty());
        assert!(
            apply_bitrate(&mut current, 10_000, |_| anyhow::bail!(
                "temporarily unavailable"
            ))
            .is_err()
        );
        assert_eq!(current, 900_000);
        apply_bitrate(&mut current, 10_000, |rate| {
            calls.push(rate);
            Ok(())
        })
        .unwrap();
        assert_eq!(current, 10_000);
        assert_eq!(calls, [10_000]);
    }
}
