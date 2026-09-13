//! Audio-only paired transport. Native helpers read/write stereo 48 kHz s16le.
//! Independent from window/input sessions so audio recovery cannot close them.
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use std::{net::SocketAddr, path::PathBuf, process::Stdio, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::Command,
};
use viewflow_transport::{PeerIdentity, build_client_config, build_server_config};
use viewflowd::audio_wire::{self, PCM_BYTES};

struct AudioLogger;
impl log::Log for AudioLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        metadata.level() <= log::Level::Warn
    }
    fn log(&self, record: &log::Record<'_>) {
        if self.enabled(record.metadata()) {
            eprintln!("audio transport {}: {}", record.target(), record.args());
        }
    }
    fn flush(&self) {}
}
static LOGGER: AudioLogger = AudioLogger;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Native {
    program: PathBuf,
    #[serde(default)]
    args: Vec<String>,
}
impl Native {
    fn command(&self) -> Command {
        let mut command = Command::new(&self.program);
        command
            .args(&self.args)
            .kill_on_drop(false)
            .stderr(Stdio::inherit());
        command
    }
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    bind: SocketAddr,
    remote: Option<SocketAddr>,
    server_name: Option<String>,
    certificate: PathBuf,
    private_key: PathBuf,
    certificate_authority: PathBuf,
    /// Source and receiver use separate configurations. A designated receiver
    /// accepts concurrent sources and its native audio server mixes playback.
    capture: Option<Native>,
    playback: Option<Native>,
}
impl Config {
    fn validate(&self) -> Result<()> {
        ensure!(
            self.capture.is_some() != self.playback.is_some(),
            "select capture or playback"
        );
        ensure!(
            self.remote.is_some() == self.capture.is_some(),
            "capture connects to the playback listener"
        );
        ensure!(
            self.remote.is_none() || self.server_name.as_ref().is_some_and(|n| !n.is_empty()),
            "missing server_name"
        );
        for native in self.capture.iter().chain(self.playback.iter()) {
            ensure!(
                native.program.is_absolute(),
                "native audio program must be absolute"
            );
            ensure!(
                native.args.len() <= 128
                    && native
                        .args
                        .iter()
                        .all(|a| a.len() <= 4096 && !a.contains('\0')),
                "invalid audio helper arguments"
            );
        }
        Ok(())
    }
}

async fn capture(connection: &quinn::Connection, native: &Native) -> Result<()> {
    ensure!(
        connection
            .max_datagram_size()
            .is_some_and(|n| n >= audio_wire::PACKET_BYTES),
        "peer does not support PCM datagrams"
    );
    // Wait until the remote playback process has started before native capture
    // moves/mutes local streams. Native EOF cleanup restores source playback.
    let mut ready = connection.accept_uni().await?;
    ensure!(
        ready.read_to_end(16).await? == b"audio-ready-v1",
        "invalid playback readiness"
    );
    let mut child = native
        .command()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    let mut output = child.stdout.take().context("capture stdout")?;
    let lifetime = child.stdin.take().context("capture lifetime pipe")?;
    let result = async {
        let mut pcm = [0; PCM_BYTES];
        let mut sequence = 0u64;
        let mut peak = 0u16;
        eprintln!("audio capture connected: {}", connection.remote_address());
        loop {
            tokio::select! {
                result = output.read_exact(&mut pcm) => { result.context("audio capture ended")?; },
                reason = connection.closed() => anyhow::bail!("audio disconnected: {reason}"),
            }
            // Keep capture progressing when the bounded send queue is full.
            // Avoid quinn-proto 0.11.17's drop-oldest accounting bug. A
            // canceled blocked send never enqueues a partial datagram.
            if let Ok(result) = tokio::time::timeout(
                Duration::ZERO,
                connection.send_datagram_wait(audio_wire::encode(1, sequence, &pcm)?.into()),
            )
            .await
            {
                result?;
            }
            peak = peak.max(
                pcm.chunks_exact(2)
                    .map(|v| i16::from_le_bytes([v[0], v[1]]).unsigned_abs())
                    .max()
                    .unwrap_or(0),
            );
            sequence = sequence.wrapping_add(1);
            if sequence % 1000 == 0 {
                eprintln!(
                    "audio tx peer={} blocks={} peak={}",
                    connection.remote_address(),
                    sequence,
                    peak
                );
                peak = 0;
            }
        }
    }
    .await;
    drop(lifetime);
    drop(output);
    if tokio::time::timeout(Duration::from_secs(5), child.wait())
        .await
        .is_err()
    {
        child.kill().await?;
    }
    result
}

