#![cfg(all(target_os = "linux", feature = "native-nvenc"))]

//! GPU-only end-to-end integrity coverage. This intentionally uses synthetic
//! receive timestamps so it does not claim a production latency measurement.
//! The assembler retains its normal 33.333 ms deadline.

use std::time::Duration;

use bytes::Bytes;
use quinn::Endpoint;
use viewflow_protocol::Id128;
use viewflow_transport::{
    CODEC_DESCRIPTOR_BYTES, CodecDescriptor, CodecResourceLimits, CodecSession,
    FRAME_CODEC_METADATA_BYTES, FrameCodecMetadata, MediaAssembler, MediaAssemblerConfig,
    MediaDatagram, MediaPlaneFrame, PeerIdentity, build_client_config, build_server_config,
};
use viewflowd::{
    encoded_media::{NvencMediaAdapter, NvencMediaFrame},
    nvenc_runtime::{AlphaFidelity, AlphaPolicy, Encoder, EncoderConfig, FrameMetadata},
};

const FRAME_COUNT: u64 = 3;
const WIDTH: u32 = 256;
const HEIGHT: u32 = 256;
const MAX_ACCESS_UNIT_BYTES: usize = 1024 * 1024;
const CONTROL_BYTES: usize = CODEC_DESCRIPTOR_BYTES * 2 + FRAME_CODEC_METADATA_BYTES * 6;
const DEADLINE_NS: u64 = 33_333_333;

fn test_identity() -> PeerIdentity {
    PeerIdentity::from_pem(
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
        include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
    )
    .unwrap()
}

fn config() -> EncoderConfig {
    EncoderConfig {
        width: WIDTH,
        height: HEIGHT,
        max_access_unit_bytes: MAX_ACCESS_UNIT_BYTES,
        max_pending_frames: 8,
        alpha_policy: AlphaPolicy::Required,
        alpha_fidelity: AlphaFidelity::Lossless,
    }
}

/// Mixed codec integrity through real QUIC and the local presenter serializer.
/// Synthetic receive times make this an integrity test, not latency evidence.
#[tokio::test]
#[ignore = "requires NVIDIA GPU and NVENC driver"]
async fn lossless_alpha_pair_survives_quic_to_presenter_pipe() {
    use viewflowd::{compatible_encoder, gpu_presenter_pipe, hyprcapture_stream::FrameHeader};
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut encoder = compatible_encoder::CompatibleEncoder::new(compatible_encoder::Config {
            max_input_bytes: MAX_ACCESS_UNIT_BYTES,
            max_color_access_unit_bytes: MAX_ACCESS_UNIT_BYTES,
            max_alpha_access_unit_bytes: MAX_ACCESS_UNIT_BYTES,
            max_pending_frames: 8,
        })
        .unwrap();
        let mut frames = Vec::new();
        for sequence in 1..=FRAME_COUNT {
            frames.extend(
                encoder
                    .submit(
                        compatible_encoder::CodecIdentity {
                            window_id: Id128(9),
                            config_generation: 1,
                        },
                        FrameHeader {
                            sequence,
                            capture_monotonic_ns: sequence * 16_666_667,
                            geometry_epoch: 1,
                            logical_rect: [0.0, 0.0, 256.0, 256.0],
                            width: WIDTH,
                            height: HEIGHT,
                            stride: WIDTH * 4,
                            payload_bytes: u64::from(WIDTH * HEIGHT * 4),
                        },
                        vec![128; usize::try_from(WIDTH * HEIGHT * 4).unwrap()],
                    )
                    .unwrap(),
            );
        }
        assert_eq!(frames.len(), 3);
        let descriptors = encoder.descriptors().unwrap();
        let mut control = Vec::new();
        control.extend_from_slice(&descriptors.color.encode().unwrap());
        control.extend_from_slice(&descriptors.alpha.encode().unwrap());
        for frame in &frames {
            control.extend_from_slice(&frame.color_metadata.encode().unwrap());
            control.extend_from_slice(&frame.alpha_metadata.encode().unwrap());
        }
        let identity = test_identity();
        let server = Endpoint::server(
            build_server_config(&identity).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let mut client = Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(build_client_config(&identity).unwrap());
        let connect = client
            .connect(server.local_addr().unwrap(), "localhost")
            .unwrap();
        let (outbound, inbound) = tokio::join!(connect, async {
            server.accept().await.unwrap().await.unwrap()
        });
        let outbound = outbound.unwrap();
        let mut send = outbound.open_uni().await.unwrap();
        send.write_all(&control).await.unwrap();
        send.finish().unwrap();
        let mut receive = inbound.accept_uni().await.unwrap();
        let (color_desc, alpha_desc, metadata) =
            decode_control(&receive.read_to_end(CONTROL_BYTES).await.unwrap());
        let mut session = CodecSession::new(encoder.codec_session_policy());
        session
            .accept_descriptors(
                color_desc,
                alpha_desc,
                CodecResourceLimits {
                    max_coded_width: WIDTH,
                    max_coded_height: HEIGHT,
                    max_luma_samples: u64::from(WIDTH * HEIGHT),
                    max_decoded_bytes: MAX_ACCESS_UNIT_BYTES as u64,
                },
            )
            .unwrap();
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig {
            deadline_ns: DEADLINE_NS,
            max_chunks_per_plane: 1024,
            max_plane_bytes: MAX_ACCESS_UNIT_BYTES,
        });
        for (frame, (cm, am)) in frames.iter().zip(metadata) {
            let color = send_and_reassemble_plane(
                &outbound,
                &inbound,
                &mut assembler,
                &frame.color,
                outbound.max_datagram_size().unwrap(),
            )
            .await;
            let alpha = send_and_reassemble_plane(
                &outbound,
                &inbound,
                &mut assembler,
                &frame.alpha,
                outbound.max_datagram_size().unwrap(),
            )
            .await;
            session
                .accept_frame(&color, cm, Some((&alpha, am)))
                .unwrap();
            let record = gpu_presenter_pipe::encode_lossless_alpha_record(
                color.frame_id,
                WIDTH,
                HEIGHT,
                &color.payload,
                alpha.payload,
                MAX_ACCESS_UNIT_BYTES,
            )
            .unwrap();
            let split = gpu_presenter_pipe::HEADER_BYTES + color.payload.len();
            assert_eq!(
                &record[gpu_presenter_pipe::HEADER_BYTES..split],
                color.payload.as_ref()
            );
            assert_eq!(
                &record[split..],
                vec![128; usize::try_from(WIDTH * HEIGHT).unwrap()]
            );
        }
        outbound.close(0_u32.into(), b"integrity complete");
        inbound.close(0_u32.into(), b"integrity complete");
    })
    .await
    .unwrap();
}

