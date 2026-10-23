//! Compatibility entry point for the bounded native media diagnostic.
#[cfg(any(windows, all(target_os = "linux", feature = "native-nvenc")))]
fn main() -> anyhow::Result<()> {
    viewflowd::coded_peer::run_from_args(std::env::args().skip(1))
}

#[cfg(not(any(windows, all(target_os = "linux", feature = "native-nvenc"))))]
fn main() -> anyhow::Result<()> {
    anyhow::bail!("coded media requires Windows or Linux with --features native-nvenc")
}
