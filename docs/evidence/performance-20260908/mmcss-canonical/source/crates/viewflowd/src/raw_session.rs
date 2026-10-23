//! Persistent raw-BGRA presentation state for already-created native windows.
//!
//! This is deliberately a small receiver/presenter ownership layer.  It does
//! not create windows, read a connection, or claim that a submitted frame has
//! reached the display; a running session supplies existing presenters and
//! feeds remote media packets into [`RawWindowSession::push_remote`].

use std::collections::HashMap;

use viewflow_core::{FrameQueueConfig, FrameRejectReason};
use viewflow_protocol::{FrameManifest, WindowId};
use viewflow_transport::{ClockEstimate, MediaAssemblerError, MediaDatagram, MediaPlane};

use crate::{
    media_runtime::{MediaReceiver, MediaReceiverConfig, MediaReceiverError, MediaReceiverOutcome},
    pixel_runtime::{PixelPresenter, PixelSinkError, RawBgraSink},
};

/// Resource bounds for one persistent raw-window receiving session.
#[derive(Clone, Copy, Debug)]
pub struct RawWindowSessionConfig {
    /// Reassembly and aggregate completed-frame bounds.
    pub receiver: MediaReceiverConfig,
    /// Number of supplied native presenters retained at once.
    pub max_presenters: usize,
    /// Maximum decoded raw-BGRA payload size for one frame.
    pub max_pixel_bytes: usize,
}

impl Default for RawWindowSessionConfig {
    fn default() -> Self {
        let receiver = MediaReceiverConfig::default();
        Self {
            max_presenters: receiver.max_windows,
            max_pixel_bytes: receiver.assembler.max_plane_bytes,
            receiver,
        }
    }
}

/// A non-fatal result for media that is no longer useful to present.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RawWindowSessionDrop {
    Late,
    StaleFrame,
    StaleGeometry,
    FutureGeometry,
}

/// Result of adding one remote raw-BGRA packet to a persistent session.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RawWindowSessionOutcome {
    Waiting,
    Presented(FrameManifest),
    Dropped(RawWindowSessionDrop),
}

/// Errors which require the caller to correct input, session state, or its
/// native presenter rather than merely sending a newer frame.
#[derive(Debug)]
pub enum RawWindowSessionError {
    Receiver(MediaReceiverError),
    Pixel(PixelSinkError),
    WindowAlreadyOpen,
    WindowLimit,
    UnknownWindow,
    EpochRegression,
    /// Raw BGRA carries premultiplied alpha in its color payload.  A separate
    /// alpha plane therefore does not belong to this session codec.
    SeparateAlphaUnsupported,
    UnsupportedPlane,
    StateInvariant,
}

impl std::fmt::Display for RawWindowSessionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "raw window session error: {self:?}")
    }
}

impl std::error::Error for RawWindowSessionError {}

/// Retains supplied native presenters while media is reassembled and submitted.
///
/// `epochs` is intentionally owned here in addition to the receiver and sink.
/// Every expected duplicate/unknown/regressing request is rejected before
/// either child is mutated, so their geometry state cannot drift apart.
pub struct RawWindowSession<P> {
    receiver: MediaReceiver,
    sink: RawBgraSink<P>,
    epochs: HashMap<WindowId, u64>,
    max_windows: usize,
}

impl<P: PixelPresenter> RawWindowSession<P> {
    /// Creates bounded persistent state.  Native windows are supplied later to
    /// [`Self::open`] and remain caller-owned again after [`Self::close`].
    ///
    /// # Errors
    ///
    /// Returns the receiver or raw-pixel bound validation failure.
    pub fn new(config: RawWindowSessionConfig) -> Result<Self, RawWindowSessionError> {
        let receiver =
            MediaReceiver::new(config.receiver).map_err(RawWindowSessionError::Receiver)?;
        let sink = RawBgraSink::new(config.max_presenters, config.max_pixel_bytes)
            .map_err(RawWindowSessionError::Pixel)?;
        Ok(Self {
            receiver,
            sink,
            epochs: HashMap::new(),
            max_windows: config.receiver.max_windows.min(config.max_presenters),
        })
    }

