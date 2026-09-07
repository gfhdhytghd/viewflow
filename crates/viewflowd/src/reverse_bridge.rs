//! Native window direction on an existing paired QUIC connection.
//! A single ordered stream carries its atlas and input. Native children retain
//! GPU ownership; Rust relays bounded encoded records, never raw color pixels.
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, process::Stdio, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    process::Command,
    sync::watch,
};

const MAGIC: &[u8; 8] = b"VFRV\0\0\0\x01";
const MAX_FRAME: u32 = 96 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ReverseBridgeConfig {
    pub native: PathBuf,
    #[serde(default)]
    pub args: Vec<String>,
}

impl ReverseBridgeConfig {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.native.is_absolute(), "reverse native program must be absolute");
        ensure!(self.args.len() <= 128 && self.args.iter().all(|arg| arg.len() <= 4096 && !arg.contains('\0')),
            "invalid reverse native arguments");
        Ok(())
    }
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct NativeDrag {
    pub id: u64,
    pub pid: u32,
    pub address: u64,
    pub handed_off: bool,
}
pub(crate) type SharedNativeDrag = std::sync::Arc<tokio::sync::Mutex<Option<NativeDrag>>>;

pub(crate) struct ReverseBridge {
    stop: Option<watch::Sender<bool>>,
    task: Option<tokio::task::JoinHandle<()>>,
}

/// Run a native window source or presenter on a dedicated paired connection.
/// Roles are independent of the operating system and of the TLS client/server
/// role. The source opens the media stream; the presenter accepts it.
///
/// The caller owns connection shutdown. Dropping this future stops the native
/// bridge, whose EOF cleanup releases held input before process teardown.
pub async fn run_window_bridge(
    connection: &quinn::Connection,
    config: &ReverseBridgeConfig,
    source: bool,
) -> Result<()> {
    let bridge = ReverseBridge::start(connection, config, source, None)?;
    connection.closed().await;
    bridge.shutdown().await?;
    Ok(())
}

impl Drop for ReverseBridge {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() { let _ = stop.send(true); }
    }
}

impl ReverseBridge {
    async fn shutdown(mut self) -> Result<()> {
        if let Some(stop) = self.stop.take() { let _ = stop.send(true); }
        if let Some(task) = self.task.take() { task.await.context("window bridge cleanup task")?; }
        Ok(())
    }
    pub(crate) fn start(connection: &quinn::Connection, config: &ReverseBridgeConfig, windows_source: bool, drag: Option<SharedNativeDrag>) -> Result<Self> {
        config.validate()?;
        ensure!(connection.peer_identity().is_some(), "reverse bridge needs a paired connection");
        let connection = connection.clone();
        let config = config.clone();
        let (stop, mut stopped) = watch::channel(false);
        let task = tokio::spawn(async move {
            loop {
                if *stopped.borrow() || connection.close_reason().is_some() { break; }
                if let Err(error) = run(&connection, &config, windows_source, &mut stopped, drag.as_ref()).await {
                    eprintln!("reverse-window-bridge recovering: {error:#}; forward desktop retained");
                }
                if let Some(drag) = &drag { *drag.lock().await = None; }
                if *stopped.borrow() || connection.close_reason().is_some() { break; }
                tokio::select! {
                    _ = stopped.changed() => break,
                    () = tokio::time::sleep(Duration::from_millis(500)) => (),
                }
            }
        });
        Ok(Self { stop: Some(stop), task: Some(task) })
    }
}

