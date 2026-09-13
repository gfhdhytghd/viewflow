//! Window-only transport for macOS, Hyprland and Windows native backends.
use anyhow::{Result, ensure};
use serde::Deserialize;
use std::{net::SocketAddr, path::PathBuf, time::Duration};
use viewflow_transport::{PeerIdentity, build_client_config, build_server_config};
use viewflowd::reverse_bridge::{ReverseBridgeConfig, run_window_bridge};

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Role {
    Source,
    Presenter,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    bind: SocketAddr,
    remote: Option<SocketAddr>,
    server_name: Option<String>,
    certificate: PathBuf,
    private_key: PathBuf,
    certificate_authority: PathBuf,
    role: Role,
    backend: ReverseBridgeConfig,
    #[serde(default)]
    diagnostic_duration_ms: Option<u64>,
}

impl Config {
    fn validate(&self) -> Result<()> {
        self.backend.validate()?;
        ensure!(
            self.diagnostic_duration_ms
                .is_none_or(|ms| (1..=120_000).contains(&ms)),
            "invalid diagnostic duration"
        );
        ensure!(
            self.remote.is_none() || self.server_name.as_ref().is_some_and(|s| !s.is_empty()),
            "connecting peer requires server_name"
        );
        for path in [
            &self.certificate,
            &self.private_key,
            &self.certificate_authority,
        ] {
            ensure!(path.is_absolute(), "TLS paths must be absolute");
        }
        Ok(())
    }
}

const USAGE: &str = "usage: vf-window-peer [validate] --config <JSON>\nOne source and one presenter per paired connection; either may listen.";

