//! Local continuous HCGF -> CUDA/NVENC diagnostic, not presentation acceptance.
//! Run with --features native-gpu-nvenc; no automatic CPU fallback or retry.

#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
fn main() -> anyhow::Result<()> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?
        .block_on(run())
}

#[cfg(not(all(target_os = "linux", feature = "native-gpu-nvenc")))]
fn main() -> anyhow::Result<()> {
    anyhow::bail!("requires Linux and --features native-gpu-nvenc")
}

#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
async fn run() -> anyhow::Result<()> {
    use anyhow::{Context, ensure};
    use sha2::{Digest, Sha256};
    use std::time::{Duration, Instant};
    use viewflowd::{
        gpu_nvenc_runtime::GpuEncoder, hyprcapture_gpu_socket::GpuReceiveOutcome,
        hyprcapture_runtime::start_gpu_stream, hyprcapture_stream::monotonic_now_ns,
    };
    let args: Vec<_> = std::env::args().skip(1).collect();
    ensure!(
        args.len() == 5 || (args.len() == 6 && args[5] == "--decode-only-warmup"),
        "usage: hyprcapture_gpu_encode WINDOW_ADDRESS COMPOSITOR_PID PHYSICAL_WIDTH PHYSICAL_HEIGHT FRAMES [--decode-only-warmup]"
    );
    let compositor = args[1].parse::<u32>()?;
    let width = args[2].parse::<u32>()?;
    let height = args[3].parse::<u32>()?;
    let requested = args[4].parse::<u32>()?;
    ensure!(
        (1..=600).contains(&requested),
        "diagnostic frame count must be 1..600"
    );
    // Initialize before exporting any source allocation: driver cold startup
    // is never hidden by restamping the first acquired frame.
    let mut encoder = GpuEncoder::new(width, height, 64 * 1024 * 1024, 64 * 1024 * 1024)?;
    let mut session = start_gpu_stream(&args[0], 60, compositor, Duration::from_secs(2)).await?;
    let session_deadline = Instant::now() + Duration::from_secs(15);
    let work = async {
        let mut completed = 0;
        let mut warmup_pending = args.len() == 6;
        while completed < requested {
            ensure!(Instant::now() < session_deadline, "GPU capture diagnostic timed out");
            let frame = match session.receiver.recv_frame()? {
                GpuReceiveOutcome::WouldBlock => {
                    tokio::time::sleep(Duration::from_millis(1)).await;
                    continue;
                }
                GpuReceiveOutcome::Disconnected => anyhow::bail!("GPU capture peer disconnected"),
                GpuReceiveOutcome::Frame(frame) => frame,
            };
            let deadline = frame.metadata().capture_monotonic_ns.checked_add(
                if warmup_pending { 2_000_000_000 } else { 33_333_333 })
                .context("capture deadline overflow")?;
            let output = encoder.encode(&frame, true, i64::try_from(deadline)?)?;
            // Native source reads are complete. This permits source reuse,
            // never Windows presentation; later diagnostics must measure that.
            session.receiver.release_after_source_reads(&frame)?;
            let age = monotonic_now_ns()?.checked_sub(output.capture_monotonic_ns)
                .context("capture clock is in the future")?;
            println!("{}", serde_json::json!({
                "sequence": output.frame_id, "epoch": output.geometry_epoch,
                "capture_monotonic_ns": output.capture_monotonic_ns,
                "encode_and_release_age_ns": age,
                "color_bytes": output.color_annex_b.len(), "alpha_bytes": output.raw_alpha.len(),
                "color_sha256": format!("{:x}", Sha256::digest(&output.color_annex_b)),
                "alpha_sha256": format!("{:x}", Sha256::digest(&output.raw_alpha)),
                "phase": if warmup_pending { "decode-only-warmup" } else { "live-encode" },
                "presentation_eligible": !warmup_pending,
                "presentation_ack": false,
            }));
            if warmup_pending { warmup_pending = false; } else { completed += 1; }
        }
        Ok::<_, anyhow::Error>(())
    }.await;
    // Every post-start exit explicitly stops only this stream's request ID.
    // In particular, a failed encode never sends HCGR before this stop.
    let stop = session.stop_stream(Duration::from_secs(2)).await;
    match (work, stop) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) => Err(error),
        (Ok(()), Err(error)) => Err(error.context("GPU stream stop failed")),
        (Err(error), Err(stop_error)) => {
            anyhow::bail!("{error:#}; GPU stream stop also failed: {stop_error:#}")
        }
    }
}
