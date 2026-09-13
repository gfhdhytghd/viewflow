//! Automatic clipboard lane on an authenticated desktop connection.
//! Start after atlas startup: only the atlas source opens this stream. Reverse
//! windows open streams in the opposite direction, so their readers cannot race.
use anyhow::{Context, Result, ensure};
use sha2::{Digest, Sha256};
use std::{borrow::Cow, io::Cursor, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::{oneshot, watch},
};

const MAGIC: &[u8; 8] = b"VFCL\0\0\0\x01";
const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_PIXELS: u64 = 16 * 1024 * 1024;
const POLL: Duration = Duration::from_millis(300);

#[derive(Clone, Debug, PartialEq, Eq)]
struct Content {
    kind: u8,
    bytes: Vec<u8>,
}
impl Content {
    fn fingerprint(&self) -> [u8; 32] {
        let mut hash = Sha256::new();
        hash.update([self.kind]);
        hash.update(&self.bytes);
        hash.finalize().into()
    }
    fn validate(&self) -> Result<()> {
        ensure!(
            self.bytes.len() <= MAX_BYTES,
            "clipboard exceeds 16 MiB transfer limit"
        );
        match self.kind {
            1 => {
                std::str::from_utf8(&self.bytes).context("clipboard UTF-8")?;
            }
            2 => {
                decode_png(&self.bytes)?;
            }
            _ => anyhow::bail!("unsupported clipboard format"),
        }
        Ok(())
    }
}

fn decode_png(bytes: &[u8]) -> Result<image::RgbaImage> {
    let mut reader = image::ImageReader::with_format(Cursor::new(bytes), image::ImageFormat::Png);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(16384);
    limits.max_image_height = Some(16384);
    limits.max_alloc = Some(MAX_PIXELS * 8);
    reader.limits(limits);
    let image = reader.decode()?;
    ensure!(
        u64::from(image.width()) * u64::from(image.height()) <= MAX_PIXELS,
        "clipboard image too large"
    );
    Ok(image.into_rgba8())
}

fn read_native(clipboard: &mut arboard::Clipboard) -> Result<Option<Content>> {
    match clipboard.get_text() {
        Ok(text) => {
            let content = Content {
                kind: 1,
                bytes: text.into_bytes(),
            };
            content.validate()?;
            return Ok(Some(content));
        }
        Err(arboard::Error::ContentNotAvailable) => (),
        Err(error) => return Err(error.into()),
    }
    match clipboard.get_image() {
        Ok(image) => {
            ensure!(
                image
                    .width
                    .checked_mul(image.height)
                    .is_some_and(|n| n as u64 <= MAX_PIXELS),
                "clipboard image too large"
            );
            let rgba = image::RgbaImage::from_raw(
                u32::try_from(image.width)?,
                u32::try_from(image.height)?,
                image.bytes.into_owned(),
            )
            .context("clipboard image layout")?;
            let mut bytes = Cursor::new(Vec::new());
            rgba.write_to(&mut bytes, image::ImageFormat::Png)?;
            let content = Content {
                kind: 2,
                bytes: bytes.into_inner(),
            };
            ensure!(
                content.bytes.len() <= MAX_BYTES,
                "clipboard image exceeds transfer limit"
            );
            Ok(Some(content))
        }
        Err(arboard::Error::ContentNotAvailable) => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn write_native(clipboard: &mut arboard::Clipboard, content: &Content) -> Result<()> {
    content.validate()?;
    if content.kind == 1 {
        clipboard.set_text(std::str::from_utf8(&content.bytes)?)?;
    } else {
        let image = decode_png(&content.bytes)?;
        clipboard.set_image(arboard::ImageData {
            width: image.width() as usize,
            height: image.height() as usize,
            bytes: Cow::Owned(image.into_raw()),
        })?;
    }
    Ok(())
}

enum NativeRequest {
    Read(oneshot::Sender<Result<Option<Content>>>),
    Write(Arc<Content>, oneshot::Sender<Result<()>>),
}
// One persistent OS clipboard owner, with a bounded mailbox. Native calls never
// run on Tokio workers. A stalled OS call does not spawn more worker threads.
struct Native(std::sync::mpsc::SyncSender<NativeRequest>);
impl Native {
    fn start() -> Self {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let mut clipboard = None;
            while let Ok(request) = rx.recv() {
                let backend = if let Some(ref mut clipboard) = clipboard {
                    Ok(clipboard)
                } else {
                    arboard::Clipboard::new()
                        .map(|new| clipboard.insert(new))
                        .map_err(anyhow::Error::from)
                };
                match request {
                    NativeRequest::Read(reply) => {
                        let _ = reply.send(backend.and_then(read_native));
                    }
                    NativeRequest::Write(content, reply) => {
                        let _ = reply
                            .send(backend.and_then(|clipboard| write_native(clipboard, &content)));
                    }
                }
            }
        });
        Self(tx)
    }
    async fn read(&self) -> Result<Option<Content>> {
        let (tx, rx) = oneshot::channel();
        self.0
            .try_send(NativeRequest::Read(tx))
            .context("clipboard worker busy")?;
        tokio::time::timeout(Duration::from_secs(5), rx).await??
    }
    async fn write(&self, content: Arc<Content>) -> Result<()> {
        let (tx, rx) = oneshot::channel();
        self.0
            .try_send(NativeRequest::Write(content, tx))
            .context("clipboard worker busy")?;
        tokio::time::timeout(Duration::from_secs(5), rx).await??
    }
}

