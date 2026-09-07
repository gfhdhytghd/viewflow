//! Short, opt-in native desktop check. Does not capture or inject input.
use std::{
    fs::OpenOptions,
    io::Write,
    time::{Duration, Instant},
};
use viewflow_platform::windows_proxy::{BgraFrame, WindowsProxy};

fn pattern(width: u32, height: u32) -> Result<BgraFrame, Box<dyn std::error::Error>> {
    let mut pixels = Vec::with_capacity(width as usize * height as usize * 4);
    for y in 0..height {
        for x in 0..width {
            let alpha = if x < width / 3 {
                0
            } else if x < 2 * width / 3 {
                128
            } else {
                255
            };
            let green = if (x / 16 + y / 16) % 2 == 0 { alpha } else { 0 };
            pixels.extend_from_slice(&[alpha / 3, green, alpha, alpha]);
        }
    }
    Ok(BgraFrame::new(width, height, width as usize * 4, pixels)?)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 1 {
        return Err(
            "usage: proxy_smoke NEW_REPORT_PATH (shows a test window for 1.5 seconds)".into(),
        );
    }
    let mut proxy = WindowsProxy::new("Viewflow native proxy check", 80, 80)?;
    let mut report = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&args[0])?;
    writeln!(
        report,
        "{{\"event\":\"created\",\"pid\":{}}}",
        std::process::id()
    )?;
    report.sync_all()?;
    for (width, height, x, y) in [(180, 120, 80, 80), (240, 140, 120, 100), (180, 120, 80, 80)] {
        let frame = pattern(width, height)?;
        proxy.move_to(x, y)?;
        proxy.present(&frame)?;
        writeln!(
            report,
            "{{\"event\":\"native_submission\",\"width\":{width},\"height\":{height},\"x\":{x},\"y\":{y}}}"
        )?;
        report.sync_all()?;
        let started = Instant::now();
        while started.elapsed() < Duration::from_millis(500) {
            if !proxy.pump_events()? {
                return Err("proxy closed during check".into());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    #[cfg(windows)]
    drop(proxy);
    writeln!(
        report,
        "{{\"event\":\"complete\",\"submitted_frames\":3,\"visual_verified\":false}}"
    )?;
    report.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn pattern_contains_transparent_translucent_and_opaque_pixels() {
        let frame = super::pattern(48, 32).unwrap();
        assert_eq!(frame.pixels()[3], 0);
        assert_eq!(frame.pixels()[16 * 4 + 3], 128);
        assert_eq!(frame.pixels()[32 * 4 + 3], 255);
    }
}
