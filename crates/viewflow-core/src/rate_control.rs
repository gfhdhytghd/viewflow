//! Adaptive media quality for weak networks (see `docs/weak-network.md`, W2).
//!
//! The controller is pure: callers feed periodic network samples with their
//! own monotonic clock and apply the returned target to an encoder. It never
//! ends a session; the worst case is the lowest quality step.
//!
//! Wi-Fi drops packets without congestion, so a little loss with a flat delay
//! is left to selective retransmission instead of lowering quality. Rising
//! delay together with a real send backlog is treated as congestion. Long
//! backpressure with flat path delay instead fits a nominal frame budget to
//! service rate, leaving room for stop-and-wait feedback and repairs.

/// User-facing quality policy for one connection.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum QualityMode {
    /// Adapt between the configured floor and the full-quality ceiling.
    #[default]
    Auto,
    /// Never degrade; always the ceiling (today's fixed behaviour).
    HighQuality,
    /// Adapt, but under a lower ceiling to leave headroom on shared links.
    SaveBandwidth,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RateControlConfig {
    pub mode: QualityMode,
    /// Bitrate that reproduces today's fixed quality for this stream.
    pub max_kbps: u32,
    /// Lowest bitrate before frame rate and resolution are reduced.
    pub min_kbps: u32,
    /// Ceiling used by [`QualityMode::SaveBandwidth`].
    pub save_bandwidth_kbps: u32,
    /// Nominal stream frame rate.
    pub max_fps: u32,
}

impl RateControlConfig {
    #[must_use]
    pub fn new(mode: QualityMode, max_kbps: u32, max_fps: u32) -> Self {
        let max_kbps = max_kbps.max(1);
        Self {
            mode,
            max_kbps,
            min_kbps: (max_kbps / 20).clamp(1, 2_000),
            // An absolute cap: a fraction of a very high wired ceiling would
            // still be far more than a shared wireless link can carry.
            save_bandwidth_kbps: (max_kbps / 4).clamp(1, SAVE_BANDWIDTH_MAX_KBPS),
            max_fps: max_fps.max(1),
        }
    }

    fn ceiling_kbps(&self) -> u32 {
        match self.mode {
            QualityMode::SaveBandwidth => self.save_bandwidth_kbps.min(self.max_kbps),
            QualityMode::Auto | QualityMode::HighQuality => self.max_kbps,
        }
    }
}

/// One periodic observation, ideally every 100–250 ms.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct NetworkSample {
    /// Caller's monotonic clock in microseconds.
    pub now_us: u64,
    /// Smoothed path RTT (e.g. `quinn::ConnectionStats::path.rtt`).
    pub rtt_us: u64,
    /// Packets declared lost since the previous sample.
    pub lost_packets: u64,
    /// Packets sent since the previous sample.
    pub sent_packets: u64,
    /// Real send backlog delay; excludes receiver feedback and NACK recovery waits.
    pub queue_age_us: u64,
    /// Original-send generation (0 if unavailable). A pending old frame must
    /// not repeatedly reduce a target its encoder has not yet applied.
    pub backlog_epoch: u64,
    /// Frames the receiver dropped to a keyframe since the previous sample.
    pub frames_dropped: u64,
    /// Bytes actually sent over the interval, in kbit/s (0 = unknown). Under
    /// congestion this approximates the bottleneck, so a high ceiling can
    /// converge in one step instead of many multiplicative cuts.
    pub send_kbps: u32,
    /// Original frames begun during the send-rate interval, in millifps.
    /// Zero means unknown. Used to normalize application-limited Wi-Fi sends
    /// to the encoder's nominal frame clock rather than a stalled wall clock.
    pub send_millifps: u32,
    /// Every queue observation in this rate interval was backlogged. Otherwise
    /// the wall-clock rate includes idle feedback time, not just link service.
    pub send_rate_backlogged: bool,
}