fn reliable_control(adapter: NvencMediaAdapter, frames: &[NvencMediaFrame]) -> Vec<u8> {
    let descriptors = adapter.descriptors();
    let mut bytes = Vec::with_capacity(CONTROL_BYTES);
    bytes.extend_from_slice(&descriptors.color.encode().unwrap());
    bytes.extend_from_slice(&descriptors.alpha.encode().unwrap());
    for frame in frames {
        bytes.extend_from_slice(&frame.color_metadata.encode().unwrap());
        let (_, alpha_metadata) = frame.alpha.as_ref().expect("required alpha");
        bytes.extend_from_slice(&alpha_metadata.encode().unwrap());
    }
    assert_eq!(bytes.len(), CONTROL_BYTES);
    bytes
}

fn decode_control(
    bytes: &[u8],
) -> (
    CodecDescriptor,
    CodecDescriptor,
    Vec<(FrameCodecMetadata, FrameCodecMetadata)>,
) {
    assert_eq!(bytes.len(), CONTROL_BYTES);
    let color =
        CodecDescriptor::decode(Bytes::copy_from_slice(&bytes[..CODEC_DESCRIPTOR_BYTES])).unwrap();
    let alpha = CodecDescriptor::decode(Bytes::copy_from_slice(
        &bytes[CODEC_DESCRIPTOR_BYTES..CODEC_DESCRIPTOR_BYTES * 2],
    ))
    .unwrap();
    let mut metadata = Vec::with_capacity(usize::try_from(FRAME_COUNT).unwrap());
    let mut offset = CODEC_DESCRIPTOR_BYTES * 2;
    for _ in 0..FRAME_COUNT {
        let color_metadata = FrameCodecMetadata::decode(Bytes::copy_from_slice(
            &bytes[offset..offset + FRAME_CODEC_METADATA_BYTES],
        ))
        .unwrap();
        offset += FRAME_CODEC_METADATA_BYTES;
        let alpha_metadata = FrameCodecMetadata::decode(Bytes::copy_from_slice(
            &bytes[offset..offset + FRAME_CODEC_METADATA_BYTES],
        ))
        .unwrap();
        offset += FRAME_CODEC_METADATA_BYTES;
        metadata.push((color_metadata, alpha_metadata));
    }
    (color, alpha, metadata)
}