async fn playback(connection: &quinn::Connection, native: &Native) -> Result<()> {
    let mut child = native
        .command()
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()?;
    let mut input = child.stdin.take().context("playback stdin")?;
    let mut ready = connection.open_uni().await?;
    ready.write_all(b"audio-ready-v1").await?;
    ready.finish()?;
    let mut queue = std::collections::BTreeMap::new();
    let mut next = None;
    let mut newest = None;
    let mut tick = tokio::time::interval(Duration::from_millis(5));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let silence = [0; PCM_BYTES];
    let mut received = 0u64;
    let mut peak = 0u16;
    eprintln!("audio playback connected: {}", connection.remote_address());
    let result = async {
        loop {
            tokio::select! {
                packet = connection.read_datagram() => {
                    let packet = packet?;
                    let (generation, sequence, pcm) = audio_wire::decode(&packet)?;
                    ensure!(generation == 1, "unsupported audio generation");
                    received += 1;
                    peak = peak.max(pcm.chunks_exact(2).map(|v| i16::from_le_bytes([v[0], v[1]]).unsigned_abs()).max().unwrap_or(0));
                    if received % 1000 == 0 {
                        eprintln!("audio rx peer={} blocks={} peak={}", connection.remote_address(), received, peak);
                        peak = 0;
                    }
                    if next.is_some_and(|n| sequence < n) {
                        if queue.is_empty() && newest.is_none_or(|n| sequence > n) {
                            next = Some(sequence);
                            tick.reset_at(tokio::time::Instant::now() + Duration::from_millis(15));
                        } else { continue; }
                    }
                    newest = Some(newest.map_or(sequence, |n: u64| n.max(sequence)));
                    queue.insert(sequence, pcm.to_vec());
                    if next.is_none() {
                        next = Some(sequence);
                        tick.reset_at(tokio::time::Instant::now() + Duration::from_millis(15));
                    }
                    // Resynchronize locally after congestion or clock drift.
                    // The connection and other media streams remain intact.
                    if queue.len() > 8 {
                        while queue.len() > 3 { queue.pop_first(); }
                        next = queue.first_key_value().map(|(&seq, _)| seq);
                    }
                }
                _ = tick.tick(), if next.is_some() => {
                    let sequence = next.unwrap();
                    let pcm = queue.remove(&sequence);
                    tokio::time::timeout(Duration::from_secs(2),
                        input.write_all(pcm.as_deref().unwrap_or(&silence))).await
                        .context("audio output stalled")??;
                    next = Some(sequence.wrapping_add(1));
                }
            }
        }
    }
    .await;
    drop(input);
    if tokio::time::timeout(Duration::from_secs(5), child.wait())
        .await
        .is_err()
    {
        child.kill().await?;
    }
    result
}

