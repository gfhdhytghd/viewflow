//! Offline alpha encoder CPU measurement, not end-to-end latency.
use std::{hint::black_box, time::Instant};
use viewflow_transport::{AlphaRleLimits, decode_alpha_rle, encode_alpha_rle};
fn main() {
    for (width, height) in [(1920_u32, 1080_u32), (6144, 3456)] {
        let count = (width * height) as usize;
        for pattern in ["opaque", "mixed", "gradient"] {
            let samples: Vec<u8> = (0..count)
                .map(|i| match pattern {
                    "opaque" => 255,
                    "mixed" if i % 256 < 128 => 255,
                    _ => (i % 128) as u8,
                })
                .collect();
            let expected = encode_alpha_rle(width, height, &samples).unwrap();
            let decoded = decode_alpha_rle(
                expected.clone(),
                AlphaRleLimits {
                    max_coded_width: width,
                    max_coded_height: height,
                    max_luma_samples: count as u64,
                    max_decoded_bytes: count as u64,
                    max_encoded_bytes: count + 24,
                },
            )
            .unwrap();
            assert_eq!(decoded.samples.as_ref(), samples);
            let start = Instant::now();
            for _ in 0..30 {
                black_box(encode_alpha_rle(width, height, black_box(&samples)).unwrap());
            }
            println!(
                "{width}x{height} {pattern} bytes={} encode_us={:.2}",
                expected.len(),
                start.elapsed().as_secs_f64() * 1e6 / 30.0
            );
        }
    }
}
