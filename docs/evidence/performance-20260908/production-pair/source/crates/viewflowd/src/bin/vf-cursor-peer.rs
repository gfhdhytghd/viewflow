#[cfg(target_os = "linux")]
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.first().is_some_and(|arg| arg == "validate-send") {
        anyhow::ensure!(
            args.len() == 3 && args[1] == "--config",
            "usage: vf-cursor-peer validate-send --config JSON"
        );
        viewflowd::atlas_peer::AtlasSourceConfig::load(std::path::Path::new(&args[2]))?;
        println!("cursor-config-valid");
        return Ok(());
    }
    if args.first().is_some_and(|arg| arg == "send") {
        args.remove(0);
    }
    anyhow::ensure!(
        args.len() == 2 && args[0] == "--config",
        "usage: vf-cursor-peer --config JSON"
    );
    viewflowd::cursor_source::run(std::path::Path::new(&args[1])).await
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("vf-cursor-peer requires Linux");
}
