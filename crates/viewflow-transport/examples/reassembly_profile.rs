//! Offline CPU profile; does not capture frames or inject input.
use bytes::Bytes;
use std::{hint::black_box, time::Instant};
use viewflow_protocol::Id128;
use viewflow_transport::{MediaAssembler, MediaAssemblerConfig, MediaDatagram, MediaPlane};

fn main() {
    for (windows, chunks) in [(1_u128, 1_u16), (64, 1), (64, 8), (1024, 8)] {
        let mut assembler = MediaAssembler::new(MediaAssemblerConfig::default());
        let payload = Bytes::from(vec![42; 1148]);
        let packet = |window, frame, index| MediaDatagram {
            window_id: Id128(window),
            frame_id: frame,
            geometry_epoch: 1,
            plane: MediaPlane::Color,
            chunk_index: index,
            chunk_count: chunks,
            source_submitted_ns: 1,
            payload: payload.clone(),
        };
        // Keep incomplete frames for the other windows to model packet loss.
        if chunks > 1 {
            for window in 0..windows {
                assembler.push_latest(packet(window, 1, 0), 2).unwrap();
            }
        }
        let iterations = 100_000_u64;
        let started = Instant::now();
        for frame in 2..iterations + 2 {
            let window = u128::from(frame) % windows;
            for index in 0..chunks {
                black_box(
                    assembler
                        .push_latest(black_box(packet(window, frame, index)), 2)
                        .unwrap(),
                );
            }
            if chunks > 1 {
                assembler
                    .push_latest(packet(window, frame + 1, 0), 2)
                    .unwrap();
            }
        }
        println!(
            "windows={windows} chunks={chunks} ns/frame={:.1}",
            started.elapsed().as_nanos() as f64 / iterations as f64
        );
    }
}