async fn run(connection: &quinn::Connection, config: &ReverseBridgeConfig, windows_source: bool, stopped: &mut watch::Receiver<bool>, drag: Option<&SharedNativeDrag>) -> Result<()> {
    let negotiate = async {
        let (mut send, mut receive) = if windows_source { connection.open_bi().await? } else { connection.accept_bi().await? };
        if windows_source { send.write_all(MAGIC).await?; }
        let mut magic = [0; 8]; receive.read_exact(&mut magic).await?;
        ensure!(&magic == MAGIC, "reverse stream version mismatch");
        if !windows_source { send.write_all(MAGIC).await?; }
        Ok::<_, anyhow::Error>((send, receive))
    };
    let (mut send, mut receive) = tokio::select! {
        result = negotiate => result?,
        _ = stopped.changed() => return Ok(()),
    };
    let mut command = Command::new(&config.native);
    command.args(&config.args).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit()).kill_on_drop(true);
    #[cfg(windows)]
    command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW; never take UI focus.
    let mut child = command.spawn().context("start native reverse window backend")?;
    let mut input = child.stdin.take().context("reverse child stdin")?;
    let mut output = child.stdout.take().context("reverse child stdout")?;
    eprintln!("reverse-window-bridge ready native_role={} paired_connection=true", if windows_source { "source" } else { "presenter" });
    let outgoing_type = if windows_source { 1 } else { 2 };
    let incoming_type = if windows_source { 2 } else { 1 };
    let child_pid = child.id().context("reverse child PID missing")?;
    let outgoing = async {
        if windows_source { relay_records(&mut output, &mut send, outgoing_type).await }
        else { relay_reverse_inputs(&mut output, &mut send, drag, child_pid).await }
    };
    let result = tokio::select! {
        result = outgoing => result,
        result = relay_records(&mut receive, &mut input, incoming_type) => result,
        _ = stopped.changed() => Ok(()),
    };
    // EOF gives the Windows owner a chance to release precisely its injected
    // keys/buttons before process teardown. A reverse failure does not close
    // the other direction or its independently owned windows.
    let _ = input.shutdown().await;
    drop(input);
    let _ = send.finish();
    let _ = receive.stop(0_u32.into());
    match tokio::time::timeout(Duration::from_secs(2), child.wait()).await {
        Ok(status) => { let status = status?; if !status.success() { eprintln!("reverse native backend exited: {status}"); } }
        Err(_) => { child.kill().await.context("stop native reverse backend")?; }
    }
    result
}

// Proxy drag identities are local child control records, never remote input.
// The local Wayland child reports its own PID/address only after mapping the
// proxy. Windows native move state is carried in the paired frame metadata.
async fn relay_reverse_inputs<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(reader: &mut R, writer: &mut W,
    drag: Option<&SharedNativeDrag>, child_pid: u32) -> Result<()> {
    loop {
        let mut record = [0u8; 44];
        reader.read_exact(&mut record).await.context("reverse input record")?;
        ensure!(u32::from_le_bytes(record[..4].try_into()?) == 40 && u32::from_le_bytes(record[4..8].try_into()?) == 2,
            "reverse input record format");
        ensure!(u64::from_le_bytes(record[16..24].try_into()?) > 0, "reverse input sequence is zero");
        if u32::from_le_bytes(record[24..28].try_into()?) == 9 {
            let id = u64::from_le_bytes(record[8..16].try_into()?);
            let pid = u32::from_le_bytes(record[28..32].try_into()?);
            let active = u32::from_le_bytes(record[32..36].try_into()?);
            let address = u64::from_le_bytes(record[36..44].try_into()?);
            ensure!(id > 0 && pid == child_pid && address > 0 && active <= 1, "invalid local reverse proxy binding");
            if let Some(drag) = drag {
                let mut current = drag.lock().await;
                if active != 0 {
                    if !current.as_ref().is_some_and(|old| old.id == id && old.pid == pid && old.address == address) {
                        *current = Some(NativeDrag { id, pid, address, handed_off: false });
                    }
                } else if current.as_ref().is_some_and(|old| old.id == id) { *current = None; }
            }
        } else {
            writer.write_all(&record).await?; writer.flush().await?;
        }
    }
}

