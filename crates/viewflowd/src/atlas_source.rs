//! Linux GPU atlas source process orchestration.
use crate::{
    atlas_clock::AtlasClockClient,
    atlas_peer::{AtlasSourceConfig, read_bounded},
    atlas_session::{AtlasSessionPlan, offer_warmed_atlas},
    compatible_encoder::Config,
    gpu_atlas_device::AtlasDevicePoll,
    gpu_atlas_session::GpuAtlasSession,
    gpu_atlas_warmup::GpuAtlasWarmup,
    gpu_compatible_encoder::GpuAtlasCompatibleEncoder,
    hyprcapture_runtime::{GpuStreamSession, GpuStreamShutdown, start_gpu_stream},
};
use anyhow::{Context, Result, ensure};
use std::time::Duration;
use tokio::{
    sync::watch,
    time::{Instant, timeout_at},
};
use viewflow_protocol::{Id128, WindowId};

struct ClockWorker(tokio::task::JoinHandle<Result<()>>);
impl Drop for ClockWorker {
    fn drop(&mut self) {
        self.0.abort();
    }
}

fn native_now() -> Result<u64> {
    Ok(u64::try_from(crate::gpu_nvenc_runtime::monotonic_ns()?)?)
}

fn prepare(plan: AtlasSessionPlan) -> Result<GpuAtlasCompatibleEncoder> {
    let mut encoder = GpuAtlasCompatibleEncoder::new(Config {
        max_input_bytes: usize::try_from(plan.max_decoded_bytes)?,
        max_color_access_unit_bytes: plan.policy.max_encoded_bytes,
        max_alpha_access_unit_bytes: plan.policy.max_encoded_bytes,
        max_pending_frames: 2,
    })?;
    encoder.set_color_codec(plan.color.codec)?;
    encoder.prepare_size(plan.color.coded_width, plan.color.coded_height)?;
    Ok(encoder)
}

async fn stopped(stop: &mut watch::Receiver<bool>) {
    while !*stop.borrow_and_update() {
        if stop.changed().await.is_err() {
            return;
        }
    }
}

/// Never cancel or detach an in-progress native capture startup. Every result
/// is gathered, including after local stop, and failed groups are checked shut.
async fn start_sources(
    config: &AtlasSourceConfig,
    deadline: Instant,
    stop: &watch::Receiver<bool>,
) -> Result<Vec<(WindowId, GpuStreamSession)>> {
    ensure!(
        !*stop.borrow() && Instant::now() < deadline,
        "atlas source startup stopped or expired"
    );
    let mut jobs = tokio::task::JoinSet::new();
    for window in &config.windows {
        let id = Id128(u128::from_str_radix(&window.window_id, 16)?);
        let address = window.address.clone();
        let fps = u16::try_from(config.fps)?;
        let pid = config.compositor_pid;
        let timeout = deadline.saturating_duration_since(Instant::now());
        let provider = config.capture_provider;
        jobs.spawn(async move {
            let stream = match provider {
                crate::atlas_peer::AtlasCaptureProvider::Viewflow => {
                    crate::hyprcapture_runtime::start_viewflow_gpu_stream(
                        &address, fps, pid, timeout,
                    )
                    .await
                }
                crate::atlas_peer::AtlasCaptureProvider::Hyprcapture => {
                    start_gpu_stream(&address, fps, pid, timeout).await
                }
            };
            stream.map(|s| (id, s))
        });
    }
    let mut streams = Vec::new();
    let mut failure = None;
    while let Some(result) = jobs.join_next().await {
        match result
            .context("atlas capture startup worker failed")
            .and_then(|r| r)
        {
            Ok(stream) => streams.push(stream),
            Err(error) => {
                failure.get_or_insert(error);
            }
        }
    }
    if *stop.borrow() || Instant::now() >= deadline {
        failure.get_or_insert_with(|| anyhow::anyhow!("atlas source startup stopped or expired"));
    }
    if let Some(error) = failure {
        let (receivers, controls): (Vec<_>, Vec<_>) =
            streams.into_iter().map(|(_, s)| s.into_parts()).unzip();
        let cleanup = GpuStreamShutdown::new(controls)
            .shutdown(Duration::from_secs(2))
            .await;
        drop(receivers);
        return match cleanup {
            Ok(()) => Err(error),
            Err(cleanup) => {
                Err(error.context(format!("capture startup cleanup failed: {cleanup:#}")))
            }
        };
    }
    Ok(streams)
}