    /// Registers an existing native presenter for one remote window.
    ///
    /// # Errors
    ///
    /// Duplicate and capacity errors leave both child registries unchanged.
    pub fn open(
        &mut self,
        window: WindowId,
        geometry_epoch: u64,
        frame_config: FrameQueueConfig,
        presenter: P,
    ) -> Result<(), RawWindowSessionError> {
        if frame_config.requires_alpha {
            // This codec embeds alpha; accepting a paired-plane queue here
            // would retain color forever while separately rejecting its alpha.
            return Err(RawWindowSessionError::SeparateAlphaUnsupported);
        }
        if self.epochs.contains_key(&window) {
            return Err(RawWindowSessionError::WindowAlreadyOpen);
        }
        if self.epochs.len() >= self.max_windows {
            return Err(RawWindowSessionError::WindowLimit);
        }

        // The local checks above eliminate the expected errors from both
        // registrations; do not add the epoch until both have succeeded.
        self.receiver
            .register_window(window, geometry_epoch, frame_config)
            .map_err(RawWindowSessionError::Receiver)?;
        self.sink
            .attach(window, geometry_epoch, presenter)
            .map_err(RawWindowSessionError::Pixel)?;
        self.epochs.insert(window, geometry_epoch);
        Ok(())
    }

    /// Commits a geometry epoch to reassembly and presentation together.
    ///
    /// # Errors
    ///
    /// Unknown windows and backwards epochs are rejected before either child
    /// is changed.  A newer epoch releases partial old-geometry media.
    pub fn commit_geometry(
        &mut self,
        window: WindowId,
        geometry_epoch: u64,
    ) -> Result<(), RawWindowSessionError> {
        let current = *self
            .epochs
            .get(&window)
            .ok_or(RawWindowSessionError::UnknownWindow)?;
        if geometry_epoch < current {
            return Err(RawWindowSessionError::EpochRegression);
        }
        if geometry_epoch == current {
            return Ok(());
        }

        self.receiver
            .set_geometry_epoch(window, geometry_epoch)
            .map_err(RawWindowSessionError::Receiver)?;
        self.sink
            .commit_geometry(window, geometry_epoch)
            .map_err(RawWindowSessionError::Pixel)?;
        self.epochs.insert(window, geometry_epoch);
        Ok(())
    }

    /// Unregisters a window and returns its supplied native presenter.
    ///
    /// # Errors
    ///
    /// An unknown window leaves the session unchanged.
    pub fn close(&mut self, window: WindowId) -> Result<P, RawWindowSessionError> {
        if !self.epochs.contains_key(&window) {
            return Err(RawWindowSessionError::UnknownWindow);
        }
        self.receiver
            .unregister_window(window)
            .map_err(RawWindowSessionError::Receiver)?;
        let presenter = self
            .sink
            .detach(window)
            .ok_or(RawWindowSessionError::StateInvariant)?;
        self.epochs.remove(&window);
        Ok(presenter)
    }

    /// Adds one remote packet for the explicit raw-BGRA-with-embedded-alpha
    /// codec.  Late or stale media is intentionally non-fatal: callers should
    /// continue feeding the same session with newer frames.
    ///
    /// # Errors
    ///
    /// Malformed reassembly, unknown windows, invalid raw payloads, and native
    /// presentation failures remain errors.
    pub fn push_remote(
        &mut self,
        packet: MediaDatagram,
        received_ns: u64,
        clock: ClockEstimate,
    ) -> Result<RawWindowSessionOutcome, RawWindowSessionError> {
        if !self.epochs.contains_key(&packet.window_id) {
            return Err(RawWindowSessionError::UnknownWindow);
        }
        match packet.plane {
            MediaPlane::Color => {}
            MediaPlane::Alpha => return Err(RawWindowSessionError::SeparateAlphaUnsupported),
            _ => return Err(RawWindowSessionError::UnsupportedPlane),
        }

        match self
            .receiver
            .push_remote(packet, received_ns, clock, &mut self.sink)
        {
            Ok(outcome) => Ok(map_receiver_outcome(outcome)),
            Err(MediaReceiverError::Assembly(MediaAssemblerError::Late)) => {
                Ok(RawWindowSessionOutcome::Dropped(RawWindowSessionDrop::Late))
            }
            Err(MediaReceiverError::Assembly(MediaAssemblerError::StaleFrame)) => Ok(
                RawWindowSessionOutcome::Dropped(RawWindowSessionDrop::StaleFrame),
            ),
            Err(error) => Err(RawWindowSessionError::Receiver(error)),
        }
    }

    #[must_use]
    pub const fn pending_bytes(&self) -> usize {
        self.receiver.pending_bytes()
    }

    #[must_use]
    pub fn registered_windows(&self) -> usize {
        self.epochs.len()
    }

