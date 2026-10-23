//! Offline lossless alpha CPU measurement, without capture or live input.
use std::{hint::black_box, time::Instant};
use viewflow_transport::{AlphaRleLimits, decode_alpha_rle, encode_alpha_rle, validate_alpha_rle};
fn main() {
    let (width, height) = (1920, 1080);
    let size = (width * height) as usize;
    let limits = AlphaRleLimits {
        max_coded_width: width,
        max_coded_height: height,
        max_luma_samples: size as u64,
        max_decoded_bytes: size as u64,
        max_encoded_bytes: size + 24,
    };
    for pattern in ["opaque", "mixed", "raw"] {
        let samples: Vec<u8> = (0..size)
            .map(|i| match pattern {
                "opaque" => 255,
                "mixed" if i % 256 < 128 => 255,
                _ => (i % 128) as u8,
            })
            .collect();
        let encoded = encode_alpha_rle(width, height, &samples).unwrap();
        assert_eq!(
            decode_alpha_rle(encoded.clone(), limits)
                .unwrap()
                .samples
                .as_ref(),
            samples
        );
        let start = Instant::now();
        for _ in 0..1000 {
            black_box(validate_alpha_rle(black_box(encoded.clone()), limits).unwrap());
        }
        let validate_us = start.elapsed().as_secs_f64() * 1000.0;
        let start = Instant::now();
        for _ in 0..1000 {
            black_box(decode_alpha_rle(black_box(encoded.clone()), limits).unwrap());
        }
        println!(
            "{pattern} bytes={} validate_us={validate_us:.2} decode_us={:.2}",
            encoded.len(),
            start.elapsed().as_secs_f64() * 1000.0
        );
    }
}
