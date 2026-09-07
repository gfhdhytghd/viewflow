//! Bounded receiver-side media admission.
//!
//! This module deliberately stops at delivery of encoded plane bytes. Native
//! decode and proxy composition belong to platform backends; keeping that
//! boundary explicit prevents the transport plumbing from pretending to be a
//! graphics implementation.

use std::collections::{BTreeMap, HashMap};

use bytes::Bytes;
use quinn::Connection;
use viewflow_core::{FrameAdmission, FrameQueue, FrameQueueConfig, FrameRejectReason};
use viewflow_protocol::{FrameManifest, FramePlane, WindowId};
use viewflow_transport::{
    AssembledPlane, ClockEstimate, MediaAssembler, MediaAssemblerConfig, MediaAssemblerError,
    MediaDatagram,
};

/// Upper bounds for one authenticated receiver's not-yet-presented media.
#[derive(Clone, Copy, Debug)]
pub struct MediaReceiverConfig {
    pub assembler: MediaAssemblerConfig,
    pub max_windows: usize,
    /// Total completed encoded bytes held while waiting for an atomic frame pair.
    pub max_pending_bytes: usize,
}

impl Default for MediaReceiverConfig {
    fn default() -> Self {
        Self {
            assembler: MediaAssemblerConfig::default(),
            max_windows: 256,
            max_pending_bytes: 64 * 1024 * 1024,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EncodedFrame {
    pub manifest: FrameManifest,
    pub color: Bytes,
    pub alpha: Option<Bytes>,
}

/// Platform-facing boundary: the receiver hands off an atomically admitted
/// encoded frame. A native decoder/proxy backend implements this trait later.
pub trait EncodedFrameSink {
    type Error;

    /// # Errors
    ///
    /// Returns the backend's delivery failure without attempting a retry.
    fn deliver_encoded_frame(&mut self, frame: EncodedFrame) -> Result<(), Self::Error>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MediaReceiverOutcome {
    Waiting,
    Delivered(FrameManifest),
    Rejected(FrameRejectReason),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MediaReceiverError {
    InvalidConfig,
    WindowLimit,
    WindowAlreadyRegistered,
    UnknownWindow,
    EpochRegression,
    PendingBytesLimit,
    UnsupportedPlane,
    SinkDelivery,
    Assembly(MediaAssemblerError),
}

/// Failure while reading one actual QUIC media datagram or admitting it.
#[derive(Debug)]
pub enum ReceiveMediaError {
    Connection(quinn::ConnectionError),
    Datagram(viewflow_transport::MediaDatagramError),
    Receiver(MediaReceiverError),
}

impl std::fmt::Display for ReceiveMediaError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "media receive error: {self:?}")
    }
}

impl std::error::Error for ReceiveMediaError {}

impl std::fmt::Display for MediaReceiverError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "media receiver error: {self:?}")
    }
}

impl std::error::Error for MediaReceiverError {}

impl From<MediaAssemblerError> for MediaReceiverError {
    fn from(value: MediaAssemblerError) -> Self {
        Self::Assembly(value)
    }
}

#[derive(Default)]
struct PendingFrame {
    color: Option<Bytes>,
    alpha: Option<Bytes>,
}

struct WindowReceiver {
    geometry_epoch: u64,
    requires_alpha: bool,
    queue: FrameQueue,
    assembler: MediaAssembler,
    pending: BTreeMap<u64, PendingFrame>,
}

/// Owns bounded reassembly and per-window atomic color/alpha admission.
pub struct MediaReceiver {
    config: MediaReceiverConfig,
    windows: HashMap<WindowId, WindowReceiver>,
    pending_bytes: usize,
}

impl MediaReceiver {
    /// Creates a receiver with explicit aggregate limits.
    ///
    /// # Errors
    ///
    /// Returns [`MediaReceiverError::InvalidConfig`] for zero resource bounds.
    pub fn new(config: MediaReceiverConfig) -> Result<Self, MediaReceiverError> {
        if config.max_windows == 0
            || config.max_pending_bytes == 0
            || config.assembler.max_plane_bytes == 0
            || config.assembler.max_chunks_per_plane == 0
        {
            return Err(MediaReceiverError::InvalidConfig);
        }
        Ok(Self {
            config,
            windows: HashMap::new(),
            pending_bytes: 0,
        })
    }

