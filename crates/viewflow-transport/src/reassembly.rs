use std::{collections::HashMap, error::Error, fmt};

use bytes::{Bytes, BytesMut};
use viewflow_protocol::{FramePlane, FramePlaneReady, WindowId};

use crate::{ClockEstimate, MediaDatagram, MediaPlane};

#[derive(Clone, Copy, Debug)]
pub struct MediaAssemblerConfig {
    pub deadline_ns: u64,
    pub max_chunks_per_plane: u16,
    pub max_plane_bytes: usize,
}

impl Default for MediaAssemblerConfig {
    fn default() -> Self {
        Self {
            deadline_ns: 33_333_333,
            max_chunks_per_plane: 8_192,
            max_plane_bytes: 64 * 1024 * 1024,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssembledPlane {
    pub ready: FramePlaneReady,
    pub payload: Bytes,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssembledMedia {
    pub window_id: WindowId,
    pub frame_id: u64,
    pub geometry_epoch: u64,
    pub plane: MediaPlane,
    /// Source submission time normalized to the receiver's monotonic clock.
    pub source_submitted_ns: u64,
    pub received_ns: u64,
    pub payload: Bytes,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MediaAssemblerError {
    InvalidChunkRange,
    ConflictingChunk,
    UnsupportedPlane,
    Late,
    StaleFrame,
    TooManyChunks,
    InconsistentChunkCount,
    PlaneTooLarge,
}

impl fmt::Display for MediaAssemblerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "media reassembly error: {self:?}")
    }
}

impl Error for MediaAssemblerError {}

#[derive(Debug)]
struct PendingPlane {
    geometry_epoch: u64,
    source_submitted_ns: u64,
    chunks: Vec<Option<Bytes>>,
    received_bytes: usize,
    received_chunks: usize,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct PlaneKey {
    window_id: WindowId,
    plane: MediaPlane,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct FrameKey {
    plane: PlaneKey,
    frame_id: u64,
}

#[derive(Debug)]
pub struct MediaAssembler {
    config: MediaAssemblerConfig,
    newest_frame: HashMap<PlaneKey, u64>,
    completed_frame: HashMap<PlaneKey, u64>,
    pending: HashMap<FrameKey, PendingPlane>,
}

impl MediaAssembler {
    #[must_use]
    pub fn new(config: MediaAssemblerConfig) -> Self {
        Self {
            config,
            newest_frame: HashMap::new(),
            completed_frame: HashMap::new(),
            pending: HashMap::new(),
        }
    }

    /// Adds one packet and emits a complete color or alpha plane when ready.
    ///
    /// # Errors
    ///
    /// Rejects stale, late, inconsistent, unsupported, or oversized frames.
    pub fn push(
        &mut self,
        packet: MediaDatagram,
        received_ns: u64,
    ) -> Result<Option<AssembledPlane>, MediaAssemblerError> {
        let assembled = self.push_any(packet, received_ns)?;
        assembled.map(Self::into_frame_plane).transpose()
    }

    /// Complete the current latest frame under the caller's operation watchdog.
    /// Keeps timestamps, byte bounds and sequence checks; latency is measured by
    /// the caller instead of discarding the only frame awaiting feedback.
    pub fn push_latest(
        &mut self,
        packet: MediaDatagram,
        received_ns: u64,
    ) -> Result<Option<AssembledPlane>, MediaAssemblerError> {
        let timestamp = packet.source_submitted_ns;
        let age = received_ns.saturating_sub(timestamp);
        self.push_normalized(packet, received_ns, timestamp, age, false)?
            .map(Self::into_frame_plane)
            .transpose()
    }

    /// Adds a video packet whose timestamp comes from a synchronized peer.
    ///
    /// # Errors
    ///
    /// Applies the same validation as [`Self::push`] after normalizing the peer
    /// timestamp and accounting for synchronization uncertainty.
    pub fn push_remote(
        &mut self,
        packet: MediaDatagram,
        received_ns: u64,
        clock: ClockEstimate,
    ) -> Result<Option<AssembledPlane>, MediaAssemblerError> {
        let assembled = self.push_any_remote(packet, received_ns, clock)?;
        assembled.map(Self::into_frame_plane).transpose()
    }

    /// Reassembles any media plane for same-clock loopback or local producers.
    ///
    /// # Errors
    ///
    /// Rejects stale, late, inconsistent, or oversized frames.
    pub fn push_any(
        &mut self,
        packet: MediaDatagram,
        received_ns: u64,
    ) -> Result<Option<AssembledMedia>, MediaAssemblerError> {
        let source_submitted_ns = packet.source_submitted_ns;
        let age_ns = received_ns.saturating_sub(source_submitted_ns);
        self.push_normalized(packet, received_ns, source_submitted_ns, age_ns, true)
    }

    /// Reassembles any media plane from a synchronized remote producer.
    ///
    /// # Errors
    ///
    /// Rejects stale, late, inconsistent, or oversized frames.
    pub fn push_any_remote(
        &mut self,
        packet: MediaDatagram,
        received_ns: u64,
        clock: ClockEstimate,
    ) -> Result<Option<AssembledMedia>, MediaAssemblerError> {
        let source_submitted_ns = clock.remote_to_local_ns(packet.source_submitted_ns);
        let age_ns = clock.age_upper_bound_ns(packet.source_submitted_ns, received_ns);
        self.push_normalized(packet, received_ns, source_submitted_ns, age_ns, true)
    }

    fn push_normalized(
        &mut self,
        packet: MediaDatagram,
        received_ns: u64,
        source_submitted_ns: u64,
        age_ns: u64,
        enforce_latency_target: bool,
    ) -> Result<Option<AssembledMedia>, MediaAssemblerError> {
        // Callers may construct a datagram directly, without the wire decoder.
        // Validate before indexing or changing the newest-frame watermark.
        if packet.chunk_count == 0 || packet.chunk_index >= packet.chunk_count {
            return Err(MediaAssemblerError::InvalidChunkRange);
        }
        if enforce_latency_target && age_ns > self.config.deadline_ns {
            return Err(MediaAssemblerError::Late);
        }
        if packet.chunk_count > self.config.max_chunks_per_plane {
            return Err(MediaAssemblerError::TooManyChunks);
        }

        let plane_key = PlaneKey {
            window_id: packet.window_id,
            plane: packet.plane,
        };
        if self
            .completed_frame
            .get(&plane_key)
            .is_some_and(|completed| packet.frame_id <= *completed)
        {
            return Err(MediaAssemblerError::StaleFrame);
        }
        let newest = self
            .newest_frame
            .entry(plane_key)
            .or_insert(packet.frame_id);
        if packet.frame_id < *newest {
            return Err(MediaAssemblerError::StaleFrame);
        }
        if packet.frame_id > *newest {
            // Only the newest frame for this plane can be pending. Remove it
            // directly instead of scanning every other window on each frame.
            self.pending.remove(&FrameKey {
                plane: plane_key,
                frame_id: *newest,
            });
            *newest = packet.frame_id;
        }

        let frame_key = FrameKey {
            plane: plane_key,
            frame_id: packet.frame_id,
        };
        // A whole plane already owns a contiguous payload. Skip the slot
        // allocation and final copy, but retain consistency checks if an
        // earlier packet declared this same frame to have multiple chunks.
        if packet.chunk_count == 1 && !self.pending.contains_key(&frame_key) {
            if packet.payload.len() > self.config.max_plane_bytes {
                return Err(MediaAssemblerError::PlaneTooLarge);
            }
            self.completed_frame.insert(plane_key, packet.frame_id);
            return Ok(Some(AssembledMedia {
                window_id: packet.window_id,
                frame_id: packet.frame_id,
                geometry_epoch: packet.geometry_epoch,
                plane: packet.plane,
                source_submitted_ns,
                received_ns,
                payload: packet.payload,
            }));
        }
        let pending = self
            .pending
            .entry(frame_key)
            .or_insert_with(|| PendingPlane {
                geometry_epoch: packet.geometry_epoch,
                source_submitted_ns,
                chunks: vec![None; usize::from(packet.chunk_count)],
                received_bytes: 0,
                received_chunks: 0,
            });
        if pending.chunks.len() != usize::from(packet.chunk_count)
            || pending.geometry_epoch != packet.geometry_epoch
            || pending.source_submitted_ns != source_submitted_ns
        {
            return Err(MediaAssemblerError::InconsistentChunkCount);
        }
        let slot = &mut pending.chunks[usize::from(packet.chunk_index)];
        if slot.as_ref().is_some_and(|bytes| bytes != &packet.payload) {
            return Err(MediaAssemblerError::ConflictingChunk);
        }
        if slot.is_none() {
            pending.received_bytes = pending.received_bytes.saturating_add(packet.payload.len());
            if pending.received_bytes > self.config.max_plane_bytes {
                self.pending.remove(&frame_key);
                return Err(MediaAssemblerError::PlaneTooLarge);
            }
            *slot = Some(packet.payload);
            pending.received_chunks += 1;
        }
        // Counting first arrivals avoids repeatedly scanning every earlier
        // slot for each chunk of a large high-resolution frame.
        if pending.received_chunks != pending.chunks.len() {
            return Ok(None);
        }

        let mut payload = BytesMut::with_capacity(pending.received_bytes);
        for chunk in pending.chunks.iter().flatten() {
            payload.extend_from_slice(chunk);
        }
        let assembled = AssembledMedia {
            window_id: packet.window_id,
            frame_id: packet.frame_id,
            geometry_epoch: packet.geometry_epoch,
            plane: packet.plane,
            source_submitted_ns,
            received_ns,
            payload: payload.freeze(),
        };
        self.pending.remove(&frame_key);
        self.completed_frame.insert(plane_key, packet.frame_id);
        Ok(Some(assembled))
    }

    fn into_frame_plane(media: AssembledMedia) -> Result<AssembledPlane, MediaAssemblerError> {
        let plane = match media.plane {
            MediaPlane::Color => FramePlane::Color,
            MediaPlane::Alpha => FramePlane::Alpha,
            MediaPlane::Audio | MediaPlane::BlurBackground => {
                return Err(MediaAssemblerError::UnsupportedPlane);
            }
        };
        Ok(AssembledPlane {
            ready: FramePlaneReady {
                window_id: media.window_id,
                frame_id: media.frame_id,
                geometry_epoch: media.geometry_epoch,
                plane,
                source_submitted_ns: media.source_submitted_ns,
                received_ns: media.received_ns,
            },
            payload: media.payload,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::Id128;

    #[test]
    fn latest_frame_finishes_after_target_but_superseded_frame_is_dropped() {
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig {
            deadline_ns: 10,
            ..Default::default()
        });
        assert_eq!(assembler.push_latest(packet(1, 0, b"a"), 100), Ok(None));
        let frame = assembler
            .push_latest(packet(1, 1, b"b"), 120)
            .unwrap()
            .unwrap();
        assert_eq!(frame.ready.source_submitted_ns, 1);
        assert_eq!(frame.payload.as_ref(), b"ab");
        assert_eq!(assembler.push_latest(packet(2, 0, b"c"), 130), Ok(None));
        assert_eq!(assembler.push_latest(packet(3, 0, b"d"), 140), Ok(None));
        assert_eq!(
            assembler.push_latest(packet(2, 1, b"e"), 150),
            Err(MediaAssemblerError::StaleFrame)
        );
        assert_eq!(
            assembler
                .push_latest(packet(3, 1, b"f"), 160)
                .unwrap()
                .unwrap()
                .payload
                .as_ref(),
            b"df"
        );
    }

    #[test]
    fn invalid_chunk_ranges_do_not_panic_or_advance_watermark() {
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
        for (count, index) in [(0, 0), (1, 1), (2, u16::MAX)] {
            let mut invalid = packet(99, index, b"invalid");
            invalid.chunk_count = count;
            assert_eq!(
                assembler.push(invalid, 100),
                Err(MediaAssemblerError::InvalidChunkRange)
            );
        }
        assert_eq!(assembler.push(packet(1, 0, b"a"), 100), Ok(None));
        assert_eq!(
            assembler
                .push(packet(1, 1, b"b"), 100)
                .unwrap()
                .unwrap()
                .payload
                .as_ref(),
            b"ab"
        );
    }

    #[test]
    fn duplicate_chunks_must_match_the_retained_bytes() {
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
        assert_eq!(assembler.push(packet(1, 0, b"a"), 100), Ok(None));
        assert_eq!(assembler.push(packet(1, 0, b"a"), 100), Ok(None));
        assert_eq!(
            assembler.push(packet(1, 0, b"changed"), 100),
            Err(MediaAssemblerError::ConflictingChunk)
        );
        assert_eq!(
            assembler
                .push(packet(1, 1, b"b"), 100)
                .unwrap()
                .unwrap()
                .payload
                .as_ref(),
            b"ab"
        );
    }

    fn packet(frame: u64, chunk: u16, payload: &'static [u8]) -> MediaDatagram {
        MediaDatagram {
            window_id: Id128(1),
            frame_id: frame,
            geometry_epoch: 2,
            plane: MediaPlane::Color,
            chunk_index: chunk,
            chunk_count: 2,
            source_submitted_ns: 1,
            payload: Bytes::from_static(payload),
        }
    }

    #[test]
    fn single_chunk_retains_payload_allocation_and_checks_limits() {
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig {
            max_plane_bytes: 3,
            ..Default::default()
        });
        let mut single = packet(1, 0, b"abc");
        single.chunk_count = 1;
        single.payload = Bytes::from(vec![1, 2, 3]);
        let original = single.payload.clone();
        let frame = assembler.push_latest(single.clone(), 100).unwrap().unwrap();
        assert_eq!(frame.payload.as_ptr(), original.as_ptr());
        assert_eq!(frame.payload, original);
        assert_eq!(
            assembler.push_latest(single.clone(), 100),
            Err(MediaAssemblerError::StaleFrame)
        );
        single.frame_id = 2;
        single.payload = Bytes::from_static(b"abcd");
        assert_eq!(
            assembler.push_latest(single, 100),
            Err(MediaAssemblerError::PlaneTooLarge)
        );
        assert!(assembler.pending.is_empty());
    }

    #[test]
    fn single_chunk_cannot_replace_inconsistent_pending_frame() {
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
        assembler.push_latest(packet(1, 0, b"a"), 100).unwrap();
        let mut single = packet(1, 0, b"a");
        single.chunk_count = 1;
        assert_eq!(
            assembler.push_latest(single, 100),
            Err(MediaAssemblerError::InconsistentChunkCount)
        );
        assert_eq!(
            assembler
                .push_latest(packet(1, 1, b"b"), 100)
                .unwrap()
                .unwrap()
                .payload
                .as_ref(),
            b"ab"
        );
    }

    #[test]
    fn replacing_frame_preserves_other_windows_and_planes() {
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
        for (window, plane) in [
            (1, MediaPlane::Color),
            (2, MediaPlane::Color),
            (1, MediaPlane::Alpha),
        ] {
            let mut first = packet(1, 0, b"a");
            first.window_id = Id128(window);
            first.plane = plane;
            assembler.push_latest(first, 100).unwrap();
        }
        assembler.push_latest(packet(2, 0, b"new"), 100).unwrap();
        assert_eq!(assembler.pending.len(), 3);
        for (window, plane) in [(2, MediaPlane::Color), (1, MediaPlane::Alpha)] {
            let mut last = packet(1, 1, b"b");
            last.window_id = Id128(window);
            last.plane = plane;
            assert_eq!(
                assembler
                    .push_latest(last, 100)
                    .unwrap()
                    .unwrap()
                    .payload
                    .as_ref(),
                b"ab"
            );
        }
        assert_eq!(
            assembler
                .push_latest(packet(2, 1, b" frame"), 100)
                .unwrap()
                .unwrap()
                .payload
                .as_ref(),
            b"new frame"
        );
        assert!(assembler.pending.is_empty());
    }

    #[test]
    fn reassembles_out_of_order_chunks() {
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
        assert_eq!(assembler.push(packet(1, 1, b"world"), 10).unwrap(), None);
        let frame = assembler
            .push(packet(1, 0, b"hello "), 11)
            .unwrap()
            .unwrap();
        assert_eq!(frame.payload, Bytes::from_static(b"hello world"));
    }

    #[test]
    fn many_chunks_and_duplicates_complete_only_when_last_gap_arrives() {
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
        let make = |index| {
            let mut value = packet(1, index, b"x");
            value.chunk_count = 8192;
            value
        };
        for index in (1..8192).rev() {
            assert!(assembler.push(make(index), 100).unwrap().is_none());
            assert!(assembler.push(make(index), 100).unwrap().is_none());
        }
        let complete = assembler.push(make(0), 100).unwrap().unwrap();
        assert_eq!(complete.payload.len(), 8192);
        assert!(complete.payload.iter().all(|byte| *byte == b'x'));
        assert_eq!(
            assembler.push(make(0), 100),
            Err(MediaAssemblerError::StaleFrame)
        );
    }

    #[test]
    fn newer_frame_evicts_incomplete_old_frame() {
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
        assembler.push(packet(1, 0, b"old"), 10).unwrap();
        assembler.push(packet(2, 0, b"new"), 11).unwrap();
        assert_eq!(
            assembler.push(packet(1, 1, b"stale"), 12),
            Err(MediaAssemblerError::StaleFrame)
        );
    }

    #[test]
    fn reassembles_audio_and_blur_through_generic_path() {
        for plane in [MediaPlane::Audio, MediaPlane::BlurBackground] {
            let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
            let mut first = packet(1, 0, b"first");
            first.plane = plane;
            let mut second = packet(1, 1, b"second");
            second.plane = plane;
            assembler.push_any(first, 10).unwrap();
            let media = assembler.push_any(second, 11).unwrap().unwrap();
            assert_eq!(media.plane, plane);
            assert_eq!(media.payload, Bytes::from_static(b"firstsecond"));
        }
    }

    #[test]
    fn rejects_replayed_completed_frame() {
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
        assembler.push(packet(1, 0, b"hello "), 10).unwrap();
        assembler.push(packet(1, 1, b"world"), 11).unwrap();
        assert_eq!(
            assembler.push(packet(1, 0, b"replay"), 12),
            Err(MediaAssemblerError::StaleFrame)
        );
    }

    #[test]
    fn remote_path_normalizes_source_timestamp_before_admission() {
        let clock = ClockEstimate {
            remote_offset_ns: 5_000_000,
            network_round_trip_ns: 2_000_000,
            uncertainty_ns: 1_000_000,
        };
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
        let mut first = packet(1, 0, b"hello ");
        first.source_submitted_ns = 15_000_000;
        let mut second = packet(1, 1, b"world");
        second.source_submitted_ns = 15_000_000;
        assembler.push_remote(first, 12_000_000, clock).unwrap();
        let plane = assembler
            .push_remote(second, 13_000_000, clock)
            .unwrap()
            .unwrap();
        assert_eq!(plane.ready.source_submitted_ns, 10_000_000);
        assert_eq!(plane.ready.received_ns, 13_000_000);
    }
}