// Diagnostic peer: authenticate the clock channel on the same paired connection.
fn clock_ns() -> Result<u64> {
    #[cfg(windows)]
    {
        viewflowd::atlas_clock::windows_now_ns()
    }
    #[cfg(target_os = "linux")]
    {
        viewflowd::hyprcapture_stream::monotonic_now_ns()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        anyhow::bail!("this clock diagnostic supports Windows and Linux")
    }
}
async fn clock_channel(connection: quinn::Connection, client: bool) -> Result<()> {
    const MAGIC: &[u8; 8] = b"VFCLK001";
    if client {
        let mut outgoing = connection.open_uni().await?;
        outgoing.write_all(MAGIC).await?;
        let mut incoming = connection.accept_uni().await?;
        let mut magic = [0; 8];
        incoming.read_exact(&mut magic).await?;
        ensure!(&magic == MAGIC, "clock channel version");
        let mut sequence = 0_u64;
        loop {
            sequence += 1;
            let t1 = clock_ns()?;
            let mut request = [0; 16];
            request[..8].copy_from_slice(&sequence.to_le_bytes());
            request[8..].copy_from_slice(&t1.to_le_bytes());
            outgoing.write_all(&request).await?;
            let mut response = [0; 32];
            incoming.read_exact(&mut response).await?;
            let t4 = clock_ns()?;
            let read =
                |offset| u64::from_le_bytes(response[offset..offset + 8].try_into().unwrap());
            ensure!(
                read(0) == sequence && read(8) == t1,
                "clock response identity"
            );
            eprintln!(
                "reverse_clock seq={} t1={} t2={} t3={} t4={}",
                sequence,
                t1,
                read(16),
                read(24),
                t4
            );
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    } else {
        let mut incoming = connection.accept_uni().await?;
        let mut magic = [0; 8];
        incoming.read_exact(&mut magic).await?;
        ensure!(&magic == MAGIC, "clock channel version");
        let mut outgoing = connection.open_uni().await?;
        outgoing.write_all(MAGIC).await?;
        loop {
            let mut request = [0; 16];
            incoming.read_exact(&mut request).await?;
            let t2 = clock_ns()?;
            let mut response = [0; 32];
            response[..16].copy_from_slice(&request);
            response[16..24].copy_from_slice(&t2.to_le_bytes());
            let t3 = clock_ns()?;
            response[24..].copy_from_slice(&t3.to_le_bytes());
            outgoing.write_all(&response).await?;
        }
    }
}

async fn stop_signal() -> std::io::Result<()> {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! {
            result = tokio::signal::ctrl_c() => result,
            _ = terminate.recv() => Ok(()),
        }
    }
    #[cfg(not(unix))]
    tokio::signal::ctrl_c().await
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["--help"] || args == ["-h"] {
        println!("{USAGE}");
        return Ok(());
    }
    let (validate, path) = match args.as_slice() {
        [flag, path] if flag == "--config" => (false, path),
        [mode, flag, path] if mode == "validate" && flag == "--config" => (true, path),
        _ => anyhow::bail!(USAGE),
    };
    let config: Config = serde_json::from_slice(&std::fs::read(path)?)?;
    config.validate()?;
    if validate {
        println!("window-peer-config-valid");
        return Ok(());
    }
    let identity = PeerIdentity::from_pem(
        &std::fs::read(&config.certificate)?,
        &std::fs::read(&config.private_key)?,
        &std::fs::read(&config.certificate_authority)?,
    )
    .map_err(|e| anyhow::anyhow!("window TLS identity: {e}"))?;
    let mut endpoint = if config.remote.is_some() {
        quinn::Endpoint::client(config.bind)?
    } else {
        quinn::Endpoint::server(
            build_server_config(&identity)
                .map_err(|e| anyhow::anyhow!("window TLS server: {e}"))?,
            config.bind,
        )?
    };
    endpoint.set_default_client_config(
        build_client_config(&identity).map_err(|e| anyhow::anyhow!("window TLS client: {e}"))?,
    );
    let (stop, mut stopped) = tokio::sync::watch::channel(false);
    let signal_endpoint = endpoint.clone();
    let diagnostic_duration_ms = config.diagnostic_duration_ms;
    let signal = tokio::spawn(async move {
        let result = if let Some(ms) = diagnostic_duration_ms {
            tokio::select! {result=stop_signal()=>result,()=tokio::time::sleep(Duration::from_millis(ms))=>Ok(())}
        } else {
            stop_signal().await
        };
        signal_endpoint.close(0u32.into(), b"window peer stopped");
        let _ = stop.send(true);
        result
    });
    let result = async {
        loop {
            if *stopped.borrow() {
                break;
            }
            let connecting = if let Some(remote) = config.remote {
                endpoint.connect(remote, config.server_name.as_deref().unwrap())?
            } else {
                let Some(incoming) = endpoint.accept().await else {
                    break;
                };
                incoming.accept()?
            };
            let connected = tokio::select! {
                result = connecting => result,
                _ = stopped.changed() => break,
            };
            match connected {
                Ok(connection) => {
                    eprintln!("window peer connected: {}", connection.remote_address());
                    let clock =
                        tokio::spawn(clock_channel(connection.clone(), config.remote.is_some()));
                    run_window_bridge(
                        &connection,
                        &config.backend,
                        matches!(config.role, Role::Source),
                    )
                    .await?;
                    clock.abort();
                }
                Err(error) => eprintln!("window peer reconnecting: {error}"),
            }
            tokio::select! {
                () = tokio::time::sleep(Duration::from_secs(2)) => (),
                _ = stopped.changed() => break,
            }
        }
        Ok::<(), anyhow::Error>(())
    }
    .await;
    endpoint.close(0u32.into(), b"window peer stopped");
    endpoint.wait_idle().await;
    signal.abort();
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn config(role: &str, remote: &str) -> Config {
        serde_json::from_str(&format!(
            r#"{{"bind":"127.0.0.1:0","role":"{role}",
            "remote":{remote},"certificate":"/tmp/cert","private_key":"/tmp/key",
            "certificate_authority":"/tmp/ca","backend":{{"native":"/tmp/native"}}}}"#
        ))
        .unwrap()
    }
    #[test]
    fn role_does_not_depend_on_listener_or_operating_system() {
        for role in ["source", "presenter"] {
            config(role, "null").validate().unwrap();
            let mut client = config(role, "\"127.0.0.1:44000\"");
            assert!(client.validate().is_err());
            client.server_name = Some("paired-device".into());
            client.validate().unwrap();
        }
    }
}
