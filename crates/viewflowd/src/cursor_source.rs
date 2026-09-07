//! Native Hyprland cursor handoff without a video session.
use crate::{
    atlas_cursor_handoff::{CursorBridge, CursorConfig},
    window_input_runtime::{AuthorizedWindow, WindowInputSession},
};
use anyhow::{Context, Result};
use std::{
    path::Path,
    time::{Duration, Instant},
};

pub async fn run(path: &Path) -> Result<()> {
    let ready = std::env::var_os("VIEWFLOW_CURSOR_READY_FILE").map(std::path::PathBuf::from);
    if let Some(path) = &ready {
        let _ = std::fs::remove_file(path);
    }
    let config = crate::atlas_peer::AtlasSourceConfig::load(path)?;
    let pointer = config
        .pointer
        .as_ref()
        .context("cursor pointer configuration missing")?;
    let desktop = config
        .desktop
        .as_ref()
        .context("cursor desktop layout missing")?;
    let size = std::env::var("VIEWFLOW_CURSOR_OUTPUT_SIZE")
        .context("VIEWFLOW_CURSOR_OUTPUT_SIZE must give remote logical WIDTHxHEIGHT")?;
    let (width, height) = size.split_once('x').context("invalid output size")?;
    let (width, height) = (width.parse::<f64>()?, height.parse::<f64>()?);
    anyhow::ensure!(
        width.is_finite() && height.is_finite() && width > 0.0 && height > 0.0,
        "invalid output size"
    );
    let (target, owner) = pointer.devices.devices()?;
    let identity = viewflow_transport::PeerIdentity::from_pem(
        &std::fs::read(&config.certificate)?,
        &std::fs::read(&config.private_key)?,
        &std::fs::read(&config.certificate_authority)?,
    )
    .map_err(|e| anyhow::anyhow!("TLS identity: {e}"))?;
    let mut endpoint = quinn::Endpoint::client(config.bind)?;
    endpoint.set_default_client_config(
        viewflow_transport::build_client_config(&identity)
            .map_err(|e| anyhow::anyhow!("TLS client: {e}"))?,
    );
    let connection = tokio::time::timeout(
        Duration::from_secs(10),
        endpoint.connect(config.remote, &config.server_name)?,
    )
    .await??;
    let writer = crate::shared_control::SharedControlWriter::start(&connection)?;
    let listener = viewflow_hyprland::window_pointer_socket::Listener::bind(
        &pointer.native_socket,
        i32::try_from(config.compositor_pid)?,
    )?;
    let _socket_cleanup = SocketCleanup(
        pointer.native_socket.clone(),
        std::fs::metadata(&pointer.native_socket)?,
    );
    let origin = Instant::now();
    let native = loop {
        match listener.accept() {
            Ok(native) => break native,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                anyhow::ensure!(
                    origin.elapsed() < Duration::from_secs(10),
                    "native cursor startup timed out"
                );
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            Err(error) => return Err(error.into()),
        }
    };
    let initial = AuthorizedWindow::unbound(target, owner);
    let mut session = WindowInputSession::prepare_atlas(
        native,
        initial.clone(),
        origin,
        pointer.wheel,
        pointer.direct_keyboard,
    )?;
    // The remote desktop occupies a virtual Linux viewport. Quartz receives
    // display-local points, so remove the viewport origin only at the wire edge.
    session.attach_cursor(CursorBridge::start(
        CursorConfig {
            drag: Default::default(),
            reverse_drag: Default::default(),
            remote_scale: desktop.remote_display.scale,
            position_offset: (
                -f64::from(desktop.remote_display.x),
                -f64::from(desktop.remote_display.y),
            ),
            position_scale: (
                width * desktop.remote_display.scale / f64::from(desktop.remote_display.width),
                height * desktop.remote_display.scale / f64::from(desktop.remote_display.height),
            ),
            ready_file: ready.clone(),
            local: crate::atlas_cursor_handoff::local_displays(&desktop.hyprland_socket, pointer.cursor_monitor_id.context("cursor monitor missing")?)?,
            remote: desktop.remote_display.rect()?,
            monitor_id: pointer
                .cursor_monitor_id
                .context("cursor monitor missing")?,
            topology_generation: desktop.topology_generation,
            owner,
            target,
            fps: config.fps,
        },
        writer.sender(),
        connection.clone(),
        origin,
        std::sync::Arc::new(std::sync::atomic::AtomicU8::new(2)),
    ));
    let (_updates, receive) = tokio::sync::watch::channel(initial);
    let (selections, _requests) = tokio::sync::mpsc::channel(64);
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let result = tokio::select! {
        result = session.serve_atlas_selections(&connection, receive, writer.sender(), selections, |_| Ok(())) => result,
        _ = terminate.recv() => Ok(()),
        _ = tokio::signal::ctrl_c() => Ok(()),
    };
    if let Some(path) = &ready {
        let _ = std::fs::remove_file(path);
    }
    connection.close(0u32.into(), b"cursor source stopped");
    drop(writer);
    endpoint.wait_idle().await;
    result
}

struct SocketCleanup(std::path::PathBuf, std::fs::Metadata);
impl Drop for SocketCleanup {
    fn drop(&mut self) {
        use std::os::unix::fs::MetadataExt;
        if let Ok(current) = std::fs::symlink_metadata(&self.0) {
            if current.dev() == self.1.dev() && current.ino() == self.1.ino() {
                let _ = std::fs::remove_file(&self.0);
            }
        }
    }
}
