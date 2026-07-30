//! termiod — durable session host (POC).
//!
//! Architecture (three parts): **host** · **protocol** · **clients**.
//! `termiod serve` is the host; other subcommands are reference clients
//! (or SSH transport helpers). Detach never kills a session.
//! Local = remote to localhost over a Unix socket.
//!
//! See `ARCHITECTURE.md` and `README.md`.

mod client;
mod daemon;
mod paths;
mod protocol;
mod pty;
mod remote;
mod session;

use anyhow::Result;
use clap::{Parser, Subcommand};
use protocol::CreateSpec;

#[derive(Parser)]
#[command(
    name = "termiod",
    version,
    about = "Durable session host — viewers attach; detach ≠ kill (#164 POC)",
    long_about = "termiod is a session host (not a window manager).\n\
A session lives in the host; Mac/iOS/CLI only attach.\n\
Local: Unix socket. Remote: SSH pipe to the same host binary.\n\
See ARCHITECTURE.md."
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run the session host in the foreground (usually auto-started).
    Serve,

    /// Create a new session and print its id.
    Create {
        /// Human name for the session (defaults to the id).
        #[arg(long)]
        name: Option<String>,
        /// Working directory for the session's process.
        #[arg(long)]
        cwd: Option<String>,
        /// Program + args to run. Empty ⇒ your login shell. Put after `--`.
        #[arg(last = true)]
        argv: Vec<String>,
    },

    /// List sessions.
    List {
        /// Emit JSON instead of a table.
        #[arg(long)]
        json: bool,
    },

    /// Kill a session (by id or name) and its process group.
    Kill {
        /// Session id or name.
        target: String,
    },

    /// Inject input into a session without attaching.
    Send {
        /// Session id or name.
        target: String,
        /// Text to inject.
        text: Vec<String>,
        /// Do not append a newline (Enter) after the text.
        #[arg(long)]
        no_enter: bool,
    },

    /// Attach to a session interactively (creating it if missing).
    Attach {
        /// Session id or name to attach to / create.
        target: String,
        /// Working directory if the session is created.
        #[arg(long)]
        cwd: Option<String>,
        /// Do not create the session if it does not already exist.
        #[arg(long)]
        no_create: bool,
        /// Program + args if the session is created. Put after `--`.
        #[arg(last = true)]
        argv: Vec<String>,
    },

    /// Remote (SSH) deploy and attach — see `termiod remote --help`.
    Remote {
        #[command(subcommand)]
        cmd: remote::RemoteCmd,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Serve => daemon::serve().await,

        Cmd::Create { name, cwd, argv } => {
            let (rows, cols) = client::term_size();
            let spec = CreateSpec {
                name,
                cwd,
                argv,
                env: Vec::new(),
                rows,
                cols,
            };
            let id = client::create(spec).await?;
            println!("{id}");
            Ok(())
        }

        Cmd::List { json } => {
            let sessions = client::list().await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&sessions)?);
            } else if sessions.is_empty() {
                println!("no sessions");
            } else {
                println!(
                    "{:<10} {:<14} {:>6} {:>7} {:>4}  COMMAND",
                    "ID", "NAME", "PID", "CLIENTS", "SIZE"
                );
                for s in sessions {
                    println!(
                        "{:<10} {:<14} {:>6} {:>7} {:>3}x{:<3} {}",
                        s.id, s.name, s.pid, s.clients, s.rows, s.cols, s.command
                    );
                }
            }
            Ok(())
        }

        Cmd::Kill { target } => {
            client::kill(&target).await?;
            eprintln!("killed {target}");
            Ok(())
        }

        Cmd::Send {
            target,
            text,
            no_enter,
        } => {
            let mut data = text.join(" ").into_bytes();
            if !no_enter {
                data.push(b'\r');
            }
            client::send(&target, data).await?;
            Ok(())
        }

        Cmd::Attach {
            target,
            cwd,
            no_create,
            argv,
        } => {
            let create_if_missing = if no_create {
                None
            } else {
                let (rows, cols) = client::term_size();
                Some(CreateSpec {
                    name: Some(target.clone()),
                    cwd,
                    argv,
                    env: Vec::new(),
                    rows,
                    cols,
                })
            };
            client::attach(&target, create_if_missing).await
        }

        Cmd::Remote { cmd } => remote::run(cmd).await,
    }
}
