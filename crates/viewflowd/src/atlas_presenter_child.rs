//! Supervised native atlas presenter. Normal errors explicitly kill and reap;
//! cancellation additionally relies on Tokio's kill-on-drop process guard.
use crate::{
    atlas_presenter::{AtlasDisposition, AtlasPresenterPipe, AtlasVisualSubmission},
    atlas_runtime::AdmittedAtlas,
    gpu_presenter_pipe::NativePresentationDeadline,
};
use anyhow::{Context, Result};
use std::{path::Path, process::Stdio, time::Duration};
use tokio::{
    process::{Child, Command},
    time::{Instant, timeout},
};

type NativeWriter = std::pin::Pin<Box<dyn tokio::io::AsyncWrite + Send>>;

struct Active {
    pipe: AtlasPresenterPipe<NativeWriter, std::pin::Pin<Box<dyn tokio::io::AsyncRead + Send>>>,
    child: Child,
    stdout_worker: Option<StdoutWorker>,
}

struct StdoutWorker(tokio::task::JoinHandle<Result<()>>);
impl Drop for StdoutWorker {
    fn drop(&mut self) {
        self.0.abort();
    }
}

pub struct AtlasPresenterChild {
    active: Option<Active>,
}

struct InputModeChild {
    child: AtlasPresenterChild,
    pointers: tokio::sync::mpsc::Receiver<crate::atlas_pointer::AtlasNativePointer>,
    recovery_notices:
        Option<tokio::sync::mpsc::Receiver<crate::atlas_input_recovery::NativeRecoveryNotice>>,
    desktop_moves: Option<tokio::sync::mpsc::Receiver<crate::desktop_pointer::AtlasDesktopMove>>,
}

#[derive(Clone, Copy)]
struct InputModeOptions {
    color_codec: viewflow_transport::VideoCodec,
    wheel: bool,
    keyboard: bool,
    recovery: bool,
    desktop: Option<crate::desktop_config::AtlasReceiverDesktopConfig>,
}

struct NativeInputCapabilities {
    dispositions: bool,
    pointers: Option<tokio::sync::mpsc::Sender<crate::atlas_pointer::AtlasNativePointer>>,
    input: InputModeOptions,
    notices: Option<tokio::sync::mpsc::Sender<crate::atlas_input_recovery::NativeRecoveryNotice>>,
    desktop_moves: Option<tokio::sync::mpsc::Sender<crate::desktop_pointer::AtlasDesktopMove>>,
}

impl AtlasPresenterChild {
    /// Launch native per-window mouse output. The input supervisor must consume
    /// the returned queue continuously and retire its connection on queue EOF.
    /// # Errors
    /// Invalid bounds or unsupported native capabilities retire the child.
    pub async fn spawn_with_pointer_events(
        executable: &Path,
        max_frame_bytes: usize,
        proxy_capacity: usize,
        deadline: Instant,
    ) -> Result<(
        Self,
        tokio::sync::mpsc::Receiver<crate::atlas_pointer::AtlasNativePointer>,
    )> {
        Self::spawn_with_pointer_mode(executable, max_frame_bytes, proxy_capacity, deadline, false)
            .await
    }

    /// # Errors
    /// Invalid bounds or missing exact native wheel capability retire the child.
    pub async fn spawn_with_pointer_mode(
        executable: &Path,
        max_frame_bytes: usize,
        proxy_capacity: usize,
        deadline: Instant,
        wheel: bool,
    ) -> Result<(
        Self,
        tokio::sync::mpsc::Receiver<crate::atlas_pointer::AtlasNativePointer>,
    )> {
        Self::spawn_with_input_capabilities(
            executable,
            max_frame_bytes,
            proxy_capacity,
            deadline,
            wheel,
            false,
        )
        .await
    }

    /// # Errors
    /// Requires exact opt-in keyboard capability and its pointer prerequisites.
    pub async fn spawn_with_input_capabilities(
        executable: &Path,
        max_frame_bytes: usize,
        proxy_capacity: usize,
        deadline: Instant,
        wheel: bool,
        keyboard: bool,
    ) -> Result<(
        Self,
        tokio::sync::mpsc::Receiver<crate::atlas_pointer::AtlasNativePointer>,
    )> {
        let spawned = Self::spawn_input_mode(
            executable,
            max_frame_bytes,
            proxy_capacity,
            deadline,
            InputModeOptions {
                color_codec: viewflow_transport::VideoCodec::H264,
                wheel,
                keyboard,
                recovery: false,
                desktop: None,
            },
        )
        .await?;
        debug_assert!(spawned.recovery_notices.is_none());
        Ok((spawned.child, spawned.pointers))
    }

