//! Owned two-host experiment. Test-only TLS identity; never captures or injects input.
use super::*;
use crate::atlas_feedback::AtlasFrameDisposition;
use serde_json::json;
use std::time::Duration;
use viewflow_protocol::Id128;

fn wifi_plan() -> AtlasSessionPlan {
    let mut plan = tests::plan();
    plan.policy.width = 1920;
    plan.policy.height = 1080;
    plan.policy.max_encoded_bytes = 16 * 1024 * 1024;
    // No clock synchronization in this fixture. These test-only bounds disable
    // cross-host timestamp validation, not production session policy. Latency
    // is measured on sender's clock through exact disposition feedback.
    plan.policy.max_age_ns = u64::MAX;
    plan.policy.max_future_ns = u64::MAX;
    plan.max_decoded_bytes = 1920 * 1080 * 8;
    plan.color.coded_width = 1920;
    plan.color.coded_height = 1080;
    plan.alpha.coded_width = 1920;
    plan.alpha.coded_height = 1080;
    plan
}

async fn wifi_connection(receive: bool) -> Result<(quinn::Endpoint, Connection)> {
    let identity = viewflow_transport::PeerIdentity::from_pem(
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem"),
        include_bytes!("../../viewflow-transport/tests/fixtures/peer.key"),
        include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem"),
    )
    .map_err(anyhow::Error::from_boxed)?;
    let bind = std::env::var("VF_WIFI_BIND")?.parse::<std::net::SocketAddr>()?;
    let config = receive
        .then(|| viewflow_transport::build_server_config(&identity))
        .transpose()
        .map_err(anyhow::Error::from_boxed)?;
    let socket = socket2::Socket::new(
        socket2::Domain::IPV4,
        socket2::Type::DGRAM,
        Some(socket2::Protocol::UDP),
    )?;
    socket.set_recv_buffer_size(4 * 1024 * 1024)?;
    socket.set_nonblocking(true)?;
    socket.bind(&bind.into())?;
    eprintln!("WIFI_SOCKET recv_actual={}", socket.recv_buffer_size()?);
    let mut endpoint = quinn::Endpoint::new(
        quinn::EndpointConfig::default(),
        config,
        socket.into(),
        quinn::default_runtime().unwrap(),
    )?;
    let connection = if receive {
        println!("WIFI_READY");
        tokio::time::timeout(Duration::from_secs(30), async {
            endpoint
                .accept()
                .await
                .context("test endpoint closed")?
                .await
                .context("accept TLS")
        })
        .await??
    } else {
        endpoint.set_default_client_config(
            viewflow_transport::build_client_config(&identity)
                .map_err(anyhow::Error::from_boxed)?,
        );
        let peer = std::env::var("VF_WIFI_PEER")?.parse()?;
        tokio::time::timeout(
            Duration::from_secs(15),
            endpoint.connect(peer, "localhost")?,
        )
        .await??
    };
    Ok((endpoint, connection))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "two-host owned content only; run tools/realwifi-test.py"]
