//! Bounded encoded lane queues. Only unsubmitted records can be removed.
//! After removing a prediction chain, suppress dependent frames until an IDR;
//! the transport writer always completes the record it already owns.
use std::collections::VecDeque;
use std::time::{Duration, Instant};
use anyhow::{Result, ensure};
use crate::activity_frame::ActivityFrame;

pub(crate) struct EncodedRecord {
    pub bytes: Vec<u8>,
    pub queued: Instant,
    pub keyframe: bool,
}
impl EncodedRecord {
    pub fn parse(bytes: Vec<u8>, now: Instant) -> Result<(usize, Self)> {
        let header = ActivityFrame::parse(&bytes)?.ok_or_else(|| anyhow::anyhow!("negotiated activity frame required"))?;
        let key_at = 56 + header.members.len()*8;
        ensure!(bytes.len() >= key_at+4, "activity keyframe flag missing");
        let key = u32::from_le_bytes(bytes[key_at..key_at+4].try_into()?);
        ensure!(key <= 1, "activity keyframe flag invalid");
        Ok((header.lane as usize, Self {bytes, queued: now, keyframe: key != 0}))
    }
}

pub(crate) struct LaneQueue {
    ready: VecDeque<EncodedRecord>,
    bytes: usize,
    byte_limit: usize,
    record_limit: usize,
    awaiting_keyframe: bool,
    pub dropped: u64,
}
impl LaneQueue {
    pub fn new(record_limit: usize, byte_limit: usize) -> Self {
        assert!(record_limit > 0 && byte_limit > 0);
        Self {ready: VecDeque::new(), bytes: 0, byte_limit, record_limit,
            awaiting_keyframe: false, dropped: 0}
    }
    /// Returns whether the source needs an IDR. An individual large record is
    /// allowed, bounded separately by the wire record limit, to ensure recovery.
    pub fn push(&mut self, record: EncodedRecord) -> bool {
        if self.awaiting_keyframe && !record.keyframe {
            self.dropped += 1;
            return true;
        }
        if self.ready.len() >= self.record_limit || (!self.ready.is_empty() && self.bytes.saturating_add(record.bytes.len()) > self.byte_limit) {
            self.dropped += self.ready.len() as u64;
            self.ready.clear(); self.bytes = 0;
            self.awaiting_keyframe = true;
        }
        if self.awaiting_keyframe && !record.keyframe {
            self.dropped += 1;
            return true;
        }
        if record.keyframe { self.awaiting_keyframe = false; }
        self.bytes += record.bytes.len();
        self.ready.push_back(record);
        false
    }
    pub fn pop(&mut self) -> Option<EncodedRecord> {
        let record = self.ready.pop_front()?;
        self.bytes -= record.bytes.len();
        Some(record)
    }
    pub fn age(&self, now: Instant) -> Duration {
        self.ready.front().map_or(Duration::ZERO, |frame| now.saturating_duration_since(frame.queued))
    }
    pub fn saturated(&self) -> bool {
        self.awaiting_keyframe || self.ready.len() >= self.record_limit || self.bytes >= self.byte_limit
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn record(keyframe: bool, value: u8) -> EncodedRecord {
        EncodedRecord {bytes: vec![value; 4], queued: Instant::now(), keyframe}
    }
    #[test]
    fn overflow_finishes_inflight_and_never_sends_broken_prediction_chain() {
        let mut queue = LaneQueue::new(2, 8);
        assert!(!queue.push(record(true, 1)));
        let in_flight = queue.pop().unwrap();
        assert!(!queue.push(record(false, 2)));
        assert!(!queue.push(record(false, 3)));
        assert!(queue.push(record(false, 4)));
        assert_eq!(in_flight.bytes, [1;4]);
        assert!(queue.pop().is_none());
        assert!(queue.push(record(false, 5)));
        assert!(!queue.push(record(true, 6)));
        assert!(!queue.push(record(false, 7)));
        assert_eq!(queue.pop().unwrap().bytes, [6;4]);
        assert_eq!(queue.pop().unwrap().bytes, [7;4]);
        assert_eq!(queue.dropped, 4);
    }
    #[test]
    fn background_saturation_does_not_consume_priority_capacity() {
        let mut lanes = [LaneQueue::new(2,8), LaneQueue::new(2,8)];
        lanes[1].push(record(true,1)); lanes[1].push(record(false,2));
        assert!(lanes[1].push(record(false,3)));
        assert!(!lanes[0].push(record(true,4)));
        assert_eq!(lanes[0].pop().unwrap().bytes, [4;4]);
        assert!(lanes[1].saturated());
    }
    #[test]
    fn large_idr_can_recover_and_age_tracks_oldest_waiting_frame() {
        let mut queue = LaneQueue::new(2,2);
        let start = Instant::now();
        assert!(!queue.push(EncodedRecord {bytes:vec![1;10],queued:start,keyframe:true}));
        assert_eq!(queue.age(start+Duration::from_millis(90)),Duration::from_millis(90));
        assert!(queue.saturated());
        queue.pop().unwrap();
        assert_eq!(queue.age(start+Duration::from_millis(90)),Duration::ZERO);
    }
}