    /// Explicit recovery mode; the caller owns source cleanup/drain coordination
    /// and must continuously consume native input even between presentations.
    /// # Errors
    /// Missing exact native capability or invalid bounds retire the child.
    pub async fn spawn_with_input_recovery(
        executable: &Path,
        max_frame_bytes: usize,
        proxy_capacity: usize,
        deadline: Instant,
    ) -> Result<(
        Self,
        tokio::sync::mpsc::Receiver<crate::atlas_pointer::AtlasNativePointer>,
        tokio::sync::mpsc::Receiver<crate::atlas_input_recovery::NativeRecoveryNotice>,
    )> {
        let spawned = Self::spawn_input_mode(
            executable,
            max_frame_bytes,
            proxy_capacity,
            deadline,
            InputModeOptions {
                color_codec: viewflow_transport::VideoCodec::H264,
                wheel: true,
                keyboard: true,
                recovery: true,
                desktop: None,
            },
        )
        .await?;
        Ok((
            spawned.child,
            spawned.pointers,
            spawned
                .recovery_notices
                .context("atlas recovery notice receiver unavailable")?,
        ))
    }

    /// Launch the full recovery/desktop-native lane. Desktop move notifications
    /// are isolated from pointer input, recovery notices, and pipe receipts.
    /// # Errors
    /// Invalid viewport/capability negotiation retires the exact child.
    pub async fn spawn_with_desktop(
        executable: &Path,
        max_frame_bytes: usize,
        proxy_capacity: usize,
        desktop: crate::desktop_config::AtlasReceiverDesktopConfig,
        color_codec: viewflow_transport::VideoCodec,
        deadline: Instant,
    ) -> Result<(
        Self,
        tokio::sync::mpsc::Receiver<crate::atlas_pointer::AtlasNativePointer>,
        tokio::sync::mpsc::Receiver<crate::atlas_input_recovery::NativeRecoveryNotice>,
        tokio::sync::mpsc::Receiver<crate::desktop_pointer::AtlasDesktopMove>,
    )> {
        let spawned = Self::spawn_input_mode(
            executable,
            max_frame_bytes,
            proxy_capacity,
            deadline,
            InputModeOptions {
                color_codec,
                wheel: true,
                keyboard: true,
                recovery: true,
                desktop: Some(desktop),
            },
        )
        .await?;
        Ok((
            spawned.child,
            spawned.pointers,
            spawned
                .recovery_notices
                .context("atlas recovery notice receiver unavailable")?,
            spawned
                .desktop_moves
                .context("atlas desktop move receiver unavailable")?,
        ))
    }

