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
    pub chunks_recovered_by_fec: u64,
    pub frames_recovered_by_fec: u64,
    pub parity_bytes: u64,
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

/// Cumulative application-media observations, only emitted after FEC v1 negotiation.
pub(crate) fn fec_feedback(total: u64, missing: u64, failed: u64) -> Bytes {
    let mut out = BytesMut::with_capacity(29);
    out.put_slice(b"VFFB\x01"); out.put_u64(total); out.put_u64(missing.min(total)); out.put_u64(failed.min(total));
    out.freeze()
}
#[derive(Default)]
pub(crate) struct MediaFeedback {
    pub total: std::sync::atomic::AtomicU64,
    pub missing: std::sync::atomic::AtomicU64,
    pub failed: std::sync::atomic::AtomicU64,
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
    original_sent: Arc<std::sync::atomic::AtomicU16>,
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

/// Poll Quinn's non-evicting send exactly once. Pending means skip this repair;
/// no application lock, heap-pinned future, or wait behind input is introduced.
async fn try_enqueue_repair(connection: &Connection, bytes: Bytes) -> bool {
    let send = connection.send_datagram_wait(bytes);
    tokio::pin!(send);
    std::future::poll_fn(|cx| std::task::Poll::Ready(matches!(
        std::future::Future::poll(send.as_mut(), cx), std::task::Poll::Ready(Ok(()))
    ))).await
}

pub(crate) struct Retransmit {
    pub feedback: Arc<MediaFeedback>,
    cache: Arc<Mutex<VecDeque<Cached>>>,
    task: tokio::task::JoinHandle<()>,
    #[cfg(test)]
    pub(crate) enqueued: Arc<std::sync::atomic::AtomicU64>,
    #[cfg(test)]
    block_repairs: Arc<std::sync::atomic::AtomicBool>,
}
impl Drop for Retransmit {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Retransmit {
    pub fn new(connection: Connection, mut requests: quinn::RecvStream, fec_enabled: bool) -> Arc<Self> {
        let cache = Arc::new(Mutex::new(VecDeque::<Cached>::new()));
        let shared = cache.clone();
        let feedback = Arc::new(MediaFeedback::default());
        let observed = feedback.clone();
        #[cfg(test)]
        let enqueued = Arc::new(std::sync::atomic::AtomicU64::new(0));
        #[cfg(test)]
        let count = enqueued.clone();
        #[cfg(test)]
        let block_repairs = Arc::new(std::sync::atomic::AtomicBool::new(false));
        #[cfg(test)]
        let blocked = block_repairs.clone();
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
                if bytes.len() == 29 && &bytes[..5] == b"VFFB\x01" {
                    let total = u64::from_be_bytes(bytes[5..13].try_into().expect("fixed feedback size"));
                    let missing = u64::from_be_bytes(bytes[13..21].try_into().expect("fixed feedback size"));
                    let failed = u64::from_be_bytes(bytes[21..29].try_into().expect("fixed feedback size"));
                    if missing <= total && failed <= total && total >= observed.total.load(std::sync::atomic::Ordering::Relaxed)
                        && missing >= observed.missing.load(std::sync::atomic::Ordering::Relaxed)
                        && failed >= observed.failed.load(std::sync::atomic::Ordering::Relaxed) {
                        observed.failed.store(failed, std::sync::atomic::Ordering::Relaxed);
                        observed.missing.store(missing, std::sync::atomic::Ordering::Relaxed);
                        observed.total.store(total, std::sync::atomic::Ordering::Relaxed);
                    }
                    continue;
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
                                            && (!fec_enabled || i < usize::from(c.original_sent.load(std::sync::atomic::Ordering::Acquire)))
                                            && (indices.contains(&ALL)
                                                || indices.contains(&(i as u16)))
                                        {
                                            if !fec_enabled { served[i] += 1; }
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
                let mut enqueued_indices = Vec::with_capacity(if fec_enabled { wanted.len() } else { 0 });
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
                        #[cfg(test)]
                        if blocked.load(std::sync::atomic::Ordering::Relaxed) { break; }
                        // Congestion drops repairs locally. Never block or extend a frame budget.
                        // quinn evicts the oldest queued datagram when full, so check space
                        // first: a repair must not displace another lane's pending media.
                        let encoded = if fec_enabled {
                            // The negotiated FEC v1 peer distinguishes repairs
                            // from original late data; old peers retain zero flags.
                            let mut bytes = packet.encode().try_into_mut().expect("fresh unique datagram");
                            bytes[7] = 1;
                            bytes.freeze()
                        } else { packet.encode() };
                        let queued = if fec_enabled {
                            try_enqueue_repair(&connection, encoded).await
                        } else {
                            connection.datagram_send_buffer_space() >= encoded.len()
                                && connection.send_datagram(encoded).is_ok()
                        };
                        if !queued { break; }
                        if fec_enabled { enqueued_indices.push(packet.chunk_index); }
                        #[cfg(test)]
                        count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                }
                // One cache update per loss request, not one lock per shard.
                // Skipped repairs must retain their quota for a later round.
                if !enqueued_indices.is_empty() {
                    if let Ok(mut ring) = shared.lock() {
                        if let Some(served) = ring.iter_mut()
                            .find(|c| c.plane.frame_id == frame_id && c.plane.plane == plane)
                            .and_then(|c| c.served.as_mut()) {
                            for index in enqueued_indices {
                                if let Some(value) = served.get_mut(usize::from(index)) { *value = value.saturating_add(1).min(3); }
                            }
                        }
                    }
                }
            }
        });
        Arc::new(Self { feedback, cache, task, #[cfg(test)] enqueued, #[cfg(test)] block_repairs })
    }
    pub fn remember(&self, plane: MediaPlaneFrame, budget: usize, lane: u64, target: Duration) -> Arc<std::sync::atomic::AtomicU16> {
        let original_sent = Arc::new(std::sync::atomic::AtomicU16::new(0));
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
                original_sent: original_sent.clone(),
            });
        }
        original_sent
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
            feedback: Default::default(),
            block_repairs: Default::default(),
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