/// What the encoder and capture should use now.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct QualityTarget {
    pub kbps: u32,
    pub max_fps: u32,
    /// Encode resolution relative to the source, in thousandths (1000 = full).
    pub scale_permille: u16,
}

// Degradation ladder beyond the bitrate floor. Each step is applied only
// after the bitrate has sat at its floor while still congested.
const FPS_STEPS: [u32; 3] = [60, 30, 20];
const SCALE_STEPS: [u16; 3] = [1000, 750, 500];

const SAVE_BANDWIDTH_MAX_KBPS: u32 = 20_000;
const DECREASE_HOLD_MIN_US: u64 = 200_000;
// After this long without congestion the ramp speeds up, so a link that has
// recovered does not take tens of seconds to return to full quality.
const FAST_RAMP_AFTER_US: u64 = 5_000_000;
const FAST_INCREASE_PER_SECOND: f64 = 0.30;
const INCREASE_HOLD_US: u64 = 1_000_000;
const INCREASE_PER_SECOND: f64 = 0.08;
const LADDER_DOWN_US: u64 = 2_000_000;
const LADDER_UP_US: u64 = 3_000_000;
const HEAVY_LOSS_RATIO: f64 = 0.10;

#[derive(Clone, Debug)]
pub struct RateController {
    config: RateControlConfig,
    kbps: f64,
    min_rtt_us: Option<u64>,
    rtt_window: [(u64, u64); 11],
    smoothed_rtt_us: u64,
    recent_rtt_us: [u64; 3],
    rtt_cursor: usize,
    last_sample_us: Option<u64>,
    last_decrease_us: Option<u64>,
    last_decrease_epoch: u64,
    /// Ladder index: 0 = full fps and scale; odd steps lower fps first.
    ladder: usize,
    congested_at_floor_since: Option<u64>,
    floor_epoch: u64,
    clear_since: Option<u64>,
}

impl RateController {
    #[must_use]
    pub fn new(config: RateControlConfig) -> Self {
        Self {
            config,
            kbps: f64::from(config.ceiling_kbps()),
            min_rtt_us: None,
            rtt_window: [(0, 0); 11],
            smoothed_rtt_us: 0,
            recent_rtt_us: [0; 3],
            rtt_cursor: 0,
            last_sample_us: None,
            last_decrease_us: None,
            last_decrease_epoch: 0,
            ladder: 0,
            congested_at_floor_since: None,
            floor_epoch: 0,
            clear_since: None,
        }
    }

    #[must_use]
    pub fn config(&self) -> RateControlConfig {
        self.config
    }

    /// Change the policy at runtime, e.g. from an app setting.
    pub fn set_mode(&mut self, mode: QualityMode) {
        self.config.mode = mode;
        self.kbps = self.kbps.min(f64::from(self.config.ceiling_kbps()));
        if mode == QualityMode::HighQuality {
            self.kbps = f64::from(self.config.max_kbps);
            self.ladder = 0;
        }
    }

    #[must_use]
    pub fn target(&self) -> QualityTarget {
        let (fps_step, scale_step) = ladder_steps(self.ladder);
        let full_fps = self.config.max_fps;
        QualityTarget {
            // `kbps` stays within u32 bounds by construction.
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            kbps: self.kbps.round() as u32,
            max_fps: FPS_STEPS[fps_step].min(full_fps).max(1),
            scale_permille: SCALE_STEPS[scale_step],
        }
    }