    async fn spawn_input_mode(
        executable: &Path,
        max_frame_bytes: usize,
        proxy_capacity: usize,
        deadline: Instant,
        options: InputModeOptions,
    ) -> Result<InputModeChild> {
        let InputModeOptions {
            color_codec,
            wheel,
            keyboard,
            recovery,
            desktop,
        } = options;
        anyhow::ensure!(!keyboard || wheel, "keyboard requires wheel capability");
        anyhow::ensure!(
            !recovery || (keyboard && max_frame_bytes >= 152),
            "recovery requires keyboard and record capacity"
        );
        if let Some(desktop) = desktop {
            desktop.validate()?;
            anyhow::ensure!(recovery, "desktop requires recovery capability");
            anyhow::ensure!(
                max_frame_bytes >= 160,
                "desktop requires v7 header capacity"
            );
        }
        anyhow::ensure!(
            max_frame_bytes >= 112
                && u32::try_from(max_frame_bytes).is_ok()
                && (1..=4096).contains(&proxy_capacity),
            "invalid atlas pointer native bounds"
        );
        let mut command = Command::new(executable);
        command
            .args(["--stdin-atlas-v5", "--max-frame-bytes"])
            .arg(max_frame_bytes.to_string())
            .arg("--atlas-proxy-capacity")
            .arg(proxy_capacity.to_string())
            .args(["--atlas-disposition-v1", "--atlas-pointer-v1"]);
        if wheel {
            command.arg("--atlas-wheel-v1");
        }
        if keyboard {
            command.arg("--atlas-keyboard-v1");
        }
        if recovery {
            command.arg("--atlas-input-recovery-v1");
        }
        if let Some(desktop) = desktop {
            command.env("VIEWFLOW_ATLAS_ICON_DIR", crate::window_icon::receiver_directory());
            command
                .arg("--atlas-desktop-v1")
                .arg("--atlas-desktop-global-origin")
                .arg((i64::from(desktop.display.x) * 1000).to_string())
                .arg((i64::from(desktop.display.y) * 1000).to_string())
                .arg("--atlas-desktop-physical-rect")
                .arg(desktop.native_x.to_string())
                .arg(desktop.native_y.to_string())
                .arg(desktop.display.width.to_string())
                .arg(desktop.display.height.to_string())
                .arg("--atlas-desktop-scale-milli")
                .arg(desktop.display.scale_milli()?.to_string());
        }
        let codec_name = match color_codec {
            viewflow_transport::VideoCodec::H264 => "h264",
            viewflow_transport::VideoCodec::Av1 => "av1",
            _ => anyhow::bail!("unsupported atlas color codec"),
        };
        if color_codec != viewflow_transport::VideoCodec::H264 {
            command.args(["--atlas-color-codec", codec_name]);
        }
        #[cfg(windows)]
        command.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
        let (sender, receiver) = tokio::sync::mpsc::channel(64);
        let (notice_sender, notice_receiver) = if recovery {
            let (sender, receiver) = tokio::sync::mpsc::channel(64);
            (Some(sender), Some(receiver))
        } else {
            (None, None)
        };
        let (desktop_sender, desktop_receiver) = if desktop.is_some() {
            let (sender, receiver) = tokio::sync::mpsc::channel(64);
            (Some(sender), Some(receiver))
        } else {
            (None, None)
        };
        let child = Self::spawn_command_capabilities(
            command,
            deadline,
            NativeInputCapabilities {
                dispositions: true,
                pointers: Some(sender),
                input: InputModeOptions {
                    color_codec,
                    wheel,
                    keyboard,
                    recovery,
                    desktop,
                },
                notices: notice_sender,
                desktop_moves: desktop_sender,
            },
        )
        .await?;
        Ok(InputModeChild {
            child,
            pointers: receiver,
            recovery_notices: notice_receiver,
            desktop_moves: desktop_receiver,
        })
    }
    /// # Errors
    /// Requires three same-shape startup pictures; failures retire the child.
    pub async fn warmup(
        &mut self,
        frames: &[crate::atlas_presenter::AtlasWarmupFrame; 3],
        deadline: Instant,
        max_record_bytes: usize,
    ) -> Result<()> {
        let mut active = self
            .active
            .take()
            .context("atlas presenter child is retired")?;
        if let Err(error) = ensure_stdout_worker_alive(&mut active).await {
            return Err(retire_after_error(active, error).await);
        }
        match active.pipe.warmup(frames, deadline, max_record_bytes).await {
            Ok(()) => {
                self.active = Some(active);
                Ok(())
            }
            Err(error) => Err(retire_after_error(active, error).await),
        }
    }

    /// Launch only the explicit atlas mode; callers must supply the verified
    /// native executable. It may create windows when live frames are submitted.
    /// # Errors
    /// Spawn/readiness errors retire the child, with bounded kill/reap waiting.
    pub async fn spawn(executable: &Path, deadline: Instant) -> Result<Self> {
        let mut command = Command::new(executable);
        command.arg("--stdin-atlas-v5");
        #[cfg(windows)]
        command.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
        Self::spawn_command(command, deadline).await
    }

    /// Launch atlas mode with the locally negotiated encoded/decoded bound.
    /// # Errors
    /// Rejects bounds not representable by the native command-line contract.
    pub async fn spawn_with_limit(
        executable: &Path,
        max_frame_bytes: usize,
        deadline: Instant,
    ) -> Result<Self> {
        Self::spawn_config(executable, max_frame_bytes, None, deadline, false).await
    }

    /// Prepare a bounded hidden HWND/target pool during decode-only startup.
    /// # Errors
    /// Invalid capacity fails before launching any native process.
    pub async fn spawn_with_capacity(
        executable: &Path,
        max_frame_bytes: usize,
        proxy_capacity: usize,
        deadline: Instant,
    ) -> Result<Self> {
        anyhow::ensure!(
            (1..=4096).contains(&proxy_capacity),
            "invalid atlas proxy capacity"
        );
        Self::spawn_config(
            executable,
            max_frame_bytes,
            Some(proxy_capacity),
            deadline,
            false,
        )
        .await
    }

