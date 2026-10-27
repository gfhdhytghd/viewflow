//! Adaptive media quality for weak networks (see `docs/weak-network.md`, W2).
//!
//! The controller is pure: callers feed periodic network samples with their
//! own monotonic clock and apply the returned target to an encoder. It never
//! ends a session; the worst case is the lowest quality step.
//!
//! Wi-Fi drops packets without congestion, so a little loss with a flat delay
//! is left to selective retransmission instead of lowering quality. Rising
//! delay, sustained loss, or a growing send queue are treated as congestion.

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
            save_bandwidth_kbps: (max_kbps / 4).max(1),
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
    /// Age of the oldest frame still queued or in flight at the sender.
    pub queue_age_us: u64,
    /// Frames the receiver dropped to a keyframe since the previous sample.
    pub frames_dropped: u64,
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

const DECREASE_HOLD_MIN_US: u64 = 200_000;
const INCREASE_HOLD_US: u64 = 1_000_000;
const INCREASE_PER_SECOND: f64 = 0.08;
const LADDER_DOWN_US: u64 = 2_000_000;
const LADDER_UP_US: u64 = 3_000_000;
// Loss below this ratio with flat delay is treated as wireless noise.
const RANDOM_LOSS_RATIO: f64 = 0.02;
const HEAVY_LOSS_RATIO: f64 = 0.10;

#[derive(Clone, Debug)]
pub struct RateController {
    config: RateControlConfig,
    kbps: f64,
    min_rtt_us: Option<u64>,
    last_sample_us: Option<u64>,
    last_decrease_us: Option<u64>,
    /// Ladder index: 0 = full fps and scale; odd steps lower fps first.
    ladder: usize,
    congested_at_floor_since: Option<u64>,
    clear_since: Option<u64>,
}

impl RateController {
    #[must_use]
    pub fn new(config: RateControlConfig) -> Self {
        Self {
            config,
            kbps: f64::from(config.ceiling_kbps()),
            min_rtt_us: None,
            last_sample_us: None,
            last_decrease_us: None,
            ladder: 0,
            congested_at_floor_since: None,
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
            self.min_rtt_us = Some(self.min_rtt_us.map_or(sample.rtt_us, |m| m.min(sample.rtt_us)));
        }
        if self.config.mode == QualityMode::HighQuality {
            return self.target();
        }

        let congested = self.is_congested(&sample);
        let ceiling = f64::from(self.config.ceiling_kbps());
        let floor = f64::from(self.config.min_kbps.min(self.config.ceiling_kbps()));

        if congested {
            self.clear_since = None;
            let hold = self
                .min_rtt_us
                .map_or(DECREASE_HOLD_MIN_US, |rtt| (2 * rtt).max(DECREASE_HOLD_MIN_US));
            let may_decrease = self
                .last_decrease_us
                .is_none_or(|last| sample.now_us.saturating_sub(last) >= hold);
            if may_decrease {
                let factor = if loss_ratio(&sample) >= HEAVY_LOSS_RATIO { 0.7 } else { 0.85 };
                self.kbps = (self.kbps * factor).max(floor);
                self.last_decrease_us = Some(sample.now_us);
            }
            if self.kbps <= floor {
                let since = *self.congested_at_floor_since.get_or_insert(sample.now_us);
                if sample.now_us.saturating_sub(since) >= LADDER_DOWN_US
                    && self.ladder + 1 < ladder_len()
                {
                    self.ladder += 1;
                    self.congested_at_floor_since = Some(sample.now_us);
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
            } else if self
                .last_decrease_us
                .is_none_or(|last| sample.now_us.saturating_sub(last) >= INCREASE_HOLD_US)
            {
                #[allow(clippy::cast_precision_loss)]
                let seconds = elapsed_us as f64 / 1_000_000.0;
                self.kbps = (self.kbps * (1.0 + INCREASE_PER_SECOND * seconds)).min(ceiling);
            }
        }
        self.kbps = self.kbps.clamp(floor, ceiling);
        self.target()
    }

    fn is_congested(&self, sample: &NetworkSample) -> bool {
        let loss = loss_ratio(sample);
        let rtt_inflated = self.min_rtt_us.is_some_and(|min| {
            sample.rtt_us > min + (min / 2).max(10_000)
        });
        // Two frame periods of queueing is the latency target already in use.
        let frame_period_us = 1_000_000 / u64::from(self.config.max_fps.max(1));
        let queue_growing = sample.queue_age_us > 2 * frame_period_us;
        loss >= HEAVY_LOSS_RATIO
            || (loss >= RANDOM_LOSS_RATIO && rtt_inflated)
            || queue_growing
            || (rtt_inflated && sample.frames_dropped > 0)
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
            frames_dropped: 0,
        }
    }

    #[test]
    fn clean_network_keeps_full_quality() {
        let mut rc = controller(QualityMode::Auto);
        for t in 0..100 {
            let target = rc.on_sample(sample(t * 100, 3, 0, 5));
            assert_eq!(target, QualityTarget { kbps: 40_000, max_fps: 60, scale_permille: 1000 });
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
        // Sustained queueing: bitrate must fall monotonically to the floor.
        while rc.target().kbps > rc.config().min_kbps {
            let next = rc.on_sample(sample(t, 40, 30, 60));
            assert!(next.kbps <= last.kbps);
            last = next;
            t += 100;
        }
        assert_eq!(last.max_fps, 60);
        // Still congested at the floor: frame rate drops before resolution.
        for _ in 0..25 {
            rc.on_sample(sample(t, 40, 30, 60));
            t += 100;
        }
        assert_eq!(rc.target().max_fps, 30);
        assert_eq!(rc.target().scale_permille, 1000);
        for _ in 0..200 {
            rc.on_sample(sample(t, 40, 30, 60));
            t += 100;
        }
        assert_eq!(rc.target(), QualityTarget { kbps: 2_000, max_fps: 20, scale_permille: 500 });
        // Network clears: ladder steps back up, then bitrate grows to ceiling.
        for _ in 0..2_000 {
            rc.on_sample(sample(t, 4, 0, 5));
            t += 100;
        }
        assert_eq!(rc.target(), QualityTarget { kbps: 40_000, max_fps: 60, scale_permille: 1000 });
    }

    #[test]
    fn decreases_are_rate_limited_by_rtt() {
        let mut rc = controller(QualityMode::Auto);
        rc.on_sample(sample(0, 100, 0, 5));
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
                QualityTarget { kbps: 40_000, max_fps: 60, scale_permille: 1000 }
            );
        }
        let mut save = controller(QualityMode::SaveBandwidth);
        assert_eq!(save.on_sample(sample(0, 3, 0, 5)).kbps, 10_000);
        save.set_mode(QualityMode::HighQuality);
        assert_eq!(save.target().kbps, 40_000);
    }

    #[test]
    fn low_frame_rate_streams_keep_their_own_rate() {
        let mut rc = RateController::new(RateControlConfig::new(QualityMode::Auto, 10_000, 24));
        assert_eq!(rc.on_sample(sample(0, 3, 0, 5)).max_fps, 24);
    }
}