    #[tokio::test]
    async fn full_quinn_buffer_skips_repair_atomically_without_evicting_originals() {
        let (_client, _server, source, _sink) = crate::atlas_session::tests::pair().await;
        let initial = source.datagram_send_buffer_space();
        assert!(try_enqueue_repair(&source, Bytes::from(vec![1; 1024])).await);
        assert!(source.datagram_send_buffer_space() < initial); // Quinn also charges datagram metadata.
        // No await/yield in this loop: the current-thread driver cannot drain it.
        for _ in 0..4096 { source.send_datagram(Bytes::from_static(&[2; 1024])).unwrap(); }
        let before = source.datagram_send_buffer_space();
        assert!(before < 1024);
        assert!(!try_enqueue_repair(&source, Bytes::from_static(&[3; 1024])).await);
        assert_eq!(source.datagram_send_buffer_space(), before);
        assert!(source.close_reason().is_none());
    }

    #[tokio::test]
    async fn blocked_fec_repairs_keep_quota_and_successful_enqueues_still_cap_at_three() {
        use std::sync::atomic::Ordering;
        let (_client, _server, source, sink) = crate::atlas_session::tests::pair().await;
        let tx = sink.open_uni().await.unwrap();
        let writer = NackSender::new(tx);
        assert!(writer.send(fec_feedback(0, 0, 0)));
        let requests = source.accept_uni().await.unwrap();
        let repairs = Retransmit::new(source, requests, true);
        let original_sent = repairs.remember(MediaPlaneFrame {
            window_id: viewflow_protocol::Id128(99), frame_id: 9, geometry_epoch: 1,
            plane: MediaPlane::Color, source_submitted_ns: 1,
            payload: Bytes::from(vec![7; 2000]),
        }, 1200, 0, Duration::from_secs(5));
        // A request for a future tail must not jump ahead of original enqueue.
        assert!(writer.send(request(9, MediaPlane::Color, None)));
        assert!(writer.send(fec_feedback(1, 0, 0)));
        tokio::time::timeout(Duration::from_secs(1), async {
            while repairs.feedback.total.load(Ordering::Relaxed) < 1 { tokio::task::yield_now().await; }
        }).await.unwrap();
        assert_eq!(repairs.enqueued.load(Ordering::Relaxed), 0);
        original_sent.store(2, Ordering::Release);
        repairs.block_repairs.store(true, Ordering::Relaxed);
        for marker in 2..=8 {
            if marker == 5 { repairs.block_repairs.store(false, Ordering::Relaxed); }
            assert!(writer.send(request(9, MediaPlane::Color, None)));
            assert!(writer.send(fec_feedback(marker, 0, 0)));
            tokio::time::timeout(Duration::from_secs(1), async {
                while repairs.feedback.total.load(Ordering::Relaxed) < marker {
                    tokio::task::yield_now().await;
                }
            }).await.unwrap();
            let expected = marker.saturating_sub(4).min(3) as u8;
            let ring = repairs.cache.lock().unwrap();
            assert_eq!(ring[0].served.as_ref().unwrap(), &[expected, expected]);
            assert_eq!(repairs.enqueued.load(Ordering::Relaxed), u64::from(expected) * 2);
        }
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