    /// Explicit experimental disposition mode; no fallback to legacy readiness.
    /// # Errors
    /// Invalid bounds or unsupported native capability retire the child.
    pub async fn spawn_with_dispositions(
        executable: &Path,
        max_frame_bytes: usize,
        proxy_capacity: usize,
        deadline: Instant,
    ) -> Result<Self> {
        anyhow::ensure!(
            (1..=4096).contains(&proxy_capacity),
            "invalid atlas proxy capacity"
        );
        Self::spawn_config(
            executable,
            max_frame_bytes,
            Some(proxy_capacity),
            deadline,
            true,
        )
        .await
    }

    async fn spawn_config(
        executable: &Path,
        max_frame_bytes: usize,
        proxy_capacity: Option<usize>,
        deadline: Instant,
        dispositions: bool,
    ) -> Result<Self> {
        anyhow::ensure!(
            max_frame_bytes >= 112 && u32::try_from(max_frame_bytes).is_ok(),
            "invalid native atlas byte limit"
        );
        let mut command = Command::new(executable);
        command
            .arg("--stdin-atlas-v5")
            .arg("--max-frame-bytes")
            .arg(max_frame_bytes.to_string());
        if let Some(capacity) = proxy_capacity {
            command
                .arg("--atlas-proxy-capacity")
                .arg(capacity.to_string());
        }
        if dispositions {
            command.arg("--atlas-disposition-v1");
        }
        #[cfg(windows)]
        command.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
        Self::spawn_command_mode(command, deadline, dispositions).await
    }

    pub(crate) async fn spawn_command(command: Command, deadline: Instant) -> Result<Self> {
        Self::spawn_command_mode(command, deadline, false).await
    }

    async fn spawn_command_mode(
        command: Command,
        deadline: Instant,
        dispositions: bool,
    ) -> Result<Self> {
        Self::spawn_command_outputs(command, deadline, dispositions, None).await
    }

    async fn spawn_command_outputs(
        command: Command,
        deadline: Instant,
        dispositions: bool,
        pointers: Option<tokio::sync::mpsc::Sender<crate::atlas_pointer::AtlasNativePointer>>,
    ) -> Result<Self> {
        Self::spawn_command_capabilities(
            command,
            deadline,
            NativeInputCapabilities {
                dispositions,
                pointers,
                input: InputModeOptions {
                    color_codec: viewflow_transport::VideoCodec::H264,
                    wheel: false,
                    keyboard: false,
                    recovery: false,
                    desktop: None,
                },
                notices: None,
                desktop_moves: None,
            },
        )
        .await
    }