/// # Errors
/// Any startup/media failure retires the dedicated connection. Local stop is
/// observed without cancelling native startup or dropping an admitted batch.
pub async fn run_until(
    mut config: AtlasSourceConfig,
    stop: impl std::future::Future<Output = ()>,
) -> Result<()> {
    tokio::pin!(stop);
    while !crate::desktop_source::refresh_automatic_seed(&mut config).await? {
        tokio::select! {
            () = &mut stop => return Ok(()),
            () = tokio::time::sleep(Duration::from_millis(100)) => {},
        }
    }
    let layout = config.layout()?;
    let mut plan = config.media.plan()?;
    for descriptor in [&mut plan.color, &mut plan.alpha] {
        descriptor.coded_width = layout.width;
        descriptor.coded_height = layout.height;
    }
    let identity = viewflow_transport::PeerIdentity::from_pem(
        &read_bounded(&config.certificate, 1 << 20)?,
        &read_bounded(&config.private_key, 1 << 20)?,
        &read_bounded(&config.certificate_authority, 1 << 20)?,
    )
    .map_err(|e| anyhow::anyhow!("parse atlas source TLS identity: {e}"))?;
    let tls = viewflow_transport::build_client_config(&identity)
        .map_err(|e| anyhow::anyhow!("atlas client TLS configuration: {e}"))?;
    // No capture leases or clock stream exist during expensive GPU preparation.
    let warm_encoder = prepare(plan)?;
    let mut endpoint = quinn::Endpoint::client(config.bind)?;
    endpoint.set_default_client_config(tls);
    let (stop_tx, stop_rx) = watch::channel(false);
    let work = async {
        let deadline = Instant::now() + Duration::from_millis(config.startup_timeout_ms);
        // Validate the launcher-provided local stable-ID/PID identity before
        // any initial capture producer is opened. Dynamic enrollment uses the
        // same local-only identity rule later in its supervisor.
        let desktop_setup = match config.desktop.as_ref() {
            Some(desktop) => Some(
                crate::desktop_source::prepare_lane_from_config(
                    desktop,
                    &config.windows,
                    plan.policy.stream_id,
                )
                .await?,
            ),
            None => None,
        };
        let streams = start_sources(&config, deadline, &stop_rx).await?;
        let mut warmup = GpuAtlasWarmup::new(streams, warm_encoder, plan, layout.clone()).await?;
        warmup.set_occlusion(config.occlusion);
        let startup = async {
            let frames = warmup
                .collect_active_until(deadline, stopped(&mut stop_rx.clone()))
                .await?;
            warmup
                .await_draining(
                    async {
                        let connection = timeout_at(
                            deadline,
                            endpoint.connect(config.remote, &config.server_name)?,
                        )
                        .await??;
                        negotiate(
                            plan,
                            frames,
                            connection,
                            deadline,
                            config.disposition_recovery,
                        )
                        .await
                    },
                    deadline,
                    stopped(&mut stop_rx.clone()),
                )
                .await
        }
        .await;
        let mut peer = match startup {
            Ok(peer) => peer,
            Err(error) => {
                return match warmup.shutdown().await {
                    Ok(()) => Err(error),
                    Err(cleanup) => {
                        Err(error.context(format!("atlas startup cleanup failed: {cleanup:#}")))
                    }
                };
            }
        };
        let _connection_sampler = crate::atlas_feedback::sample_connection(&peer.connection, "source", native_now);
        let (_shared_writer, input) = match setup_input(&config, &mut peer, desktop_setup.clone()) {
            Ok(setup) => setup,
            Err(error) => {
                return match warmup.shutdown().await {
                    Ok(()) => Err(error),
                    Err(cleanup) => Err(error.context(format!(
                        "atlas input setup capture cleanup failed: {cleanup:#}"
                    ))),
                };
            }
        };
        let _clipboard = crate::clipboard_sync::ClipboardSync::start(&peer.connection, true);
        let _reverse = config
            .reverse
            .as_ref()
            .map(|reverse| {
                crate::reverse_bridge::ReverseBridge::start(
                    &peer.connection,
                    reverse,
                    false,
                    input.as_ref().map(|input| input.reverse_drag()),
                )
            })
            .transpose()?;
        let session = warmup.into_live(peer.sender).await?;
        let mut session = session;
        session.set_occlusion(config.occlusion)?;
        let desktop = if let Some(lane) = desktop_setup {
            session.attach_desktop_source(lane.clone())?;
            Some(crate::desktop_source::DesktopEnrollmentSupervisor::new(
                lane,
                config.desktop.as_ref().expect("desktop setup has config"),
                config.capture_provider,
                u16::try_from(config.fps)?,
                config.compositor_pid,
                plan.policy.stream_id,
            ))
        } else {
            None
        };
        let result = run_live(
            &config,
            session,
            &peer.connection,
            (peer.mapping, peer.clock),
            stop_rx,
            input,
            desktop,
        )
        .await;
        peer.connection.close(0_u32.into(), b"atlas source retired");
        result
    };
    tokio::pin!(work);
    let result = tokio::select! {
        result = &mut work => result,
        () = &mut stop => {
            let _ = stop_tx.send(true);
            // Let the bounded admitted handoff finish before closing QUIC.
            // Closing here can cut off its exact disposition receipt and turn
            // a requested local stop into an ambiguous transport failure.
            // Startup and the live loop observe stop_rx; all started capture
            // workers and their stop authorities are still gathered below.
            work.await
        }
    };
    endpoint.close(0_u32.into(), b"atlas source finished");
    result
}