#[derive(Clone, Debug)]
struct Update {
    version: (u64, u8),
    content: Arc<Content>,
}
async fn send_update<W: AsyncWrite + Unpin>(writer: &mut W, update: &Update) -> Result<()> {
    writer.write_u64(update.version.0).await?;
    writer.write_u8(update.version.1).await?;
    writer.write_u8(update.content.kind).await?;
    writer
        .write_u32(u32::try_from(update.content.bytes.len())?)
        .await?;
    writer.write_all(&update.content.bytes).await?;
    writer.flush().await?;
    Ok(())
}
async fn receive_update<R: AsyncRead + Unpin>(reader: &mut R, remote_role: u8) -> Result<Update> {
    let version = (reader.read_u64().await?, reader.read_u8().await?);
    ensure!(
        version.0 > 0 && version.1 == remote_role,
        "invalid clipboard version"
    );
    let kind = reader.read_u8().await?;
    let len = reader.read_u32().await? as usize;
    ensure!(
        len <= MAX_BYTES && matches!(kind, 1 | 2),
        "invalid clipboard record"
    );
    let mut bytes = vec![0; len];
    reader.read_exact(&mut bytes).await?;
    Ok(Update {
        version,
        content: Arc::new(Content { kind, bytes }),
    })
}

#[derive(Default)]
struct State {
    clock: u64,
    version: (u64, u8),
    observed: Option<[u8; 32]>,
    initialized: bool,
    pending: Option<Update>,
}
impl State {
    fn local(&mut self, content: Option<Content>, role: u8) -> Option<Update> {
        let fingerprint = content.as_ref().map(Content::fingerprint);
        let changed = self.initialized && self.observed != fingerprint;
        self.initialized = true;
        self.observed = fingerprint;
        if !changed {
            return None;
        }
        self.clock = self.clock.checked_add(1)?;
        self.version = (self.clock, role);
        self.pending = None;
        let content = content?;
        Some(Update {
            version: self.version,
            content: Arc::new(content),
        })
    }
    fn remote(&mut self, update: Update) {
        self.clock = self.clock.max(update.version.0);
        if update.version > self.version {
            self.version = update.version;
            self.pending = Some(update);
        }
    }
    fn installed(&mut self, content: &Content) {
        self.observed = Some(content.fingerprint());
        self.initialized = true;
        self.pending = None;
    }
}

