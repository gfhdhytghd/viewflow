//! Experimental delay-gated Cubic. Quinn still owns loss recovery and pacing.
//! Random loss alone does not reduce cwnd; queue growth and ECN still do.
use quinn::congestion::{Controller, ControllerFactory, ControllerMetrics, Cubic, CubicConfig};
use quinn_proto::RttEstimator;
use std::{
    any::Any,
    sync::Arc,
    time::{Duration, Instant},
};

#[derive(Debug, Default)]
pub(crate) struct DelayCubicConfig;
impl ControllerFactory for DelayCubicConfig {
    fn build(self: Arc<Self>, now: Instant, current_mtu: u16) -> Box<dyn Controller> {
        Box::new(DelayCubic::new(now, current_mtu))
    }
}

#[derive(Debug, Clone)]
struct DelayCubic {
    cubic: Cubic,
    config: Arc<CubicConfig>,
    mtu: u16,
    epoch: Instant,
    previous_min: Duration,
    current_min: Duration,
    rtt: Duration,
    queue_growing: bool,
    last_reduction: Option<Instant>,
}
impl DelayCubic {
    fn new(now: Instant, mtu: u16) -> Self {
        let config = Arc::new(CubicConfig::default());
        Self {
            cubic: Cubic::new(config.clone(), now, mtu),
            config,
            mtu,
            epoch: now,
            previous_min: Duration::MAX,
            current_min: Duration::MAX,
            rtt: Duration::ZERO,
            queue_growing: false,
            last_reduction: None,
        }
    }

    fn observe_rtt(&mut self, now: Instant, rtt: Duration) {
        // Two fixed one-second buckets expire the clean warmup baseline.
        let old_baseline = self.current_min.min(self.previous_min);
        let age = now.saturating_duration_since(self.epoch);
        if age >= Duration::from_secs(1) {
            self.previous_min = if age < Duration::from_secs(2) {
                self.current_min
            } else {
                Duration::MAX
            };
            self.current_min = Duration::MAX;
            self.epoch = now;
        }
        self.current_min = self.current_min.min(rtt);
        self.rtt = rtt;
        let baseline = self.current_min.min(self.previous_min);
        // Once both buckets confirm a higher base RTT, restore at most the
        // original initial window instead of crawling from two packets.
        // Reuse the existing config: no allocation or lock in ACK processing.
        if old_baseline != Duration::MAX
            && baseline > old_baseline + Duration::from_millis(15)
            && self.cubic.window() < self.cubic.initial_window()
        {
            self.cubic = Cubic::new(self.config.clone(), now, self.mtu);
            self.last_reduction = None;
        }
        self.queue_growing =
            rtt > baseline + Duration::from_millis(15) && rtt > baseline + baseline / 2;
    }

