use anyhow::Result;
use viewflowd::{USAGE, parse_args, run};

#[tokio::main]
async fn main() -> Result<()> {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
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