/// Lifetime of automatic synchronization. Set `VIEWFLOW_CLIPBOARD=0` to disable
/// on either endpoint. No per-copy consent or focus-dependent gate is applied.
pub struct ClipboardSync(tokio::task::JoinHandle<()>);
impl Drop for ClipboardSync {
    fn drop(&mut self) {
        self.0.abort();
    }
}
impl ClipboardSync {
    #[must_use]
    pub fn start(connection: &quinn::Connection, source: bool) -> Self {
        let connection = connection.clone();
        Self(tokio::spawn(async move {
            if std::env::var("VIEWFLOW_CLIPBOARD").is_ok_and(|value| value == "0")
                || connection.peer_identity().is_none()
            {
                return;
            }
            let native = Native::start();
            while connection.close_reason().is_none() {
                if let Err(error) = session(&connection, source, &native).await {
                    eprintln!("clipboard lane recovering: {error:#}");
                }
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        }))
    }
}

async fn session(connection: &quinn::Connection, source: bool, native: &Native) -> Result<()> {
    let (mut send, mut receive) = if source {
        connection.open_bi().await?
    } else {
        connection.accept_bi().await?
    };
    send.write_all(MAGIC).await?;
    let mut magic = [0; 8];
    tokio::time::timeout(Duration::from_secs(10), receive.read_exact(&mut magic)).await??;
    ensure!(&magic == MAGIC, "clipboard stream version mismatch");
    let diagnostics = std::env::var_os("VIEWFLOW_CLIPBOARD_DIAGNOSTICS").is_some();
    if diagnostics {
        eprintln!("clipboard lane ready");
    }
    let role = u8::from(source);
    let (outgoing, mut outgoing_rx) = watch::channel::<Option<Update>>(None);
    let (incoming, mut incoming_rx) = watch::channel::<Option<Update>>(None);
    let write = async {
        loop {
            outgoing_rx.changed().await?;
            let update = outgoing_rx.borrow_and_update().clone();
            if let Some(update) = update {
                send_update(&mut send, &update).await?;
            }
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    };
    let read = async {
        loop {
            incoming.send(Some(receive_update(&mut receive, 1 - role).await?))?;
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    };
    let synchronize = async {
        let mut state = State::default();
        let mut tick = tokio::time::interval(POLL);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                _ = tick.tick() => (),
                changed = incoming_rx.changed() => { changed?; },
            }
            // Observe local edits before applying a remote update. Lamport
            // versions and the source tie-break make simultaneous copies converge.
            if let Ok(content) = native.read().await {
                if let Some(update) = state.local(content, role) {
                    if diagnostics {
                        eprintln!(
                            "clipboard send kind={} bytes={}",
                            update.content.kind,
                            update.content.bytes.len()
                        );
                    }
                    outgoing.send(Some(update))?;
                }
            }
            if let Some(update) = incoming_rx.borrow_and_update().clone() {
                state.remote(update);
            }
            if let Some(update) = state.pending.clone() {
                match native.write(update.content.clone()).await {
                    Ok(()) => {
                        if diagnostics {
                            eprintln!(
                                "clipboard installed kind={} bytes={}",
                                update.content.kind,
                                update.content.bytes.len()
                            );
                        }
                        state.installed(&update.content);
                    }
                    Err(error) => {
                        if diagnostics {
                            eprintln!("clipboard native write failed: {error}");
                        }
                    }
                }
            }
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    };
    tokio::select! { result = write => result, result = read => result, result = synchronize => result }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn text(value: &str) -> Content {
        Content {
            kind: 1,
            bytes: value.as_bytes().to_vec(),
        }
    }
    #[test]
    fn baseline_echo_repeated_copy_and_more_than_64_updates() {
        let mut state = State::default();
        assert!(state.local(Some(text("initial")), 0).is_none());
        for n in 1..100 {
            let update = Update {
                version: (n, 1),
                content: Arc::new(text(&format!("remote {n}"))),
            };
            state.remote(update.clone());
            state.installed(&update.content);
            assert!(state.local(Some((*update.content).clone()), 0).is_none());
        }
        assert!(state.local(Some(text("initial")), 0).is_some());
    }
    #[test]
    fn simultaneous_copies_converge_and_failed_install_is_retriable() {
        let mut left = State::default();
        let mut right = State::default();
        left.local(Some(text("old")), 1);
        right.local(Some(text("old")), 0);
        let a = left.local(Some(text("A")), 1).unwrap();
        let b = right.local(Some(text("B")), 0).unwrap();
        left.remote(b);
        right.remote(a.clone());
        assert!(left.pending.is_none());
        assert_eq!(right.pending.as_ref().unwrap().content, a.content);
        // A failed native write leaves the same update available next poll.
        assert!(right.local(Some(text("B")), 0).is_none());
        assert!(right.pending.is_some());
        right.installed(&a.content);
        assert!(right.local(Some(text("A")), 0).is_none());
        let next = right.local(Some(text("C")), 0).unwrap();
        left.remote(next.clone());
        assert_eq!(left.pending.unwrap().content, next.content);
    }
    #[tokio::test]
    async fn wire_round_trip_unicode_empty_and_png() {
        let mut png = Cursor::new(Vec::new());
        image::RgbaImage::from_pixel(2, 2, image::Rgba([255, 0, 0, 128]))
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        for content in [
            text("中文🙂\nline\r\n"),
            text(""),
            Content {
                kind: 2,
                bytes: png.into_inner(),
            },
        ] {
            content.validate().unwrap();
            let update = Update {
                version: (1, 1),
                content: Arc::new(content),
            };
            let (mut tx, mut rx) = tokio::io::duplex(4096);
            send_update(&mut tx, &update).await.unwrap();
            let received = receive_update(&mut rx, 1).await.unwrap();
            assert_eq!(received.content, update.content);
        }
    }
    #[tokio::test]
    async fn reject_oversized_record_before_allocating_payload() {
        let (mut tx, mut rx) = tokio::io::duplex(64);
        tx.write_u64(1).await.unwrap();
        tx.write_u8(0).await.unwrap();
        tx.write_u8(1).await.unwrap();
        tx.write_u32(MAX_BYTES as u32 + 1).await.unwrap();
        assert!(receive_update(&mut rx, 0).await.is_err());
        assert!(
            Content {
                kind: 1,
                bytes: vec![255]
            }
            .validate()
            .is_err()
        );
        assert!(
            Content {
                kind: 2,
                bytes: vec![0; 20]
            }
            .validate()
            .is_err()
        );
    }
    #[tokio::test]
    async fn clipboard_stream_failure_keeps_peer_and_other_streams_alive() {
        let (_client, _server, local, remote) = crate::atlas_session::tests::pair().await;
        let (mut send, mut receive) = local.open_bi().await.unwrap();
        send.write_all(MAGIC).await.unwrap();
        let (mut peer_send, mut peer_receive) = remote.accept_bi().await.unwrap();
        let mut magic = [0; 8];
        peer_receive.read_exact(&mut magic).await.unwrap();
        assert_eq!(&magic, MAGIC);
        peer_send.reset(0u32.into()).unwrap();
        assert!(receive.read_exact(&mut magic).await.is_err());
        assert!(local.close_reason().is_none());
        assert!(remote.close_reason().is_none());
        let (mut next, _) = local.open_bi().await.unwrap();
        next.write_all(b"alive").await.unwrap();
        let (_, mut next_remote) = remote.accept_bi().await.unwrap();
        let mut payload = [0; 5];
        next_remote.read_exact(&mut payload).await.unwrap();
        assert_eq!(&payload, b"alive");
    }
    fn fake_native() -> (Native, Arc<std::sync::Mutex<Option<Content>>>) {
        let state = Arc::new(std::sync::Mutex::new(Some(text("baseline"))));
        let shared = state.clone();
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        std::thread::spawn(move || {
            while let Ok(request) = rx.recv() {
                match request {
                    NativeRequest::Read(reply) => {
                        let _ = reply.send(Ok(shared.lock().unwrap().clone()));
                    }
                    NativeRequest::Write(content, reply) => {
                        *shared.lock().unwrap() = Some((*content).clone());
                        let _ = reply.send(Ok(()));
                    }
                }
            }
        });
        (Native(tx), state)
    }
    #[tokio::test]
    async fn automatic_session_syncs_both_directions_without_control_reader() {
        let (_client, _server, local, remote) = crate::atlas_session::tests::pair().await;
        let (left_native, left) = fake_native();
        let (right_native, right) = fake_native();
        let a = local.clone();
        let b = remote.clone();
        let left_task = tokio::spawn(async move { session(&a, true, &left_native).await });
        let right_task = tokio::spawn(async move { session(&b, false, &right_native).await });
        tokio::time::sleep(POLL * 2).await;
        *left.lock().unwrap() = Some(text("left 中文"));
        tokio::time::timeout(Duration::from_secs(3), async {
            while *right.lock().unwrap() != Some(text("left 中文")) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        *right.lock().unwrap() = Some(text("right 🙂"));
        tokio::time::timeout(Duration::from_secs(3), async {
            while *left.lock().unwrap() != Some(text("right 🙂")) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        left_task.abort();
        right_task.abort();
        let _ = left_task.await;
        let _ = right_task.await;
        assert!(local.close_reason().is_none());
        assert!(remote.close_reason().is_none());
    }
}
