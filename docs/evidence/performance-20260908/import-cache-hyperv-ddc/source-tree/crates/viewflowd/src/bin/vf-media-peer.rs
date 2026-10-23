#[cfg(target_os = "linux")]
use anyhow::Context;
use anyhow::{Result, bail};
use viewflowd::atlas_peer::{AtlasReceiverConfig, AtlasSourceConfig, USAGE};

fn main() -> Result<()> {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    if arguments.len() == 1 && (arguments[0] == "--help" || arguments[0] == "-h") {
        println!(
            "{USAGE}\n\nNative desktop metadata probe:\n  vf-media-peer probe --compositor-pid <PID> --window <ADDRESS>\nOffline config checks:\n  vf-media-peer validate-send --config <JSON>\n  vf-media-peer validate-receive --config <JSON>"
        );
        return Ok(());
    }
    if arguments
        .first()
        .is_some_and(|argument| argument == "probe")
    {
        return run_probe(&arguments[1..]);
    }
    if arguments.len() != 3 || arguments[1] != "--config" {
        bail!("{USAGE}");
    }
    if arguments[0] == "send" {
        return run_source(AtlasSourceConfig::load(std::path::Path::new(
            &arguments[2],
        ))?);
    }
    if arguments[0] == "validate-send" {
        AtlasSourceConfig::load(std::path::Path::new(&arguments[2]))?;
        println!("source-config-valid");
        return Ok(());
    }
    if arguments[0] == "validate-receive" {
        AtlasReceiverConfig::load(std::path::Path::new(&arguments[2]))?;
        println!("receiver-config-valid");
        return Ok(());
    }
    if arguments[0] != "receive" {
        bail!("{USAGE}");
    }
    let config = AtlasReceiverConfig::load(std::path::Path::new(&arguments[2]))?;
    run(config)
}

#[cfg(target_os = "linux")]
fn run_probe(arguments: &[std::ffi::OsString]) -> Result<()> {
    if arguments.len() != 4 || arguments[0] != "--compositor-pid" || arguments[2] != "--window" {
        bail!("usage: vf-media-peer probe --compositor-pid <PID> --window <ADDRESS>");
    }
    let compositor_pid = arguments[1]
        .to_str()
        .context("--compositor-pid must be UTF-8")?
        .parse::<u32>()
        .context("invalid --compositor-pid")?;
    let window = arguments[3].to_str().context("--window must be UTF-8")?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let output = runtime.block_on(async {
        use tokio::signal::unix::{SignalKind, signal};
        let mut interrupt = signal(SignalKind::interrupt())?;
        let mut terminate = signal(SignalKind::terminate())?;
        let probe = viewflowd::desktop_probe::probe_viewflow_desktop_window(window, compositor_pid);
        tokio::pin!(probe);
        tokio::select! {
            result = &mut probe => result,
            _ = interrupt.recv() => {
                // The bounded probe owns its stop authority; gather it instead
                // of dropping a live producer when the user cancels startup.
                probe.await?;
                bail!("desktop probe cancelled after capture cleanup")
            }
            _ = terminate.recv() => {
                probe.await?;
                bail!("desktop probe terminated after capture cleanup")
            }
        }
    })?;
    println!("{}", serde_json::to_string(&output)?);
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn run_probe(_arguments: &[std::ffi::OsString]) -> Result<()> {
    bail!("vf-media-peer probe requires Linux and the native Viewflow capture plugin")
}

#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
fn source_runtime() -> Result<tokio::runtime::Runtime> {
    // block_on keeps the native GPU owner on its calling thread. Spawned QUIC,
    // clock and input work must progress while that owner executes native calls.
    Ok(tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?)
}

#[cfg(all(target_os = "linux", feature = "native-gpu-nvenc"))]
fn run_source(config: AtlasSourceConfig) -> Result<()> {
    let runtime = source_runtime()?;
    runtime.block_on(async {
        use tokio::signal::unix::{SignalKind, signal};
        let mut interrupt = signal(SignalKind::interrupt())?;
        let mut terminate = signal(SignalKind::terminate())?;
        viewflowd::atlas_source::run_until(config, async move {
            tokio::select! { _ = interrupt.recv() => (), _ = terminate.recv() => () }
        })
        .await
    })
}

#[cfg(all(test, target_os = "linux", feature = "native-gpu-nvenc"))]
mod source_runtime_tests {
    #[test]
    fn background_work_progresses_while_native_owner_keeps_its_thread() {
        let runtime = super::source_runtime().unwrap();
        let owner = std::thread::current().id();
        runtime.block_on(async {
            let (sent, receive) = std::sync::mpsc::channel();
            let task = tokio::spawn(async move {
                assert_ne!(std::thread::current().id(), owner);
                sent.send(()).unwrap();
            });
            // Model a synchronous native call. A current-thread runtime cannot
            // execute the task above until this call returns, and fails here.
            receive
                .recv_timeout(std::time::Duration::from_secs(2))
                .unwrap();
            task.await.unwrap();
            tokio::task::yield_now().await;
            assert_eq!(std::thread::current().id(), owner);
        });
    }
}

#[cfg(not(all(target_os = "linux", feature = "native-gpu-nvenc")))]
fn run_source(_config: AtlasSourceConfig) -> Result<()> {
    bail!("atlas native send mode requires Linux and native-gpu-nvenc; no CPU fallback is selected")
}

#[cfg(windows)]
fn run(config: AtlasReceiverConfig) -> Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        // Native GPU/UI ownership lives in the supervised child. Keep QUIC
        // I/O and clock tasks progressing while this owner handles a frame.
        .worker_threads(2)
        .enable_all()
        .build()?;
    runtime.block_on(async {
        // Register signal ownership before binding/listening or starting native work.
        let mut interrupt = tokio::signal::windows::ctrl_c()?;
        let mut control_break = tokio::signal::windows::ctrl_break()?;
        viewflowd::atlas_peer::run_receiver_until(config, async move {
            tokio::select! { _ = interrupt.recv() => (), _ = control_break.recv() => () }
        })
        .await
    })
}

#[cfg(not(windows))]
fn run(_config: AtlasReceiverConfig) -> Result<()> {
    bail!(
        "atlas native receive mode requires Windows; no CPU or single-window fallback is selected"
    )
}
