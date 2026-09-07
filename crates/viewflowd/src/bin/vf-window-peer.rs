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
}

impl Config {
    fn validate(&self) -> Result<()> {
        self.backend.validate()?;
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
    let signal = tokio::spawn(async move {
        let result = stop_signal().await;
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
                    run_window_bridge(
                        &connection,
                        &config.backend,
                        matches!(config.role, Role::Source),
                    )
                    .await?;
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