async fn relay_records<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(reader: &mut R, writer: &mut W, kind: u32) -> Result<()> {
    let mut buffer = [0; 32 * 1024];
    loop {
        let mut prefix = [0; 4];
        reader.read_exact(&mut prefix).await.context("reverse record length")?;
        let length = u32::from_le_bytes(prefix);
        ensure!(if kind == 2 { length == 40 } else { (32..=MAX_FRAME).contains(&length) }, "reverse record length out of bounds");
        let mut tag = [0; 4]; reader.read_exact(&mut tag).await?;
        ensure!(u32::from_le_bytes(tag) == kind, "reverse record direction mismatch");
        writer.write_all(&prefix).await?; writer.write_all(&tag).await?;
        let mut remaining = length as usize - 4;
        while remaining != 0 {
            let count = remaining.min(buffer.len());
            reader.read_exact(&mut buffer[..count]).await?;
            writer.write_all(&buffer[..count]).await?;
            remaining -= count;
        }
        writer.flush().await?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn local_proxy_binding_is_consumed_and_cannot_reclaim_a_transferred_drag() {
        let drag = SharedNativeDrag::default();
        let record = |pid: u32, active: u32| {
            let mut bytes = Vec::new();
            bytes.extend(40u32.to_le_bytes()); bytes.extend(2u32.to_le_bytes());
            bytes.extend(42u64.to_le_bytes()); bytes.extend(1u64.to_le_bytes());
            bytes.extend(9u32.to_le_bytes()); bytes.extend(pid.to_le_bytes());
            bytes.extend(active.to_le_bytes()); bytes.extend(0x9876u64.to_le_bytes()); bytes
        };
        let mut forwarded = Vec::new();
        assert!(relay_reverse_inputs(&mut record(99, 1).as_slice(), &mut forwarded, Some(&drag), 123).await.is_err());
        assert!(drag.lock().await.is_none() && forwarded.is_empty());
        assert!(relay_reverse_inputs(&mut record(123, 1).as_slice(), &mut forwarded, Some(&drag), 123).await.is_err()); // finite fixture EOF
        { let mut state = drag.lock().await; let current = state.as_mut().unwrap(); assert_eq!(current.id, 42); current.handed_off = true; }
        assert!(relay_reverse_inputs(&mut record(123, 1).as_slice(), &mut forwarded, Some(&drag), 123).await.is_err());
        assert!(drag.lock().await.as_ref().unwrap().handed_off);
        assert!(relay_reverse_inputs(&mut record(123, 0).as_slice(), &mut forwarded, Some(&drag), 123).await.is_err());
        assert!(drag.lock().await.is_none() && forwarded.is_empty());
        let mut pointer = record(123, 0); pointer[24..28].copy_from_slice(&1u32.to_le_bytes());
        assert!(relay_reverse_inputs(&mut pointer.as_slice(), &mut forwarded, Some(&drag), 123).await.is_err());
        assert_eq!(forwarded, pointer);
    }

    #[tokio::test]
    async fn rejects_wrong_direction_and_oversize_before_forwarding() {
        for (kind, length, tag) in [(2, 41_u32, 2_u32), (1, MAX_FRAME + 1, 1), (2, 40, 1)] {
            let mut bytes = length.to_le_bytes().to_vec(); bytes.extend(tag.to_le_bytes()); bytes.extend([0; 36]);
            let mut source = bytes.as_slice(); let mut output = Vec::new();
            assert!(relay_records(&mut source, &mut output, kind).await.is_err());
            assert!(output.is_empty());
        }
    }
    #[tokio::test]
    async fn preserves_consecutive_ordered_input_records_exactly() {
        let mut expected = Vec::new();
        for sequence in 1_u64..=3 { expected.extend(40_u32.to_le_bytes());expected.extend(2_u32.to_le_bytes());expected.extend(7_u64.to_le_bytes());expected.extend(sequence.to_le_bytes());expected.extend([0;20]); }
        let mut source = expected.as_slice(); let mut output = Vec::new();
        assert!(relay_records(&mut source, &mut output, 2).await.is_err()); // clean finite fixture EOF
        assert_eq!(output, expected);
    }
}