    /// Registers one remote window before accepting its media packets.
    ///
    /// # Errors
    ///
    /// Returns an error for a duplicate window or when the window bound is full.
    pub fn register_window(
        &mut self,
        window: WindowId,
        geometry_epoch: u64,
        frame_config: FrameQueueConfig,
    ) -> Result<(), MediaReceiverError> {
        if self.windows.contains_key(&window) {
            return Err(MediaReceiverError::WindowAlreadyRegistered);
        }
        if self.windows.len() >= self.config.max_windows {
            return Err(MediaReceiverError::WindowLimit);
        }
        let mut queue = FrameQueue::new(frame_config);
        queue.set_geometry_epoch(geometry_epoch);
        self.windows.insert(
            window,
            WindowReceiver {
                geometry_epoch,
                requires_alpha: frame_config.requires_alpha,
                queue,
                assembler: MediaAssembler::new(self.config.assembler),
                pending: BTreeMap::new(),
            },
        );
        Ok(())
    }

    /// Advances a committed geometry epoch and drops completed old-size bytes.
    ///
    /// # Errors
    ///
    /// Returns an error for an unknown window or an epoch regression.
    pub fn set_geometry_epoch(
        &mut self,
        window: WindowId,
        geometry_epoch: u64,
    ) -> Result<(), MediaReceiverError> {
        let Some(receiver) = self.windows.get_mut(&window) else {
            return Err(MediaReceiverError::UnknownWindow);
        };
        if geometry_epoch < receiver.geometry_epoch {
            return Err(MediaReceiverError::EpochRegression);
        }
        if geometry_epoch > receiver.geometry_epoch {
            receiver.geometry_epoch = geometry_epoch;
            receiver.queue.set_geometry_epoch(geometry_epoch);
            // Partial old-size datagrams must not survive into the new epoch.
            receiver.assembler = MediaAssembler::new(self.config.assembler);
            let released = pending_bytes(&receiver.pending);
            receiver.pending.clear();
            self.pending_bytes = self.pending_bytes.saturating_sub(released);
        }
        Ok(())
    }

    #[must_use]
    pub const fn pending_bytes(&self) -> usize {
        self.pending_bytes
    }

    #[must_use]
    pub fn registered_windows(&self) -> usize {
        self.windows.len()
    }

    /// Stops accepting a window and releases both completed and incomplete media.
    ///
    /// # Errors
    ///
    /// Returns an error if the window was not registered.
    pub fn unregister_window(&mut self, window: WindowId) -> Result<(), MediaReceiverError> {
        if !self.windows.contains_key(&window) {
            return Err(MediaReceiverError::UnknownWindow);
        }
        self.remove_window_pending(window);
        Ok(())
    }

    /// Accepts one QUIC datagram with a peer clock estimate and delivers an
    /// atomically admitted encoded frame to the backend-facing sink.
    ///
    /// # Errors
    ///
    /// Returns explicit errors for unregistered windows, unsupported planes,
    /// bounded reassembly failures, byte limits, or backend delivery failure.
    pub fn push_remote<S: EncodedFrameSink>(
        &mut self,
        packet: MediaDatagram,
        received_ns: u64,
        clock: ClockEstimate,
        sink: &mut S,
    ) -> Result<MediaReceiverOutcome, MediaReceiverError> {
        let Some(receiver) = self.windows.get(&packet.window_id) else {
            return Err(MediaReceiverError::UnknownWindow);
        };
        if !matches!(
            packet.plane,
            viewflow_transport::MediaPlane::Color | viewflow_transport::MediaPlane::Alpha
        ) {
            return Err(MediaReceiverError::UnsupportedPlane);
        }
        if packet.geometry_epoch < receiver.geometry_epoch {
            return Ok(MediaReceiverOutcome::Rejected(
                FrameRejectReason::StaleGeometry,
            ));
        }
        if packet.geometry_epoch > receiver.geometry_epoch {
            return Ok(MediaReceiverOutcome::Rejected(
                FrameRejectReason::FutureGeometry,
            ));
        }

        let Some(receiver) = self.windows.get_mut(&packet.window_id) else {
            return Err(MediaReceiverError::UnknownWindow);
        };
        let Some(assembled) = receiver.assembler.push_remote(packet, received_ns, clock)? else {
            return Ok(MediaReceiverOutcome::Waiting);
        };
        self.admit(assembled, sink)
    }