    /// Feed one observation and return the target to apply.
    pub fn on_sample(&mut self, sample: NetworkSample) -> QualityTarget {
        let elapsed_us = self
            .last_sample_us
            .map_or(0, |last| sample.now_us.saturating_sub(last));
        self.last_sample_us = Some(sample.now_us);
        if sample.rtt_us > 0 {
            // One fixed bucket per second, expiring at ten seconds. No heap
            // storage, including when the path baseline changes after warmup.
            let second = sample.now_us / 1_000_000;
            let bucket = &mut self.rtt_window[(second % 11) as usize];
            if bucket.1 == 0 || bucket.0 != second {
                *bucket = (second, sample.rtt_us);
            } else {
                bucket.1 = bucket.1.min(sample.rtt_us);
            }
            self.min_rtt_us = self
                .rtt_window
                .iter()
                .filter(|(at, rtt)| *rtt > 0 && second.saturating_sub(*at) < 10)
                .map(|(_, rtt)| *rtt)
                .min();
            if self.smoothed_rtt_us == 0 {
                self.recent_rtt_us.fill(sample.rtt_us);
            }
            self.recent_rtt_us[self.rtt_cursor] = sample.rtt_us;
            self.rtt_cursor = (self.rtt_cursor + 1) % 3;
            let mut recent = self.recent_rtt_us;
            recent.sort_unstable();
            self.smoothed_rtt_us = if self.smoothed_rtt_us == 0 {
                recent[1]
            } else {
                self.smoothed_rtt_us
                    .saturating_mul(3)
                    .saturating_add(recent[1])
                    / 4
            };
        }
        if self.config.mode == QualityMode::HighQuality {
            return self.target();
        }

        let congested = self.is_congested(&sample);
        let ceiling = f64::from(self.config.ceiling_kbps());
        let floor = f64::from(self.config.min_kbps.min(self.config.ceiling_kbps()));

        if congested {
            self.clear_since = None;
            let hold = self.min_rtt_us.map_or(DECREASE_HOLD_MIN_US, |rtt| {
                (2 * rtt).max(DECREASE_HOLD_MIN_US)
            });
            let may_decrease = self
                .last_decrease_us
                .is_none_or(|last| sample.now_us.saturating_sub(last) >= hold);
            if may_decrease
                && (sample.backlog_epoch == 0 || sample.backlog_epoch != self.last_decrease_epoch)
            {
                let factor = if loss_ratio(&sample) >= HEAVY_LOSS_RATIO {
                    0.7
                } else {
                    0.85
                };
                let path_congested = self.rtt_inflated()
                    && (sample.send_rate_backlogged
                        || self.large_network_delay()
                        || sample.backlog_epoch == 0);
                // With flat path delay, Cubic recovery can still back up the
                // application. Fit a nominal frame budget to measured service
                // rather than repeatedly multiplying quality down for loss.
                let mut next = if path_congested || sample.backlog_epoch == 0 {
                    self.kbps * factor
                } else {
                    self.kbps
                };
                if sample.send_kbps > 0 && sample.queue_age_us > 0 {
                    let mut capacity = f64::from(sample.send_kbps);
                    let application_limited = (!path_congested || !sample.send_rate_backlogged)
                        && sample.send_millifps > 0
                        && sample.send_millifps < self.config.max_fps.saturating_mul(1000);
                    let headroom = if application_limited {
                        capacity *= f64::from(self.config.max_fps) * 1000.0
                            / f64::from(sample.send_millifps);
                        // Leave service time for feedback and selective repair
                        // instead of filling an entire stop-and-wait cycle.
                        0.6
                    } else {
                        0.9
                    };
                    if application_limited || sample.send_rate_backlogged {
                        next = next.min(capacity * headroom);
                    }
                }
                self.kbps = next.max(floor);
                self.last_decrease_us = Some(sample.now_us);
                self.last_decrease_epoch = sample.backlog_epoch;
            }
            if self.kbps <= floor {
                if self.congested_at_floor_since.is_none() {
                    self.floor_epoch = sample.backlog_epoch;
                }
                let since = *self.congested_at_floor_since.get_or_insert(sample.now_us);
                if (sample.backlog_epoch == 0 || sample.backlog_epoch != self.floor_epoch)
                    && sample.now_us.saturating_sub(since) >= LADDER_DOWN_US
                    && self.ladder + 1 < ladder_len()
                {
                    self.ladder += 1;
                    self.congested_at_floor_since = Some(sample.now_us);
                    self.floor_epoch = sample.backlog_epoch;
                }
            } else {
                self.congested_at_floor_since = None;
            }
        } else {
            self.congested_at_floor_since = None;
            let since = *self.clear_since.get_or_insert(sample.now_us);
            if self.ladder > 0 {
                // Restore frame rate and resolution before raising bitrate.
                if sample.now_us.saturating_sub(since) >= LADDER_UP_US {
                    self.ladder -= 1;
                    self.clear_since = Some(sample.now_us);
                }
            } else if self.service_limited(&sample) {
                // An empty send buffer during feedback/repair wait does not
                // prove spare link capacity. Resume probing when original
                // frame service reaches 80% of the RTT-adjusted FPS step.
                self.clear_since = Some(sample.now_us);
            } else if self
                .last_decrease_us
                .is_none_or(|last| sample.now_us.saturating_sub(last) >= INCREASE_HOLD_US)
            {
                #[allow(clippy::cast_precision_loss)]
                let seconds = elapsed_us as f64 / 1_000_000.0;
                let rate = if sample.now_us.saturating_sub(since) >= FAST_RAMP_AFTER_US {
                    FAST_INCREASE_PER_SECOND
                } else {
                    INCREASE_PER_SECOND
                };
                self.kbps = (self.kbps * (1.0 + rate * seconds)).min(ceiling);
            }
        }
        self.kbps = self.kbps.clamp(floor, ceiling);
        self.target()
    }

