//! Capture one explicitly selected window without transmitting or writing pixels.
use anyhow::{Context, Result, bail};
use std::time::Duration;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let address = args
        .next()
        .context("usage: hyprcapture_probe <window-address>")?;
    if args.next().is_some() {
        bail!("usage: hyprcapture_probe <window-address>");
    }
    let frame = viewflowd::hyprcapture_runtime::capture_window(
        &address,
        64 * 1024 * 1024,
        Duration::from_secs(2),
    )
    .await?;
    println!(
        "logical_width={} logical_height={} wire_bytes={} capture_elapsed_us={}",
        frame.logical_width,
        frame.logical_height,
        frame.payload.len(),
        frame.capture_elapsed.as_micros(),
    );
    Ok(())
}
