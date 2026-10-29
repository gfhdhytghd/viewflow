//! Opt-in hardware/network experiment. Never captures or posts native input.
use super::*;
use crate::atlas_feedback::AtlasFrameDisposition;
use crate::nvenc_runtime::{AlphaFidelity, AlphaPolicy, Encoder, EncoderConfig, FrameMetadata};
use crate::quality::{QualityMonitor, SourceQualityMode};
use serde_json::json;
use std::time::Duration;
use viewflow_protocol::Id128;

fn shape(args: &[&str]) {
    let status = std::process::Command::new("tc")
        .args([
            "qdisc", "replace", "dev", "lo", "root", "netem", "limit", "1000",
        ])
        .args(args)
        .status()
        .expect("tc installed");
    assert!(status.success(), "tc netem failed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "owned RGBA NVENC + private netns only; run tools/weak-network-test.py"]
async fn owned_netem_session() -> Result<()> {
    // The launcher sets this marker only after entering its private namespace.
    ensure!(
        std::env::var("VF_NETEM_PRIVATE").as_deref() == Ok("1"),
        "use netem launcher"
    );
    let scenario = std::env::var("VF_NETEM_SCENARIO")?;
    let mode: SourceQualityMode =
        serde_json::from_str(&format!("\"{}\"", std::env::var("VF_NETEM_MODE")?))?;
    let seconds: u64 = std::env::var("VF_NETEM_SECONDS")?.parse()?;
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
    let (_client, _server, outbound, inbound) = tests::pair().await;
    let mut plan = tests::plan();
    plan.policy.width = width;
    plan.policy.height = height;
    plan.policy.max_encoded_bytes = 16 * 1024 * 1024;
    plan.policy.max_age_ns = 33_333_333;
    plan.policy.max_future_ns = 1_000_000;
    plan.max_decoded_bytes = u64::from(width) * u64::from(height) * 8;
    plan.color.coded_width = width;
    plan.color.coded_height = height;
    plan.alpha.coded_width = width;
    plan.alpha.coded_height = height;
    let deadline = Instant::now() + Duration::from_secs(10);
    let (sender, receiver) = tokio::join!(
        offer_warmed_atlas_dispositions(&outbound, plan, &frames, deadline),
        accept_warmed_atlas_dispositions(&inbound, plan, deadline, |_| async { Ok(()) })
    );
    let mut sender = sender?;
    let mut receiver = receiver?;
    let retransmit = sender.retransmit.as_ref().expect("NACK negotiated").clone();
    let monitor = QualityMonitor::start(
        outbound.clone(),
        sender.quality_telemetry.clone(),
        mode,
        60,
        "netem",
    );
    match scenario.as_str() {
        "clean" | "burst" => shape(&[]),
        "wifi1" => shape(&["delay", "5ms", "3ms", "loss", "1%"]),
        "wifi5" => shape(&["delay", "15ms", "10ms", "loss", "5%"]),
        "cap20" => shape(&["delay", "10ms", "rate", "20mbit"]),
        "cap8" => shape(&["rate", "8mbit", "loss", "2%"]),
        _ => anyhow::bail!("unknown scenario"),
    }
    let origin = Instant::now();
    let clock = || origin.elapsed().as_nanos() as u64 + 1;
    let end = origin + Duration::from_secs(seconds);
    let shaper = (scenario == "burst").then(|| {
        tokio::spawn(async move {
            tokio::time::sleep_until(origin + Duration::from_secs(10)).await;
            shape(&["loss", "30%"]);
            tokio::time::sleep_until(origin + Duration::from_secs(20)).await;
            shape(&[]);
        })
    });
    let (stop_tx, mut stop_rx) = tokio::sync::watch::channel(false);
    let mut observation_stop = stop_rx.clone();
    let observation = async {
        let mut trace = Vec::new();
        let mut timer = tokio::time::interval(Duration::from_millis(200));
        timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                _ = observation_stop.changed() => break,
                () = tokio::time::sleep_until(end + Duration::from_secs(10)) => break,
                _ = timer.tick() => {
                    let target = monitor.target();
                    trace.push((origin.elapsed().as_secs_f64(), target.kbps, target.max_fps));
                }
            }
        }
        trace
    };
    let receiving = async {
        let mut latencies = Vec::new();
        let mut gaps = Vec::new();
        let mut completed_at = origin;
        let mut phases = [0_u64; 3];
        let mut bytes = 0_u64;
        let mut recovery_ms = None;
        let mut error = None;
        loop {
            let result = tokio::select! {
                () = tokio::time::sleep_until(end + Duration::from_secs(10)) => break,
                changed = stop_rx.changed() => { let _ = changed; break; },
                result = receiver.next_frame(clock, Instant::now() + Duration::from_millis(100)) => result,
            };
            match result {
                Ok(frame) => {
                    let now = Instant::now();
                    let elapsed = origin.elapsed().as_secs() as usize;
                    phases[(elapsed / 10).min(2)] += 1;
                    if elapsed >= 20 && recovery_ms.is_none() {
                        recovery_ms =
                            Some((now - origin - Duration::from_secs(20)).as_secs_f64() * 1000.0);
                    }
                    latencies.push(clock().saturating_sub(frame.layout.source_submitted_ns) / 1000);
                    let gap = now.duration_since(completed_at).as_micros() as u64;
                    if gap > 100_000 {
                        gaps.push(gap);
                    }
                    completed_at = now;
                    bytes += frame.media.color.len() as u64
                        + frame.media.alpha.as_ref().map_or(0, |a| a.len()) as u64;
                    if let Err(e) = receiver
                        .report_disposition(
                            &frame.layout,
                            AtlasFrameDisposition::Committed,
                            Instant::now() + Duration::from_secs(5),
                        )
                        .await
                    {
                        error = Some(format!("{e:#}"));
                        break;
                    }
                }
                Err(e) if e.is::<AtlasWaitExpired>() => {}
                Err(e) => {
                    error = Some(format!("{e:#}"));
                    break;
                }
            }
        }
        let tail = completed_at.elapsed().as_micros() as u64;
        if tail > 100_000 {
            gaps.push(tail);
        }
        (
            latencies,
            gaps,
            phases,
            bytes,
            recovery_ms,
            error,
            receiver.loss_telemetry.clone(),
        )
    };
    let initial_bytes = outbound.stats().udp_tx.bytes;
    let sending = async {
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
            let id = sent + 1;
            let force = sent == 0
                || sender.last_disposition() == Some(AtlasFrameDisposition::ExpiredUnbound);
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
            sent += 1;
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
            next = (next + Duration::from_secs_f64(1.0 / f64::from(target.max_fps)))
                .max(Instant::now());
        }
        let elapsed = origin.elapsed().as_secs_f64();
        let _ = stop_tx.send(true);
        Ok::<_, anyhow::Error>((sent, keyframes, encoded_bytes, error, elapsed))
    };
    let (
        sending,
        (mut latencies, gaps, phases, received_bytes, recovery_ms, receive_error, loss),
        trace,
    ) = tokio::join!(sending, receiving, observation);
    if let Some(shaper) = shaper {
        shaper.abort();
    }
    let (sent, keyframes, encoded_bytes, send_error, elapsed) = sending?;
    latencies.sort_unstable();
    let quantile = |p: usize| {
        latencies
            .get(latencies.len().saturating_sub(1) * p / 100)
            .copied()
            .unwrap_or(0) as f64
            / 1000.0
    };
    let result = json!({
        "scenario": scenario, "mode": mode, "seconds": elapsed,
        "survived": send_error.is_none() && receive_error.is_none() && outbound.close_reason().is_none(),
        "send_error": send_error, "receive_error": receive_error,
        "sent": sent, "complete": latencies.len(), "complete_by_10s_phase": phases,
        "first_complete_after_20s_ms": recovery_ms,
        "keyframe_requests": keyframes.saturating_sub(1), "nacks": loss.nack_requests_sent,
        "repair_datagrams_enqueued": retransmit.enqueued.load(std::sync::atomic::Ordering::Relaxed),
        "frames_lost": loss.frames_dropped_to_keyframe, "nack_completed": loss.frames_recovered_by_nack,
        "chunks_lost_lower_bound": loss.chunks_lost,
        "fec_observed_media_chunks": receiver.fec_observed.0, "fec_observed_missing": receiver.fec_observed.1, "fec_failed_media_frames": receiver.fec_observed.2,
        "fec_recovered_frames": loss.frames_recovered_by_fec,
        "fec_recovered_chunks": loss.chunks_recovered_by_fec, "fec_parity_bytes": loss.parity_bytes,
        "fec": std::env::var("VIEWFLOW_FEC").unwrap_or_else(|_| "auto".into()),
        "encoder_mbps": encoded_bytes as f64 * 8.0 / elapsed / 1e6,
        "udp_tx_mbps": (outbound.stats().udp_tx.bytes - initial_bytes) as f64 * 8.0 / elapsed / 1e6,
        "complete_mbps": received_bytes as f64 * 8.0 / elapsed / 1e6,
        "latency_ms": [quantile(50), quantile(95), quantile(99)],
        "stall_ms": gaps.iter().map(|v| *v as f64 / 1000.0).collect::<Vec<_>>(),
        "target_trace_s_kbps_fps": trace,
    });
    println!("NETEM_RESULT {result}");
    Ok(())
}