    fn reduce(&mut self, now: Instant, sent: Instant, persistent: bool, bytes: u64) {
        // A batch or a flight of ACKs can report the same queue. Reduce once
        // per smoothed RTT, never once per packet. ECN and persistent congestion
        // are explicit network signals and bypass this local rate limit.
        if !persistent
            && self.last_reduction.is_some_and(|last| {
                now.saturating_duration_since(last) < self.rtt.max(Duration::from_millis(1))
            })
        {
            return;
        }
        self.cubic.on_congestion_event(now, sent, persistent, bytes);
        self.last_reduction = Some(now);
    }
}
impl Controller for DelayCubic {
    fn on_sent(&mut self, now: Instant, bytes: u64, last_packet_number: u64) {
        self.cubic.on_sent(now, bytes, last_packet_number);
    }
    fn on_ack(
        &mut self,
        now: Instant,
        sent: Instant,
        bytes: u64,
        app_limited: bool,
        rtt: &RttEstimator,
    ) {
        self.observe_rtt(now, rtt.get());
        // Detect queue growth even on a lossless rate-limited link. Queueing
        // can be present in the kernel while the application is stop-and-wait.
        if self.queue_growing {
            self.reduce(now, sent, false, 0);
        }
        self.cubic.on_ack(now, sent, bytes, app_limited, rtt);
    }
    fn on_end_acks(
        &mut self,
        now: Instant,
        in_flight: u64,
        app_limited: bool,
        largest: Option<u64>,
    ) {
        self.cubic.on_end_acks(now, in_flight, app_limited, largest);
    }
    fn on_congestion_event(
        &mut self,
        now: Instant,
        sent: Instant,
        persistent: bool,
        lost_bytes: u64,
    ) {
        if persistent || lost_bytes == 0 {
            // Quinn uses lost_bytes == 0 for ECN. Preserve this direct signal.
            self.cubic
                .on_congestion_event(now, sent, persistent, lost_bytes);
            self.last_reduction = Some(now);
        } else if self.queue_growing {
            self.reduce(now, sent, false, lost_bytes);
        }
    }
    fn on_mtu_update(&mut self, new_mtu: u16) {
        self.mtu = new_mtu;
        self.cubic.on_mtu_update(new_mtu);
    }
    fn window(&self) -> u64 {
        self.cubic.window()
    }
    fn metrics(&self) -> ControllerMetrics {
        self.cubic.metrics()
    }
    fn clone_box(&self) -> Box<dyn Controller> {
        Box::new(self.clone())
    }
    fn initial_window(&self) -> u64 {
        self.cubic.initial_window()
    }
    fn into_any(self: Box<Self>) -> Box<dyn Any> {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn random_loss_preserves_window_but_queue_growth_reduces_once_per_rtt() {
        let origin = Instant::now();
        let mut c = DelayCubic::new(origin, 1200);
        c.observe_rtt(origin, Duration::from_millis(10));
        let initial = c.window();
        for n in 1..100 {
            let now = origin + Duration::from_millis(n);
            c.on_congestion_event(now, now, false, 1200);
        }
        assert_eq!(c.window(), initial);
        let now = origin + Duration::from_secs(1);
        c.observe_rtt(now, Duration::from_millis(40));
        assert!(c.queue_growing);
        c.reduce(now, now, false, 0);
        let reduced = c.window();
        assert!(reduced < initial);
        c.reduce(
            now + Duration::from_millis(1),
            now + Duration::from_millis(1),
            false,
            0,
        );
        assert_eq!(c.window(), reduced);
        c.reduce(
            now + Duration::from_millis(41),
            now + Duration::from_millis(41),
            false,
            0,
        );
        assert!(c.window() < reduced);
    }
    #[test]
    fn ecn_and_persistent_congestion_reduce_even_without_rtt_growth() {
        let now = Instant::now();
        for (persistent, lost_bytes) in [(false, 0), (true, 1200)] {
            let mut c = DelayCubic::new(now, 1200);
            let initial = c.window();
            c.on_congestion_event(now, now, persistent, lost_bytes);
            assert!(c.window() < initial);
        }
    }
    #[test]
    fn path_delay_step_restores_initial_probe_after_baseline_rebase() {
        let origin = Instant::now();
        let mut c = DelayCubic::new(origin, 1200);
        c.observe_rtt(origin, Duration::from_micros(100));
        let now = origin + Duration::from_millis(500);
        c.observe_rtt(now, Duration::from_millis(25));
        c.reduce(now, now, false, 0);
        assert!(c.window() < c.initial_window());
        c.observe_rtt(origin + Duration::from_secs(1), Duration::from_millis(25));
        c.observe_rtt(origin + Duration::from_secs(2), Duration::from_millis(25));
        assert_eq!(c.window(), c.initial_window());
        assert!(!c.queue_growing);
        let now = origin + Duration::from_millis(2100);
        c.observe_rtt(now, Duration::from_millis(60));
        c.reduce(now, now, false, 0);
        assert!(c.window() < c.initial_window());
    }
    #[test]
    fn baseline_expires_and_jitter_does_not_trigger_reduction() {
        let origin = Instant::now();
        let mut c = DelayCubic::new(origin, 1200);
        c.observe_rtt(origin, Duration::from_micros(100));
        c.observe_rtt(
            origin + Duration::from_millis(500),
            Duration::from_millis(12),
        );
        assert!(!c.queue_growing);
        c.observe_rtt(origin + Duration::from_secs(1), Duration::from_millis(25));
        assert!(c.queue_growing);
        c.observe_rtt(origin + Duration::from_secs(2), Duration::from_millis(25));
        assert!(!c.queue_growing);
        c.observe_rtt(origin + Duration::from_secs(20), Duration::from_millis(50));
        assert!(!c.queue_growing);
        c.on_mtu_update(1400);
        assert!(c.window() >= 2800);
        assert_eq!(c.clone_box().window(), c.window());
    }
}
