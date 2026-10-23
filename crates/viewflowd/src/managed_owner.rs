//! GUI-owned services must not outlive their launching application.
//! Standalone CLI services (without VIEWFLOW_OWNER_PID) are unaffected.
#[cfg(unix)]
#[allow(unsafe_code)] // Only pointer-free getppid/getpid and signals to this process.
pub fn watch() -> anyhow::Result<()> {
    use std::time::Duration;
    let Some(value) = std::env::var_os("VIEWFLOW_OWNER_PID") else {
        return Ok(());
    };
    let owner: libc::pid_t = value
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("invalid owner PID"))?
        .parse()?;
    anyhow::ensure!(owner > 1, "invalid owner PID");
    std::thread::Builder::new()
        .name("managed-owner".into())
        .spawn(move || {
            // getppid changes on reparenting, so PID reuse cannot keep an orphan alive.
            while unsafe { libc::getppid() } == owner {
                std::thread::sleep(Duration::from_millis(250));
            }
            eprintln!("managed service owner exited; shutting down");
            unsafe {
                libc::kill(libc::getpid(), libc::SIGINT);
            }
            // Only owner death starts this shutdown watchdog; normal sessions have
            // no deadline. Allow peers to close QUIC and native children first.
            std::thread::sleep(Duration::from_secs(5));
            unsafe {
                libc::kill(libc::getpid(), libc::SIGTERM);
            }
            std::thread::sleep(Duration::from_secs(2));
            unsafe {
                libc::kill(libc::getpid(), libc::SIGKILL);
            }
        })?;
    Ok(())
}

#[cfg(not(unix))]
pub fn watch() -> anyhow::Result<()> {
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    #[test]
    #[allow(unsafe_code)] // Test-only ignored signals exercise forced orphan cleanup.
    fn owner_fixture() {
        if std::env::var_os("VIEWFLOW_OWNER_TEST").is_none() {
            return;
        }
        if std::env::var("VIEWFLOW_OWNER_TEST").as_deref() == Ok("stubborn") {
            unsafe {
                libc::signal(libc::SIGINT, libc::SIG_IGN);
                libc::signal(libc::SIGTERM, libc::SIG_IGN);
            }
        }
        super::watch().unwrap();
        println!("owner-fixture-ready");
        std::thread::sleep(std::time::Duration::from_secs(60));
        panic!("orphan service survived");
    }
}