    /// Reads exactly one QUIC datagram, validates its media header, then runs
    /// the same bounded clock/epoch/atomic-pair admission as [`Self::push_remote`].
    ///
    /// # Errors
    ///
    /// Returns a connection, datagram-header, or receiver admission failure.
    pub async fn receive_next<S: EncodedFrameSink>(
        &mut self,
        connection: &Connection,
        received_ns: impl FnOnce() -> u64,
        clock: ClockEstimate,
        sink: &mut S,
    ) -> Result<MediaReceiverOutcome, ReceiveMediaError> {
        let bytes = connection
            .read_datagram()
            .await
            .map_err(ReceiveMediaError::Connection)?;
        let packet = MediaDatagram::decode(bytes).map_err(ReceiveMediaError::Datagram)?;
        self.push_remote(packet, received_ns(), clock, sink)
            .map_err(ReceiveMediaError::Receiver)
    }

    fn admit<S: EncodedFrameSink>(
        &mut self,
        assembled: AssembledPlane,
        sink: &mut S,
    ) -> Result<MediaReceiverOutcome, MediaReceiverError> {
        let window = assembled.ready.window_id;
        let frame_id = assembled.ready.frame_id;
        let bytes = assembled.payload;
        let byte_count = bytes.len();
        let receiver = self
            .windows
            .get_mut(&window)
            .expect("window was checked before assembly");

        // Mirror FrameQueue's latest-frame policy so discarded old bytes do not
        // survive after the queue has moved on.
        let released = remove_older_pending(&mut receiver.pending, frame_id);
        self.pending_bytes = self.pending_bytes.saturating_sub(released);
        if self.pending_bytes.saturating_add(byte_count) > self.config.max_pending_bytes {
            return Err(MediaReceiverError::PendingBytesLimit);
        }

        let pending = receiver.pending.entry(frame_id).or_default();
        let slot = match assembled.ready.plane {
            FramePlane::Color => &mut pending.color,
            FramePlane::Alpha => &mut pending.alpha,
        };
        let replaced = slot.replace(bytes);
        self.pending_bytes = self
            .pending_bytes
            .saturating_add(byte_count)
            .saturating_sub(replaced.as_ref().map_or(0, Bytes::len));

        match receiver.queue.push(assembled.ready) {
            FrameAdmission::Waiting => Ok(MediaReceiverOutcome::Waiting),
            FrameAdmission::Rejected(reason) => {
                let released = receiver
                    .pending
                    .remove(&frame_id)
                    .map_or(0, |frame| pending_frame_bytes(&frame));
                self.pending_bytes = self.pending_bytes.saturating_sub(released);
                Ok(MediaReceiverOutcome::Rejected(reason))
            }
            FrameAdmission::Ready(manifest) => {
                let frame = receiver
                    .pending
                    .remove(&frame_id)
                    .expect("ready frame was staged");
                let color = frame.color.expect("frame queue requires color");
                let alpha = frame.alpha;
                debug_assert!(!receiver.requires_alpha || alpha.is_some());
                let released = color.len() + alpha.as_ref().map_or(0, Bytes::len);
                self.pending_bytes = self.pending_bytes.saturating_sub(released);
                // FrameQueue has discarded every incomplete predecessor too.
                let released = pending_bytes(&receiver.pending);
                receiver.pending.clear();
                self.pending_bytes = self.pending_bytes.saturating_sub(released);
                sink.deliver_encoded_frame(EncodedFrame {
                    manifest,
                    color,
                    alpha,
                })
                .map_err(|_| MediaReceiverError::SinkDelivery)?;
                Ok(MediaReceiverOutcome::Delivered(manifest))
            }
        }
    }

    fn remove_window_pending(&mut self, window: WindowId) {
        if let Some(previous) = self.windows.remove(&window) {
            self.pending_bytes = self
                .pending_bytes
                .saturating_sub(pending_bytes(&previous.pending));
        }
    }
}

fn pending_frame_bytes(frame: &PendingFrame) -> usize {
    frame.color.as_ref().map_or(0, Bytes::len) + frame.alpha.as_ref().map_or(0, Bytes::len)
}

fn pending_bytes(pending: &BTreeMap<u64, PendingFrame>) -> usize {
    pending.values().map(pending_frame_bytes).sum()
}

fn remove_older_pending(pending: &mut BTreeMap<u64, PendingFrame>, frame_id: u64) -> usize {
    let current_or_newer = pending.split_off(&frame_id);
    let discarded = std::mem::replace(pending, current_or_newer);
    pending_bytes(&discarded)
}