    fn service_limited(&self, sample: &NetworkSample) -> bool {
        if sample.backlog_epoch == 0 {
            return false;
        }
        // Allow half a nominal frame for production/service plus the baseline
        // round trip. Requiring 60fps on a 20-40ms path freezes recovery;
        // allowing an entire extra frame hides a persistent serialization queue.
        let fps = self.target().max_fps;
        let period = 500_000 / u64::from(fps);
        let service = period.saturating_add(self.min_rtt_us.unwrap_or(0));
        let expected_millifps = (1_000_000_000 / service.max(1)).min(u64::from(fps) * 1000);
        u64::from(sample.send_millifps) < expected_millifps * 4 / 5
    }

    fn rtt_inflated(&self) -> bool {
        self.min_rtt_us
            .is_some_and(|min| self.smoothed_rtt_us > min.saturating_add((min / 2).max(15_000)))
    }

    fn large_network_delay(&self) -> bool {
        self.rtt_inflated()
            && self
                .min_rtt_us
                .is_some_and(|min| self.smoothed_rtt_us > min.saturating_add(60_000))
    }

    fn is_congested(&self, sample: &NetworkSample) -> bool {
        let rtt_inflated = self.rtt_inflated();
        let frame_period_us = 1_000_000 / u64::from(self.config.max_fps.max(1));
        // QUIC can queue while Cubic recovers random wireless loss too.
        // Moderate backlog needs path-delay corroboration; long backpressure
        // uses a service budget, without repeated loss-based cuts (above).
        // These are latency tuning targets, never session exit conditions.
        let network_queue = self.large_network_delay() && sample.send_millifps > 0;
        // Large sustained path delay also sees queues after Quinn (kernel/AP).
        // It only permits multiplicative cuts: no measured-rate clip without
        // a real local backlog, and no cuts while merely waiting for feedback.
        let service_backlog = if sample.backlog_epoch == 0 {
            sample.queue_age_us > 4 * frame_period_us
        } else {
            sample.queue_age_us > frame_period_us && self.service_limited(sample)
        };
        network_queue || (rtt_inflated && sample.queue_age_us > 0) || service_backlog
    }
}

/// Turns a cumulative sent-byte counter (e.g. `quinn` `udp_tx.bytes`) into
/// [`NetworkSample::send_kbps`] for the interval since the previous call.
#[derive(Clone, Copy, Debug, Default)]
pub struct SendRateMeter {
    last: Option<(u64, u64)>,
}

