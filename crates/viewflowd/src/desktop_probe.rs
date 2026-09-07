//! One-shot native desktop-window metadata probe.
//!
//! This module deliberately reads only the authenticated HCGF/HCGI metadata.
//! It never imports the DMA-BUF, waits on its fence, submits work, or sends an
//! HCGR release. The producer is explicitly stopped before its retained frame
//! is dropped, so this probe cannot claim source-read completion.

use std::time::Duration;

use anyhow::{Context, Result, bail, ensure};
use serde::Serialize;
use tokio::time::Instant;
use viewflow_hyprland::{HyprIpcClient, HyprWindow, parse_windows, resolve_socket_path};

use crate::{
    hyprcapture_gpu_socket::{GpuFrame, GpuReceiveOutcome},
    hyprcapture_gpu_wire::InputGeometry,
    hyprcapture_runtime::start_viewflow_gpu_stream,
};

const PROBE_TIMEOUT: Duration = Duration::from_secs(2);
const PROBE_FPS: u16 = 1;

/// Logical capture bounds emitted by [`probe_viewflow_desktop_window`].
#[derive(Clone, Copy, Debug, Serialize, PartialEq)]
pub struct DesktopProbeLogicalBounds {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Exact metadata emitted by `vf-media-peer probe` for its launcher.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct DesktopProbeOutput {
    pub width: u32,
    pub height: u32,
    pub geometry_epoch: u64,
    pub logical: DesktopProbeLogicalBounds,
    pub address: String,
    pub pid: u32,
    pub stable_id: String,
}

/// Starts a one-frame Viewflow GPU capture and returns source metadata only.
///
/// The HCGI address and PID are required to match both the caller's requested
/// address and a current Hyprland `j/clients` entry before the stable ID is
/// emitted. No HCGR is sent: this probe performs no source GPU read and does
/// not wait on the native fence.
///
/// # Errors
///
/// Returns an error if the selected address/PID is invalid, no authenticated
/// HCGF/HCGI frame arrives before the fixed deadline, current Hyprland window
/// metadata disagrees, or the explicitly owned stream cannot be stopped.
pub async fn probe_viewflow_desktop_window(
    requested_address: &str,
    compositor_pid: u32,
) -> Result<DesktopProbeOutput> {
    let requested_address = parse_address(requested_address)?;
    ensure!(compositor_pid > 0, "compositor PID is required");

    let mut stream = start_viewflow_gpu_stream(
        &canonical_address(requested_address),
        PROBE_FPS,
        compositor_pid,
        PROBE_TIMEOUT,
    )
    .await?;
    let mut retained_frame = None;
    let probe = async {
        retained_frame = Some(first_frame(&mut stream, Instant::now() + PROBE_TIMEOUT).await?);
        let frame = retained_frame
            .as_ref()
            .expect("first_frame assigned retained probe frame");
        let input = frame
            .input_geometry()
            .context("desktop probe HCGF lacks required HCGI identity")?;
        output_from_frame(requested_address, input, frame)
    }
    .await;

    // Keep the descriptors in `retained_frame` alive until producer stop is
    // confirmed. The stream's own receiver is dropped by `stop_stream`; we do
    // not emit HCGR because no source read/fence completion was performed.
    let stop = stream.stop_stream(PROBE_TIMEOUT).await;
    drop(retained_frame);
    match (probe, stop) {
        (Ok(output), Ok(())) => Ok(output),
        (Err(error), Ok(())) => Err(error),
        (Ok(_), Err(stop_error)) => Err(stop_error).context("desktop probe stream stop failed"),
        (Err(error), Err(stop_error)) => Err(error).context(format!(
            "desktop probe stream stop also failed: {stop_error:#}"
        )),
    }
}

fn output_from_frame(
    requested_address: u64,
    input: InputGeometry,
    frame: &GpuFrame,
) -> Result<DesktopProbeOutput> {
    let pid = u32::try_from(input.pid).context("desktop probe HCGI PID is invalid")?;
    ensure!(
        input.window == requested_address && input.surface != 0,
        "desktop probe HCGI identity does not match requested window"
    );
    let metadata = frame.metadata();
    let stable_id = current_stable_id(input.window, pid)?;
    Ok(DesktopProbeOutput {
        width: metadata.crop_width,
        height: metadata.crop_height,
        geometry_epoch: metadata.geometry_epoch,
        logical: DesktopProbeLogicalBounds {
            x: metadata.logical_x,
            y: metadata.logical_y,
            width: metadata.logical_width,
            height: metadata.logical_height,
        },
        address: canonical_address(input.window),
        pid,
        stable_id,
    })
}

fn current_stable_id(address: u64, pid: u32) -> Result<String> {
    let socket = resolve_socket_path().context("resolve Hyprland command socket")?;
    let response = HyprIpcClient::new(socket)
        .request("j/clients")
        .context("read current Hyprland clients")?;
    let windows = parse_windows(&response).context("parse current Hyprland clients")?;
    exact_window(&windows, address, pid)
        .map(|window| window.stable_id.clone())
        .context("HCGI source does not match one current mapped Hyprland window")
}

fn exact_window(windows: &[HyprWindow], address: u64, pid: u32) -> Option<&HyprWindow> {
    windows.iter().find(|window| {
        window.mapped
            && !window.hidden
            && parse_address(&window.address).ok() == Some(address)
            && u32::try_from(window.pid).ok() == Some(pid)
            && !window.stable_id.is_empty()
    })
}

async fn first_frame(
    stream: &mut crate::hyprcapture_runtime::GpuStreamSession,
    deadline: Instant,
) -> Result<Box<GpuFrame>> {
    loop {
        match stream.receiver.recv_frame()? {
            GpuReceiveOutcome::Frame(frame) => return Ok(frame),
            GpuReceiveOutcome::Disconnected => bail!("desktop probe capture peer disconnected"),
            GpuReceiveOutcome::WouldBlock => {
                ensure!(
                    Instant::now() < deadline,
                    "desktop probe timed out waiting for HCGF"
                );
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        }
    }
}

fn parse_address(value: &str) -> Result<u64> {
    let hex = value
        .strip_prefix("0x")
        .context("window address must start with 0x")?;
    ensure!(
        !hex.is_empty() && hex.len() <= 16 && hex.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "invalid window address"
    );
    let address = u64::from_str_radix(hex, 16).context("invalid window address")?;
    ensure!(address != 0, "window address is zero");
    Ok(address)
}

fn canonical_address(address: u64) -> String {
    format!("0x{address:x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(address: &str, pid: i64, stable_id: &str) -> HyprWindow {
        HyprWindow {
            address: address.into(),
            mapped: true,
            hidden: false,
            visible: true,
            at: [0.0, 0.0],
            size: [1.0, 1.0],
            floating: false,
            monitor: 0,
            class: String::new(),
            title: String::new(),
            initial_class: String::new(),
            initial_title: String::new(),
            pid,
            xwayland: false,
            fullscreen: 0,
            grouped: Vec::new(),
            stable_id: stable_id.into(),
        }
    }

    #[test]
    fn exact_window_requires_hcgi_address_pid_and_stable_id() {
        let windows = vec![
            window("0x100", 9, "other-address"),
            window("0x123", 8, "other-pid"),
            window("0x123", 9, ""),
            window("0x123", 9, "selected"),
        ];
        assert_eq!(
            exact_window(&windows, 0x123, 9).map(|found| found.stable_id.as_str()),
            Some("selected")
        );
        assert!(exact_window(&windows, 0x124, 9).is_none());
        assert!(exact_window(&windows, 0x123, 10).is_none());
    }

    #[test]
    fn address_is_bounded_and_canonicalized() {
        assert_eq!(parse_address("0x000f").unwrap(), 15);
        assert_eq!(canonical_address(15), "0xf");
        assert!(parse_address("0x0").is_err());
        assert!(parse_address("123").is_err());
        assert!(parse_address("0x10000000000000000").is_err());
    }
}
