//! Bounded local Windows preview for one premultiplied VFBG frame.
//!
//! This deliberately has no QUIC, certificates, capture producer, or timing
//! claims. It is a native presentation diagnostic for visually inspecting one
//! already-staged frame on the local Windows desktop.

#[cfg(windows)]
use std::time::Instant;
use std::{env, fs::File, io::Read, time::Duration};

use anyhow::{Context, Result, bail};
use bytes::Bytes;
use viewflow_transport::RawBgraPayload;

const DEFAULT_MAX_BYTES: usize = 16 * 1024 * 1024;
const DEFAULT_VISIBLE_MS: u64 = 2_000;
const MAX_VISIBLE_MS: u64 = 60_000;

#[derive(Clone, Copy, Debug, PartialEq)]
struct LogicalSize {
    width: f64,
    height: f64,
}

impl LogicalSize {
    fn checked(width: f64, height: f64) -> Result<Self> {
        if !width.is_finite()
            || !height.is_finite()
            || width <= 0.0
            || height <= 0.0
            || width > 100_000.0
            || height > 100_000.0
        {
            bail!("invalid logical frame dimensions");
        }
        Ok(Self { width, height })
    }
}

#[cfg_attr(not(windows), allow(dead_code))]
#[derive(Clone, Debug)]
struct Options {
    file: String,
    logical_size: LogicalSize,
    visible: Duration,
    x: i32,
    y: i32,
    max_bytes: usize,
}

fn main() -> Result<()> {
    run(parse_options()?)
}

#[cfg(windows)]
fn run(options: Options) -> Result<()> {
    use viewflow_platform::windows_proxy::{BgraFrame, WindowsProxy};

    let raw = read_raw_bgra(&options.file, options.max_bytes)?;
    let input_width = raw.width;
    let input_height = raw.height;
    let input_stride = raw.stride;
    let input_bytes = raw.pixels.len();
    let frame = BgraFrame::new(
        raw.width,
        raw.height,
        raw.stride as usize,
        raw.pixels.to_vec(),
    )
    .context("convert validated VFBG payload to native BGRA frame")?;
    let mut proxy = WindowsProxy::new("Viewflow raw local preview", options.x, options.y)
        .context("create local native Windows proxy")?;
    let submit_started = Instant::now();
    let timing = proxy
        .present_logical_profiled(
            &frame,
            options.logical_size.width,
            options.logical_size.height,
        )
        .context("submit local BGRA preview")?;
    eprintln!(
        "local preview native submission: input_pixels={}x{} stride={} bytes={} logical={}x{} proxy_dpi={} submit_elapsed_ns={}",
        input_width,
        input_height,
        input_stride,
        input_bytes,
        options.logical_size.width,
        options.logical_size.height,
        proxy.dpi().context("read local proxy DPI")?,
        submit_started.elapsed().as_nanos(),
    );
    eprintln!(
        "local preview stages: target_pixels={}x{} resample_ns={} allocation_ns={} copy_ns={} win32_submit_ns={}; excludes decoding and physical scanout",
        timing.target_pixels.0,
        timing.target_pixels.1,
        timing.resample.as_nanos(),
        timing.surface_allocation.as_nanos(),
        timing.pixel_copy.as_nanos(),
        timing.update_layered_window.as_nanos(),
    );
    eprintln!(
        "local preview submitted; pumping the one local HWND for {} ms",
        options.visible.as_millis()
    );
    let visible_until = Instant::now() + options.visible;
    while Instant::now() < visible_until {
        if !proxy.pump_events().context("pump local preview events")? {
            break;
        }
        std::thread::sleep(Duration::from_millis(16));
    }
    println!(
        "local raw preview finished; this proves only local native submission/pumping, not transport, remote display, or latency"
    );
    Ok(())
}

#[cfg(not(windows))]
fn run(_options: Options) -> Result<()> {
    bail!("raw_window_preview requires Windows: it is a local WindowsProxy diagnostic")
}

#[cfg_attr(not(windows), allow(dead_code))]
fn read_raw_bgra(path: &str, max_bytes: usize) -> Result<RawBgraPayload> {
    let metadata = std::fs::metadata(path).with_context(|| format!("stat {path}"))?;
    if !metadata.file_type().is_file() {
        bail!("VFBG input must be a regular file")
    }
    let length =
        usize::try_from(metadata.len()).context("raw file length does not fit this platform")?;
    if length < 20 || length > max_bytes.saturating_add(20) {
        bail!(
            "VFBG file length {length} is outside bounded limit (20..={})",
            max_bytes.saturating_add(20)
        );
    }
    let mut file = File::open(path).with_context(|| format!("open {path}"))?;
    if !file
        .metadata()
        .with_context(|| format!("fstat {path}"))?
        .file_type()
        .is_file()
    {
        bail!("VFBG input changed to a non-regular file")
    }
    let mut header = [0u8; 20];
    file.read_exact(&mut header).context("read VFBG header")?;
    if &header[..4] != b"VFBG" || header[4..8] != [1, 1, 0, 0] {
        bail!("file is not a version-1 premultiplied BGRA VFBG payload")
    }
    let mut bytes = Vec::with_capacity(length);
    bytes.extend_from_slice(&header);
    let remaining = length.saturating_sub(header.len());
    file.take(u64::try_from(remaining.saturating_add(1)).unwrap_or(u64::MAX))
        .read_to_end(&mut bytes)
        .context("read bounded VFBG payload")?;
    if bytes.len() != length {
        bail!("VFBG file changed while it was read")
    }
    RawBgraPayload::decode(Bytes::from(bytes), max_bytes)
        .context("validate bounded premultiplied raw BGRA payload")
}

