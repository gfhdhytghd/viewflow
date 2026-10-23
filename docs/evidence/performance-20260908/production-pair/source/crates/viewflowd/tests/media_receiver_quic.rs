use std::time::Duration;

use bytes::Bytes;
use quinn::Endpoint;
use viewflow_core::FrameQueueConfig;
use viewflow_protocol::Id128;
use viewflow_transport::{
    ClockEstimate, MediaAssemblerError, MediaDatagram, MediaPlane, PeerIdentity,
    build_client_config, build_server_config,
};
use viewflowd::media_runtime::{
    EncodedFrame, EncodedFrameSink, MediaReceiver, MediaReceiverConfig, MediaReceiverError,
    MediaReceiverOutcome, ReceiveMediaError,
};

#[derive(Default)]
struct Sink(Vec<EncodedFrame>);

impl EncodedFrameSink for Sink {
    type Error = ();

    fn deliver_encoded_frame(&mut self, frame: EncodedFrame) -> Result<(), Self::Error> {
        self.0.push(frame);
        Ok(())
    }
}

fn test_identity() -> PeerIdentity {
    PeerIdentity::from_pem(
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
        include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
    )
    .unwrap()
}

#[derive(Default)]
struct PixelCapture(Vec<u8>);

impl viewflowd::pixel_runtime::PixelPresenter for PixelCapture {
    fn present_pixels(
        &mut self,
        frame: &viewflow_platform::windows_proxy::BgraFrame,
    ) -> Result<(), viewflow_platform::windows_proxy::ProxyError> {
        assert_eq!((frame.width(), frame.height()), (564, 262));
        self.0 = frame.pixels().to_vec();
        Ok(())
    }
}