struct Negotiated {
    connection: quinn::Connection,
    sender: crate::atlas_session::AtlasSenderSession,
    mapping: watch::Receiver<crate::atlas_clock::AtlasClockMapping>,
    clock: ClockWorker,
}

fn setup_input(
    config: &AtlasSourceConfig,
    peer: &mut Negotiated,
    desktop_lane: Option<crate::desktop_source::SharedDesktopSourceLane>,
) -> Result<(
    Option<crate::shared_control::SharedControlWriter>,
    Option<crate::atlas_source_input::AtlasSourceInput>,
)> {
    if config.pointer.is_none() {
        return Ok((None, None));
    }
    let writer = crate::shared_control::SharedControlWriter::start(&peer.connection)?;
    peer.sender.attach_shared_control(writer.sender())?;
    let input = crate::atlas_source_input::AtlasSourceInput::start(
        config,
        &peer.connection,
        writer.sender(),
        desktop_lane,
    )?;
    Ok((Some(writer), Some(input)))
}

async fn negotiate(
    plan: AtlasSessionPlan,
    frames: [crate::atlas_presenter::AtlasWarmupFrame; 3],
    connection: quinn::Connection,
    deadline: Instant,
    dispositions: bool,
) -> Result<Negotiated> {
    let mut guard = crate::atlas_session::StartupGuard(Some(connection.clone()));
    let mut clock = AtlasClockClient::open(
        &connection,
        plan.policy.max_age_ns / 4,
        Duration::from_secs(2),
        deadline,
    )
    .await?;
    let mapping = clock.calibrate(native_now, deadline).await?;
    let (mapping_tx, mapping_rx) = watch::channel(mapping);
    let clock_worker = ClockWorker(tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_millis(250)).await;
            let mapping = clock
                .calibrate(native_now, Instant::now() + Duration::from_secs(1))
                .await?;
            if mapping_tx.send(mapping).is_err() {
                return Ok(());
            }
        }
    }));
    let sender = if dispositions {
        crate::atlas_session::offer_warmed_atlas_dispositions(&connection, plan, &frames, deadline)
            .await?
    } else {
        offer_warmed_atlas(&connection, plan, &frames, deadline).await?
    };
    guard.0 = None;
    Ok(Negotiated {
        connection,
        sender,
        mapping: mapping_rx,
        clock: clock_worker,
    })
}

