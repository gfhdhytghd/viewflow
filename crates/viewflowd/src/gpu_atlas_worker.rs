//! One native encoder and its asynchronous network queue per OS thread.
//! Capture leases cross the queue by ownership, and return only after GPU reads.
use crate::{
    atlas_session::AtlasSenderSession,
    gpu_atlas_sender::{AtlasBatch, AtlasBatchSent, AtlasPublication, GpuAtlasSender},
    gpu_compatible_encoder::AtlasEncoderRecipe,
};
use anyhow::{Context, Result};
use tokio::sync::{mpsc, oneshot};

enum Command {
    Batch(
        AtlasBatch,
        u64,
        tokio::time::Instant,
        Option<crate::atlas_occlusion::AtlasOcclusionMode>,
    ),
    Grow(u32, u32),
}
pub(crate) enum WorkerEvent {
    Released(
        Vec<(
            viewflow_protocol::WindowId,
            crate::hyprcapture_gpu_socket::HyprCaptureGpuSocketReceiver,
        )>,
    ),
    Batch(AtlasBatchSent),
    Publication(AtlasPublication),
    Grown,
    CapacityLimited(String),
}

pub(crate) struct GpuAtlasWorker {
    commands: Option<mpsc::Sender<Command>>,
    events: mpsc::Receiver<Result<WorkerEvent>>,
    thread: Option<std::thread::JoinHandle<()>>,
    busy: bool,
    occlusion: Option<crate::atlas_occlusion::AtlasOcclusionMode>,
    buffered: Option<Result<WorkerEvent>>,
}
impl GpuAtlasWorker {
    /// On initialization failure, return the untouched wire owner so the
    /// caller can retain its original warmed encoder and single-lane session.
    pub(crate) async fn start(
        recipe: AtlasEncoderRecipe,
        wire: AtlasSenderSession,
    ) -> std::result::Result<Self, (anyhow::Error, AtlasSenderSession)> {
        let wire = std::sync::Arc::new(std::sync::Mutex::new(Some(wire)));
        let worker_wire = wire.clone();
        let (ready, initialized) = oneshot::channel();
        let (commands, mut receive) = mpsc::channel(1);
        let (events, output) = mpsc::channel(4);
        let spawned = std::thread::Builder::new().name("vf-atlas-codec".into()).spawn(move || {
            let prepared = (|| -> Result<_> {
                let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
                let encoder = recipe.create()?;
                Ok((runtime, encoder))
            })();
            let (runtime, encoder) = match prepared {
                Ok(prepared) => prepared,
                Err(error) => { let _ = ready.send(Err(error)); return; }
            };
            // Do not move the authenticated wire until resource preparation succeeds.
            let wire = worker_wire.lock().unwrap().take().unwrap();
            let mut sender = GpuAtlasSender::new(encoder, wire);
            if ready.send(Ok(())).is_err() { return; }
            runtime.block_on(async {
                loop {
                    let result = tokio::select! {
                        command = receive.recv() => match command {
                            None => break,
                            Some(Command::Batch(batch, sequence, deadline, mode)) => {
                                if let Some(mode) = mode { if let Err(error) = sender.set_occlusion(mode) { let _ = events.send(Err(error)).await; break; } }
                                let released = events.clone();
                                sender.submit_batch_with_release(batch, sequence, deadline, Some(Box::new(move |receivers| {
                                    released.try_send(Ok(WorkerEvent::Released(receivers)))
                                        .map_err(|error| anyhow::anyhow!("atlas source return queue: {error}"))
                                }))).await.map(WorkerEvent::Batch)
                            },
                            Some(Command::Grow(width, height)) => match sender.grow_canvas_recoverable(width, height).await {
                                Ok((publication, growth)) => {
                                    if let Some(publication) = publication {
                                        if events.send(Ok(WorkerEvent::Publication(publication))).await.is_err() { break; }
                                    }
                                    Ok(match growth { Ok(()) => WorkerEvent::Grown, Err(error) => WorkerEvent::CapacityLimited(format!("{error:#}")) })
                                }
                                Err(error) => Err(error),
                            },

                        },
                        result = sender.wait_feedback() => result.map(WorkerEvent::Publication),
                    };
                    let failed = result.is_err();
                    if events.send(result).await.is_err() || failed { break; }
                }
                // Drop the encoder and its outstanding network task on their owner thread.
                drop(sender);
            });
        });
        let thread = match spawned {
            Ok(thread) => thread,
            Err(error) => return Err((error.into(), wire.lock().unwrap().take().unwrap())),
        };
        match initialized.await {
            Ok(Ok(())) => Ok(Self {
                commands: Some(commands),
                events: output,
                thread: Some(thread),
                busy: false,
                occlusion: None,
                buffered: None,
            }),
            result => {
                let _ = thread.join();
                let error = match result {
                    Ok(Err(error)) => error,
                    Err(error) => error.into(),
                    _ => unreachable!(),
                };
                Err((
                    error,
                    wire.lock()
                        .unwrap()
                        .take()
                        .expect("failed preparation retains wire"),
                ))
            }
        }
    }
    pub(crate) fn busy(&self) -> bool {
        self.busy
    }
    pub(crate) fn submit(
        &mut self,
        batch: AtlasBatch,
        sequence: u64,
        deadline: tokio::time::Instant,
    ) -> Result<()> {
        anyhow::ensure!(!self.busy, "atlas lane already owns a capture batch");
        self.commands
            .as_ref()
            .context("atlas worker stopped")?
            .try_send(Command::Batch(
                batch,
                sequence,
                deadline,
                self.occlusion.take(),
            ))
            .map_err(|error| anyhow::anyhow!("atlas worker queue: {error}"))?;
        self.busy = true;
        Ok(())
    }
    pub(crate) fn poll_readable(&mut self, cx: &mut std::task::Context<'_>) -> std::task::Poll<()> {
        if self.buffered.is_some() {
            return std::task::Poll::Ready(());
        }
        match self.events.poll_recv(cx) {
            std::task::Poll::Ready(Some(event)) => {
                self.buffered = Some(event);
                std::task::Poll::Ready(())
            }
            std::task::Poll::Ready(None) => {
                self.buffered = Some(Err(anyhow::anyhow!("atlas encoder worker ended")));
                std::task::Poll::Ready(())
            }
            std::task::Poll::Pending => std::task::Poll::Pending,
        }
    }
    pub(crate) fn poll(&mut self) -> Result<Option<WorkerEvent>> {
        match self
            .buffered
            .take()
            .map_or_else(|| self.events.try_recv(), Ok)
        {
            Ok(result) => {
                let event = result?;
                if matches!(
                    event,
                    WorkerEvent::Batch(_) | WorkerEvent::Grown | WorkerEvent::CapacityLimited(_)
                ) {
                    self.busy = false;
                }
                Ok(Some(event))
            }
            Err(mpsc::error::TryRecvError::Empty) => Ok(None),
            Err(mpsc::error::TryRecvError::Disconnected) => {
                anyhow::bail!("atlas encoder worker ended")
            }
        }
    }
    pub(crate) fn grow(&mut self, width: u32, height: u32) -> Result<()> {
        anyhow::ensure!(!self.busy, "atlas growth overlaps source reads");
        self.commands
            .as_ref()
            .context("atlas worker stopped")?
            .try_send(Command::Grow(width, height))
            .map_err(|error| anyhow::anyhow!("atlas worker queue: {error}"))?;
        self.busy = true;
        Ok(())
    }
    pub(crate) fn set_occlusion(&mut self, mode: crate::atlas_occlusion::AtlasOcclusionMode) {
        self.occlusion = Some(mode);
    }
    pub(crate) async fn shutdown(mut self) -> Result<()> {
        self.commands.take();
        self.events.close();
        if let Some(thread) = self.thread.take() {
            tokio::task::spawn_blocking(move || thread.join())
                .await?
                .map_err(|_| anyhow::anyhow!("atlas worker panicked during shutdown"))?;
        }
        Ok(())
    }
}
impl Drop for GpuAtlasWorker {
    fn drop(&mut self) {
        self.commands.take();
        self.events.close();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
