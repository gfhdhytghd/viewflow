//! Optional atlas NACK v1. The responder owns a dedicated small uni stream;
//! it never queues media behind reliable input/control writes.
use bytes::{BufMut, Bytes, BytesMut};
use quinn::Connection;
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::time::Instant;
use viewflow_transport::{MediaPlane, MediaPlaneFrame};

const MAGIC: &[u8; 5] = b"VFNA\x01";
const ALL: u16 = u16::MAX;
const MAX_INDICES: usize = 512;

#[derive(Default, Debug, Clone)]
pub struct LossTelemetry {
    pub chunks_lost: u64,
    pub frames_recovered_by_nack: u64,
    pub frames_dropped_to_keyframe: u64,
    pub nack_round_trips: u64,
    pub nack_requests_sent: u64,
    pub nack_rtt_us: u64,
    pub quic_rtt_us: u64,
    pub quic_lost_packets: u64,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct LossWait {
    pub request_at: Instant,
    pub expires: Instant,
    pub repair_until: Instant,
    pub requested: bool,
    pub attempted: bool,
    rtt: Duration,
    budget: Duration,
    pub progressed: bool,
    rounds: u8,
}
impl LossWait {
    pub fn new(rtt: Duration, frame_period: Duration) -> Self {
        let started = Instant::now();
        // Recovery scheduling only; the first frame uses a nominal 60 Hz period.
        let budget = (rtt.saturating_mul(2) + frame_period)
            .clamp(Duration::from_millis(8), Duration::from_millis(250));
        Self {
            request_at: started + rtt.max(Duration::from_millis(2)),
            // A manifest can overtake media queued behind congestion control.
            // Wait for the first chunk before applying an inactivity budget.
            expires: started + Duration::from_millis(250),
            repair_until: started + Duration::from_millis(250),
            requested: false,
            attempted: false,
            rtt,
            budget,
            progressed: false,
            rounds: 0,
        }
    }
    // Only a new accepted chunk extends inactivity waiting. Duplicates do
    // not keep a dead frame alive; supersession still drops it immediately.
    pub fn progress(&mut self) {
        let now = Instant::now();
        self.progressed = true;
        self.expires = now + if self.requested { self.repair_grace() } else { self.budget };
        self.repair_until = self.expires;
        if !self.attempted {
            self.request_at = now + self.rtt.max(Duration::from_millis(2));
        }
    }
    fn repair_grace(self) -> Duration {
        // NACK uses a reliable stream: a lost control packet can need PTO,
        // not merely one smoothed RTT, before its repairs can arrive.
        (self.rtt.saturating_mul(3) + Duration::from_millis(200)).min(Duration::from_secs(1))
    }
    pub fn mark_request(&mut self, requested: bool) {
        self.attempted = true;
        self.rounds += 1;
        if requested {
            self.requested = true;
            self.request_at = Instant::now();
            self.expires = self.request_at + self.repair_grace();
            self.repair_until = self.expires;
        }
    }
    pub fn retry(&mut self) -> bool {
        if !self.requested || self.rounds >= 3 { return false; }
        self.attempted = false;
        self.request_at = Instant::now();
        self.expires = self.request_at + self.repair_grace();
        self.repair_until = self.expires;
        true
    }
    pub fn wake(self, nack: bool) -> Instant {
        if nack && self.progressed && !self.attempted {
            self.request_at.min(self.expires)
        } else {
            self.expires
        }
    }
}

pub(crate) fn request(frame: u64, plane: MediaPlane, indices: Option<&[u16]>) -> Bytes {
    let mut out = BytesMut::with_capacity(16 + indices.map_or(2, |v| v.len() * 2));
    out.put_slice(MAGIC);
    out.put_u64(frame);
    out.put_u8(plane as u8);
    out.put_u16(indices.map_or(1, |v| v.len()) as u16);
    for index in indices.unwrap_or(&[ALL]) {
        out.put_u16(*index);
    }
    out.freeze()
}
fn decode(bytes: &[u8]) -> Option<(u64, MediaPlane, Vec<u16>)> {
    if bytes.len() < 18 || &bytes[..5] != MAGIC {
        return None;
    }
    let frame = u64::from_be_bytes(bytes[5..13].try_into().ok()?);
    let plane = MediaPlane::try_from(bytes[13]).ok()?;
    if !matches!(plane, MediaPlane::Color | MediaPlane::Alpha) {
        return None;
    }
    let count = u16::from_be_bytes(bytes[14..16].try_into().ok()?) as usize;
    if count == 0 || count > MAX_INDICES || bytes.len() != 16 + count * 2 {
        return None;
    }
    let indices = bytes[16..]
        .chunks_exact(2)
        .map(|v| u16::from_be_bytes([v[0], v[1]]))
        .collect();
    Some((frame, plane, indices))
}

struct Cached {
    lane: u64,
    plane: MediaPlaneFrame,
    budget: usize,
    expires: Instant,
    served: Option<Vec<u8>>,
}

/// A bounded loss-only writer. Backpressure drops a repair request locally;
/// it must never hold the receive pump or the ordered input/control stream.
pub(crate) struct NackSender {
    queue: tokio::sync::mpsc::Sender<Bytes>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for NackSender {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl NackSender {
    pub fn new(mut stream: quinn::SendStream) -> Self {
        let (queue, mut incoming) = tokio::sync::mpsc::channel::<Bytes>(64);
        let task = tokio::spawn(async move {
            while let Some(bytes) = incoming.recv().await {
                if stream
                    .write_all(&(bytes.len() as u16).to_be_bytes())
                    .await
                    .is_err()
                    || stream.write_all(&bytes).await.is_err()
                {
                    break;
                }
            }
        });
        Self { queue, task }
    }
    pub fn send(&self, bytes: Bytes) -> bool {
        self.queue.try_send(bytes).is_ok()
    }
}

pub(crate) struct Retransmit {
    cache: Arc<Mutex<VecDeque<Cached>>>,
    task: tokio::task::JoinHandle<()>,
    #[cfg(test)]
    pub(crate) enqueued: Arc<std::sync::atomic::AtomicU64>,
}
impl Drop for Retransmit {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Retransmit {
    pub fn new(connection: Connection, mut requests: quinn::RecvStream) -> Arc<Self> {
        let cache = Arc::new(Mutex::new(VecDeque::<Cached>::new()));
        let shared = cache.clone();
        #[cfg(test)]
        let enqueued = Arc::new(std::sync::atomic::AtomicU64::new(0));
        #[cfg(test)]
        let count = enqueued.clone();
        let task = tokio::spawn(async move {
            loop {
                let mut length = [0; 2];
                if requests.read_exact(&mut length).await.is_err() {
                    break;
                }
                let length = usize::from(u16::from_be_bytes(length));
                if !(18..=16 + MAX_INDICES * 2).contains(&length) {
                    break;
                }
                let mut bytes = vec![0; length];
                if requests.read_exact(&mut bytes).await.is_err() {
                    break;
                }
                let Some((frame, plane, indices)) = decode(&bytes) else {
                    continue;
                };
                let cached = {
                    let Ok(mut ring) = shared.lock() else {
                        break;
                    };
                    let lane = ring
                        .iter()
                        .find(|c| c.plane.frame_id == frame)
                        .map(|c| c.lane);
                    let superseded = ring
                        .iter()
                        .any(|c| Some(c.lane) == lane && c.plane.frame_id > frame);
                    if superseded {
                        None
                    } else {
                        ring.iter_mut()
                            .find(|c| {
                                c.plane.frame_id == frame
                                    && c.plane.plane == plane
                                    && c.expires > Instant::now()
                            })
                            .map(|c| {
                                let count =
                                    c.plane.clone().fragment(c.budget).map_or(0, |p| p.len());
                                let served = c.served.get_or_insert_with(|| vec![0; count]);
                                let wanted: Vec<u16> = (0..count)
                                    .filter_map(|i| {
                                        if served[i] < 3
                                            && (indices.contains(&ALL)
                                                || indices.contains(&(i as u16)))
                                        {
                                            served[i] += 1;
                                            Some(i as u16)
                                        } else {
                                            None
                                        }
                                    })
                                    .collect();
                                (c.plane.clone(), c.budget, c.expires, c.lane, wanted)
                            })
                    }
                };
                let Some((cached, budget, expires, lane, wanted)) = cached else {
                    continue;
                };
                let frame_id = cached.frame_id;
                let Ok(packets) = cached.fragment(budget) else {
                    continue;
                };
                for (index, packet) in packets.enumerate() {
                    if index % 64 == 0 {
                        tokio::task::yield_now().await;
                        let superseded = shared.lock().map_or(true, |ring| {
                            ring.iter()
                                .any(|c| c.lane == lane && c.plane.frame_id > frame_id)
                        });
                        if superseded {
                            break;
                        }
                    }
                    if Instant::now() >= expires {
                        break;
                    }
                    if wanted.binary_search(&packet.chunk_index).is_ok() {
                        // Congestion drops repairs locally. Never block or extend a frame budget.
                        if connection.send_datagram(packet.encode()).is_err() {
                            break;
                        }
                        #[cfg(test)]
                        count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                }
            }
        });
        Arc::new(Self { cache, task, #[cfg(test)] enqueued })
    }
    pub fn remember(&self, plane: MediaPlaneFrame, budget: usize, lane: u64, target: Duration) {
        if let Ok(mut ring) = self.cache.lock() {
            // Two frames (two planes each) per lane, sharing Bytes payloads.
            while ring.iter().filter(|c| c.lane == lane).count() >= 4 {
                if let Some(index) = ring.iter().position(|c| c.lane == lane) {
                    ring.remove(index);
                }
            }
            ring.push_back(Cached {
                lane,
                plane,
                budget,
                expires: Instant::now() + target,
                served: None,
            });
        }
    }
}

pub(crate) const NACK_BATCH: usize = MAX_INDICES;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_repairs_retry_with_control_grace_but_stop_after_three_rounds() {
        let mut wait = LossWait::new(Duration::from_millis(30), Duration::from_millis(16));
        assert!(!wait.retry());
        wait.progress();
        for round in 1..=3 {
            wait.mark_request(true);
            assert_eq!(wait.rounds, round);
            assert!(wait.expires - wait.request_at >= Duration::from_millis(290));
            assert_eq!(wait.retry(), round < 3);
        }
        // Real progress can keep reception alive, but cannot reset the retry cap.
        wait.progress();
        assert!(!wait.retry());
    }

    #[tokio::test]
    async fn retransmit_cache_is_bounded_per_lane_and_shares_payloads() {
        let cache = Arc::new(Mutex::new(VecDeque::new()));
        let retransmit = Retransmit {
            cache: cache.clone(),
            enqueued: Arc::default(),
            task: tokio::spawn(std::future::pending()),
        };
        let payload = Bytes::from_static(b"shared encoded bytes");
        for id in 1..=8 {
            for plane in [MediaPlane::Color, MediaPlane::Alpha] {
                retransmit.remember(
                    MediaPlaneFrame {
                        window_id: viewflow_protocol::Id128(1),
                        frame_id: id,
                        geometry_epoch: 1,
                        plane,
                        source_submitted_ns: id,
                        payload: payload.clone(),
                    },
                    1200,
                    id % 2,
                    Duration::from_millis(33),
                );
            }
        }
        let ring = cache.lock().expect("cache lock");
        assert_eq!(ring.len(), 8);
        assert!(ring.iter().all(|entry| entry.plane.frame_id >= 5));
        assert!(
            ring.iter()
                .all(|entry| entry.plane.payload.as_ptr() == payload.as_ptr())
        );
    }

    #[test]
    fn nack_is_versioned_bounded_and_strict() {
        assert_eq!(
            decode(&request(42, MediaPlane::Color, Some(&[0, 3]))),
            Some((42, MediaPlane::Color, vec![0, 3]))
        );
        assert_eq!(
            decode(&request(42, MediaPlane::Alpha, None)),
            Some((42, MediaPlane::Alpha, vec![ALL]))
        );
        assert!(decode(b"VFNA\x02").is_none());
        assert!(decode(&request(42, MediaPlane::Color, Some(&vec![0; 513]))).is_none());
    }
}
