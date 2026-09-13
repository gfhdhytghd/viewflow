//! Hyprland GPU window source for the portable native-window peer.
use anyhow::{Result, ensure};

const USAGE: &str = "usage: vf-hyprland-windows --window 0xADDRESS --compositor-pid PID [--fps 60] [--performance-mode frame-rate|latency] [--input-native /absolute/viewflow-linux-window-input]\nShares one selected window using the Viewflow capture plugin and NVENC. Omit --input-native for view-only sharing. Launch through vf-window-peer.";

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["--help"] || args == ["-h"] {
        println!("{USAGE}");
        return Ok(());
    }
    ensure!(args.len() >= 4 && args.len() % 2 == 0, USAGE);
    run(args)
}

#[cfg(not(all(target_os = "linux", feature = "native-gpu-nvenc")))]
fn run(_: Vec<String>) -> Result<()> {
    anyhow::bail!("Hyprland window source requires Linux and --features native-gpu-nvenc")
}

#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
fn run(args: Vec<String>) -> Result<()> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?
        .block_on(native::run(args))
}

#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
mod native {
    use super::*;
    use anyhow::Context;
    use std::{
        path::PathBuf,
        process::{Command, Stdio},
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, AtomicU64, Ordering},
        },
        time::Duration,
    };
    use viewflow_hyprland::{HyprIpcClient, resolve_socket_path};
    use viewflowd::{
        atlas_peer::AtlasPerformanceMode,
        gpu_nvenc_runtime::{GpuAtlasIdentity, GpuAtlasTile, GpuEncodeOutcome, GpuEncoder},
        hyprcapture_gpu_socket::{GpuFrame, GpuReceiveOutcome},
        hyprcapture_gpu_wire::{HcgfFrame, InputGeometry},
        hyprcapture_runtime::start_viewflow_gpu_stream_with_mode,
        native_window_blur::BlurRecipe,
        native_window_wire::{self as wire, Frame, Input, Tile},
    };
    type Snapshot = Arc<Mutex<Option<(HcgfFrame, InputGeometry)>>>;

    fn now() -> Result<i64> {
        let time = nix::time::clock_gettime(nix::time::ClockId::CLOCK_MONOTONIC)?;
        Ok(time
            .tv_sec()
            .checked_mul(1_000_000_000)
            .and_then(|n| n.checked_add(time.tv_nsec()))
            .context("monotonic clock overflow")?)
    }
    fn millidips(value: f64) -> Result<i32> {
        let rounded = (value * 1000.0).round();
        ensure!(
            rounded.is_finite() && rounded >= f64::from(i32::MIN) && rounded <= f64::from(i32::MAX),
            "window coordinate out of range"
        );
        Ok(rounded as i32)
    }
    fn translate(mut event: Input, frame: &HcgfFrame, input: &InputGeometry) -> Result<Input> {
        let sx = frame.logical_width / f64::from(frame.crop_width);
        let sy = frame.logical_height / f64::from(frame.crop_height);
        if event.kind == 1 {
            event.a = millidips(
                f64::from(event.a) * sx + if event.c == 1 { 0.0 } else { frame.logical_x },
            )?;
            event.b = millidips(
                f64::from(event.b) * sy + if event.c == 1 { 0.0 } else { frame.logical_y },
            )?;
            event.c = 1;
        } else if event.kind == 6 {
            ensure!(event.c > 0 && event.d > 0, "invalid window resize");
            event.a = millidips(f64::from(event.a) * sx + input.content[0] - frame.logical_x)?;
            event.b = millidips(f64::from(event.b) * sy + input.content[1] - frame.logical_y)?;
            event.c = millidips(f64::from(event.c) * sx - frame.logical_width + input.content[2])?;
            event.d = millidips(f64::from(event.d) * sy - frame.logical_height + input.content[3])?;
        }
        Ok(event)
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn scaled_negative_origin_and_decorations_route_to_content() {
            let frame = HcgfFrame {
                sequence: 1,
                capture_monotonic_ns: 1,
                geometry_epoch: 1,
                logical_x: -510.0,
                logical_y: 90.0,
                logical_width: 420.0,
                logical_height: 320.0,
                image_width: 840,
                image_height: 640,
                fourcc: 0,
                stride: 3360,
                modifier: 0,
                offset: 0,
                crop_x: 0,
                crop_y: 0,
                crop_width: 840,
                crop_height: 640,
                flip_y: false,
                shadow: None,
            };
            let geometry = InputGeometry {
                window: 1,
                surface: 1,
                pid: 1,
                content: [-500.0, 100.0, 400.0, 300.0],
                surface_extent: [400.0, 300.0],
            };
            let pointer = Input {
                id: 1,
                sequence: 9,
                kind: 1,
                a: 40,
                b: 60,
                c: 0,
                d: 0,
            };
            let mapped = translate(pointer, &frame, &geometry).unwrap();
            assert_eq!(
                (mapped.a, mapped.b, mapped.c, mapped.sequence),
                (-490000, 120000, 1, 9)
            );
            let global = translate(
                Input {
                    a: -980,
                    b: 240,
                    c: 1,
                    ..pointer
                },
                &frame,
                &geometry,
            )
            .unwrap();
            assert_eq!((global.a, global.b), (mapped.a, mapped.b));
            // A title-bar drag moves the source while video is in flight.
            // Desktop pointer coordinates must not inherit that displacement.
            let mut later_frame = frame.clone();
            later_frame.logical_x += 170.0;
            later_frame.logical_y -= 90.0;
            let later = translate(
                Input { a: -980, b: 240, c: 1, ..pointer },
                &later_frame,
                &geometry,
            ).unwrap();
            assert_eq!((later.a, later.b), (global.a, global.b));
            // Precise scrolling is not a position: preserve milli-points,
            // axis, source, and stop across Retina/source geometry conversion.
            let scroll = translate(
                Input { kind: 3, a: 1, b: -1250, c: 1, d: 1, ..pointer },
                &later_frame, &geometry,
            ).unwrap();
            assert_eq!((scroll.a, scroll.b, scroll.c, scroll.d), (1, -1250, 1, 1));
            let moved = translate(
                Input {
                    kind: 6,
                    a: -800,
                    b: 200,
                    c: 1040,
                    d: 840,
                    ..pointer
                },
                &frame,
                &geometry,
            )
            .unwrap();
            assert_eq!(
                (moved.a, moved.b, moved.c, moved.d),
                (-390000, 110000, 500000, 400000)
            );
        }
    }
    struct InputHelper {
        child: std::process::Child,
        send: Option<std::process::ChildStdin>,
        receive: std::process::ChildStdout,
    }
    impl InputHelper {
        fn start(path: &std::path::Path, address: &str, pid: u32, stable: &str) -> Result<Self> {
            let mut child = Command::new(path)
                .args([address, &pid.to_string(), stable])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .spawn()?;
            Ok(Self {
                send: child.stdin.take(),
                receive: child.stdout.take().context("native input stdout")?,
                child,
            })
        }
        fn apply(&mut self, event: Input) -> Result<Input> {
            wire::write_record(
                self.send.as_mut().context("native input stdin")?,
                &event.encode(),
            )?;
            let receipt =
                wire::read_input(&mut self.receive)?.context("native input helper stopped")?;
            ensure!(
                receipt.sequence == event.sequence && receipt.id == event.id,
                "native input receipt mismatch"
            );
            Ok(receipt)
        }
    }
    impl Drop for InputHelper {
        fn drop(&mut self) {
            self.send.take(); // EOF releases the helper's virtual keys/buttons.
            let deadline = std::time::Instant::now() + Duration::from_secs(6);
            loop {
                if !matches!(self.child.try_wait(), Ok(None)) {
                    break;
                }
                if std::time::Instant::now() >= deadline {
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
    fn input_worker(
        native: Option<PathBuf>,
        address: String,
        pid: u32,
        stable: String,
        snapshot: Snapshot,
        stopped: Arc<AtomicBool>,
        ack: Arc<AtomicU64>,
    ) {
        std::thread::spawn(move || {
            let mut helper: Option<InputHelper> = None;
            let mut retry = std::time::Instant::now();
            let result = (|| -> Result<()> {
                let mut sequence = 0;
                let mut stdin = std::io::stdin().lock();
                while let Some(event) = wire::read_input(&mut stdin)? {
                    if event.kind == 3 { eprintln!("window-scroll transport seq={} id={} axis={} amount={} precise={} stop={}",event.sequence,event.id,event.a,event.b,event.c,event.d); }
                    if event.sequence <= sequence {
                        eprintln!("window input sequence regression rejected");
                        continue;
                    }
                    sequence = event.sequence;
                    if event.id != 1 && !(event.id == 0 && event.kind == 8) {
                        continue;
                    }
                    let mut translated = event;
                    if event.kind != 8 {
                        let current = snapshot.lock().unwrap().clone();
                        let Some((frame, input)) = current else {
                            continue;
                        };
                        match translate(event, &frame, &input) {
                            Ok(value) => translated = value,
                            Err(error) => {
                                eprintln!("window input coordinates rejected: {error:#}");
                                continue;
                            }
                        }
                    }
                    if let Some(path) = &native {
                        if helper.is_none() && std::time::Instant::now() >= retry {
                            match InputHelper::start(path, &address, pid, &stable) {
                                Ok(value) => helper = Some(value),
                                Err(error) => {
                                    eprintln!(
                                        "window input helper unavailable; media retained: {error:#}"
                                    );
                                    retry = std::time::Instant::now() + Duration::from_secs(1);
                                }
                            }
                        }
                        if let Some(active) = &mut helper {
                            match active.apply(translated) {
                                Ok(receipt) if receipt.d == 0 => (),
                                Ok(_) => eprintln!(
                                    "Hyprland window input operation unavailable, media retained"
                                ),
                                Err(error) => {
                                    eprintln!(
                                        "window input helper recovering; media retained: {error:#}"
                                    );
                                    helper = None;
                                    retry = std::time::Instant::now() + Duration::from_secs(1);
                                }
                            }
                        }
                    }
                    // Receipt means the geometry request was processed, even
                    // if unavailable. Publish observed native geometry so the
                    // proxy can recover instead of waiting for an impossible ACK.
                    if event.kind == 6 || event.kind == 15 {
                        ack.store(event.sequence, Ordering::Release);
                    }
                }
                Ok(())
            })();
            // Let capture teardown start immediately; releasing a slow input
            // helper must not hold the producer slot until the peer kills us.
            stopped.store(true, Ordering::Release);
            drop(helper);
            if let Err(error) = result {
                eprintln!("Hyprland window input pipe ended: {error:#}");
            }
            stopped.store(true, Ordering::Release);
        });
    }

    pub async fn run(args: Vec<String>) -> Result<()> {
        let mut address = None;
        let mut compositor = None;
        let mut fps = 60u16;
        let mut performance_mode = AtlasPerformanceMode::FrameRate;
        let mut input_native = None;
        for pair in args.chunks_exact(2) {
            match pair[0].as_str() {
                "--window" => address = Some(pair[1].clone()),
                "--compositor-pid" => compositor = Some(pair[1].parse::<u32>()?),
                "--fps" => fps = pair[1].parse()?,
                "--performance-mode" => {
                    performance_mode = match pair[1].as_str() {
                        "frame-rate" => AtlasPerformanceMode::FrameRate,
                        "latency" => AtlasPerformanceMode::Latency,
                        _ => anyhow::bail!("invalid performance mode"),
                    }
                }
                "--input-native" => input_native = Some(PathBuf::from(&pair[1])),
                _ => anyhow::bail!(USAGE),
            }
        }
        let address = address.context("--window required")?;
        let compositor = compositor.context("--compositor-pid required")?;
        ensure!(
            (1..=120).contains(&fps)
                && compositor > 0
                && address.starts_with("0x")
                && u64::from_str_radix(&address[2..], 16).is_ok_and(|n| n > 0)
                && input_native.as_ref().is_none_or(|path| path.is_absolute()),
            "invalid source arguments"
        );
        let native_address = u64::from_str_radix(&address[2..], 16)?;
        let ipc = HyprIpcClient::new(resolve_socket_path()?);
        let clients: Vec<serde_json::Value> = serde_json::from_str(&ipc.request("j/clients")?)?;
        let client = clients
            .iter()
            .find(|c| c["address"].as_str() == Some(address.as_str()))
            .context("selected window no longer exists")?;
        let pid = u32::try_from(client["pid"].as_u64().context("window PID missing")?)?;
        let stable = client["stableId"]
            .as_str()
            .context("window stable identity missing")?
            .to_string();
        let title = client["title"]
            .as_str()
            .unwrap_or("Shared window")
            .chars()
            .take(512)
            .collect::<String>();
        let snapshot: Snapshot = Arc::new(Mutex::new(None));
        let stopped = Arc::new(AtomicBool::new(false));
        let blur: Arc<Mutex<Option<BlurRecipe>>> = Arc::new(Mutex::new(None));
        let fullscreen = Arc::new(AtomicBool::new(false));
        let raised = Arc::new(AtomicBool::new(false));
        {
            let raised = raised.clone();
            let fullscreen = fullscreen.clone();
            let address = address.clone();
            let target = blur.clone();
            let stopped = stopped.clone();
            let ipc = ipc.clone().with_timeout(Duration::from_millis(150));
            std::thread::spawn(move || {
                let mut failed = false;
                while !stopped.load(Ordering::Acquire) {
                    if let Ok(text) = ipc.request("j/clients") {
                        if let Ok(clients) = serde_json::from_str::<Vec<serde_json::Value>>(&text) {
                            if let Some(window) = clients.iter().find(|w| w["address"].as_str()==Some(address.as_str())) {
                                raised.store(window["focusHistoryID"].as_u64()==Some(0),Ordering::Release);
                                fullscreen.store(window["fullscreen"].as_u64()==Some(2) || window["fullscreenClient"].as_u64()==Some(2),Ordering::Release);
                            }
                        }
                    }
                    match BlurRecipe::read(&ipc) {
                        Ok(recipe) => {
                            let mut current = target.lock().unwrap();
                            if *current != Some(recipe) {
                                eprintln!("window-source-blur {recipe:?}");
                                *current = Some(recipe);
                            }
                            failed = false;
                        }
                        Err(error) => {
                            if !failed {
                                eprintln!(
                                    "window source blur query recovering, last recipe retained: {error}"
                                );
                            }
                            failed = true;
                        }
                    }
                    std::thread::sleep(Duration::from_millis(500));
                }
            });
        }
        let ack = Arc::new(AtomicU64::new(0));
        input_worker(
            input_native,
            address.clone(),
            pid,
            stable,
            snapshot.clone(),
            stopped.clone(),
            ack.clone(),
        );
        let stream = start_viewflow_gpu_stream_with_mode(
            &address,
            fps,
            compositor,
            Duration::from_secs(10),
            performance_mode,
        )
        .await?;
        let (mut receiver, control) = stream.into_parts();
        let mut encoder: Option<GpuEncoder> = None;
        let mut extent = (0, 0);
        let mut force_idr = true;
        let mut outstanding: Option<Box<GpuFrame>> = None;
        let binding_path = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .map(|root| {
                root.join("viewflow/macos-windows/bindings")
                    .join(format!("{}.json", std::process::id()))
            });
        let mut published_binding = None;
        let result = async {
            while !stopped.load(Ordering::Acquire) {
                let frame = match receiver.recv_frame()? {
                    GpuReceiveOutcome::WouldBlock => {
                        tokio::time::sleep(Duration::from_millis(2)).await;
                        continue;
                    }
                    GpuReceiveOutcome::Disconnected => break,
                    GpuReceiveOutcome::Frame(frame) => frame,
                };
                outstanding = Some(frame);
                let frame = outstanding.as_ref().unwrap();
                let metadata = frame.metadata();
                let input = frame
                    .input_geometry()
                    .context("capture omitted native window binding")?;
                ensure!(
                    input.window == native_address && input.pid == u64::from(pid),
                    "capture target identity changed"
                );
                if published_binding!=Some((input.window,input.surface,input.pid)) {
                    if let Some(path)=&binding_path {
                        let value=serde_json::json!({"producer_pid":std::process::id(),"window":input.window,"surface":input.surface,"pid":input.pid});
                        if let Some(parent)=path.parent() {let _=std::fs::create_dir_all(parent);}
                        let temporary=path.with_extension("next");
                        if std::fs::write(&temporary,value.to_string()).is_ok() {let _=std::fs::rename(temporary,path);}
                    }
                    published_binding=Some((input.window,input.surface,input.pid));
                }
                let wanted = (
                    metadata.crop_width.div_ceil(2) * 2,
                    metadata.crop_height.div_ceil(2) * 2,
                );
                if wanted.0 > 8192
                    || wanted.1 > 8192
                    || u64::from(wanted.0) * u64::from(wanted.1) > 32 * 1024 * 1024
                {
                    receiver.release_after_source_reads(frame)?;
                    outstanding = None;
                    force_idr = true;
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                }
                if extent != wanted {
                    // Allocate between capture leases; decoder receives a new
                    // in-band IDR after resize, without changing the connection.
                    receiver.release_after_source_reads(frame)?;
                    outstanding = None;
                    encoder = Some(GpuEncoder::new(
                        wanted.0,
                        wanted.1,
                        32 * 1024 * 1024,
                        wanted.0 as usize * wanted.1 as usize,
                    )?);
                    extent = wanted;
                    force_idr = true;
                    continue;
                }
                let start = now()?;
                // This is an operation watchdog for GPU completion, independent
                // of the 33 ms performance metric and of source-frame age.
                let watchdog = start
                    .checked_add(5_000_000_000)
                    .context("GPU watchdog overflow")?;
                let outcome = encoder.as_mut().unwrap().encode_atlas_recoverable(
                    &[GpuAtlasTile {
                        frame,
                        x: 0,
                        y: 0,
                        deadline_monotonic_ns: watchdog,
                    }],
                    GpuAtlasIdentity {
                        frame_id: metadata.sequence,
                        capture_monotonic_ns: metadata.capture_monotonic_ns,
                        geometry_epoch: metadata.geometry_epoch,
                    },
                    force_idr,
                    watchdog,
                )?;
                let captured = metadata.clone();
                receiver.release_after_source_reads(frame)?;
                outstanding = None;
                let encoded_at = now()?;
                match outcome {
                    GpuEncodeOutcome::Encoded(encoded) => {
                        let sx = f64::from(captured.crop_width) / captured.logical_width;
                        let sy = f64::from(captured.crop_height) / captured.logical_height;
                        let tile = Tile {
                            flags: (if fullscreen.load(Ordering::Acquire) {32} else {0}) | (if raised.load(Ordering::Acquire) {64} else {0}),
                            id: 1,
                            x: (captured.logical_x * sx).round() as i32,
                            y: (captured.logical_y * sy).round() as i32,
                            width: captured.crop_width,
                            height: captured.crop_height,
                            atlas_x: 0,
                            atlas_y: 0,
                            title: title.clone(),
                            geometry_ack: ack.load(Ordering::Acquire),
                        };
                        let blur_recipe=*blur.lock().unwrap();
                        let record = Frame {
                            width: extent.0,
                            height: extent.1,
                            pts: encoded.capture_monotonic_ns / 1000,
                            keyframe: encoded.idr,
                            tiles: &[tile],
                            raw_alpha: &encoded.raw_alpha,
                            color: &encoded.color_annex_b,
                        }
                        .encode_with_blur(blur_recipe.as_ref())?;
                        *snapshot.lock().unwrap() = Some((captured, input));
                        let packed_at = now()?;
                        wire::write_record(&mut std::io::stdout().lock(), &record)?;
                        let sent_at = now()?;
                        if sent_at.saturating_sub(start) > 100_000_000 {
                            eprintln!("window-source-slow encode-ms={:.1} pack-ms={:.1} pipe-ms={:.1} bytes={}",
                                encoded_at.saturating_sub(start) as f64 / 1e6,
                                packed_at.saturating_sub(encoded_at) as f64 / 1e6,
                                sent_at.saturating_sub(packed_at) as f64 / 1e6, record.len());
                        }
                        force_idr = false;
                    }
                    GpuEncodeOutcome::ExpiredClean | GpuEncodeOutcome::ExpiredAfterSubmission => {
                        force_idr = true;
                        eprintln!("window GPU operation recovered; capture/session retained");
                    }
                    GpuEncodeOutcome::NeedsCanvas { .. } => {
                        force_idr = true;
                        extent = (0, 0);
                    }
                }
                if now()?.saturating_sub(start) > 33_000_000 {
                    eprintln!("window encode/send performance target missed; stream retained");
                }
            }
            Ok::<(), anyhow::Error>(())
        }
        .await;
        if let Some(path) = binding_path {
            let _ = std::fs::remove_file(path);
        }
        *snapshot.lock().unwrap() = None;
        // GPU failures retain the outstanding lease until the owned producer is
        // stopped. Never manufacture a release receipt for uncertain GPU reads.
        let cleanup = control.stop_stream(Duration::from_secs(5)).await;
        drop(outstanding);
        drop(receiver);
        drop(encoder);
        result.and(cleanup)
    }
}
