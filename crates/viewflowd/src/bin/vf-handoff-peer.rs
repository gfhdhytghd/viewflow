//! Input-only symmetric desktop link. No video or GPU initialization.
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use viewflow_transport::{PeerIdentity, build_client_config, build_server_config};
use viewflowd::desktop_handoff::*;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    bind: SocketAddr,
    remote: SocketAddr,
    server_name: String,
    device_id: String,
    peer_id: String,
    certificate: PathBuf,
    private_key: PathBuf,
    certificate_authority: PathBuf,
    native: PathBuf,
    local: Rect,
    peer: Rect,
    #[serde(default = "yes")]
    sender: bool,
    #[serde(default = "yes")]
    receiver: bool,
}
fn yes() -> bool {
    true
}
impl Config {
    fn validate(&self) -> Result<()> {
        for id in [&self.device_id, &self.peer_id] {
            ensure!(
                id.len() == 32 && id.bytes().all(|c| c.is_ascii_hexdigit()),
                "invalid device ID"
            );
        }
        ensure!(self.device_id != self.peer_id, "self handoff link");
        ensure!(
            self.local.adjacent(self.peer),
            "handoff requires adjacent displays"
        );
        ensure!(self.native.is_absolute(), "absolute native path required");
        ensure!(!self.server_name.is_empty(), "server_name required");
        Ok(())
    }
}
fn status(message: &str) {
    if let Some(path) = std::env::var_os("VIEWFLOW_HANDOFF_STATUS_FILE") {
        let _ = std::fs::write(path, message);
    }
}
async fn read<R: AsyncRead + Unpin>(r: &mut R) -> Result<Record> {
    ensure!(r.read_u32_le().await? == 40, "invalid handoff frame size");
    let mut b = [0; 40];
    r.read_exact(&mut b).await?;
    Record::decode(&b)
}
async fn write<W: AsyncWrite + Unpin>(w: &mut W, mut r: Record, seq: &mut u64) -> Result<()> {
    *seq += 1;
    r.sequence = *seq;
    w.write_u32_le(40).await?;
    w.write_all(&r.encode()).await?;
    w.flush().await?;
    Ok(())
}
async fn stop() -> Result<()> {
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! {r=tokio::signal::ctrl_c()=>r?,_=term.recv()=>{}}
    }
    #[cfg(not(unix))]
    tokio::signal::ctrl_c().await?;
    Ok(())
}
#[derive(Debug)]
struct Stopped;
impl std::fmt::Display for Stopped {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("handoff stopped")
    }
}
impl std::error::Error for Stopped {}
async fn session(config: &Config, connection: &quinn::Connection, dialer: bool) -> Result<()> {
    let (mut tx, mut rx) = if dialer {
        connection.open_bi().await?
    } else {
        connection.accept_bi().await?
    };
    let mut child = tokio::process::Command::new(&config.native)
        .args(config.local.args())
        .args(config.peer.args())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .context("start desktop handoff native adapter")?;
    let mut native_in = child.stdin.take().context("native stdin")?;
    let mut native_out = child.stdout.take().context("native stdout")?;
    let (mut ns, mut ps) = (0, 0);
    let mut machine = Ownership::new(dialer, false, false);
    let result = async {
        let cap = tokio::time::timeout(Duration::from_secs(10), read(&mut native_out)).await??;
        ensure!(cap.kind == CAPS, "native adapter capability missing");
        let ours = Record::new(
            CAPS,
            1,
            [
                i32::from(config.sender && cap.values[0] != 0),
                i32::from(config.receiver && cap.values[1] != 0),
                1,
                0,
            ],
        );
        write(&mut tx, ours, &mut ps).await?;
        let theirs = read(&mut rx).await?;
        ensure!(
            theirs.kind == CAPS && theirs.values[2] == 1,
            "peer handoff version unavailable"
        );
        machine.can_send = ours.values[0] != 0 && theirs.values[1] != 0;
        machine.can_receive = ours.values[1] != 0 && theirs.values[0] != 0;
        eprintln!(
            "handoff capabilities sender={} receiver={}; other lanes unchanged",
            machine.can_send, machine.can_receive
        );
        write(
            &mut native_in,
            Record::new(
                CAPS,
                0,
                [
                    i32::from(machine.can_send),
                    i32::from(machine.can_receive),
                    1,
                    0,
                ],
            ),
            &mut ns,
        )
        .await?;
        status(&format!(
            "光标接管：发送{}；接收{}",
            if machine.can_send {
                "可用"
            } else {
                "不可用（能力或权限缺失）"
            },
            if machine.can_receive {
                "可用"
            } else {
                "不可用（能力或权限缺失）"
            }
        ));
        let mut seat = None;
        let mut releasing = false;
        let mut last_peer_sequence = theirs.sequence;
        // Keep partially read frames alive across select iterations. Cancelling
        // read_exact on an ordered stream would lose its framing.
        let (events, mut inbox) = tokio::sync::mpsc::channel(256);
        let local_events = events.clone();
        let local_task = tokio::spawn(async move {
            loop {
                let r = read(&mut native_out).await;
                let end = r.is_err();
                if local_events.send((true, r)).await.is_err() || end {
                    break;
                }
            }
        });
        let remote_task = tokio::spawn(async move {
            loop {
                let r = read(&mut rx).await;
                let end = r.is_err();
                if events.send((false, r)).await.is_err() || end {
                    break;
                }
            }
        });
        let work = async {
            while let Some((local, r)) = inbox.recv().await {
                let r = r?;
                if !local {
                    ensure!(
                        r.sequence > last_peer_sequence,
                        "handoff sequence regression"
                    );
                    last_peer_sequence = r.sequence;
                }
                if local && r.kind == 204 && releasing {
                    releasing = false;
                    if !machine.busy() {
                        seat = None;
                    }
                    continue;
                }
                if r.kind == REQUEST && seat.is_none() {
                    seat = Seat::acquire().ok();
                }
                let actions = if local {
                    machine.local(r, seat.is_some() && !releasing)
                } else {
                    machine.peer(r, seat.is_some() && !releasing)
                };
                for action in actions {
                    match action {
                        Action::Native(r) => {
                            if r.kind == RELEASED {
                                releasing = true;
                            }
                            write(&mut native_in, r, &mut ns).await?;
                        }
                        Action::Peer(r) => write(&mut tx, r, &mut ps).await?,
                    }
                }
                if !machine.busy() && !releasing {
                    seat = None;
                }
            }
            Ok::<(), anyhow::Error>(())
        };
        let outcome = tokio::select! {r=work=>r,_=stop()=>Err(anyhow::Error::new(Stopped))};
        // Restore native input before dropping the target-wide ownership lock.
        let _ = write(&mut native_in, Record::new(RELEASED, 0, [0; 4]), &mut ns).await;
        drop(native_in);
        local_task.abort();
        remote_task.abort();
        let _ = tokio::time::timeout(Duration::from_secs(3), child.wait()).await;
        drop(seat);
        outcome
    }
    .await;
    // EOF is the native cleanup path, including capability negotiation errors.
    // kill_on_drop is only the resource-failure fallback after the graceful wait.
    result
}
#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let (validate, path) = match args.as_slice() {
        [a, b] if a == "--config" => (false, b),
        [a, b, c] if a == "validate" && b == "--config" => (true, c),
        _ => anyhow::bail!("usage: vf-handoff-peer [validate] --config JSON"),
    };
    let config: Config = serde_json::from_slice(&std::fs::read(Path::new(path))?)?;
    config.validate()?;
    if validate {
        println!("handoff-config-valid");
        return Ok(());
    }
    viewflowd::managed_owner::watch()?;
    status("光标接管：正在连接");
    let identity = PeerIdentity::from_pem(
        &std::fs::read(&config.certificate)?,
        &std::fs::read(&config.private_key)?,
        &std::fs::read(&config.certificate_authority)?,
    )
    .map_err(|e| anyhow::anyhow!("handoff TLS: {e}"))?;
    let mut transport = viewflow_transport::media_transport_config();
    transport.keep_alive_interval(Some(Duration::from_secs(5)));
    let transport = Arc::new(transport);
    let mut server =
        build_server_config(&identity).map_err(|e| anyhow::anyhow!("handoff TLS server: {e}"))?;
    server.transport_config(transport.clone());
    let mut client =
        build_client_config(&identity).map_err(|e| anyhow::anyhow!("handoff TLS client: {e}"))?;
    client.transport_config(transport);
    let mut endpoint = quinn::Endpoint::server(server, config.bind)?;
    endpoint.set_default_client_config(client);
    let dialer = config.device_id < config.peer_id;
    loop {
        let connect = async {
            if dialer {
                Ok(endpoint
                    .connect(config.remote, &config.server_name)?
                    .await?)
            } else {
                Ok(endpoint
                    .accept()
                    .await
                    .context("handoff listener closed")?
                    .await?)
            }
        };
        let connected: Result<quinn::Connection> = tokio::select! {r=connect=>r,_=stop()=>break};
        match connected {
            Ok(c) => {
                if let Err(e) = session(&config, &c, dialer).await {
                    if e.downcast_ref::<Stopped>().is_some() {
                        break;
                    }
                    eprintln!("handoff recovering: {e:#}");
                    status(&format!("光标接管：正在恢复：{e:#}"));
                }
                c.close(0u32.into(), b"handoff reconnect");
            }
            Err(e) => eprintln!("handoff reconnect: {e:#}"),
        }
        tokio::select! {_=tokio::time::sleep(Duration::from_secs(2))=>{},_=stop()=>break}
    }
    endpoint.close(0u32.into(), b"handoff stopped");
    Ok(())
}
