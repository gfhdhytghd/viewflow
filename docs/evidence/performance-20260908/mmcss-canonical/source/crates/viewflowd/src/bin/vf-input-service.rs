#[cfg(windows)]
fn main() -> std::io::Result<()> {
    viewflow_platform::windows_input_service::run()
}
#[cfg(not(windows))]
fn main() {
    eprintln!("vf-input-service requires Windows");
    std::process::exit(1);
}