impl SendRateMeter {
    pub fn update(&mut self, now_us: u64, total_bytes: u64) -> u32 {
        let rate = self.last.map_or(0, |(at, bytes)| {
            let elapsed_us = now_us.saturating_sub(at);
            if elapsed_us == 0 {
                return 0;
            }
            // bytes * 8 / ms = kbit/s; saturates rather than wrapping.
            let kbps = total_bytes.saturating_sub(bytes).saturating_mul(8_000) / elapsed_us;
            u32::try_from(kbps).unwrap_or(u32::MAX)
        });
        self.last = Some((now_us, total_bytes));
        rate
    }
}

fn loss_ratio(sample: &NetworkSample) -> f64 {
    if sample.sent_packets == 0 {
        return 0.0;
    }
    #[allow(clippy::cast_precision_loss)]
    let ratio = sample.lost_packets as f64 / sample.sent_packets as f64;
    ratio
}

// Ladder order: (60fps,100%) → (30,100%) → (30,75%) → (20,75%) → (20,50%).
const LADDER: [(usize, usize); 5] = [(0, 0), (1, 0), (1, 1), (2, 1), (2, 2)];

fn ladder_len() -> usize {
    LADDER.len()
}

fn ladder_steps(index: usize) -> (usize, usize) {
    LADDER[index.min(LADDER.len() - 1)]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn controller(mode: QualityMode) -> RateController {
        RateController::new(RateControlConfig::new(mode, 40_000, 60))
    }

    fn sample(now_ms: u64, rtt_ms: u64, lost: u64, queue_ms: u64) -> NetworkSample {
        NetworkSample {
            now_us: now_ms * 1000,
            rtt_us: rtt_ms * 1000,
            lost_packets: lost,
            sent_packets: 1000,
            queue_age_us: queue_ms * 1000,
            backlog_epoch: 0,
            frames_dropped: 0,
            send_kbps: 0,
            send_millifps: 0,
            send_rate_backlogged: true,
        }
    }

    #[test]
    fn baseline_expires_after_path_change() {
        let mut rc = controller(QualityMode::Auto);
        rc.on_sample(sample(0, 1, 0, 0));
        for t in 1..=60 {
            assert_eq!(rc.on_sample(sample(t * 200, 25, 15, 0)).kbps, 40_000);
        }
        assert_eq!(rc.min_rtt_us, Some(25_000));
        assert!(!rc.is_congested(&sample(12_200, 25, 30, 20)));
    }

    #[test]
    fn jitter_needs_absolute_and_relative_smoothed_inflation() {
        for baseline in [1, 40] {
            let mut rc = controller(QualityMode::Auto);
            rc.on_sample(sample(0, baseline, 0, 0));
            for t in 1..50 {
                let rtt = baseline + if t % 2 == 0 { 12 } else { 0 };
                assert_eq!(rc.on_sample(sample(t * 200, rtt, 30, 20)).kbps, 40_000);
            }
            // One large outlier is not a sustained RTT increase.
            assert_eq!(
                rc.on_sample(sample(10_000, baseline + 45, 30, 20)).kbps,
                40_000
            );
        }
    }

    #[test]
    fn application_limited_rate_and_recovery_drops_do_not_cut_target_or_fps() {
        let mut rc = controller(QualityMode::Auto);
        rc.on_sample(sample(0, 1, 0, 0));
        for t in 1..200 {
            let mut waiting = sample(t * 200, 40, 150, 0);
            waiting.send_kbps = 500;
            waiting.frames_dropped = 1;
            assert_eq!(
                rc.on_sample(waiting),
                QualityTarget {
                    kbps: 40_000,
                    max_fps: 60,
                    scale_permille: 1000,
                }
            );
        }
    }

    #[test]
    fn wifi_cubic_backlog_with_flat_path_delay_does_not_lower_quality() {
        let mut rc = controller(QualityMode::Auto);
        rc.on_sample(sample(0, 1, 0, 0));
        for t in 1..200 {
            let mut queued = sample(t * 200, 10 + t % 3, 15, 40);
            queued.send_kbps = 1_000;
            assert_eq!(rc.on_sample(queued).kbps, 40_000);
        }
    }

    #[test]
    fn application_limited_backpressure_uses_a_nominal_frame_budget() {
        let mut rc = RateController::new(RateControlConfig::new(QualityMode::Auto, 900_000, 60));
        rc.on_sample(sample(0, 1, 0, 0));
        let mut queued = sample(200, 10, 15, 200);
        queued.backlog_epoch = 1;
        queued.send_kbps = 5_000;
        queued.send_millifps = 10_000; // 10 fps because of stop-and-wait
        queued.send_rate_backlogged = false;
        assert_eq!(rc.on_sample(queued).kbps, 18_000);
        queued.now_us += 200_000;
        queued.backlog_epoch = 2;
        // The same service budget does not trigger another multiplicative cut.
        assert_eq!(rc.on_sample(queued).kbps, 18_000);
    }

    #[test]
    fn feedback_idle_does_not_probe_above_the_proven_service_budget() {
        let mut rc = RateController::new(RateControlConfig::new(QualityMode::Auto, 900_000, 60));
        rc.on_sample(sample(0, 1, 0, 0));
        let mut queued = sample(200, 10, 15, 200);
        queued.backlog_epoch = 1;
        queued.send_kbps = 5_000;
        queued.send_millifps = 10_000;
        queued.send_rate_backlogged = false;
        assert_eq!(rc.on_sample(queued).kbps, 18_000);
        for t in 2..100 {
            queued.now_us = t * 200_000;
            queued.backlog_epoch = t;
            queued.queue_age_us = 0;
            assert_eq!(rc.on_sample(queued).kbps, 18_000);
        }
        queued.send_millifps = 60_000;
        for t in 100..200 {
            queued.now_us = t * 200_000;
            queued.backlog_epoch = t;
            rc.on_sample(queued);
        }
        assert_eq!(rc.target().kbps, 900_000);
    }

    #[test]
    fn downstream_queue_can_lower_quality_but_not_clip_to_an_idle_send_rate() {
        let mut rc = controller(QualityMode::Auto);
        rc.on_sample(sample(0, 1, 0, 0));
        for t in 1..10 {
            let mut network_queued = sample(t * 200, 150, 0, 0);
            network_queued.backlog_epoch = t;
            network_queued.send_millifps = 10_000;
            network_queued.send_kbps = 500;
            rc.on_sample(network_queued);
        }
        assert!(rc.target().kbps < 40_000);
        assert!(rc.target().kbps > 2_000);
    }

    #[test]
    fn baseline_round_trip_does_not_freeze_recovery_at_the_floor() {
        let mut rc = controller(QualityMode::Auto);
        rc.kbps = 2_000.0;
        for t in 0..100 {
            let mut clear = sample(t * 200, 20, 0, 0);
            clear.backlog_epoch = t + 1;
            clear.send_millifps = 30_000;
            rc.on_sample(clear);
        }
        assert!(rc.target().kbps > 10_000);
    }

    #[test]
    fn full_frame_service_does_not_cut_quality_for_a_transient_buffer_peak() {
        let mut rc = RateController::new(RateControlConfig::new(QualityMode::Auto, 900_000, 60));
        rc.on_sample(sample(0, 1, 0, 0));
        for t in 1..100 {
            let mut burst = sample(t * 200, 2, 0, 30);
            burst.backlog_epoch = t;
            burst.send_millifps = 60_000;
            burst.send_kbps = 160_000;
            assert_eq!(rc.on_sample(burst).kbps, 900_000);
        }
    }

    #[test]
    fn new_backlog_after_feedback_idle_does_not_measure_link_capacity() {
        let mut rc = RateController::new(RateControlConfig::new(QualityMode::Auto, 900_000, 60));
        rc.on_sample(sample(0, 1, 0, 0));
        // Delay is moderately inflated, but the interval spent most of its
        // time in feedback idle before a fresh original frame was queued.
        for t in 1..30 {
            let mut partial = sample(t * 200, 22, 15, 100);
            partial.backlog_epoch = t;
            partial.send_kbps = 1_000;
            partial.send_millifps = 5_000;
            partial.send_rate_backlogged = false;
            assert_eq!(rc.on_sample(partial).kbps, 7_200);
        }
    }

    #[test]
    fn old_backlog_cannot_repeatedly_cut_an_unapplied_target_or_fps() {
        let mut rc = controller(QualityMode::Auto);
        rc.on_sample(sample(0, 4, 0, 0));
        let mut queued = sample(200, 40, 30, 500);
        for t in 1..10 {
            rc.on_sample(sample(t * 10, 40, 0, 0));
        }
        queued.backlog_epoch = 1;
        queued.send_kbps = 500;
        assert_eq!(rc.on_sample(queued).kbps, 2_000);
        for t in 2..50 {
            queued.now_us = t * 200_000;
            assert_eq!(
                rc.on_sample(queued),
                QualityTarget {
                    kbps: 2_000,
                    max_fps: 60,
                    scale_permille: 1000,
                }
            );
        }
        // New original media at the already-applied floor can lower fps.
        queued.now_us = 10_000_000;
        queued.backlog_epoch = 2;
        assert_eq!(rc.on_sample(queued).max_fps, 30);
    }

    #[test]
    fn real_backlog_still_cuts_after_baseline_refresh() {
        let mut rc = controller(QualityMode::Auto);
        for t in 0..100 {
            rc.on_sample(sample(t * 200, 4, 0, 0));
        }
        for t in 100..110 {
            rc.on_sample(sample(t * 200, 80, 0, 0));
        }
        let mut queued = sample(22_000, 80, 0, 60);
        queued.send_kbps = 10_000;
        assert_eq!(rc.on_sample(queued).kbps, 9_000);
    }

    #[test]
    fn clean_network_keeps_full_quality() {
        let mut rc = controller(QualityMode::Auto);
        for t in 0..100 {
            let target = rc.on_sample(sample(t * 100, 3, 0, 5));
            assert_eq!(
                target,
                QualityTarget {
                    kbps: 40_000,
                    max_fps: 60,
                    scale_permille: 1000
                }
            );
        }
    }

    #[test]
    fn wifi_random_loss_with_flat_delay_does_not_lower_quality() {
        let mut rc = controller(QualityMode::Auto);
        for t in 0..100 {
            // 1.5% loss, RTT stays at its floor: retransmission handles it.
            assert_eq!(rc.on_sample(sample(t * 100, 4, 15, 5)).kbps, 40_000);
        }
    }

    #[test]
    fn congestion_lowers_bitrate_then_ladder_then_recovers_in_reverse() {
        let mut rc = controller(QualityMode::Auto);
        rc.on_sample(sample(0, 4, 0, 5));
        let mut t = 100;
        let mut last = rc.target();
        // Persistent congestion with periodic unloaded RTT observations.
        // Those observations keep the rolling baseline below loaded delay.
        while rc.target().kbps > rc.config().min_kbps {
            let next = rc.on_sample(sample(t, if t % 1000 == 0 { 4 } else { 40 }, 30, 60));
            assert!(next.kbps <= last.kbps);
            last = next;
            t += 100;
        }
        assert_eq!(last.max_fps, 60);
        // Still congested at the floor: frame rate drops before resolution.
        for _ in 0..25 {
            rc.on_sample(sample(t, if t % 1000 == 0 { 4 } else { 40 }, 30, 60));
            t += 100;
        }
        assert_eq!(rc.target().max_fps, 30);
        assert_eq!(rc.target().scale_permille, 1000);
        for _ in 0..200 {
            rc.on_sample(sample(t, if t % 1000 == 0 { 4 } else { 40 }, 30, 60));
            t += 100;
        }
        assert_eq!(
            rc.target(),
            QualityTarget {
                kbps: 2_000,
                max_fps: 20,
                scale_permille: 500
            }
        );
        // Network clears: ladder steps back up, then bitrate grows to ceiling.
        for _ in 0..2_000 {
            rc.on_sample(sample(t, 4, 0, 5));
            t += 100;
        }
        assert_eq!(
            rc.target(),
            QualityTarget {
                kbps: 40_000,
                max_fps: 60,
                scale_permille: 1000
            }
        );
    }

    #[test]
    fn decreases_are_rate_limited_by_rtt() {
        let mut rc = controller(QualityMode::Auto);
        rc.on_sample(sample(0, 100, 0, 5));
        for t in 1..10 {
            rc.on_sample(sample(t, 300, 0, 0));
        }
        let first = rc.on_sample(sample(10, 300, 200, 60)).kbps;
        // Within 2*min RTT (200 ms) a second congested sample does not cut again.
        assert_eq!(rc.on_sample(sample(50, 300, 200, 60)).kbps, first);
        assert!(rc.on_sample(sample(260, 300, 200, 60)).kbps < first);
    }

    #[test]
    fn high_quality_never_degrades_and_save_bandwidth_caps() {
        let mut high = controller(QualityMode::HighQuality);
        for t in 0..200 {
            assert_eq!(
                high.on_sample(sample(t * 100, 80, 300, 200)),
                QualityTarget {
                    kbps: 40_000,
                    max_fps: 60,
                    scale_permille: 1000
                }
            );
        }
        let mut save = controller(QualityMode::SaveBandwidth);
        assert_eq!(save.on_sample(sample(0, 3, 0, 5)).kbps, 10_000);
        let mut wired = RateController::new(RateControlConfig::new(
            QualityMode::SaveBandwidth,
            900_000,
            60,
        ));
        assert_eq!(wired.on_sample(sample(0, 3, 0, 5)).kbps, 20_000);
        save.set_mode(QualityMode::HighQuality);
        assert_eq!(save.target().kbps, 40_000);
    }

    #[test]
    fn low_frame_rate_streams_keep_their_own_rate() {
        let mut rc = RateController::new(RateControlConfig::new(QualityMode::Auto, 10_000, 24));
        assert_eq!(rc.on_sample(sample(0, 3, 0, 5)).max_fps, 24);
    }

    #[test]
    fn send_rate_meter_reports_interval_kbps() {
        let mut meter = SendRateMeter::default();
        assert_eq!(meter.update(0, 1_000), 0);
        // 250 kB in 200 ms = 10 Mbit/s.
        assert_eq!(meter.update(200_000, 251_000), 10_000);
        assert_eq!(meter.update(200_000, 260_000), 0);
    }

    #[test]
    fn measured_send_rate_converges_a_high_ceiling_in_one_step() {
        let mut rc = RateController::new(RateControlConfig::new(QualityMode::Auto, 900_000, 60));
        rc.on_sample(sample(0, 4, 0, 5));
        for t in 1..10 {
            rc.on_sample(sample(t * 100, 40, 30, 0));
        }
        let mut congested = sample(1000, 40, 30, 60);
        congested.send_kbps = 30_000;
        assert_eq!(rc.on_sample(congested).kbps, 27_000);
    }

    #[test]
    fn stable_recovery_ramps_faster_after_five_seconds() {
        let mut rc = controller(QualityMode::Auto);
        rc.on_sample(sample(0, 4, 0, 5));
        let mut t = 100;
        while rc.target().kbps > rc.config().min_kbps {
            rc.on_sample(sample(t, 40, 30, 60));
            t += 100;
        }
        let low = rc.target().kbps;
        // 5 s clear at the slow rate, then 5 s at the fast rate.
        for _ in 0..50 {
            rc.on_sample(sample(t, 4, 0, 5));
            t += 100;
        }
        let slow = rc.target().kbps;
        for _ in 0..50 {
            rc.on_sample(sample(t, 4, 0, 5));
            t += 100;
        }
        let fast = rc.target().kbps;
        assert!(f64::from(slow) / f64::from(low) < 1.6);
        assert!(f64::from(fast) / f64::from(slow) > 3.0);
    }
}
