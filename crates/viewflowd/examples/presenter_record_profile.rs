//! Offline CPU measurement; no capture, presentation, or input.
use std::{hint::black_box, time::Instant};
use viewflowd::gpu_presenter_pipe::{NativePresentationDeadline, encode_deadline_alpha_record};
fn main() {
    let alpha = viewflow_transport::encode_alpha_rle(1920, 1080, &vec![255; 1920 * 1080]).unwrap();
    for size in [64 * 1024, 1024 * 1024, 8 * 1024 * 1024] {
        let color = vec![42; size];
        let start = Instant::now();
        for _ in 0..1000 {
            black_box(
                encode_deadline_alpha_record(
                    1,
                    1920,
                    1080,
                    black_box(&color),
                    &alpha,
                    NativePresentationDeadline {
                        ticks: 1,
                        frequency: 1,
                    },
                    32 * 1024 * 1024,
                )
                .unwrap(),
            );
        }
        println!(
            "color_bytes={size} us/record={:.2}",
            start.elapsed().as_secs_f64() * 1000.0
        );
    }
}