fn parse_options() -> Result<Options> {
    parse_options_from(env::args().skip(1))
}

fn parse_options_from(mut arguments: impl Iterator<Item = String>) -> Result<Options> {
    let mut values = std::collections::BTreeMap::new();
    while let Some(name) = arguments.next() {
        let name = name
            .strip_prefix("--")
            .context("options must start with --")?
            .to_owned();
        let value = arguments
            .next()
            .with_context(|| format!("--{name} needs a value"))?;
        if values.insert(name.clone(), value).is_some() {
            bail!("--{name} was specified more than once")
        }
    }
    let allowed = [
        "file",
        "logical-width",
        "logical-height",
        "visible-ms",
        "x",
        "y",
        "max-bytes",
    ];
    if let Some(unknown) = values.keys().find(|name| !allowed.contains(&name.as_str())) {
        bail!("unknown option --{unknown}")
    }
    let take = |name: &str| {
        values
            .get(name)
            .cloned()
            .with_context(|| format!("missing --{name}"))
    };
    let parse = |name: &str| {
        take(name)?
            .parse()
            .with_context(|| format!("invalid --{name}"))
    };
    let max_bytes = values
        .get("max-bytes")
        .map_or(Ok(DEFAULT_MAX_BYTES), |value| {
            value.parse().context("invalid --max-bytes")
        })?;
    if max_bytes == 0 {
        bail!("--max-bytes must be greater than zero")
    }
    let visible_ms = values
        .get("visible-ms")
        .map_or(Ok(DEFAULT_VISIBLE_MS), |value| {
            value.parse().context("invalid --visible-ms")
        })?;
    if !(1..=MAX_VISIBLE_MS).contains(&visible_ms) {
        bail!("--visible-ms must be within 1..={MAX_VISIBLE_MS}")
    }
    Ok(Options {
        file: take("file")?,
        logical_size: LogicalSize::checked(parse("logical-width")?, parse("logical-height")?)?,
        visible: Duration::from_millis(visible_ms),
        x: values
            .get("x")
            .map_or(Ok(0_i32), |value| value.parse().context("invalid --x"))?,
        y: values
            .get("y")
            .map_or(Ok(0_i32), |value| value.parse().context("invalid --y"))?,
        max_bytes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn parse(tail: &[&str]) -> Result<Options> {
        let base = [
            "--file",
            "unused.vfbg",
            "--logical-width",
            "320",
            "--logical-height",
            "200",
        ];
        parse_options_from(base.iter().chain(tail).map(|value| (*value).to_owned()))
    }

    #[test]
    fn parser_requires_geometry_and_bounds_visible_duration() {
        let options = parse(&[]).unwrap();
        assert_eq!(options.visible, Duration::from_secs(2));
        assert_eq!(options.max_bytes, DEFAULT_MAX_BYTES);
        assert_eq!(
            parse(&["--visible-ms", "1"]).unwrap().visible,
            Duration::from_millis(1)
        );
        assert_eq!(
            parse(&["--visible-ms", "60000"]).unwrap().visible,
            Duration::from_secs(60)
        );
        assert!(parse(&["--visible-ms", "0"]).is_err());
        assert!(parse(&["--visible-ms", "60001"]).is_err());
        assert!(parse(&["--max-bytes", "0"]).is_err());
        assert!(parse(&["--unexpected", "value"]).is_err());
        assert!(
            parse_options_from(["--file", "unused.vfbg"].map(str::to_owned).into_iter()).is_err()
        );
    }

    #[test]
    fn bounded_reader_rejects_invalid_payloads_before_preview() {
        let payload = RawBgraPayload {
            width: 1,
            height: 1,
            stride: 4,
            pixels: Bytes::from_static(&[1, 2, 3, 255]),
        }
        .encode(4)
        .unwrap();
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(&payload).unwrap();
        let path = file.path().to_str().unwrap();
        assert_eq!(
            read_raw_bgra(path, 4).unwrap().pixels,
            Bytes::from_static(&[1, 2, 3, 255])
        );
        assert!(read_raw_bgra(path, 3).is_err());
        std::fs::write(path, b"not a frame").unwrap();
        assert!(read_raw_bgra(path, 4).is_err());
    }
}