#[cfg(test)]
mod tests {
    use bytes::Bytes;
    use viewflow_protocol::Id128;
    use viewflow_transport::{MediaDatagram, MediaPlane};

    use super::*;

    #[derive(Default)]
    struct Sink(Vec<EncodedFrame>);

    impl EncodedFrameSink for Sink {
        type Error = ();

        fn deliver_encoded_frame(&mut self, frame: EncodedFrame) -> Result<(), Self::Error> {
            self.0.push(frame);
            Ok(())
        }
    }

    fn receiver(requires_alpha: bool) -> MediaReceiver {
        let mut receiver = MediaReceiver::new(MediaReceiverConfig {
            assembler: MediaAssemblerConfig {
                deadline_ns: 100,
                max_chunks_per_plane: 2,
                max_plane_bytes: 16,
            },
            max_windows: 1,
            max_pending_bytes: 32,
        })
        .unwrap();
        receiver
            .register_window(
                Id128(1),
                2,
                FrameQueueConfig {
                    refresh_millihz: 1_000_000_000,
                    max_refresh_periods: 1,
                    requires_alpha,
                },
            )
            .unwrap();
        receiver
    }

    fn packet(
        frame_id: u64,
        epoch: u64,
        plane: MediaPlane,
        payload: &'static [u8],
    ) -> MediaDatagram {
        MediaDatagram {
            window_id: Id128(1),
            frame_id,
            geometry_epoch: epoch,
            plane,
            chunk_index: 0,
            chunk_count: 1,
            source_submitted_ns: 10,
            payload: Bytes::from_static(payload),
        }
    }

    fn chunk(
        frame_id: u64,
        epoch: u64,
        plane: MediaPlane,
        chunk_index: u16,
        chunk_count: u16,
        payload: &'static [u8],
    ) -> MediaDatagram {
        MediaDatagram {
            window_id: Id128(1),
            frame_id,
            geometry_epoch: epoch,
            plane,
            chunk_index,
            chunk_count,
            source_submitted_ns: 10,
            payload: Bytes::from_static(payload),
        }
    }

    fn clock() -> ClockEstimate {
        ClockEstimate {
            remote_offset_ns: 0,
            network_round_trip_ns: 0,
            uncertainty_ns: 0,
        }
    }

    #[test]
    fn retains_actual_encoded_color_and_alpha_until_atomic_delivery() {
        let mut receiver = receiver(true);
        let mut sink = Sink::default();
        assert_eq!(
            receiver
                .push_remote(
                    packet(8, 2, MediaPlane::Color, b"color-h264"),
                    20,
                    clock(),
                    &mut sink
                )
                .unwrap(),
            MediaReceiverOutcome::Waiting
        );
        assert_eq!(receiver.pending_bytes(), 10);
        assert_eq!(
            receiver
                .push_remote(
                    packet(8, 2, MediaPlane::Alpha, b"alpha-a8"),
                    21,
                    clock(),
                    &mut sink
                )
                .unwrap(),
            MediaReceiverOutcome::Delivered(sink.0[0].manifest)
        );
        assert_eq!(sink.0.len(), 1);
        assert_eq!(sink.0[0].color, Bytes::from_static(b"color-h264"));
        assert_eq!(sink.0[0].alpha, Some(Bytes::from_static(b"alpha-a8")));
        assert_eq!(receiver.pending_bytes(), 0);
    }

    #[test]
    fn alpha_from_another_frame_never_delivers_color() {
        let mut receiver = receiver(true);
        let mut sink = Sink::default();
        receiver
            .push_remote(
                packet(8, 2, MediaPlane::Color, b"color"),
                20,
                clock(),
                &mut sink,
            )
            .unwrap();
        receiver
            .push_remote(
                packet(9, 2, MediaPlane::Alpha, b"alpha"),
                21,
                clock(),
                &mut sink,
            )
            .unwrap();
        assert!(sink.0.is_empty());
        assert!(receiver.pending_bytes() <= 5);
    }

