use anyhow::Result;
use viewflowd::{USAGE, parse_args, run};

#[tokio::main]
async fn main() -> Result<()> {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    #[cfg(target_os = "macos")]
    if arguments.as_slice() == ["--macos-input-status"] {
        println!(
            "{}",
            serde_json::json!({
                "event_post_authorized": viewflow_platform::macos_input::MacOsInputBackend::is_authorized(),
                "cursor": viewflow_platform::macos_input::observe_cursor().ok(),
                "input_posted": false,
            })
        );
        return Ok(());
    }
    if arguments
        .first()
        .is_some_and(|value| matches!(value.as_str(), "-h" | "--help"))
    {
        println!("{USAGE}");
        return Ok(());
    }

    let command = parse_args(arguments).inspect_err(|_| eprintln!("{USAGE}"))?;
    run(command).await
}
