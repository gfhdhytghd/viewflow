//! Explicitly start one selected-window stream, measure it, and stop it.
#[cfg(target_os = "linux")]
#[tokio::main(flavor = "current_thread")]
async fn main() -> anyhow::Result<()> {
    use anyhow::{Context, bail};
    use std::time::{Duration, Instant};
    use viewflowd::{
        hyprcapture_runtime::start_stream, hyprcapture_socket::ReceiveOutcome,
        hyprcapture_stream::monotonic_now_ns,
    };
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 3 {
        bail!("usage: hyprcapture_live_stream <window-address> <compositor-pid> <seconds>");
    }
    let pid: u32 = args[1].parse()?;
    let seconds: u64 = args[2].parse()?;
    if !(1..=60).contains(&seconds) {
        bail!("duration must be 1..=60 seconds");
    }
    let mut session =
        start_stream(&args[0], 60, 64 * 1024 * 1024, pid, Duration::from_secs(2)).await?;
    println!("started_stream={}", session.request_id());
    let result: anyhow::Result<()> = async {
        let deadline = Instant::now() + Duration::from_secs(seconds);
        let mut count = 0_u64;
        let mut worst_age_ns = 0_u64;
        while Instant::now() < deadline {
            match session.receiver.recv_frame()? {
                ReceiveOutcome::WouldBlock => tokio::time::sleep(Duration::from_millis(1)).await,
                ReceiveOutcome::Disconnected => bail!("producer disconnected"),
                ReceiveOutcome::Frame(header, pixels) => {
                    let frame = header.into_raw_bgra(pixels, 64 * 1024 * 1024)?;
                    let age = monotonic_now_ns()?
                        .checked_sub(header.capture_monotonic_ns)
                        .context("capture timestamp is in the future")?;
                    count += 1;
                    worst_age_ns = worst_age_ns.max(age);
                    println!(
                        "frame={} epoch={} capture_to_import_ns={} pixels={}x{} logical={:?}",
                        header.sequence,
                        header.geometry_epoch,
                        age,
                        frame.width,
                        frame.height,
                        header.logical_rect
                    );
                }
            }
        }
        if count == 0 {
            bail!("no frames received");
        }
        println!(
            "frames={count} worst_capture_to_import_ns={worst_age_ns}; excludes network and display"
        );
        Ok(())
    }
    .await;
    // Always attempt explicit stop, including malformed input/disconnection.
    let stopped = session.stop_stream(Duration::from_secs(2)).await;
    match (result, stopped) {
        (Ok(()), Ok(())) => {
            println!("stream_stop_confirmed=true");
            Ok(())
        }
        (Err(error), Ok(())) => Err(error.context("stream stop confirmed")),
        (result, Err(stop_error)) => {
            bail!("capture result={result:?}; stream stop unproven: {stop_error:#}")
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn main() -> anyhow::Result<()> {
    anyhow::bail!("HyprCapture requires Linux")
}