    async fn spawn_command_capabilities(
        mut command: Command,
        deadline: Instant,
        capabilities: NativeInputCapabilities,
    ) -> Result<Self> {
        let NativeInputCapabilities {
            dispositions,
            pointers,
            input,
            notices,
            desktop_moves,
        } = capabilities;
        let InputModeOptions {
            color_codec: _,
            wheel,
            keyboard,
            recovery,
            desktop,
        } = input;
        anyhow::ensure!(
            !recovery || keyboard,
            "recovery requires keyboard capability"
        );
        anyhow::ensure!(
            recovery == notices.is_some(),
            "recovery requires a dedicated notice consumer"
        );
        anyhow::ensure!(
            desktop.is_some() == desktop_moves.is_some(),
            "desktop requires a dedicated move consumer"
        );
        anyhow::ensure!(
            desktop.is_none() || recovery,
            "desktop requires recovery capability"
        );
        if let Some(desktop) = desktop {
            desktop.validate()?;
        }
        anyhow::ensure!(!keyboard || wheel, "keyboard requires wheel capability");
        anyhow::ensure!(
            !wheel || (dispositions && pointers.is_some()),
            "wheel requires supervised pointer dispositions"
        );
        anyhow::ensure!(Instant::now() < deadline, "atlas startup deadline expired");
        #[cfg(windows)]
        let writer = prepare_windows_stdin(&mut command)?;
        #[cfg(not(windows))]
        command.stdin(Stdio::piped());
        let mut child = command
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()?;
        drop(command);
        #[cfg(not(windows))]
        let writer: NativeWriter = Box::pin(child.stdin.take().context("atlas stdin unavailable")?);
        let reader = child.stdout.take().context("atlas stdout unavailable")?;
        let pointer_events = pointers.is_some();
        let (reader, stdout_worker): (std::pin::Pin<Box<dyn tokio::io::AsyncRead + Send>>, _) =
            if let Some(sender) = pointers {
                let (receipt_reader, receipt_writer) = tokio::io::duplex(4096);
                let worker = tokio::spawn(async move {
                    crate::atlas_pointer::dispatch_stdout_with_recovery_notices_and_desktop(
                        reader,
                        receipt_writer,
                        sender,
                        recovery,
                        notices,
                        desktop_moves,
                    )
                    .await
                });
                (Box::pin(receipt_reader), Some(StdoutWorker(worker)))
            } else {
                (Box::pin(reader), None)
            };
        let mut active = Active {
            pipe: if desktop.is_some() {
                AtlasPresenterPipe::with_desktop(writer, reader)
            } else if recovery {
                AtlasPresenterPipe::with_input_recovery(writer, reader)
            } else if keyboard {
                AtlasPresenterPipe::with_keyboard_events(writer, reader)
            } else if wheel {
                AtlasPresenterPipe::with_wheel_events(writer, reader)
            } else if pointer_events {
                AtlasPresenterPipe::with_pointer_events(writer, reader)
            } else if dispositions {
                AtlasPresenterPipe::with_dispositions(writer, reader)
            } else {
                AtlasPresenterPipe::new(writer, reader)
            },
            child,
            stdout_worker,
        };
        if let Err(error) = active.pipe.wait_ready(deadline).await {
            return Err(retire_after_error(active, error).await);
        }
        Ok(Self {
            active: Some(active),
        })
    }

    /// # Errors
    /// Errors retire and reap the child. Cancellation drops the active process
    /// guard; this object cannot subsequently reuse that native codec session.
    pub async fn submit(
        &mut self,
        frame: &AdmittedAtlas,
        native_deadline: NativePresentationDeadline,
        deadline: Instant,
        max_record_bytes: usize,
    ) -> Result<AtlasVisualSubmission> {
        let mut active = self
            .active
            .take()
            .context("atlas presenter child is retired")?;
        if let Err(error) = ensure_stdout_worker_alive(&mut active).await {
            return Err(retire_after_error(active, error).await);
        }
        match active
            .pipe
            .submit(frame, native_deadline, deadline, max_record_bytes)
            .await
        {
            Ok(submitted) => {
                self.active = Some(active);
                Ok(submitted)
            }
            Err(error) => Err(retire_after_error(active, error).await),
        }
    }

    /// # Errors
    /// Errors and cancellation retire the exact owned native process.
    pub async fn submit_disposition(
        &mut self,
        frame: &AdmittedAtlas,
        native_deadline: NativePresentationDeadline,
        deadline: Instant,
        max_record_bytes: usize,
        clock: impl FnMut() -> Result<(u64, u64)>,
    ) -> Result<AtlasDisposition> {
        let mut active = self
            .active
            .take()
            .context("atlas presenter child is retired")?;
        if let Err(error) = ensure_stdout_worker_alive(&mut active).await {
            return Err(retire_after_error(active, error).await);
        }
        match active
            .pipe
            .submit_disposition(frame, native_deadline, deadline, max_record_bytes, clock)
            .await
        {
            Ok(result) => {
                self.active = Some(active);
                Ok(result)
            }
            Err(error) => Err(retire_after_error(active, error).await),
        }
    }

    /// Forward a recovery transaction to the exact owned native process.
    /// # Errors
    /// Failure/cancellation retires the child; successful completion is only a
    /// native acknowledgement, never source authorization or physical scanout.
    pub async fn recover_input(
        &mut self,
        confirmation: crate::atlas_input_recovery::InputRecoveryConfirmation,
        deadline: Instant,
        clock: impl FnMut() -> Result<(u64, u64)>,
    ) -> Result<u64> {
        let mut active = self
            .active
            .take()
            .context("atlas presenter child is retired")?;
        if let Err(error) = ensure_stdout_worker_alive(&mut active).await {
            return Err(retire_after_error(active, error).await);
        }
        match active
            .pipe
            .recover_input(confirmation, deadline, clock)
            .await
        {
            Ok(ticks) => {
                self.active = Some(active);
                Ok(ticks)
            }
            Err(error) => Err(retire_after_error(active, error).await),
        }
    }

