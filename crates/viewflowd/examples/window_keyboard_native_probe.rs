//! Explicit owned-widget native keyboard diagnostic, not QUIC/hardware acceptance.
#[cfg(not(target_os = "linux"))]
fn main() {
    panic!("Linux only");
}

#[cfg(target_os = "linux")]
#[tokio::main(flavor = "current_thread")]
#[allow(clippy::too_many_lines)] // One bounded diagnostic keeps capture cleanup around every input exit.
async fn main() -> anyhow::Result<()> {
    use anyhow::{Context, ensure};
    use std::{
        path::Path,
        time::{Duration, Instant},
    };
    use viewflow_hyprland::window_pointer_socket::{Connection, Event, Listener};
    use viewflow_hyprland::window_pointer_wire::{Outcome, Request};
    use viewflowd::hyprcapture_gpu_socket::GpuReceiveOutcome;
    use viewflowd::hyprcapture_stream::monotonic_now_ns;

    async fn exchange(
        connection: &mut Connection,
        request: Request,
        expected: Outcome,
    ) -> anyhow::Result<()> {
        connection.send(request)?;
        let until = Instant::now() + Duration::from_millis(300);
        loop {
            match connection.receive() {
                Ok(Event::Completed(outcome)) => {
                    ensure!(
                        outcome == expected,
                        "native result {outcome:?}, expected {expected:?}"
                    );
                    return Ok(());
                }
                Ok(Event::Metadata(_)) => {}
                Ok(Event::CaptureReceipt(_)) => {
                    anyhow::bail!("unexpected capture receipt during keyboard probe")
                }
                Ok(Event::Revoked { reason, .. }) => anyhow::bail!("native revoked: {reason:?}"),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error.into()),
            }
            ensure!(Instant::now() < until, "native confirmation timeout");
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }

    let args: Vec<_> = std::env::args().skip(1).collect();
    ensure!(
        args.len() == 5,
        "usage: window_keyboard_native_probe ADDRESS COMPOSITOR_PID PROBE_PID NATIVE_SOCKET balanced|disconnect|deny|plain|ime"
    );
    ensure!(
        ["balanced", "disconnect", "deny", "plain", "ime"].contains(&args[4].as_str()),
        "unknown test mode"
    );
    let compositor: i32 = args[1].parse()?;
    let probe: u32 = args[2].parse()?;
    ensure!(compositor > 0 && probe > 0, "invalid process identity");
    let executable = std::fs::read_link(format!("/proc/{probe}/exe"))?;
    ensure!(
        executable.file_name() == Some(std::ffi::OsStr::new("viewflow_linux_pointer_probe")),
        "target is not the owned probe executable"
    );
    let cmdline = std::fs::read(format!("/proc/{probe}/cmdline"))?;
    let ime = args[4] == "ime";
    let observation_flag: &[u8] = if ime { b"--ime" } else { b"--keyboard" };
    ensure!(
        cmdline
            .split(|b| *b == 0)
            .any(|arg| arg == observation_flag),
        "probe keyboard observation not explicitly enabled"
    );
    let native_path = Path::new(&args[3]);
    let listener = Listener::bind(native_path, compositor)?;
    let mut stream = match viewflowd::hyprcapture_runtime::start_viewflow_gpu_stream(
        &args[0],
        5,
        u32::try_from(compositor)?,
        Duration::from_secs(2),
    )
    .await
    {
        Ok(stream) => stream,
        Err(error) => {
            std::fs::remove_file(native_path)?;
            return Err(error);
        }
    };
    let work = async {
        let until = Instant::now() + Duration::from_secs(3);
        let input = loop {
            ensure!(Instant::now() < until, "source binding timeout");
            match stream.receiver.recv_frame()? {
                GpuReceiveOutcome::Frame(frame) => {
                    let input = frame
                        .input_geometry()
                        .context("source lacks native input binding")?;
                    stream.receiver.release_after_source_reads(&frame)?;
                    break input;
                }
                GpuReceiveOutcome::WouldBlock => tokio::time::sleep(Duration::from_millis(1)).await,
                GpuReceiveOutcome::Disconnected => anyhow::bail!("capture disconnected"),
            }
        };
        ensure!(
            input.pid == u64::from(probe)
                && input.window == u64::from_str_radix(args[0].trim_start_matches("0x"), 16)?,
            "capture did not bind the owned probe"
        );
        let mut connection = loop {
            match listener.accept() {
                Ok(connection) => break connection,
                Err(error)
                    if error.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < until =>
                {
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
                Err(error) => return Err(error.into()),
            }
        };
        let begin = if args[4] == "deny" {
            Request::begin_buttons_wheel
        } else {
            Request::begin_direct_keyboard
        };
        exchange(
            &mut connection,
            begin(
                1,
                1,
                input.window,
                probe,
                monotonic_now_ns()? + 2_000_000_000,
                input.surface_extent,
                input.surface,
            )
            .map_err(|e| anyhow::anyhow!("native begin: {e:?}"))?,
            Outcome::Begun,
        )
        .await?;
        println!("native begin confirmed mode={} pid={probe}", args[4]);
        let mut sequence = 2;
        if ime {
            exchange(
                &mut connection,
                Request::motion(
                    sequence,
                    1,
                    monotonic_now_ns()? + 33_333_333,
                    [100.0, 120.0],
                )
                .map_err(|e| anyhow::anyhow!("native hover: {e:?}"))?,
                Outcome::MotionSent,
            )
            .await?;
            sequence += 1;
        }
        // Allow the owned widget to process its native focus notification.
        tokio::time::sleep(Duration::from_millis(if ime { 600 } else { 50 })).await;
        let pattern: &[(u16, u32)] = if ime {
            // Physical usages for n i h a o Space; source IME performs composition.
            &[
                (0x11, 1),
                (0x11, 2),
                (0x0c, 1),
                (0x0c, 2),
                (0x0b, 1),
                (0x0b, 2),
                (4, 1),
                (4, 2),
                (0x12, 1),
                (0x12, 2),
                (0x2c, 1),
                (0x2c, 2),
            ]
        } else if args[4] == "deny" {
            &[(4, 1)]
        } else if args[4] == "disconnect" {
            &[(0xe1, 1), (4, 1)]
        } else if args[4] == "plain" {
            &[(4, 1), (4, 2)]
        } else {
            &[(0xe1, 1), (4, 1), (4, 2), (0xe1, 2)]
        };
        for &(usage, state) in pattern {
            exchange(
                &mut connection,
                Request::key(
                    sequence,
                    1,
                    monotonic_now_ns()? + 33_333_333,
                    [7, usage],
                    state,
                    false,
                )
                .map_err(|e| anyhow::anyhow!("native key: {e:?}"))?,
                if args[4] == "deny" {
                    Outcome::Rejected
                } else {
                    Outcome::KeySent
                },
            )
            .await?;
            sequence += 1;
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        if ime {
            // Verify that a subsequent admitted motion can reacquire only the
            // same source target after a stationary popup recheck cleared focus.
            exchange(
                &mut connection,
                Request::motion(
                    sequence,
                    1,
                    monotonic_now_ns()? + 33_333_333,
                    [200.0, 300.0],
                )
                .map_err(|e| anyhow::anyhow!("native post-IME motion: {e:?}"))?,
                Outcome::MotionSent,
            )
            .await?;
            sequence += 1;
        }
        if args[4] != "disconnect" {
            exchange(
                &mut connection,
                Request::end(sequence, 1).map_err(|e| anyhow::anyhow!("native end: {e:?}"))?,
                Outcome::Ended,
            )
            .await?;
        }
        connection.close();
        tokio::time::sleep(Duration::from_millis(150)).await;
        println!(
            "native pattern done mode={}; app witness remains the delivery evidence",
            args[4]
        );
        Ok::<_, anyhow::Error>(())
    }
    .await;
    let stopped = stream.stop_stream(Duration::from_secs(2)).await;
    let removed = std::fs::remove_file(native_path);
    stopped.context("native probe capture stop")?;
    removed.context("remove owned native socket")?;
    work
}