    /// Borrow the retained native presenter without unregistering its media.
    /// The caller can pump HWND messages even when no new frame arrives.
    ///
    /// # Errors
    /// Rejects unknown windows or an inconsistent internal registry.
    pub fn presenter_mut(&mut self, window: WindowId) -> Result<&mut P, RawWindowSessionError> {
        if !self.epochs.contains_key(&window) {
            return Err(RawWindowSessionError::UnknownWindow);
        }
        self.sink
            .presenter_mut(window)
            .ok_or(RawWindowSessionError::StateInvariant)
    }
}

fn map_receiver_outcome(outcome: MediaReceiverOutcome) -> RawWindowSessionOutcome {
    match outcome {
        MediaReceiverOutcome::Waiting => RawWindowSessionOutcome::Waiting,
        MediaReceiverOutcome::Delivered(manifest) => RawWindowSessionOutcome::Presented(manifest),
        MediaReceiverOutcome::Rejected(reason) => RawWindowSessionOutcome::Dropped(match reason {
            FrameRejectReason::Late => RawWindowSessionDrop::Late,
            FrameRejectReason::StaleFrame => RawWindowSessionDrop::StaleFrame,
            FrameRejectReason::StaleGeometry => RawWindowSessionDrop::StaleGeometry,
            FrameRejectReason::FutureGeometry => RawWindowSessionDrop::FutureGeometry,
        }),
    }
}

#[cfg(test)]
mod tests {
    use std::{cell::RefCell, rc::Rc};

    use bytes::Bytes;
    use viewflow_platform::windows_proxy::{BgraFrame, ProxyError};
    use viewflow_protocol::Id128;
    use viewflow_transport::RawBgraPayload;

    use super::*;

    #[derive(Clone)]
    struct Recorder(Rc<RefCell<Vec<BgraFrame>>>);

    impl PixelPresenter for Recorder {
        fn present_pixels(&mut self, frame: &BgraFrame) -> Result<(), ProxyError> {
            self.0.borrow_mut().push(frame.clone());
            Ok(())
        }
    }

    fn config() -> FrameQueueConfig {
        FrameQueueConfig {
            refresh_millihz: 60_000,
            max_refresh_periods: 2,
            requires_alpha: false,
        }
    }

    fn clock() -> ClockEstimate {
        ClockEstimate {
            remote_offset_ns: 0,
            network_round_trip_ns: 0,
            uncertainty_ns: 0,
        }
    }

    fn packet(window: WindowId, frame_id: u64, epoch: u64, source_ns: u64) -> MediaDatagram {
        MediaDatagram {
            window_id: window,
            frame_id,
            geometry_epoch: epoch,
            plane: MediaPlane::Color,
            chunk_index: 0,
            chunk_count: 1,
            source_submitted_ns: source_ns,
            payload: RawBgraPayload {
                width: 1,
                height: 1,
                stride: 4,
                pixels: Bytes::from_static(&[10, 20, 30, 128]),
            }
            .encode(4)
            .unwrap(),
        }
    }

    #[test]
    fn event_pump_borrow_retains_registration_and_identity() {
        let frames = Rc::new(RefCell::new(Vec::new()));
        let mut session = RawWindowSession::new(RawWindowSessionConfig::default()).unwrap();
        let window = Id128(1);
        session
            .open(window, 1, config(), Recorder(frames.clone()))
            .unwrap();
        assert!(Rc::ptr_eq(
            &session.presenter_mut(window).unwrap().0,
            &frames
        ));
        assert_eq!(session.registered_windows(), 1);
        let returned = session.close(window).unwrap();
        assert!(Rc::ptr_eq(&returned.0, &frames));
        assert!(matches!(
            session.presenter_mut(window),
            Err(RawWindowSessionError::UnknownWindow)
        ));
    }

    #[test]
    fn separate_alpha_queue_is_rejected_before_registration() {
        let frames = Rc::new(RefCell::new(Vec::new()));
        let mut session = RawWindowSession::new(RawWindowSessionConfig::default()).unwrap();
        let mut invalid = config();
        invalid.requires_alpha = true;
        assert!(matches!(
            session.open(Id128(1), 1, invalid, Recorder(frames.clone())),
            Err(RawWindowSessionError::SeparateAlphaUnsupported)
        ));
        assert_eq!(session.registered_windows(), 0);
        session
            .open(Id128(1), 1, config(), Recorder(frames))
            .unwrap();
    }

