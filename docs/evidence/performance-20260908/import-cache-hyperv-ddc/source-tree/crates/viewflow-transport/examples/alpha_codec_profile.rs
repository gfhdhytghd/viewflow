//! Synthetic alpha-only timing, not end-to-end latency acceptance.
use std::time::Instant;
use viewflow_transport::{AlphaRleLimits, decode_alpha_rle, encode_alpha_rle};

fn main() {
    let (width, height) = (6144_u32, 3456_u32);
    let count = usize::try_from(u64::from(width) * u64::from(height)).unwrap();
    for pattern in ["constant", "gradient"] {
        let samples: Vec<u8> = (0..count)
            .map(|i| {
                if pattern == "constant" {
                    200
                } else {
                    u8::try_from(i % 256).unwrap()
                }
            })
            .collect();
        let start = Instant::now();
        let encoded = encode_alpha_rle(width, height, &samples).unwrap();
        let encode = start.elapsed();
        let length = encoded.len();
        let start = Instant::now();
        let decoded = decode_alpha_rle(
            encoded,
            AlphaRleLimits {
                max_coded_width: width,
                max_coded_height: height,
                max_luma_samples: count as u64,
                max_decoded_bytes: count as u64,
                max_encoded_bytes: count + 24,
            },
        )
        .unwrap();
        let decode = start.elapsed();
        assert_eq!(decoded.samples.as_ref(), samples);
        println!(
            "{pattern}: {width}x{height} encoded_bytes={length} encode_us={} decode_us={}",
            encode.as_micros(),
            decode.as_micros()
        );
    }
}