async fn run(config: &Config, endpoint: &quinn::Endpoint) -> Result<()> {
    if let Some(native) = &config.capture {
        loop {
            let connecting = endpoint.connect(
                config.remote.unwrap(),
                config.server_name.as_deref().unwrap(),
            )?;
            match connecting.await {
                Ok(connection) => {
                    let result = capture(&connection, native).await;
                    connection.close(0u32.into(), b"audio capture restarting");
                    if let Err(error) = result {
                        eprintln!("audio recovering: {error:#}");
                    }
                }
                Err(error) => eprintln!("audio reconnecting: {error}"),
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }
    let mut sessions = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            incoming = endpoint.accept() => {
                let Some(incoming) = incoming else { break; };
                let native = config.playback.clone().unwrap();
                sessions.spawn(async move {
                    let connection = incoming.await?;
                    let result = playback(&connection, &native).await;
                    connection.close(0u32.into(), b"audio playback ended");
                    result
                });
            }
            Some(result) = sessions.join_next(), if !sessions.is_empty() => {
                match result {
                    Ok(Ok(())) => (),
                    Ok(Err(error)) => eprintln!("audio receiver recovering: {error:#}"),
                    Err(error) => eprintln!("audio receiver task: {error}"),
                }
            }
        }
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = log::set_logger(&LOGGER);
    log::set_max_level(log::LevelFilter::Warn);
    let args: Vec<_> = std::env::args().skip(1).collect();
    let (validate, path) = match args.as_slice() {
        [flag, path] if flag == "--config" => (false, path),
        [mode, flag, path] if mode == "validate" && flag == "--config" => (true, path),
        _ => anyhow::bail!("usage: vf-audio-peer [validate] --config <JSON>"),
    };
    let config: Config = serde_json::from_slice(&std::fs::read(path)?)?;
    config.validate()?;
    if validate {
        println!("audio-peer-config-valid");
        return Ok(());
    }
    let identity = PeerIdentity::from_pem(
        &std::fs::read(&config.certificate)?,
        &std::fs::read(&config.private_key)?,
        &std::fs::read(&config.certificate_authority)?,
    )
    .map_err(|e| anyhow::anyhow!("audio TLS: {e}"))?;
    let mut transport = quinn::TransportConfig::default();
    transport.keep_alive_interval(Some(Duration::from_secs(5)));
    transport.datagram_receive_buffer_size(Some(audio_wire::PACKET_BYTES * 8));
    transport.datagram_send_buffer_size(audio_wire::PACKET_BYTES * 4);
    let transport = Arc::new(transport);
    let mut endpoint = if config.capture.is_some() {
        quinn::Endpoint::client(config.bind)?
    } else {
        let mut server =
            build_server_config(&identity).map_err(|e| anyhow::anyhow!("audio server: {e}"))?;
        server.transport_config(transport.clone());
        quinn::Endpoint::server(server, config.bind)?
    };
    let mut client =
        build_client_config(&identity).map_err(|e| anyhow::anyhow!("audio client: {e}"))?;
    client.transport_config(transport);
    endpoint.set_default_client_config(client);
    eprintln!("audio endpoint listening={} remote={:?}", endpoint.local_addr()?, config.remote);
    let result = tokio::select! {
        result = run(&config, &endpoint) => result,
        result = tokio::signal::ctrl_c() => result.map_err(Into::into),
    };
    endpoint.close(0u32.into(), b"audio peer stopped");
    endpoint.wait_idle().await;
    result
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[tokio::test]
    async fn paired_pcm_transport_and_capture_eof_cleanup() {
        let root = tempfile::tempdir().unwrap();
        let script = root.path().join("native.py");
        std::fs::write(
            &script,
            r#"
import os, sys, threading, time
from pathlib import Path
role, root = sys.argv[1:]
root = Path(root)
if role == 'capture':
    def lifetime():
        sys.stdin.buffer.read()
        (root / 'restored').write_text('eof')
        os._exit(0)
    threading.Thread(target=lifetime, daemon=True).start()
    while True:
        try:
            sys.stdout.buffer.write(bytes([37]) * 960)
            sys.stdout.buffer.flush()
        except BrokenPipeError:
            time.sleep(.01)
            continue
        time.sleep(.005)
else:
    block = bytearray()
    while True:
        data = os.read(0, 960 - len(block))
        if not data: break
        block.extend(data)
        if len(block) == 960:
            if block == bytes([37]) * 960: (root / 'played').write_text('pcm')
            block.clear()
"#,
        )
        .unwrap();
        let native = |role: &str| Native {
            program: "/usr/bin/python3".into(),
            args: vec![
                script.to_string_lossy().into_owned(),
                role.into(),
                root.path().to_string_lossy().into_owned(),
            ],
        };
        let identity = PeerIdentity::from_pem(
            include_bytes!("../../../viewflow-transport/tests/fixtures/peer.pem"),
            include_bytes!("../../../viewflow-transport/tests/fixtures/peer.key"),
            include_bytes!("../../../viewflow-transport/tests/fixtures/ca.pem"),
        )
        .unwrap();
        let server = quinn::Endpoint::server(
            build_server_config(&identity).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(build_client_config(&identity).unwrap());
        let (sender, receiver) = tokio::join!(
            client
                .connect(server.local_addr().unwrap(), "localhost")
                .unwrap(),
            async { server.accept().await.unwrap().await }
        );
        let sender = sender.unwrap();
        let receiver = receiver.unwrap();
        let source_native = native("capture");
        let receiver_native = native("playback");
        let copy = sender.clone();
        let source = tokio::spawn(async move { capture(&copy, &source_native).await });
        let sink = tokio::spawn(async move { playback(&receiver, &receiver_native).await });
        tokio::time::timeout(Duration::from_secs(5), async {
            while !root.path().join("played").exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        sender.close(0u32.into(), b"test disconnect");
        tokio::time::timeout(Duration::from_secs(5), source)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err();
        tokio::time::timeout(Duration::from_secs(5), sink)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err();
        assert_eq!(
            std::fs::read_to_string(root.path().join("restored")).unwrap(),
            "eof"
        );
    }
}
