//! Portable clipboard-only peer for systems without an atlas presenter.
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use std::{net::SocketAddr, path::PathBuf, time::Duration};
use viewflow_transport::{PeerIdentity, build_client_config, build_server_config};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    bind: SocketAddr,
    remote: Option<SocketAddr>,
    server_name: Option<String>,
    certificate: PathBuf,
    private_key: PathBuf,
    certificate_authority: PathBuf,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    ensure!(
        args.len() == 3 && args[1] == "--config",
        "usage: vf-clipboard-peer --config <JSON>"
    );
    let config: Config = serde_json::from_slice(&std::fs::read(&args[2])?)?;
    let identity = PeerIdentity::from_pem(
        &std::fs::read(&config.certificate)?,
        &std::fs::read(&config.private_key)?,
        &std::fs::read(&config.certificate_authority)?,
    )
    .map_err(|error| anyhow::anyhow!("clipboard TLS identity: {error}"))?;
    let source = config.remote.is_some();
    let mut endpoint = if source {
        quinn::Endpoint::client(config.bind)?
    } else {
        quinn::Endpoint::server(
            build_server_config(&identity)
                .map_err(|error| anyhow::anyhow!("clipboard TLS server: {error}"))?,
            config.bind,
        )?
    };
    if source {
        ensure!(
            config
                .server_name
                .as_ref()
                .is_some_and(|name| !name.is_empty()),
            "client requires server_name"
        );
        endpoint.set_default_client_config(
            build_client_config(&identity)
                .map_err(|error| anyhow::anyhow!("clipboard TLS client: {error}"))?,
        );
    }
    let run = async {
        loop {
            let connecting = if let Some(remote) = config.remote {
                endpoint.connect(remote, config.server_name.as_deref().unwrap())?
            } else {
                endpoint
                    .accept()
                    .await
                    .context("clipboard endpoint stopped")?
                    .accept()?
            };
            match connecting.await {
                Ok(connection) => {
                    eprintln!("clipboard peer connected: {}", connection.remote_address());
                    let _sync =
                        viewflowd::clipboard_sync::ClipboardSync::start(&connection, source);
                    connection.closed().await;
                }
                Err(error) => eprintln!("clipboard connection recovering: {error}"),
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    };
    let result = tokio::select! { result = run => result, result = tokio::signal::ctrl_c() => result.map_err(Into::into) };
    endpoint.close(0u32.into(), b"clipboard peer stopped");
    endpoint.wait_idle().await;
    result
}
