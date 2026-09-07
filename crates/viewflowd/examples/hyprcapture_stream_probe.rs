//! Bounded live stream diagnostic; prints metadata only, never stores pixels.
#[cfg(target_os = "linux")]
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    use anyhow::{Context, bail};
    use std::time::{Duration, Instant};
    use viewflowd::{hyprcapture_runtime::start_stream, hyprcapture_socket::ReceiveOutcome};
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        bail!("usage: hyprcapture_stream_probe WINDOW_ADDRESS COMPOSITOR_PID");
    }
    let pid = args[2].parse()?;
    let mut stream =
        start_stream(&args[1], 60, 32 * 1024 * 1024, pid, Duration::from_secs(5)).await?;
    let result: anyhow::Result<()> = async {
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut count = 0;
        let mut last = None;
        let mut ages_ns = Vec::new();
        let mut logical_rect = None;
        while Instant::now() < deadline {
            match stream.receiver.recv_latest_frame()? {
                ReceiveOutcome::Frame(header, pixels) => {
                    count += 1;
                    let now = viewflowd::hyprcapture_stream::monotonic_now_ns()?;
                    ages_ns.push(
                        now.checked_sub(header.capture_monotonic_ns)
                            .context("capture timestamp is in the future")?,
                    );
                    logical_rect = Some(header.logical_rect);
                    last = Some((header.sequence, header.width, header.height, pixels.len()));
                }
                ReceiveOutcome::WouldBlock => tokio::time::sleep(Duration::from_millis(1)).await,
                ReceiveOutcome::Disconnected => bail!("producer disconnected"),
            }
        }
        println!("frames={count} last={last:?}");
        ages_ns.sort_unstable();
        if !ages_ns.is_empty() {
            println!(
                "capture_to_import_ns p50={} p95={} max={} logical_rect={logical_rect:?}",
                ages_ns[ages_ns.len() / 2],
                ages_ns[(ages_ns.len() - 1) * 95 / 100],
                ages_ns[ages_ns.len() - 1]
            );
        }
        if count < 2 {
            bail!("continuous capture not proven");
        }
        Ok(())
    }
    .await;
    let stopped = stream.stop_stream(Duration::from_secs(5)).await;
    stopped.context("stop live stream")?;
    result
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("Linux only");
    std::process::exit(2);
}