async fn send_and_reassemble_plane(
    outbound: &quinn::Connection,
    inbound: &quinn::Connection,
    assembler: &mut MediaAssembler,
    expected: &MediaPlaneFrame,
    max_datagram_bytes: usize,
) -> MediaPlaneFrame {
    let mut completed = None;
    for packet in expected.clone().fragment(max_datagram_bytes).unwrap() {
        outbound.send_datagram(packet.encode()).unwrap();
        let packet = inbound.read_datagram().await.unwrap();
        if let Some(plane) = assembler
            .push_any(
                MediaDatagram::decode(packet).unwrap(),
                expected.source_submitted_ns + 1,
            )
            .unwrap()
        {
            assert!(completed.replace(plane).is_none());
        }
    }
    let completed = completed.expect("all encoded plane fragments reassemble");
    assert_eq!(completed.payload, expected.payload);
    assert_eq!(completed.window_id, expected.window_id);
    assert_eq!(completed.frame_id, expected.frame_id);
    assert_eq!(completed.geometry_epoch, expected.geometry_epoch);
    assert_eq!(completed.source_submitted_ns, expected.source_submitted_ns);
    MediaPlaneFrame {
        window_id: completed.window_id,
        frame_id: completed.frame_id,
        geometry_epoch: completed.geometry_epoch,
        plane: completed.plane,
        source_submitted_ns: completed.source_submitted_ns,
        payload: completed.payload,
    }
}

/// Real NVENC frames through authenticated loopback QUIC. The virtual receive
/// clock is only for byte/identity validation; it preserves, rather than
/// loosens, the production 33.333 ms assembler deadline.
#[tokio::test]
#[ignore = "requires NVIDIA GPU and NVENC driver"]
async fn real_nvenc_color_and_alpha_survive_mtls_quic() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let config = config();
        let adapter = NvencMediaAdapter::new(Id128(9), 1, 1, &config).unwrap();
        let mut encoder = Encoder::new(config).unwrap();
        let pixels = vec![128; usize::try_from(WIDTH * HEIGHT * 4).unwrap()];
        let mut access_units = Vec::new();
        for frame_id in 1..=FRAME_COUNT {
            access_units.extend(
                encoder
                    .submit(
                        &pixels,
                        FrameMetadata {
                            frame_id,
                            timestamp_ns: frame_id * 16_666_667,
                            geometry_epoch: 1,
                        },
                        frame_id == 1,
                    )
                    .unwrap(),
            );
        }
        access_units.extend(encoder.drain().unwrap());
        assert_eq!(access_units.len(), usize::try_from(FRAME_COUNT).unwrap());
        let frames: Vec<_> = access_units
            .into_iter()
            .map(|access_unit| adapter.adapt(access_unit).unwrap())
            .collect();
        let control = reliable_control(adapter, &frames);

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

        let mut send = outbound.open_uni().await.unwrap();
        send.write_all(&control).await.unwrap();
        send.finish().unwrap();
        let mut receive = inbound.accept_uni().await.unwrap();
        let (color_descriptor, alpha_descriptor, metadata) =
            decode_control(&receive.read_to_end(CONTROL_BYTES).await.unwrap());
        let mut session = CodecSession::new(adapter.codec_session_policy());
        session
            .accept_descriptors(
                color_descriptor,
                alpha_descriptor,
                CodecResourceLimits {
                    max_coded_width: WIDTH,
                    max_coded_height: HEIGHT,
                    max_luma_samples: u64::from(WIDTH) * u64::from(HEIGHT),
                    max_decoded_bytes: 1024 * 1024,
                },
            )
            .unwrap();

        let max_datagram_bytes = outbound.max_datagram_size().unwrap();
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig {
            deadline_ns: DEADLINE_NS,
            max_chunks_per_plane: 1024,
            max_plane_bytes: MAX_ACCESS_UNIT_BYTES,
        });
        for (index, frame) in frames.iter().enumerate() {
            let (expected_alpha, _) = frame.alpha.as_ref().expect("required alpha");
            let color = send_and_reassemble_plane(
                &outbound,
                &inbound,
                &mut assembler,
                &frame.color,
                max_datagram_bytes,
            )
            .await;
            let alpha = send_and_reassemble_plane(
                &outbound,
                &inbound,
                &mut assembler,
                expected_alpha,
                max_datagram_bytes,
            )
            .await;
            let (color_metadata, alpha_metadata) = metadata[index];
            let admission = session
                .accept_frame(&color, color_metadata, Some((&alpha, alpha_metadata)))
                .unwrap();
            assert_eq!(admission.frame_id, u64::try_from(index).unwrap() + 1);
            assert_eq!(admission.config_generation, 1);
            assert_eq!(admission.paired_keyframe, index == 0);
        }
        outbound.close(0u32.into(), b"test complete");
        inbound.close(0u32.into(), b"test complete");
    })
    .await
    .expect("NVENC mTLS QUIC loopback timed out");
}