    /// Close the pipe and explicitly terminate/reap this exact owned process.
    /// # Errors
    /// Reports termination failure/timeout; kill-on-drop remains a backup.
    pub async fn shutdown(mut self) -> Result<()> {
        if let Some(active) = self.active.take() {
            retire(active).await?;
        }
        Ok(())
    }
}

/// A bounded burst buffer avoids the default 4 KiB Windows anonymous pipe
/// forcing a thread handoff for every fragment of one encoded atlas record.
/// This changes transport buffering only; the native QPC deadline and all
/// partial-write retirement rules remain identical.
#[cfg(windows)]
fn prepare_windows_stdin(command: &mut Command) -> Result<NativeWriter> {
    let (read, write) = crate::coded_peer::presenter_stdin_pipe(256 * 1024)?;
    command.stdin(read);
    let mut writer = tokio::fs::File::from_std(write);
    writer.set_max_buf_size(256 * 1024);
    Ok(Box::pin(writer))
}

async fn ensure_stdout_worker_alive(active: &mut Active) -> Result<()> {
    let Some(worker) = active.stdout_worker.as_mut() else {
        return Ok(());
    };
    if !worker.0.is_finished() {
        return Ok(());
    }
    (&mut worker.0)
        .await
        .context("atlas stdout worker join failed")?
        .context("atlas stdout worker ended")
}

async fn retire(active: Active) -> Result<()> {
    let Active {
        pipe,
        mut child,
        stdout_worker,
    } = active;
    drop(pipe);
    drop(stdout_worker);
    timeout(Duration::from_secs(2), child.kill())
        .await
        .context("atlas child termination wait expired")??;
    Ok(())
}

