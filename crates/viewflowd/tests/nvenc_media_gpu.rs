#![cfg(all(target_os = "linux", feature = "native-nvenc"))]

use viewflow_protocol::Id128;
use viewflow_transport::{
    CodecResourceLimits, CodecSession, MediaAssembler, MediaAssemblerConfig, MediaDatagram,
};
use viewflowd::{
    encoded_media::NvencMediaAdapter,
    nvenc_runtime::{AlphaFidelity, AlphaPolicy, Encoder, EncoderConfig, FrameMetadata},
};

#[test]
#[ignore = "requires NVIDIA GPU and NVENC driver"]
fn real_encoded_pairs_enter_codec_session() {
    let config = EncoderConfig {
        width: 256,
        height: 256,
        max_access_unit_bytes: 1024 * 1024,
        max_pending_frames: 8,
        alpha_policy: AlphaPolicy::Required,
        alpha_fidelity: AlphaFidelity::Lossless,
    };
    let mut encoder = Encoder::new(config).unwrap();
    let adapter = NvencMediaAdapter::new(Id128(9), 1, 1, &config).unwrap();
    let descriptors = adapter.descriptors();
    let mut session = CodecSession::new(adapter.codec_session_policy());
    session
        .accept_descriptors(
            descriptors.color,
            descriptors.alpha,
            CodecResourceLimits {
                max_coded_width: 256,
                max_coded_height: 256,
                max_luma_samples: 256 * 256,
                max_decoded_bytes: 1024 * 1024,
            },
        )
        .unwrap();
    let pixels = vec![128; 256 * 256 * 4];
    let mut outputs = Vec::new();
    for frame_id in 1..=3 {
        outputs.extend(
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
    outputs.extend(encoder.drain().unwrap());
    assert_eq!(outputs.len(), 3);
    let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
    for (index, output) in outputs.into_iter().enumerate() {
        let frame = adapter.adapt(output).unwrap();
        // Exercise the actual wire representation, including out-of-order
        // packet arrival. Synthetic receive times test identity, not latency.
        for plane in
            std::iter::once(&frame.color).chain(frame.alpha.as_ref().map(|(plane, _)| plane))
        {
            let mut packets: Vec<_> = plane.clone().fragment(1200).unwrap().collect();
            packets.reverse();
            let mut completed = None;
            for packet in packets {
                let decoded = MediaDatagram::decode(packet.encode()).unwrap();
                if let Some(result) = assembler
                    .push_any(decoded, plane.source_submitted_ns + 1)
                    .unwrap()
                {
                    assert!(completed.replace(result).is_none());
                }
            }
            let completed = completed.expect("all encoded chunks must reassemble");
            assert_eq!(completed.payload, plane.payload);
            assert_eq!(completed.frame_id, plane.frame_id);
            assert_eq!(completed.geometry_epoch, plane.geometry_epoch);
            assert_eq!(completed.source_submitted_ns, plane.source_submitted_ns);
        }
        let admitted = session
            .accept_frame(
                &frame.color,
                frame.color_metadata,
                frame
                    .alpha
                    .as_ref()
                    .map(|(plane, metadata)| (plane, *metadata)),
            )
            .unwrap();
        assert_eq!(admitted.frame_id, u64::try_from(index).unwrap() + 1);
        assert_eq!(
            frame.color.source_submitted_ns,
            admitted.frame_id * 16_666_667
        );
        if index == 0 {
            assert!(admitted.paired_keyframe);
        }
    }
}
