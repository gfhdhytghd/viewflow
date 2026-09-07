//! Connects the raw BGRA transport codec to native proxy presentation.
//!
//! The compressed-codec path and a compositor presentation timestamp are still
//! separate work. Successful submission here is not display-latency proof.

use std::collections::HashMap;

use viewflow_platform::windows_proxy::{BgraFrame, ProxyError, WindowsProxy};
use viewflow_protocol::WindowId;
use viewflow_transport::{RawBgraError, RawBgraPayload};

use crate::media_runtime::{EncodedFrame, EncodedFrameSink};

pub trait PixelPresenter {
    /// # Errors
    /// Returns a native allocation, window, or composition submission failure.
    fn present_pixels(&mut self, frame: &BgraFrame) -> Result<(), ProxyError>;
}

impl PixelPresenter for WindowsProxy {
    fn present_pixels(&mut self, frame: &BgraFrame) -> Result<(), ProxyError> {
        self.present(frame)
    }
}

#[derive(Debug)]
pub enum PixelSinkError {
    InvalidLimit,
    WindowLimit,
    UnknownWindow,
    DuplicateWindow,
    GeometryMismatch,
    StaleFrame,
    SeparateAlphaUnsupported,
    Payload(RawBgraError),
    Native(ProxyError),
}

impl std::fmt::Display for PixelSinkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "pixel submission error: {self:?}")
    }
}

impl std::error::Error for PixelSinkError {}

struct ProxySlot<P> {
    presenter: P,
    epoch: u64,
    last_frame: Option<u64>,
}

/// Decoder-facing sink for explicitly selected raw premultiplied BGRA streams.
/// Color carries its own alpha; separate-alpha video codecs are not interpreted
/// as raw pixels. Limits are caller resources, not a 6K resolution ceiling.
pub struct RawBgraSink<P> {
    proxies: HashMap<WindowId, ProxySlot<P>>,
    max_windows: usize,
    max_pixel_bytes: usize,
}

impl<P: PixelPresenter> RawBgraSink<P> {
    /// # Errors
    /// Rejects zero resource limits.
    pub fn new(max_windows: usize, max_pixel_bytes: usize) -> Result<Self, PixelSinkError> {
        if max_windows == 0 || max_pixel_bytes == 0 {
            return Err(PixelSinkError::InvalidLimit);
        }
        Ok(Self {
            proxies: HashMap::new(),
            max_windows,
            max_pixel_bytes,
        })
    }

    /// # Errors
    /// Rejects duplicate registrations or the configured window bound.
    pub fn attach(
        &mut self,
        window: WindowId,
        epoch: u64,
        presenter: P,
    ) -> Result<(), PixelSinkError> {
        if self.proxies.contains_key(&window) {
            return Err(PixelSinkError::DuplicateWindow);
        }
        if self.proxies.len() >= self.max_windows {
            return Err(PixelSinkError::WindowLimit);
        }
        self.proxies.insert(
            window,
            ProxySlot {
                presenter,
                epoch,
                last_frame: None,
            },
        );
        Ok(())
    }

    /// # Errors
    /// Rejects an unknown window or a backwards committed epoch.
    pub fn commit_geometry(&mut self, window: WindowId, epoch: u64) -> Result<(), PixelSinkError> {
        let slot = self
            .proxies
            .get_mut(&window)
            .ok_or(PixelSinkError::UnknownWindow)?;
        if epoch < slot.epoch {
            return Err(PixelSinkError::GeometryMismatch);
        }
        slot.epoch = epoch;
        Ok(())
    }

    pub fn detach(&mut self, window: WindowId) -> Option<P> {
        self.proxies.remove(&window).map(|slot| slot.presenter)
    }

    /// Access the retained presenter to pump its native events or move it.
    /// This does not expose or alter stream epochs and sequence watermarks.
    pub fn presenter_mut(&mut self, window: WindowId) -> Option<&mut P> {
        self.proxies
            .get_mut(&window)
            .map(|slot| &mut slot.presenter)
    }
}

impl<P: PixelPresenter> EncodedFrameSink for RawBgraSink<P> {
    type Error = PixelSinkError;