async fn retire_after_error(active: Active, error: anyhow::Error) -> anyhow::Error {
    match retire(active).await {
        Ok(()) => error,
        Err(termination) => {
            error.context(format!("atlas child retirement also failed: {termination}"))
        }
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    #[tokio::test]
    async fn invalid_proxy_capacity_never_launches_a_child() {
        for capacity in [0, 4097, usize::MAX] {
            let result = AtlasPresenterChild::spawn_with_capacity(
                Path::new("/nonexistent/atlas-presenter"),
                4096,
                capacity,
                Instant::now() + Duration::from_secs(1),
            )
            .await;
            assert!(
                result
                    .err()
                    .unwrap()
                    .to_string()
                    .contains("invalid atlas proxy capacity")
            );
        }
    }
    #[tokio::test]
    async fn pointer_mode_owns_stdout_worker_and_reaps_child() {
        pointer_mode_child(false, false, false).await;
    }

    #[tokio::test]
    async fn wheel_mode_owns_stdout_worker_and_reaps_child() {
        pointer_mode_child(true, false, false).await;
    }

    #[tokio::test]
    async fn keyboard_mode_owns_stdout_worker_and_reaps_child() {
        pointer_mode_child(true, true, false).await;
    }

    #[tokio::test]
    async fn recovery_mode_owns_stdout_worker_and_reaps_child() {
        pointer_mode_child(true, true, true).await;
    }

    #[tokio::test]
    async fn desktop_mode_requires_v7_capacity_before_launch() {
        let desktop = crate::desktop_config::AtlasReceiverDesktopConfig {
            display: crate::desktop_config::AtlasDisplayConfig {
                x: -100,
                y: 200,
                width: 64,
                height: 32,
                scale: 1.0,
            },
            native_x: -1,
            native_y: 2,
        };
        let result = AtlasPresenterChild::spawn_with_desktop(
            Path::new("/nonexistent/atlas-presenter"),
            159,
            1,
            desktop,
            viewflow_transport::VideoCodec::H264,
            Instant::now() + Duration::from_secs(1),
        )
        .await;
        let error = result.err().unwrap();
        assert!(
            error
                .to_string()
                .contains("desktop requires v7 header capacity")
        );
    }

    #[tokio::test]
    async fn desktop_mode_owns_every_output_lane_and_requires_exact_readiness() {
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            "printf 'atlas-native-ready disposition=v1 input_enabled=true pointer=v1 wheel=v1 keyboard=v1 recovery=v1 desktop=v1 move_mode=win\\n'; read line",
        ]);
        let (pointer_sender, mut pointers) = tokio::sync::mpsc::channel(64);
        let (notice_sender, mut notices) = tokio::sync::mpsc::channel(64);
        let (move_sender, mut moves) = tokio::sync::mpsc::channel(64);
        let child = AtlasPresenterChild::spawn_command_capabilities(
            command,
            Instant::now() + Duration::from_secs(2),
            NativeInputCapabilities {
                dispositions: true,
                pointers: Some(pointer_sender),
                input: InputModeOptions {
                    color_codec: viewflow_transport::VideoCodec::H264,
                    wheel: true,
                    keyboard: true,
                    recovery: true,
                    desktop: Some(crate::desktop_config::AtlasReceiverDesktopConfig {
                        display: crate::desktop_config::AtlasDisplayConfig {
                            x: -100,
                            y: 200,
                            width: 64,
                            height: 32,
                            scale: 1.0,
                        },
                        native_x: -1,
                        native_y: 2,
                    }),
                },
                notices: Some(notice_sender),
                desktop_moves: Some(move_sender),
            },
        )
        .await
        .unwrap();
        assert!(child.active.as_ref().unwrap().stdout_worker.is_some());
        child.shutdown().await.unwrap();
        assert!(
            timeout(Duration::from_secs(1), pointers.recv())
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            timeout(Duration::from_secs(1), notices.recv())
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            timeout(Duration::from_secs(1), moves.recv())
                .await
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn recovery_notice_consumer_loss_retires_the_owned_child() {
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            "printf 'atlas-native-ready disposition=v1 input_enabled=true pointer=v1 wheel=v1 keyboard=v1 recovery=v1\\n'; read line",
        ]);
        let (pointer_sender, mut pointers) = tokio::sync::mpsc::channel(64);
        let (notice_sender, notices) = tokio::sync::mpsc::channel(64);
        let mut child = AtlasPresenterChild::spawn_command_capabilities(
            command,
            Instant::now() + Duration::from_secs(2),
            NativeInputCapabilities {
                dispositions: true,
                pointers: Some(pointer_sender),
                input: InputModeOptions {
                    color_codec: viewflow_transport::VideoCodec::H264,
                    wheel: true,
                    keyboard: true,
                    recovery: true,
                    desktop: None,
                },
                notices: Some(notice_sender),
                desktop_moves: None,
            },
        )
        .await
        .unwrap();
        let pid = child.active.as_ref().unwrap().child.id().unwrap();
        drop(notices);
        timeout(Duration::from_secs(1), async {
            loop {
                if child
                    .active
                    .as_ref()
                    .unwrap()
                    .stdout_worker
                    .as_ref()
                    .unwrap()
                    .0
                    .is_finished()
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let confirmation = crate::atlas_input_recovery::InputRecoveryConfirmation {
            rejection: None,
            sequence: 1,
            stream: 2,
            window: 3,
            atlas_epoch: 4,
            config_generation: 5,
            previous_epoch: 6,
            geometry_epoch: 7,
            grant_generation: 8,
            atlas_frame: 9,
            source_frame: 10,
            placement_generation: 11,
            deadline_qpc: 120,
            frequency: 1000,
        };
        let error = child
            .recover_input(
                confirmation,
                Instant::now() + Duration::from_secs(1),
                || Ok((100, 1000)),
            )
            .await
            .unwrap_err();
        assert!(error.to_string().contains("atlas stdout worker ended"));
        assert!(child.active.is_none());
        assert!(
            timeout(Duration::from_secs(1), pointers.recv())
                .await
                .unwrap()
                .is_none()
        );
        assert!(!Path::new(&format!("/proc/{pid}")).exists());
    }

    async fn pointer_mode_child(wheel: bool, keyboard: bool, recovery: bool) {
        let mut command = Command::new("/bin/sh");
        let capability = if recovery {
            " wheel=v1 keyboard=v1 recovery=v1"
        } else if keyboard {
            " wheel=v1 keyboard=v1"
        } else if wheel {
            " wheel=v1"
        } else {
            ""
        };
        command.args(["-c", &format!("printf 'atlas-native-ready disposition=v1 input_enabled=true pointer=v1{capability}\\n'; read line")]);
        let (sender, mut events) = tokio::sync::mpsc::channel(64);
        let (notice_sender, mut notices) = tokio::sync::mpsc::channel(64);
        let mut child = AtlasPresenterChild::spawn_command_capabilities(
            command,
            Instant::now() + Duration::from_secs(2),
            NativeInputCapabilities {
                dispositions: true,
                pointers: Some(sender),
                input: InputModeOptions {
                    color_codec: viewflow_transport::VideoCodec::H264,
                    wheel,
                    keyboard,
                    recovery,
                    desktop: None,
                },
                notices: recovery.then_some(notice_sender),
                desktop_moves: None,
            },
        )
        .await
        .unwrap();
        let pid = child.active.as_ref().unwrap().child.id().unwrap();
        assert!(child.active.as_ref().unwrap().stdout_worker.is_some());
        assert!(matches!(
            events.try_recv(),
            Err(tokio::sync::mpsc::error::TryRecvError::Empty)
        ));
        assert!(matches!(
            notices.try_recv(),
            Err(tokio::sync::mpsc::error::TryRecvError::Empty)
                | Err(tokio::sync::mpsc::error::TryRecvError::Disconnected)
        ));
        if recovery {
            let confirmation = crate::atlas_input_recovery::InputRecoveryConfirmation {
                rejection: None,
                sequence: 1,
                stream: 2,
                window: 3,
                atlas_epoch: 4,
                config_generation: 5,
                previous_epoch: 6,
                geometry_epoch: 7,
                grant_generation: 8,
                atlas_frame: 9,
                source_frame: 10,
                placement_generation: 11,
                deadline_qpc: 120,
                frequency: 1000,
            };
            // Readiness alone supplies no committed frame. A failed recovery
            // must reap the child and close input, not leave it reusable.
            assert!(
                child
                    .recover_input(
                        confirmation,
                        Instant::now() + Duration::from_secs(1),
                        || Ok((100, 1000))
                    )
                    .await
                    .is_err()
            );
            assert!(child.active.is_none());
        } else {
            child.shutdown().await.unwrap();
        }
        assert!(
            tokio::time::timeout(Duration::from_secs(1), events.recv())
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            tokio::time::timeout(Duration::from_secs(1), notices.recv())
                .await
                .unwrap()
                .is_none()
        );
        assert!(!Path::new(&format!("/proc/{pid}")).exists());
    }

    #[tokio::test]
    async fn shutdown_reaps_owned_native_contract_process() {
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            "printf 'atlas-native-ready input_enabled=false\\n'; read line",
        ]);
        let child =
            AtlasPresenterChild::spawn_command(command, Instant::now() + Duration::from_secs(2))
                .await
                .unwrap();
        let pid = child.active.as_ref().unwrap().child.id().unwrap();
        child.shutdown().await.unwrap();
        assert!(!Path::new(&format!("/proc/{pid}")).exists());
    }

    #[tokio::test]
    async fn rejected_readiness_does_not_leave_a_live_child() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("pid");
        let mut command = Command::new("/bin/sh");
        command.env("VIEWFLOW_TEST_PID_FILE", &path);
        command.args(["-c", "printf '%s' \"$$\" > \"$VIEWFLOW_TEST_PID_FILE\"; printf 'composition preview ready\\n'; read line"]);
        assert!(
            AtlasPresenterChild::spawn_command(command, Instant::now() + Duration::from_secs(2))
                .await
                .is_err()
        );
        let pid: u32 = std::fs::read_to_string(path).unwrap().parse().unwrap();
        assert!(!Path::new(&format!("/proc/{pid}")).exists());
    }

    #[tokio::test]
    async fn cancelled_startup_terminates_partial_ready_process() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("pid");
        let mut command = Command::new("/bin/sh");
        command.env("VIEWFLOW_TEST_PID_FILE", &path);
        command.args(["-c", "printf '%s' \"$$\" > \"$VIEWFLOW_TEST_PID_FILE\"; printf 'atlas-native-ready '; read line"]);
        let task = tokio::spawn(AtlasPresenterChild::spawn_command(
            command,
            Instant::now() + Duration::from_secs(5),
        ));
        let pid = timeout(Duration::from_secs(2), async {
            loop {
                if let Some(pid) = std::fs::read_to_string(&path)
                    .ok()
                    .and_then(|text| text.parse::<u32>().ok())
                {
                    break pid;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        task.abort();
        assert!(task.await.is_err());
        timeout(Duration::from_secs(2), async {
            while Path::new(&format!("/proc/{pid}")).exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
    }
}
