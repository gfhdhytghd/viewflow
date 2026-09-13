//! Window-only transport for macOS, Hyprland and Windows native backends.
use anyhow::{Result, ensure};
use serde::Deserialize;
use std::{net::SocketAddr, path::PathBuf, sync::Arc, time::Duration};
use viewflow_transport::{PeerIdentity, build_client_config, build_server_config};
use viewflowd::reverse_bridge::{ReverseBridgeConfig, run_window_bridge, serve_window_bridges};

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

// An empty or unchanged desktop has no media records to keep QUIC alive.
// Keepalive probes preserve that normal idle state while QUIC still detects
// a genuinely unreachable peer using its transport idle timeout.
fn window_transport(interval: Duration) -> quinn::TransportConfig {
    let mut transport = quinn::TransportConfig::default();
    transport.keep_alive_interval(Some(interval));
    transport
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
    let transport = Arc::new(window_transport(Duration::from_secs(5)));
    let mut endpoint = if config.remote.is_some() {
        quinn::Endpoint::client(config.bind)?
    } else {
        let mut server = build_server_config(&identity)
            .map_err(|e| anyhow::anyhow!("window TLS server: {e}"))?;
        server.transport_config(transport.clone());
        quinn::Endpoint::server(server, config.bind)?
    };
    let mut client =
        build_client_config(&identity).map_err(|e| anyhow::anyhow!("window TLS client: {e}"))?;
    client.transport_config(transport);
    endpoint.set_default_client_config(client);
    let (stop, mut stopped) = tokio::sync::watch::channel(false);
    let signal_endpoint = endpoint.clone();
    let signal = tokio::spawn(async move {
        let result = stop_signal().await;
        signal_endpoint.close(0u32.into(), b"window peer stopped");
        let _ = stop.send(true);
        result
    });
    let result = async {
        if config.remote.is_none() {
            return serve_window_bridges(
                &endpoint,
                &config.backend,
                matches!(config.role, Role::Source),
            )
            .await;
        }
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
    #[tokio::test]
    async fn unchanged_desktop_survives_transport_idle_periods() {
        let identity = PeerIdentity::from_pem(
            include_bytes!("../../../viewflow-transport/tests/fixtures/peer.pem"),
            include_bytes!("../../../viewflow-transport/tests/fixtures/peer.key"),
            include_bytes!("../../../viewflow-transport/tests/fixtures/ca.pem"),
        )
        .unwrap();
        let mut transport = window_transport(Duration::from_millis(50));
        transport.max_idle_timeout(Some(Duration::from_millis(200).try_into().unwrap()));
        let transport = Arc::new(transport);
        let mut server_config = build_server_config(&identity).unwrap();
        server_config.transport_config(transport.clone());
        let server =
            quinn::Endpoint::server(server_config, "127.0.0.1:0".parse().unwrap()).unwrap();
        let mut client_config = build_client_config(&identity).unwrap();
        client_config.transport_config(transport);
        let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(client_config);
        let (sent, received) = tokio::join!(
            client
                .connect(server.local_addr().unwrap(), "localhost")
                .unwrap(),
            async { server.accept().await.unwrap().await },
        );
        let (sent, received) = (sent.unwrap(), received.unwrap());
        tokio::time::sleep(Duration::from_millis(700)).await;
        assert!(sent.close_reason().is_none());
        assert!(received.close_reason().is_none());
        let mut stream = sent.open_uni().await.unwrap();
        stream.write_all(b"still idle-safe").await.unwrap();
        stream.finish().unwrap();
        let mut incoming = tokio::time::timeout(Duration::from_secs(2), received.accept_uni())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(incoming.read_to_end(32).await.unwrap(), b"still idle-safe");
        client.close(0u32.into(), b"test complete");
        server.close(0u32.into(), b"test complete");
    }
}