async fn run_live(
    config: &AtlasSourceConfig,
    mut session: GpuAtlasSession,
    connection: &quinn::Connection,
    clock: (
        watch::Receiver<crate::atlas_clock::AtlasClockMapping>,
        ClockWorker,
    ),
    stop: watch::Receiver<bool>,
    mut input: Option<crate::atlas_source_input::AtlasSourceInput>,
    mut desktop: Option<crate::desktop_source::DesktopEnrollmentSupervisor>,
) -> Result<()> {
    let (mapping_rx, _clock_worker) = clock;
    let plan = config.media.plan()?;
    eprintln!(
        "atlas-source-active windows={} input_enabled={}",
        config.windows.len(),
        input.is_some()
    );
    let mut waiting = 0_u64;
    let mut expired = 0_u64;
    let mut enqueued = 0_u64;
    let result = async {
        let mut last_frame = Instant::now();
        loop {
            if *stop.borrow() {
                return Ok(());
            }
            ensure!(
                connection.close_reason().is_none(),
                "atlas peer connection closed"
            );
            if last_frame.elapsed() >= Duration::from_millis(config.media_idle_timeout_ms) {
                eprintln!("atlas-media-idle connection_retained=true waiting={waiting} expired_clean={expired}");
                last_frame = Instant::now();
            }
            if let Some(desktop) = &mut desktop {
                desktop.poll_one(&mut session, input.as_mut()).await.context("update desktop capture enrollment")?;
            }
            let mapping = *mapping_rx.borrow();
            if let Some(input) = &mut input {
                input.poll(session.committed_input()).await.context("update atlas source input")?;
            }
            let media = session.poll_and_send(
                |captured| mapping.map_source_ns(connection, captured),
                Instant::now() + Duration::from_nanos(plan.policy.max_age_ns),
            );
            let poll = if let Some(input) = &mut input {
                Box::pin(input.while_media(media)).await.context("drive atlas capture and presentation")?
            } else {
                media.await?
            };
            match &poll {
                AtlasDevicePoll::Submitted => {},
                AtlasDevicePoll::Waiting => waiting = waiting.saturating_add(1),
                AtlasDevicePoll::ExpiredClean => expired = expired.saturating_add(1),
                AtlasDevicePoll::Enqueued(_) => {
                    enqueued = enqueued.saturating_add(1);
                    last_frame = Instant::now();
                }
            }
            if let Some(input) = &mut input {
                input.poll(session.committed_input()).await.context("update atlas source input")?;
            }
            match poll {
                AtlasDevicePoll::Waiting => tokio::time::sleep(Duration::from_millis(1)).await,
                // A clean expiry can complete without network I/O. Give other
                // tasks a turn without delaying an already-ready fresh capture.
                AtlasDevicePoll::ExpiredClean | AtlasDevicePoll::Submitted => tokio::task::yield_now().await,
                AtlasDevicePoll::Enqueued(_) => {}
            }
        }
    }
    .await;
    eprintln!(
        "atlas-source-retiring waiting={waiting} expired_clean={expired} enqueued={enqueued} physical_present_receipt=false"
    );
    // Gather every source-enrollment worker before retiring input/capture
    // owners. A probe may be holding a locally started producer even though it
    // has not yet joined the atlas session.
    let desktop_cleanup = if let Some(desktop) = &mut desktop {
        desktop.shutdown().await
    } else {
        Ok(())
    };
    // Await native route cancellation before releasing capture binding owners.
    let input_cleanup = if let Some(input) = input.take() {
        input.shutdown().await
    } else {
        Ok(())
    };
    let cleanup = session.shutdown(Duration::from_secs(2)).await;
    let cleanup = match (desktop_cleanup, input_cleanup, cleanup) {
        (Err(desktop), Err(input), Err(capture)) => Err(desktop.context(format!(
            "atlas input cleanup also failed: {input:#}; atlas capture cleanup also failed: {capture:#}"
        ))),
        (Err(desktop), Err(input), Ok(())) => {
            Err(desktop.context(format!("atlas input cleanup also failed: {input:#}")))
        }
        (Err(desktop), Ok(()), Err(capture)) => {
            Err(desktop.context(format!("atlas capture cleanup also failed: {capture:#}")))
        }
        (Ok(()), Err(input), Err(capture)) => {
            Err(input.context(format!("atlas capture cleanup also failed: {capture:#}")))
        }
        (Err(error), Ok(()), Ok(())) | (Ok(()), Err(error), Ok(())) | (Ok(()), Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(()), Ok(())) => Ok(()),
    };
    match (result, cleanup) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
        (Err(error), Err(cleanup)) => {
            Err(error.context(format!("atlas source cleanup failed: {cleanup:#}")))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[ignore = "requires explicit owned Wayland test-window address and compositor PID"]
    async fn real_capture_warmup_releases_and_stops_producer() {
        use crate::hyprcapture_gpu_socket::GpuReceiveOutcome;
        let address = std::env::var("VIEWFLOW_ATLAS_TEST_WINDOW").unwrap();
        let pid = std::env::var("VIEWFLOW_ATLAS_COMPOSITOR_PID")
            .unwrap()
            .parse()
            .unwrap();
        let mut probe = start_gpu_stream(&address, 30, pid, Duration::from_secs(2))
            .await
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        let geometry = loop {
            match probe.receiver.recv_frame().unwrap() {
                GpuReceiveOutcome::Frame(frame) => {
                    let m = frame.metadata();
                    let geometry = (m.crop_width, m.crop_height, m.geometry_epoch);
                    probe.receiver.release_after_source_reads(&frame).unwrap();
                    break geometry;
                }
                GpuReceiveOutcome::WouldBlock => {
                    assert!(Instant::now() < deadline, "capture probe timed out");
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
                GpuReceiveOutcome::Disconnected => panic!("capture probe disconnected"),
            }
        };
        probe.stop_stream(Duration::from_secs(2)).await.unwrap();
        eprintln!("owned capture geometry={geometry:?}");
        let root = std::env::temp_dir();
        let config = AtlasSourceConfig {
            occlusion: crate::atlas_occlusion::AtlasOcclusionMode::Opaque,
            reverse: None,
            pointer: None,
            desktop: None,
            capture_provider: crate::atlas_peer::AtlasCaptureProvider::Hyprcapture,
            disposition_recovery: false,
            bind: "127.0.0.1:0".parse().unwrap(),
            remote: "127.0.0.1:9000".parse().unwrap(),
            server_name: "localhost".into(),
            certificate: root.join("unused.pem"),
            private_key: root.join("unused.key"),
            certificate_authority: root.join("unused-ca.pem"),
            compositor_pid: pid,
            fps: 30,
            startup_timeout_ms: 10000,
            media_idle_timeout_ms: 3000,
            media: crate::atlas_peer::AtlasMediaPolicyConfig {
                max_width: None,
                max_height: None,
                color_codec: Default::default(),
                stream_id: format!("{:032x}", 99),
                geometry_epoch: 1,
                config_generation: 1,
                width: (geometry.0 + 1) & !1,
                height: (geometry.1 + 1) & !1,
                max_tiles: 1,
                max_encoded_bytes: 8 << 20,
                max_decoded_bytes: 64 << 20,
                refresh_hz: 60,
            },
            windows: vec![crate::atlas_peer::AtlasSourceWindow {
                window_id: format!("{:032x}", 1),
                address,
                width: geometry.0,
                height: geometry.1,
                geometry_epoch: geometry.2,
            }],
        };
        let plan = config.media.plan().unwrap();
        let layout = config.layout().unwrap();
        let encoder = prepare(plan).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let (_tx, stop) = watch::channel(false);
        let streams = start_sources(&config, deadline, &stop).await.unwrap();
        let mut warmup = GpuAtlasWarmup::new(streams, encoder, plan, layout)
            .await
            .unwrap();
        let frames = warmup
            .collect_until(deadline, std::future::pending())
            .await
            .unwrap();
        for frame in frames {
            assert!(!frame.color.is_empty() && !frame.alpha.is_empty());
            assert_eq!(
                (frame.width, frame.height),
                (plan.policy.width, plan.policy.height)
            );
            eprintln!(
                "owned warmup color_bytes={} alpha_bytes={}",
                frame.color.len(),
                frame.alpha.len()
            );
        }
        warmup.shutdown().await.unwrap();
    }
}