    #[test]
    fn presenter_survives_fresh_late_fresh_frames() {
        let frames = Rc::new(RefCell::new(Vec::new()));
        let window = Id128(1);
        let mut session = RawWindowSession::new(RawWindowSessionConfig::default()).unwrap();
        session
            .open(window, 1, config(), Recorder(frames.clone()))
            .unwrap();

        assert!(matches!(
            session.push_remote(packet(window, 1, 1, 100), 200, clock()),
            Ok(RawWindowSessionOutcome::Presented(_))
        ));
        assert!(matches!(
            session.push_remote(packet(window, 2, 1, 0), 100_000_000, clock()),
            Ok(RawWindowSessionOutcome::Dropped(RawWindowSessionDrop::Late))
        ));
        assert!(matches!(
            session.push_remote(packet(window, 3, 1, 300), 400, clock()),
            Ok(RawWindowSessionOutcome::Presented(_))
        ));
        assert_eq!(frames.borrow().len(), 2);
    }

    #[test]
    fn resize_discards_an_incomplete_old_frame() {
        let frames = Rc::new(RefCell::new(Vec::new()));
        let window = Id128(2);
        let mut session = RawWindowSession::new(RawWindowSessionConfig::default()).unwrap();
        session
            .open(window, 1, config(), Recorder(frames.clone()))
            .unwrap();
        let complete = packet(window, 1, 1, 100);
        let mut partial = complete.clone();
        partial.chunk_count = 2;
        partial.payload = complete.payload.slice(..6);
        assert!(matches!(
            session.push_remote(partial, 200, clock()),
            Ok(RawWindowSessionOutcome::Waiting)
        ));

        session.commit_geometry(window, 2).unwrap();
        assert_eq!(session.pending_bytes(), 0);
        assert!(frames.borrow().is_empty());
        let mut old_tail = complete;
        old_tail.chunk_count = 2;
        old_tail.chunk_index = 1;
        old_tail.payload = old_tail.payload.slice(6..);
        assert!(matches!(
            session.push_remote(old_tail, 200, clock()),
            Ok(RawWindowSessionOutcome::Dropped(
                RawWindowSessionDrop::StaleGeometry
            ))
        ));
        assert!(matches!(
            session.push_remote(packet(window, 2, 2, 300), 400, clock()),
            Ok(RawWindowSessionOutcome::Presented(_))
        ));
        // A fully assembled old-epoch frame is stale too, even after the new
        // geometry has already presented. It must never repaint the proxy.
        assert!(matches!(
            session.push_remote(packet(window, 3, 1, 400), 500, clock()),
            Ok(RawWindowSessionOutcome::Dropped(
                RawWindowSessionDrop::StaleGeometry
            ))
        ));
        assert_eq!(frames.borrow().len(), 1);
    }

    #[test]
    fn close_releases_the_presenter_and_registration() {
        let frames = Rc::new(RefCell::new(Vec::new()));
        let window = Id128(3);
        let mut session = RawWindowSession::new(RawWindowSessionConfig::default()).unwrap();
        session
            .open(window, 1, config(), Recorder(frames.clone()))
            .unwrap();
        let returned = session.close(window).unwrap();
        assert!(Rc::ptr_eq(&returned.0, &frames));
        assert_eq!(session.registered_windows(), 0);
        assert_eq!(session.pending_bytes(), 0);
        assert!(matches!(
            session.push_remote(packet(window, 1, 1, 100), 200, clock()),
            Err(RawWindowSessionError::UnknownWindow)
        ));
    }

    #[test]
    fn duplicate_and_invalid_epoch_leave_the_existing_window_unchanged() {
        let frames = Rc::new(RefCell::new(Vec::new()));
        let window = Id128(4);
        let mut session = RawWindowSession::new(RawWindowSessionConfig::default()).unwrap();
        session
            .open(window, 2, config(), Recorder(frames.clone()))
            .unwrap();
        assert!(matches!(
            session.open(
                window,
                3,
                config(),
                Recorder(Rc::new(RefCell::new(Vec::new())))
            ),
            Err(RawWindowSessionError::WindowAlreadyOpen)
        ));
        assert!(matches!(
            session.commit_geometry(window, 1),
            Err(RawWindowSessionError::EpochRegression)
        ));
        assert_eq!(session.registered_windows(), 1);
        assert!(matches!(
            session.push_remote(packet(window, 1, 2, 100), 200, clock()),
            Ok(RawWindowSessionOutcome::Presented(_))
        ));
        assert_eq!(frames.borrow().len(), 1);
    }
}