    #[test]
    fn rejects_stale_and_future_epochs_and_cleans_on_epoch_change() {
        let mut receiver = receiver(true);
        let mut sink = Sink::default();
        assert_eq!(
            receiver
                .push_remote(
                    packet(1, 1, MediaPlane::Color, b"old"),
                    20,
                    clock(),
                    &mut sink
                )
                .unwrap(),
            MediaReceiverOutcome::Rejected(FrameRejectReason::StaleGeometry)
        );
        assert_eq!(
            receiver
                .push_remote(
                    packet(1, 3, MediaPlane::Color, b"new"),
                    20,
                    clock(),
                    &mut sink
                )
                .unwrap(),
            MediaReceiverOutcome::Rejected(FrameRejectReason::FutureGeometry)
        );
        receiver
            .push_remote(
                packet(2, 2, MediaPlane::Color, b"held"),
                20,
                clock(),
                &mut sink,
            )
            .unwrap();
        assert_eq!(receiver.pending_bytes(), 4);
        receiver.set_geometry_epoch(Id128(1), 3).unwrap();
        assert_eq!(receiver.pending_bytes(), 0);
    }

    #[test]
    fn enforces_window_and_completed_byte_limits() {
        let mut bounded = receiver(false);
        assert_eq!(
            bounded.register_window(
                Id128(2),
                2,
                FrameQueueConfig {
                    refresh_millihz: 60_000,
                    max_refresh_periods: 2,
                    requires_alpha: false,
                },
            ),
            Err(MediaReceiverError::WindowLimit)
        );

        let mut limited = receiver(true);
        limited.config.max_pending_bytes = 3;
        let mut sink = Sink::default();
        assert_eq!(
            limited.push_remote(
                packet(1, 2, MediaPlane::Color, b"four"),
                20,
                clock(),
                &mut sink
            ),
            Err(MediaReceiverError::PendingBytesLimit)
        );
        assert_eq!(limited.pending_bytes(), 0);
    }

    #[test]
    fn opaque_frame_does_not_require_alpha() {
        let mut receiver = receiver(false);
        let mut sink = Sink::default();
        receiver
            .push_remote(
                packet(1, 2, MediaPlane::Color, b"opaque"),
                20,
                clock(),
                &mut sink,
            )
            .unwrap();
        assert_eq!(sink.0.len(), 1);
        assert_eq!(sink.0[0].alpha, None);
    }

    #[test]
    fn epoch_change_discards_partial_reassembly() {
        let mut receiver = receiver(false);
        let mut sink = Sink::default();
        receiver
            .push_remote(
                chunk(4, 2, MediaPlane::Color, 0, 2, b"old-"),
                20,
                clock(),
                &mut sink,
            )
            .unwrap();
        receiver.set_geometry_epoch(Id128(1), 3).unwrap();

        // If the old fragment survived, this cross-epoch continuation would
        // fail reassembly or combine old bytes. It must instead wait for the
        // new epoch's missing first fragment.
        assert_eq!(
            receiver
                .push_remote(
                    chunk(4, 3, MediaPlane::Color, 1, 2, b"new"),
                    21,
                    clock(),
                    &mut sink,
                )
                .unwrap(),
            MediaReceiverOutcome::Waiting
        );
        receiver
            .push_remote(
                chunk(4, 3, MediaPlane::Color, 0, 2, b"fresh-"),
                22,
                clock(),
                &mut sink,
            )
            .unwrap();
        assert_eq!(sink.0.len(), 1);
        assert_eq!(sink.0[0].color, Bytes::from_static(b"fresh-new"));
    }

    #[test]
    fn unregister_releases_completed_and_partial_state_then_allows_reregistration() {
        let mut receiver = receiver(true);
        let mut sink = Sink::default();
        receiver
            .push_remote(
                packet(1, 2, MediaPlane::Color, b"held"),
                20,
                clock(),
                &mut sink,
            )
            .unwrap();
        assert_eq!(receiver.pending_bytes(), 4);
        receiver
            .push_remote(
                chunk(2, 2, MediaPlane::Alpha, 0, 2, b"partial"),
                21,
                clock(),
                &mut sink,
            )
            .unwrap();

        receiver.unregister_window(Id128(1)).unwrap();
        assert_eq!(receiver.pending_bytes(), 0);
        assert_eq!(receiver.registered_windows(), 0);
        receiver
            .register_window(
                Id128(1),
                3,
                FrameQueueConfig {
                    refresh_millihz: 1_000_000_000,
                    max_refresh_periods: 1,
                    requires_alpha: false,
                },
            )
            .unwrap();

        // The former partial alpha is gone, and the re-registered window can
        // accept a new encoded frame under its new epoch.
        receiver
            .push_remote(
                packet(3, 3, MediaPlane::Color, b"again"),
                22,
                clock(),
                &mut sink,
            )
            .unwrap();
        assert_eq!(sink.0.len(), 1);
        assert_eq!(sink.0[0].color, Bytes::from_static(b"again"));
    }
}