/// Real decorated capture bytes, real authenticated transport, recording
/// presenter. Synthetic timestamps isolate byte correctness, NOT latency.
#[tokio::test]
async fn decorated_capture_survives_quic_and_pixel_submission() {
    use viewflow_transport::MediaPlaneFrame;
    use viewflowd::pixel_runtime::RawBgraSink;

    tokio::time::timeout(Duration::from_secs(10), async {
        let identity = test_identity();
        let server = Endpoint::server(
            build_server_config(&identity).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let mut client = Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(build_client_config(&identity).unwrap());
        let outbound = client
            .connect(server.local_addr().unwrap(), "localhost")
            .unwrap();
        let (outbound, inbound) = tokio::join!(outbound, async {
            server.accept().await.unwrap().await.unwrap()
        });
        let outbound = outbound.unwrap();
        let payload = Bytes::from_static(include_bytes!(
            "../../../docs/evidence/linux-capture-20260904/decorated-window.vfbg"
        ));
        let mut receiver = MediaReceiver::new(MediaReceiverConfig::default()).unwrap();
        receiver
            .register_window(
                Id128(42),
                1,
                FrameQueueConfig {
                    refresh_millihz: 60_000,
                    max_refresh_periods: 2,
                    requires_alpha: false, // Alpha is embedded in explicitly selected raw BGRA.
                },
            )
            .unwrap();
        let mut sink = RawBgraSink::new(1, 4 * 1024 * 1024).unwrap();
        sink.attach(Id128(42), 1, PixelCapture::default()).unwrap();
        let frame = MediaPlaneFrame {
            window_id: Id128(42),
            frame_id: 1,
            geometry_epoch: 1,
            plane: MediaPlane::Color,
            source_submitted_ns: 100,
            payload: payload.clone(),
        };
        let clock = ClockEstimate {
            remote_offset_ns: 0,
            network_round_trip_ns: 0,
            uncertainty_ns: 0,
        };
        let mut delivered = 0;
        // Drain each datagram to avoid testing local sender-queue overflow.
        // Production pacing and deadline behavior require separate validation.
        for packet in frame
            .fragment(outbound.max_datagram_size().unwrap())
            .unwrap()
        {
            outbound.send_datagram(packet.encode()).unwrap();
            if matches!(
                receiver
                    .receive_next(&inbound, || 200, clock, &mut sink)
                    .await
                    .unwrap(),
                MediaReceiverOutcome::Delivered(_)
            ) {
                delivered += 1;
            }
        }
        assert_eq!(delivered, 1);
        let pixels = sink.detach(Id128(42)).unwrap().0;
        assert_eq!(pixels.as_slice(), &payload[20..]);
        assert!(pixels.chunks_exact(4).any(|p| p[3] > 0 && p[3] < 255));
        assert_eq!(receiver.pending_bytes(), 0);
        outbound.close(0u32.into(), b"done");
        inbound.close(0u32.into(), b"done");
    })
    .await
    .expect("decorated frame transport timed out");
}

#[tokio::test]
async fn authenticated_datagrams_deliver_actual_atomic_plane_bytes() {
    tokio::time::timeout(Duration::from_secs(5), async {
        let identity = test_identity();
        let server = Endpoint::server(
            build_server_config(&identity).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let mut client = Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(build_client_config(&identity).unwrap());
        let outbound = client
            .connect(server.local_addr().unwrap(), "localhost")
            .unwrap();
        let (outbound, inbound) = tokio::join!(outbound, async {
            server.accept().await.unwrap().await.unwrap()
        });
        let outbound = outbound.unwrap();
        let mut receiver = MediaReceiver::new(MediaReceiverConfig::default()).unwrap();
        receiver
            .register_window(
                Id128(1),
                1,
                FrameQueueConfig {
                    refresh_millihz: 60_000,
                    max_refresh_periods: 2,
                    requires_alpha: true,
                },
            )
            .unwrap();
        let clock = ClockEstimate {
            remote_offset_ns: 0,
            network_round_trip_ns: 0,
            uncertainty_ns: 0,
        };
        let mut sink = Sink::default();
        // Alpha may arrive before color. Each payload must survive the real
        // authenticated transport and join only its matching frame.
        for (plane, payload) in [
            (MediaPlane::Alpha, &b"encoded-alpha"[..]),
            (MediaPlane::Color, &b"encoded-color"[..]),
        ] {
            outbound
                .send_datagram(
                    MediaDatagram {
                        window_id: Id128(1),
                        frame_id: 7,
                        geometry_epoch: 1,
                        plane,
                        chunk_index: 0,
                        chunk_count: 1,
                        source_submitted_ns: 100,
                        payload: Bytes::copy_from_slice(payload),
                    }
                    .encode(),
                )
                .unwrap();
            let outcome = receiver
                .receive_next(&inbound, || 200, clock, &mut sink)
                .await
                .unwrap();
            if plane == MediaPlane::Alpha {
                assert_eq!(outcome, MediaReceiverOutcome::Waiting);
                assert!(sink.0.is_empty());
            } else {
                assert!(matches!(outcome, MediaReceiverOutcome::Delivered(_)));
            }
        }
        assert_eq!(sink.0.len(), 1);
        assert_eq!(sink.0[0].color.as_ref(), b"encoded-color");
        assert_eq!(sink.0[0].alpha.as_ref().unwrap().as_ref(), b"encoded-alpha");
        assert_eq!(sink.0[0].manifest.frame_id, 7);
        assert_eq!(receiver.pending_bytes(), 0);
        outbound
            .send_datagram(
                MediaDatagram {
                    window_id: Id128(1),
                    frame_id: 8,
                    geometry_epoch: 1,
                    plane: MediaPlane::Color,
                    chunk_index: 0,
                    chunk_count: 1,
                    source_submitted_ns: 100,
                    payload: Bytes::from_static(b"late"),
                }
                .encode(),
            )
            .unwrap();
        let late = receiver
            .receive_next(&inbound, || 100_000_000, clock, &mut sink)
            .await;
        assert!(matches!(
            late,
            Err(ReceiveMediaError::Receiver(MediaReceiverError::Assembly(
                MediaAssemblerError::Late
            )))
        ));
        assert_eq!(sink.0.len(), 1, "expired frame must not reach the sink");
        outbound.close(0u32.into(), b"test complete");
        inbound.close(0u32.into(), b"test complete");
    })
    .await
    .expect("QUIC media receiver timed out");
}