    fn deliver_encoded_frame(&mut self, frame: EncodedFrame) -> Result<(), Self::Error> {
        let slot = self
            .proxies
            .get_mut(&frame.manifest.window_id)
            .ok_or(PixelSinkError::UnknownWindow)?;
        if slot.epoch != frame.manifest.geometry_epoch {
            return Err(PixelSinkError::GeometryMismatch);
        }
        if slot
            .last_frame
            .is_some_and(|last| frame.manifest.frame_id <= last)
        {
            return Err(PixelSinkError::StaleFrame);
        }
        if frame.alpha.is_some() {
            return Err(PixelSinkError::SeparateAlphaUnsupported);
        }
        let raw = RawBgraPayload::decode(frame.color, self.max_pixel_bytes)
            .map_err(PixelSinkError::Payload)?;
        let pixels = BgraFrame::new(
            raw.width,
            raw.height,
            raw.stride as usize,
            raw.pixels.to_vec(),
        )
        .map_err(PixelSinkError::Native)?;
        slot.presenter
            .present_pixels(&pixels)
            .map_err(PixelSinkError::Native)?;
        slot.last_frame = Some(frame.manifest.frame_id);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use std::{cell::RefCell, rc::Rc};
    use viewflow_protocol::{FrameManifest, Id128};

    struct Recorder(Rc<RefCell<Vec<BgraFrame>>>);
    impl PixelPresenter for Recorder {
        fn present_pixels(&mut self, frame: &BgraFrame) -> Result<(), ProxyError> {
            self.0.borrow_mut().push(frame.clone());
            Ok(())
        }
    }

    fn frame() -> EncodedFrame {
        EncodedFrame {
            manifest: FrameManifest {
                window_id: Id128(1),
                frame_id: 5,
                geometry_epoch: 2,
                source_submitted_ns: 100,
                received_ns: 200,
            },
            color: RawBgraPayload {
                width: 1,
                height: 1,
                stride: 4,
                pixels: Bytes::from_static(&[10, 20, 30, 128]),
            }
            .encode(4)
            .unwrap(),
            alpha: None,
        }
    }

    #[test]
    fn payload_reaches_presenter_only_for_matching_epoch_once() {
        let recorded = Rc::new(RefCell::new(Vec::new()));
        let mut sink = RawBgraSink::new(1, 4).unwrap();
        sink.attach(Id128(1), 2, Recorder(recorded.clone()))
            .unwrap();
        sink.deliver_encoded_frame(frame()).unwrap();
        assert_eq!(
            recorded.borrow().as_slice(),
            &[BgraFrame::new(1, 1, 4, vec![10, 20, 30, 128]).unwrap()]
        );
        assert!(matches!(
            sink.deliver_encoded_frame(frame()),
            Err(PixelSinkError::StaleFrame)
        ));
        sink.commit_geometry(Id128(1), 3).unwrap();
        assert!(matches!(
            sink.deliver_encoded_frame(frame()),
            Err(PixelSinkError::GeometryMismatch)
        ));
        assert_eq!(recorded.borrow().len(), 1);
        assert!(sink.detach(Id128(1)).is_some());
        assert!(matches!(
            sink.deliver_encoded_frame(frame()),
            Err(PixelSinkError::UnknownWindow)
        ));
    }

    #[test]
    fn rejects_unknown_codec_and_separate_alpha_before_native_submission() {
        let recorded = Rc::new(RefCell::new(Vec::new()));
        let mut sink = RawBgraSink::new(1, 4).unwrap();
        sink.attach(Id128(1), 2, Recorder(recorded.clone()))
            .unwrap();
        let mut invalid = frame();
        invalid.color = Bytes::from_static(b"not BGRA");
        assert!(matches!(
            sink.deliver_encoded_frame(invalid),
            Err(PixelSinkError::Payload(_))
        ));
        let mut separate = frame();
        separate.alpha = Some(Bytes::from_static(b"alpha"));
        assert!(matches!(
            sink.deliver_encoded_frame(separate),
            Err(PixelSinkError::SeparateAlphaUnsupported)
        ));
        assert!(recorded.borrow().is_empty());
        sink.deliver_encoded_frame(frame()).unwrap();
        assert_eq!(recorded.borrow().len(), 1);
    }

    #[test]
    fn raw_pixels_flow_through_fragment_reassembly_and_admission() {
        use crate::media_runtime::{MediaReceiver, MediaReceiverConfig, MediaReceiverOutcome};
        use viewflow_core::FrameQueueConfig;
        use viewflow_transport::{ClockEstimate, MediaDatagram, MediaPlane};

        let recorded = Rc::new(RefCell::new(Vec::new()));
        let mut sink = RawBgraSink::new(1, 4).unwrap();
        sink.attach(Id128(1), 2, Recorder(recorded.clone()))
            .unwrap();
        let mut receiver = MediaReceiver::new(MediaReceiverConfig::default()).unwrap();
        receiver
            .register_window(
                Id128(1),
                2,
                FrameQueueConfig {
                    refresh_millihz: 60_000,
                    max_refresh_periods: 2,
                    requires_alpha: false,
                },
            )
            .unwrap();
        let payload = frame().color;
        let clock = ClockEstimate {
            remote_offset_ns: 0,
            network_round_trip_ns: 0,
            uncertainty_ns: 0,
        };
        for index in [1, 0] {
            let chunk = if index == 0 {
                payload.slice(..12)
            } else {
                payload.slice(12..)
            };
            let outcome = receiver
                .push_remote(
                    MediaDatagram {
                        window_id: Id128(1),
                        frame_id: 5,
                        geometry_epoch: 2,
                        plane: MediaPlane::Color,
                        chunk_index: index,
                        chunk_count: 2,
                        source_submitted_ns: 100,
                        payload: chunk,
                    },
                    200,
                    clock,
                    &mut sink,
                )
                .unwrap();
            if index == 1 {
                assert_eq!(outcome, MediaReceiverOutcome::Waiting);
                assert!(recorded.borrow().is_empty());
            } else {
                assert!(matches!(outcome, MediaReceiverOutcome::Delivered(_)));
            }
        }
        assert_eq!(
            recorded.borrow().as_slice(),
            &[BgraFrame::new(1, 1, 4, vec![10, 20, 30, 128]).unwrap()]
        );
    }
}
