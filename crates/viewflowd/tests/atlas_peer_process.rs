#[test]
fn peer_help_and_invalid_arguments_do_not_require_a_native_backend() {
    let executable = env!("CARGO_BIN_EXE_vf-media-peer");
    let help = std::process::Command::new(executable)
        .arg("--help")
        .output()
        .unwrap();
    assert!(help.status.success());
    let help = String::from_utf8(help.stdout).unwrap();
    assert!(help.contains("receive --config"));
    assert!(help.contains("send --config"));
    let invalid = std::process::Command::new(executable)
        .args(["receive", "--unknown"])
        .output()
        .unwrap();
    assert!(!invalid.status.success());
}

#[test]
fn source_rejects_invalid_configuration_before_backend_startup() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("send.json");
    std::fs::write(&path, b"{\"input_enabled\":true}").unwrap();
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_vf-media-peer"))
        .arg("send")
        .arg("--config")
        .arg(path)
        .output()
        .unwrap();
    assert!(!output.status.success());
    let error = String::from_utf8(output.stderr).unwrap();
    assert!(error.contains("parse atlas source config"));
    assert!(!error.contains("atlas-source-active"));
}

#[cfg(windows)]
#[tokio::test]
#[ignore = "requires interactive Windows session, native presenter and explicit H264 fixtures"]
async fn receiver_process_accepts_real_native_warmup_and_retires_on_disconnect() {
    use std::{path::PathBuf, process::Stdio, time::Duration};
    use tokio::{
        io::{AsyncBufReadExt, AsyncReadExt, BufReader},
        time::{Instant, timeout},
    };
    use viewflowd::{
        atlas_clock::AtlasClockClient, atlas_peer::AtlasReceiverConfig,
        atlas_presenter::AtlasWarmupFrame, atlas_session::offer_warmed_atlas,
    };
    let root = tempfile::tempdir().unwrap();
    let certificate = include_bytes!("../../viewflow-transport/tests/fixtures/peer.pem");
    let key = include_bytes!("../../viewflow-transport/tests/fixtures/peer.key");
    let ca = include_bytes!("../../viewflow-transport/tests/fixtures/ca.pem");
    std::fs::write(root.path().join("peer.pem"), certificate).unwrap();
    std::fs::write(root.path().join("peer.key"), key).unwrap();
    std::fs::write(root.path().join("ca.pem"), ca).unwrap();
    let config = AtlasReceiverConfig {
        reverse: None,
        color_codec: Default::default(),
        desktop: None,
        pointer: None,
        disposition_recovery: false,
        input_recovery: false,
        bind: "127.0.0.1:0".parse().unwrap(),
        expected_peer_ip: "127.0.0.1".parse().unwrap(),
        certificate: root.path().join("peer.pem"),
        private_key: root.path().join("peer.key"),
        certificate_authority: root.path().join("ca.pem"),
        native_presenter: PathBuf::from(std::env::var_os("VIEWFLOW_ATLAS_NATIVE_EXE").unwrap()),
        stream_id: format!("{:032x}", 99),
        geometry_epoch: 1,
        config_generation: 1,
        width: 1626,
        height: 1240,
        max_tiles: 4,
        max_encoded_bytes: 8 << 20,
        max_decoded_bytes: 64 << 20,
        refresh_hz: 60,
        startup_timeout_ms: 10000,
        media_idle_timeout_ms: 3000,
        clock_silence_timeout_ms: 3000,
    };
    let plan = config.plan().unwrap();
    let config_path = root.path().join("receive.json");
    std::fs::write(&config_path, serde_json::to_vec(&config).unwrap()).unwrap();
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_vf-media-peer"))
        .args([
            std::ffi::OsStr::new("receive"),
            std::ffi::OsStr::new("--config"),
            config_path.as_os_str(),
        ])
        .creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let mut first = String::new();
    timeout(Duration::from_secs(10), stderr.read_line(&mut first))
        .await
        .unwrap()
        .unwrap();
    let address: std::net::SocketAddr = first
        .strip_prefix("atlas-peer-listening address=")
        .unwrap()
        .split_whitespace()
        .next()
        .unwrap()
        .parse()
        .unwrap();
    // Drain native diagnostics concurrently; a full stderr pipe must not stall
    // the very startup that this process test is trying to observe.
    let diagnostics = tokio::spawn(async move {
        let mut remaining = String::new();
        stderr
            .take((1 << 20) + 1)
            .read_to_string(&mut remaining)
            .await
            .unwrap();
        assert!(remaining.len() <= 1 << 20, "native diagnostic byte limit");
        remaining
    });
    let identity = viewflow_transport::PeerIdentity::from_pem(certificate, key, ca).unwrap();
    let mut endpoint = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
    endpoint.set_default_client_config(viewflow_transport::build_client_config(&identity).unwrap());
    let connection = timeout(
        Duration::from_secs(5),
        endpoint.connect(address, "localhost").unwrap(),
    )
    .await
    .unwrap()
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut clock = AtlasClockClient::open(
        &connection,
        plan.policy.max_age_ns / 4,
        Duration::from_secs(1),
        deadline,
    )
    .await
    .unwrap();
    let origin = Instant::now();
    let now = || u64::try_from(origin.elapsed().as_nanos()).map_err(anyhow::Error::from);
    let mapping = clock.calibrate(now, deadline).await.unwrap();
    assert!(mapping.map_source_ns(&connection, now().unwrap()).unwrap() > 0);
    let fixtures = PathBuf::from(std::env::var_os("VIEWFLOW_ATLAS_WARMUP_FIXTURES").unwrap());
    let alpha = viewflow_transport::encode_alpha_rle(1626, 1240, &vec![0; 1626 * 1240]).unwrap();
    let frames = std::array::from_fn(|i| AtlasWarmupFrame {
        width: 1626,
        height: 1240,
        color: std::fs::read(fixtures.join(format!("color-{}.h264", i + 1)))
            .unwrap()
            .into(),
        alpha: alpha.clone(),
    });
    // The source must keep the clock stream responsive during native startup,
    // not only after the first live frame. Do not extend the silence bound.
    let (stop_clock, mut clock_stopped) = tokio::sync::oneshot::channel();
    let startup = async {
        let result = offer_warmed_atlas(&connection, plan, &frames, deadline).await;
        let _ = stop_clock.send(());
        result
    };
    let refresh = async {
        loop {
            tokio::select! {
                _ = &mut clock_stopped => return Ok::<(), anyhow::Error>(()),
                () = tokio::time::sleep(Duration::from_millis(250)) => (),
            }
            clock.calibrate(now, deadline).await?;
        }
    };
    let (sender, refreshed) = tokio::join!(startup, refresh);
    connection.close(0_u32.into(), b"warmup fixture finished");
    let status = timeout(Duration::from_secs(10), child.wait())
        .await
        .unwrap()
        .unwrap();
    let mut log = first;
    log.push_str(
        &timeout(Duration::from_secs(2), diagnostics)
            .await
            .unwrap()
            .unwrap(),
    );
    assert!(sender.is_ok(), "startup failed: {:?}\n{log}", sender.err());
    assert!(
        refreshed.is_ok(),
        "clock refresh failed: {refreshed:?}\n{log}"
    );
    // Terminal transport errors remain visible even though cleanup is awaited.
    assert!(!status.success());
    assert!(
        log.contains("atlas-peer-ready input_enabled=false physical_present_receipt=false"),
        "{log}"
    );
    assert!(log.contains("atlas-peer-retirement-finished"), "{log}");
    assert!(!log.contains("cleanup failed"), "{log}");
    eprintln!("{log}");
    eprintln!("receiver process warmup/retirement PASS; no V5 frame or input sent");
}