async fn owned_wifi_receiver() -> Result<()> {
    let seconds: u64 = std::env::var("VF_WIFI_SECONDS")?.parse()?;
    let (_endpoint, inbound) = wifi_connection(true).await?;
    let mut receiver = accept_warmed_atlas_dispositions(
        &inbound,
        wifi_plan(),
        Instant::now() + Duration::from_secs(15),
        |_| async { Ok(()) },
    )
    .await?;
    let origin = Instant::now();
    let mut previous = origin;
    let mut gaps_ms = Vec::new();
    let mut complete = 0_u64;
    let mut bytes = 0_u64;
    let mut error = None;
    loop {
        match receiver
            .next_frame(|| 1, Instant::now() + Duration::from_millis(100))
            .await
        {
            Ok(frame) => {
                let now = Instant::now();
                gaps_ms.push(now.duration_since(previous).as_secs_f64() * 1000.0);
                previous = now;
                complete += 1;
                bytes += frame.media.color.len() as u64
                    + frame.media.alpha.as_ref().map_or(0, |a| a.len()) as u64;
                receiver
                    .report_disposition(
                        &frame.layout,
                        AtlasFrameDisposition::Committed,
                        Instant::now() + Duration::from_secs(5),
                    )
                    .await?;
            }
            Err(e) if e.is::<AtlasWaitExpired>() => {}
            Err(e) => {
                if inbound.close_reason().is_none() {
                    error = Some(format!("{e:#}"));
                }
                break;
            }
        }
        if origin.elapsed() > Duration::from_secs(seconds + 15) {
            error = Some("receiver watchdog".into());
            break;
        }
    }
    let tail = previous.elapsed().as_secs_f64() * 1000.0;
    let loss = &receiver.loss_telemetry;
    println!(
        "WIFI_RECEIVER {}",
        json!({"complete":complete,"bytes":bytes,"gaps_ms":gaps_ms,
        "tail_until_close_ms":tail,"error":error,"nacks":loss.nack_requests_sent,
        "frames_lost":loss.frames_dropped_to_keyframe,"nack_completed":loss.frames_recovered_by_nack,
        "fec_recovered_frames":loss.frames_recovered_by_fec,"fec_recovered_chunks":loss.chunks_recovered_by_fec,
        "fec_parity_bytes":loss.parity_bytes})
    );
    Ok(())
}

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "two-host owned NVENC only; run tools/realwifi-test.py"]
async fn owned_wifi_sender() -> Result<()> {
    use crate::nvenc_runtime::{AlphaFidelity, AlphaPolicy, Encoder, EncoderConfig, FrameMetadata};
    use crate::quality::{QualityMonitor, SourceQualityMode};
    let mode: SourceQualityMode =
        serde_json::from_str(&format!("\"{}\"", std::env::var("VF_WIFI_MODE")?))?;
    let seconds: u64 = std::env::var("VF_WIFI_SECONDS")?.parse()?;
    let (width, height) = (1920, 1080);
    // CPU-owned RGBA -> existing NVENC ABI. No compositor/GBM/capture setup.
    let mut encoder = Encoder::new_with_bitrate(
        EncoderConfig {
            width,
            height,
            max_access_unit_bytes: 16 * 1024 * 1024,
            max_pending_frames: 2,
            alpha_policy: AlphaPolicy::ColorOnlyExternalAlpha,
            alpha_fidelity: AlphaFidelity::Lossless,
        },
        mode.initial_kbps(),
    )?;
    let alpha =
        viewflow_transport::encode_alpha_rle(width, height, &vec![255; (width * height) as usize])?;
    let mut pixels = vec![0; (width * height * 4) as usize];
    let paint = |pixels: &mut [u8], frame: u64| {
        for (i, p) in pixels.chunks_exact_mut(4).enumerate() {
            let x = i as u32 % width;
            let y = i as u32 / width;
            let scroll = y + frame as u32 * 3;
            let glyph = ((x / 7) * 13 + (scroll / 13) * 7) % 19 < 9 && x % 7 < 4 && scroll % 13 < 9;
            let shade = if glyph { 220 } else { 24 };
            p.copy_from_slice(&[
                shade,
                ((x + frame as u32 * 5) % 256) as u8,
                ((scroll + x / 8) % 256) as u8,
                255,
            ]);
        }
    };
    paint(&mut pixels, 0);
    // Pre-render twice so scrolling uses one bounded memcpy per frame.
    let mut scene = pixels.clone();
    scene.extend_from_slice(&pixels);
    let warm = encoder.submit(
        &pixels,
        FrameMetadata {
            frame_id: 1,
            timestamp_ns: 1,
            geometry_epoch: 1,
        },
        true,
    )?;
    ensure!(warm.len() == 1, "zero-delay NVENC required");
    let frames = std::array::from_fn(|_| crate::atlas_presenter::AtlasWarmupFrame {
        width,
        height,
        color: warm[0].color_annex_b.clone().into(),
        alpha: alpha.clone(),
    });
    let (endpoint, outbound) = wifi_connection(false).await?;
    let mut sender = offer_warmed_atlas_dispositions(
        &outbound,
        wifi_plan(),
        &frames,
        Instant::now() + Duration::from_secs(15),
    )
    .await?;
    let retransmit = sender.retransmit.as_ref().expect("NACK negotiated").clone();
    let monitor = QualityMonitor::start(
        outbound.clone(),
        sender.quality_telemetry.clone(),
        mode,
        60,
        "realwifi",
    );
    let origin = Instant::now();
    let clock = || origin.elapsed().as_nanos() as u64 + 1;
    let end = origin + Duration::from_secs(seconds);
    let initial_bytes = outbound.stats().udp_tx.bytes;
    let mut trace = Vec::new();
    let mut dispositions = Vec::new();
    let mut feedback_ms = Vec::new();
    let mut sent = 0_u64;
    let mut keyframes = 0_u64;
    let mut encoded_bytes = 0_u64;
    let mut error = None;
    let mut next = origin;
    let mut applied = mode.initial_kbps();
    while Instant::now() < end {
        tokio::time::sleep_until(next).await;
        if Instant::now() >= end {
            break;
        }
        let target = monitor.target();
        if mode != SourceQualityMode::HighQuality {
            crate::quality::apply_bitrate(&mut applied, target.kbps, |kbps| {
                Ok(encoder.set_bitrate_kbps(kbps)?)
            })?;
        }
        trace.push((origin.elapsed().as_secs_f64(), target.kbps, target.max_fps));
        let id = sent + 1;
        let force =
            sent == 0 || sender.last_disposition() == Some(AtlasFrameDisposition::ExpiredUnbound);
        if force {
            keyframes += 1;
        }
        let submitted = clock();
        let offset = (id as usize * 3 % height as usize) * width as usize * 4;
        let len = pixels.len();
        pixels.copy_from_slice(&scene[offset..offset + len]);
        let mut encoded = encoder.submit(
            &pixels,
            FrameMetadata {
                frame_id: id + 1,
                timestamp_ns: submitted + 1,
                geometry_epoch: 1,
            },
            force,
        )?;
        ensure!(encoded.len() == 1, "unexpected delayed output");
        let au = encoded.remove(0);
        encoded_bytes += au.color_annex_b.len() as u64 + alpha.len() as u64;
        let manifest = AtlasFrame {
            activity: None,
            patches: None,
            stream_id: Id128(99),
            frame_id: id,
            geometry_epoch: 1,
            config_generation: 1,
            layout_revision: 0,
            width,
            height,
            source_submitted_ns: submitted,
            tiles: vec![],
            color_keyframe: au.color_is_idr,
            alpha_keyframe: true,
            desktop: None,
        };
        let manifest_bytes = au.color_annex_b.len();
        sent += 1;
        let sending_started = Instant::now();
        if let Err(e) = sender
            .send_frame(
                manifest,
                au.color_annex_b.into(),
                alpha.clone(),
                id,
                Instant::now() + Duration::from_secs(5),
            )
            .await
        {
            error = Some(format!("{e:#}"));
            break;
        }
        feedback_ms.push((clock() - submitted) as f64 / 1e6);
        dispositions.push(format!("{:?}", sender.last_disposition()));
        if sending_started.elapsed() > Duration::from_millis(100) {
            eprintln!(
                "NETEM_SLOW at_ms={} frame={id} keyframe={force} color_bytes={} send_ms={} disposition={:?} rtt_us={} cwnd={}",
                origin.elapsed().as_millis(),
                manifest_bytes,
                sending_started.elapsed().as_millis(),
                sender.last_disposition(),
                outbound.stats().path.rtt.as_micros(),
                outbound.stats().path.cwnd
            );
        }
        next =
            (next + Duration::from_secs_f64(1.0 / f64::from(target.max_fps))).max(Instant::now());
    }
    let elapsed = origin.elapsed().as_secs_f64();
    let udp = outbound.stats().udp_tx.bytes - initial_bytes;
    println!(
        "WIFI_SENDER {}",
        json!({"mode":mode,"seconds":elapsed,"sent":sent,
        "keyframe_requests":keyframes.saturating_sub(1),"encoded_bytes":encoded_bytes,
        "udp_tx_mbps":udp as f64*8.0/elapsed/1e6,"error":error,
        "submit_to_disposition_ms":feedback_ms,"dispositions":dispositions,
        "repair_datagrams_enqueued":retransmit.enqueued.load(std::sync::atomic::Ordering::Relaxed),
        "target_trace_s_kbps_fps":trace})
    );
    // Allow receiver's last disposition write to complete before normal test close.
    tokio::time::sleep(Duration::from_millis(100)).await;
    outbound.close(0_u32.into(), b"owned wifi measurement finished");
    endpoint.wait_idle().await;
    Ok(())
}
