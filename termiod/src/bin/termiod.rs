//! termiod — durable session host.
//!
//! Architecture (three parts): **host** · **protocol** · **clients**.
//! `termiod serve` is the host and the only thing this binary does; every
//! client verb a person or a machine runs is `termio`'s. Detach never kills a
//! session. Local = remote to localhost over a Unix socket.
//!
//! See `ARCHITECTURE.md` and `README.md`.

use anyhow::{bail, Result};
use clap::{Parser, Subcommand};
use std::net::SocketAddr;
use termiod::{client, daemon, handoff, lifecycle, wss};

#[derive(Parser)]
#[command(
    name = "termiod",
    version = lifecycle::BUILD_VERSION,
    about = "Durable session host — viewers attach; detach ≠ kill",
    long_about = "termiod is a session host (not a window manager).\n\
A session lives in the host; Mac/iOS/CLI only attach.\n\
See ARCHITECTURE.md.",
    after_help = "Everything else is `termio`: `termio server …` (with `--host` for another machine), `termio pair`."
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run the session host in the foreground (usually auto-started).
    Serve {
        /// Also accept WebSocket clients on this address (default port 8790).
        ///
        /// Loopback only — 127.0.0.0/8 or ::1. `0.0.0.0`, `[::]`, a LAN
        /// address and a hostname that resolves off loopback are all refused.
        /// Put TLS in front with Tailscale Serve or Caddy; termiod never
        /// terminates it. Needs a token from `termio pair`.
        #[arg(long, value_name = "ADDR", value_parser = wss::parse_bind)]
        wss: Option<SocketAddr>,

        /// Browser origin allowed on the WebSocket. Repeatable, or comma-separated.
        ///
        /// Required in front of a TLS terminator: the default same-origin check
        /// compares the page's Origin against a loopback Host and refuses.
        #[arg(long, value_name = "URL", value_parser = wss::parse_origin, value_delimiter = ',')]
        wss_origin: Vec<wss::Origin>,

        /// Adopt the sessions on this descriptor instead of starting empty.
        ///
        /// Set by a daemon replacing its own image (`termio server handoff`) and by
        /// nothing else: the number means something only inside the process
        /// that wrote it, which is the same process, on the far side of an
        /// `execve`.
        #[arg(long = "handoff", value_name = "FD", hide = true)]
        handoff_fd: Option<std::os::fd::RawFd>,

        /// Let the machine idle-sleep even while an agent is working or
        /// waiting on its user.
        ///
        /// By default (macOS, on AC power only) the daemon renews a short
        /// `caffeinate` assertion while any session is busy, so the box stays
        /// reachable for the phone that has to answer a waiting agent. The
        /// display sleeps either way. `TERMIOD_KEEP_AWAKE=off` in the daemon's
        /// environment does the same as this flag.
        #[arg(long)]
        no_keep_awake: bool,
    },

    /// The SSH pipe released apps open: `ssh <host> termiod stdio`. Kept
    /// under the old name so an app from before `termio stdio` still reaches
    /// a box a newer app has upgraded.
    #[command(hide = true)]
    Stdio,

    /// The daemon binary's own `status --json`, which the deploy loop reads
    /// when the client beside it cannot answer: a box from before the client
    /// took the verbs, or a staged client that is broken. Without it the loop
    /// would misread a new daemon as one too old to have `status`.
    #[command(hide = true)]
    Status {
        #[arg(long)]
        json: bool,
    },

    /// The question a running daemon asks a binary before handing off to it:
    /// which handoff contract it speaks. Asked of every build, old and new, so
    /// the spelling never changes. Hidden because only a daemon asks it.
    #[command(hide = true)]
    Handoff {
        #[arg(long)]
        probe: bool,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Serve {
            wss,
            wss_origin,
            handoff_fd,
            no_keep_awake,
        } => {
            let keep_awake = !no_keep_awake
                && !matches!(
                    std::env::var("TERMIOD_KEEP_AWAKE").as_deref(),
                    Ok("off") | Ok("false") | Ok("0")
                );
            daemon::serve(wss, wss_origin, handoff_fd, keep_awake).await
        }
        Cmd::Stdio => client::stdio().await,
        Cmd::Status { json } => {
            let status = lifecycle::status().await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&status)?);
            } else {
                lifecycle::print_status(&status);
            }
            Ok(())
        }
        Cmd::Handoff { probe: true } => {
            println!("{}", handoff::probe_token());
            Ok(())
        }
        Cmd::Handoff { probe: false } => {
            bail!("handing off is `termio server handoff` now")
        }
    }
}
