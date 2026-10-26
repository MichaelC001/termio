//! `termio server …` and `termio pair`: the client verbs that act on a
//! machine's daemon. They lived on `termiod` until the daemon was cut down to
//! `serve`; every verb a person or a control plane runs is `termio`'s now, the
//! way `docker` holds every verb and `dockerd` only runs.
//!
//! `--host` makes every verb act on another machine, the way Rex's `--server`
//! does: `deploy` runs its loop from here, and every other verb runs as
//! `termio server <verb>` on that machine over the user's own `ssh`.

use anyhow::{bail, Result};
use clap::{Args, Subcommand};
use std::path::PathBuf;

use crate::protocol::CreateSpec;
use crate::{agent, client, lifecycle, log, remote, service, tailnet, wss};

#[derive(Args)]
#[command(after_long_help = SERVER_EXAMPLES)]
pub struct ServerArgs {
    /// Act on the termiod of this SSH host (an alias from `~/.ssh/config`, or
    /// user@host) instead of this machine's.
    #[arg(short = 'H', long, global = true, value_name = "HOST")]
    host: Option<String>,

    #[command(subcommand)]
    cmd: ServerCmd,
}

const SERVER_EXAMPLES: &str = "\
Examples:
  termio server status
  termio server logs -f
  termio server ls
  termio server attach build -- npm run dev
  termio server -H mybox deploy
  termio server -H mybox attach api
  termio server -H mybox tailscale on";

#[derive(Subcommand)]
pub enum ServerCmd {
    /// What this machine has: the daemon binary, the daemon, its sessions.
    ///
    /// Read-only, one connection.
    ///
    /// The daemon's version comes from the daemon, not from the file on disk:
    /// the two differ exactly when an update is staged and not yet running.
    Status {
        #[arg(long)]
        json: bool,
    },

    /// Print the daemon's log — what it recorded while nobody was attached.
    Logs {
        /// Print the path and exit, for piping into an editor or a bug report.
        #[arg(long)]
        path: bool,

        /// Keep printing as the daemon writes, like `tail -f`.
        #[arg(short, long)]
        follow: bool,

        /// How many trailing lines to print (default 200; 0 for the whole file).
        #[arg(short = 'n', long, default_value_t = 200)]
        lines: usize,
    },

    /// Ask the daemon to stop.
    ///
    /// Declines while a command is running or an agent is mid-task, and names
    /// the sessions; `--force` stops it regardless.
    /// A client attached to an idle prompt does not hold it up.
    ///
    /// The daemon is found by the credential on its socket, never by its
    /// command line, so a second daemon someone runs by hand on another socket
    /// is never the one stopped. Exit 3 means "in use", not failure.
    Stop {
        /// Stop even while work is in progress. Every session ends.
        #[arg(long)]
        force: bool,
        #[arg(long)]
        json: bool,
    },

    /// Install or update the daemon, and check it answers.
    ///
    /// One loop for every state the machine can be in: nothing installed, an
    /// older binary, a newer binary the daemon has not picked up. It asks the
    /// old daemon to hand off or stop when it is idle, checks the new one
    /// answers, and puts the previous binary back if it does not. Running it
    /// again is the recovery from any outcome. With `--host` the loop runs from
    /// here and copies this build to that machine over `ssh`.
    Deploy {
        /// Stop the old daemon even while its sessions have work in progress.
        #[arg(long)]
        force: bool,
        /// Put the binary in place and leave the running daemon alone.
        #[arg(long)]
        stage_only: bool,
        /// Upgrade only if the daemon can hand off in place: one that cannot
        /// and holds any live session is left running and reported as staged,
        /// never stopped. For automatic callers with no user behind them.
        #[arg(long, conflicts_with = "force", conflicts_with = "stage_only")]
        handoff_only: bool,
        /// Emit the outcome as one JSON document on stdout.
        #[arg(long)]
        json: bool,
        /// With `--host`: send this prebuilt daemon (and the `termio` beside
        /// it) instead of the bundled or cross-compiled build.
        #[arg(long, value_name = "PATH")]
        bin: Option<PathBuf>,
        /// With `--host`: the Rust target triple, instead of asking `uname`.
        #[arg(long, value_name = "TRIPLE")]
        target: Option<String>,
    },

    /// Put the machine on your tailnet with Tailscale built in.
    ///
    /// Paired Macs and iPhones then reach it with no Tailscale install there.
    Tailscale {
        #[command(subcommand)]
        cmd: TailscaleCmd,
    },

    /// Keep the daemon running across logins and crashes.
    ///
    /// launchd on macOS, systemd --user on Linux.
    Service {
        #[command(subcommand)]
        cmd: service::ServiceCmd,
    },

    /// Replace the running daemon's binary without stopping it.
    ///
    /// The host `execve`s the new binary, keeping its pid, its children and
    /// every PTY, so nothing running in a session notices. `deploy` runs it
    /// as its first rung; run it by hand after replacing the binary yourself.
    Handoff {
        /// Emit the result as JSON — pid, version, sessions.
        #[arg(long)]
        json: bool,
        /// Hand off to this binary instead of the daemon beside this client.
        #[arg(long, value_name = "PATH")]
        binary: Option<std::path::PathBuf>,
    },

    /// List every session the daemon hosts, across projects.
    #[command(visible_alias = "ls")]
    List {
        /// Emit JSON instead of a table.
        #[arg(long)]
        json: bool,
    },

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

    /// Attach to a session (interactively by default, or as an observer).
    Attach {
        /// Session id or name to attach to / create.
        target: String,
        /// Working directory if the session is created.
        #[arg(long)]
        cwd: Option<String>,
        /// Do not create the session if it does not already exist.
        #[arg(long)]
        no_create: bool,
        /// Stream output without a tty, stdin, resize handling, or write access.
        #[arg(long)]
        observe: bool,
        /// Use capability-gated dirty-row grid diffs instead of downstream PTY
        /// bytes. Opt-in on every transport: measured 8.6× *more* bytes than
        /// raw for scrolling output, since every row goes dirty and each cell
        /// costs 16 bytes. Its value is catch-up and sparse TUI redraw.
        #[arg(long)]
        grid_diff: bool,
        /// Program + args if the session is created. Put after `--`.
        #[arg(last = true)]
        argv: Vec<String>,
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

    /// Stream a workspace's filesystem changes from the host (§C.10).
    ///
    /// The host owns the watch; this is a resumable subscriber. Stop it, change
    /// the tree, restart with `--since <seq>` and the missed batches replay —
    /// or the host reports a gap when the cursor has aged out of its ring.
    #[command(hide = true)]
    Watch {
        /// Absolute workspace root to watch on the host.
        root: String,
        /// Resume from this seq instead of starting fresh.
        #[arg(long)]
        since: Option<u64>,
    },
}

#[derive(Subcommand)]
pub enum TailscaleCmd {
    /// Join the tailnet, printing a sign-in link the first time.
    ///
    /// Only the Tailscale account that signs in gets in, and each client still
    /// needs the pairing token. The setting survives restarts and reboots.
    On {
        /// The device name on the tailnet (default: termio).
        #[arg(long, value_name = "NAME")]
        hostname: Option<String>,
        /// Sign in with a one-time auth key from this file, or `-` for stdin,
        /// instead of a browser.
        #[arg(long, value_name = "FILE")]
        auth_key_file: Option<PathBuf>,
        /// Return at once instead of waiting for the sign-in.
        #[arg(long)]
        no_wait: bool,
    },
    /// Leave the tailnet until `on`. The machine stays signed in.
    Off,
    /// Sign the machine out of Tailscale and turn built-in Tailscale off.
    Logout,
    /// Show whether the machine is on the tailnet, and where clients reach it.
    Status {
        #[arg(long)]
        json: bool,
    },
}

pub async fn run(args: ServerArgs) -> Result<()> {
    match args.host {
        Some(host) => run_on_host(host, args.cmd).await,
        None => run_here(args.cmd).await,
    }
}

/// Every verb but `deploy` runs as the same `termio server` command on the
/// host, so a box answers with its own build's code. `deploy` cannot: it is
/// the thing that puts that build there.
async fn run_on_host(host: String, cmd: ServerCmd) -> Result<()> {
    match cmd {
        ServerCmd::Deploy {
            force,
            stage_only,
            handoff_only,
            json,
            bin,
            target,
        } => {
            let options = lifecycle::Options {
                force,
                stage_only,
                handoff_only,
            };
            let report = remote::deploy(host, bin, target, options).await?;
            print_report(&report, json)
        }
        ServerCmd::Attach { observe, .. } => {
            std::process::exit(remote::run_server_verb(&host, !observe, &verb_words()?)?)
        }
        _ => std::process::exit(remote::run_server_verb(&host, false, &verb_words()?)?),
    }
}

/// The words after `server`, without `--host`, as the user typed them — which
/// is what the host's own `termio server` should parse. Taken from argv rather
/// than rebuilt from the parsed command, so no flag can be dropped on the way.
fn verb_words() -> Result<Vec<String>> {
    verb_words_of(&std::env::args().collect::<Vec<String>>())
}

fn verb_words_of(argv: &[String]) -> Result<Vec<String>> {
    let Some(start) = argv.iter().skip(1).position(|word| word == "server") else {
        bail!("`--host` is only understood after `termio server`");
    };
    let mut words = Vec::new();
    let mut rest = argv[start + 2..].iter();
    let mut verbatim = false;
    while let Some(word) = rest.next() {
        if verbatim {
            words.push(word.clone());
            continue;
        }
        match word.as_str() {
            "--" => {
                verbatim = true;
                words.push(word.clone());
            }
            "-H" | "--host" => {
                rest.next();
            }
            _ if word.starts_with("--host=") => {}
            _ if word.starts_with("-H") && word.len() > 2 && !word.starts_with("--") => {}
            // Short flags combined into one word, `-fHbox`: everything from
            // the `H` on is the host. No other short flag of `server` takes a
            // value that could contain an `H`, except `-n`, which takes digits.
            _ if !word.starts_with("--") && word.starts_with('-') && word[1..].contains('H') => {
                let at = word.find('H').unwrap_or(word.len());
                let flags = &word[..at];
                if flags.len() > 1 {
                    words.push(flags.to_string());
                }
                // `-fH box`: the host is the next word.
                if at + 1 == word.len() {
                    rest.next();
                }
            }
            _ => words.push(word.clone()),
        }
    }
    Ok(words)
}

fn print_report(report: &lifecycle::Report, json: bool) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(report)?);
    } else {
        println!("{}", report.describe());
    }
    let code = report.exit_code();
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}

async fn run_here(cmd: ServerCmd) -> Result<()> {
    match cmd {
        ServerCmd::Status { json } => {
            let status = lifecycle::status().await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&status)?);
            } else {
                lifecycle::print_status(&status);
            }
            Ok(())
        }

        ServerCmd::Logs {
            path,
            follow,
            lines,
        } => log::show(path, follow, lines).await,

        ServerCmd::Stop { force, json } => {
            let outcome = lifecycle::stop(force).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&outcome)?);
            } else {
                println!("{}", outcome.message);
                for session in &outcome.busy {
                    println!("  • {} — {}", session.name, session.command);
                }
            }
            if !outcome.stopped {
                std::process::exit(lifecycle::EXIT_BUSY);
            }
            Ok(())
        }

        ServerCmd::Deploy {
            force,
            stage_only,
            handoff_only,
            json,
            bin,
            target,
        } => {
            // A global flag set on `server` is not visible to clap's `requires`
            // on the verb, so the pairing is checked here.
            if bin.is_some() || target.is_some() {
                bail!("--bin and --target choose what to send to another machine; add --host <HOST>");
            }
            let options = lifecycle::Options {
                force,
                stage_only,
                handoff_only,
            };
            let report =
                lifecycle::reconcile(&lifecycle::LocalNode, lifecycle::BUILD_VERSION, options)
                    .await;
            print_report(&report, json)
        }

        ServerCmd::Tailscale { cmd } => match cmd {
            TailscaleCmd::On {
                hostname,
                auth_key_file,
                no_wait,
            } => {
                tailnet::run_on(tailnet::OnOptions {
                    hostname,
                    auth_key_file,
                    no_wait,
                })
                .await
            }
            TailscaleCmd::Off => tailnet::run_off(),
            TailscaleCmd::Logout => tailnet::run_logout().await,
            TailscaleCmd::Status { json } => tailnet::run_status(json),
        },

        ServerCmd::Service { cmd } => service::run(cmd),

        ServerCmd::Handoff { json, binary } => lifecycle::run_handoff(json, binary).await,

        ServerCmd::List { json } => {
            let sessions = client::list().await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&sessions)?);
                return Ok(());
            }
            if sessions.is_empty() {
                println!("no sessions");
                return Ok(());
            }
            println!(
                "{:<10} {:<14} {:>6} {:>7} {:>4}  COMMAND",
                "ID", "NAME", "PID", "CLIENTS", "SIZE"
            );
            for s in sessions {
                println!(
                    "{:<10} {:<14} {:>6} {:>7} {:>3}x{:<3} {}",
                    s.id, s.name, s.pid, s.attached_clients, s.rows, s.cols, s.command
                );
            }
            Ok(())
        }

        ServerCmd::Create { name, cwd, argv } => {
            let (rows, cols) = client::term_size();
            let spec = CreateSpec {
                name,
                cwd,
                argv,
                command: None,
                env: Vec::new(),
                rows,
                cols,
                workstream: None,
                place: None,
            };
            let id = client::create(spec).await?;
            println!("{id}");
            Ok(())
        }

        ServerCmd::Attach {
            target,
            cwd,
            no_create,
            observe,
            grid_diff,
            argv,
        } => {
            let create_if_missing = if no_create {
                None
            } else {
                let (rows, cols) = if observe {
                    (24, 80)
                } else {
                    client::term_size()
                };
                Some(CreateSpec {
                    name: Some(target.clone()),
                    cwd,
                    argv,
                    command: None,
                    env: Vec::new(),
                    rows,
                    cols,
                    workstream: None,
                    place: None,
                })
            };
            if observe {
                client::observe(&target, create_if_missing, grid_diff).await
            } else {
                client::attach(&target, create_if_missing, grid_diff, None).await
            }
        }

        ServerCmd::Kill { target } => {
            client::kill(&target).await?;
            eprintln!("killed {target}");
            Ok(())
        }

        ServerCmd::Send {
            target,
            text,
            no_enter,
        } => {
            let mut data = text.join(" ").into_bytes();
            if !no_enter {
                data.push(b'\r');
            }
            client::send(&target, data).await
        }

        ServerCmd::Watch { root, since } => client::watch(&root, since).await,
    }
}

/// `termio pair` — the pairing token that lets a phone or a browser attach.
///
/// The token authenticates the WebSocket pipe. It is not the session write
/// token, and it never expires: `--rotate` is the only revocation.
#[derive(Args)]
pub struct PairArgs {
    /// Emit the invite as JSON — url, token, host_id, proto.
    #[arg(long)]
    json: bool,
    /// Print the invite as a QR code for a phone to scan off this terminal.
    #[arg(long)]
    qr: bool,
    /// Replace the token. Attached clients detach; no session is killed.
    #[arg(long)]
    rotate: bool,
    /// Stop listening for WebSocket clients on the next start.
    #[arg(long)]
    wss_off: bool,
    /// The URL this box is reachable at, when it is not the daemon's own
    /// `--wss-origin` — a tunnel, or a proxy mounted under a path.
    #[arg(long, value_name = "URL")]
    url: Option<String>,
}

pub fn pair(args: PairArgs) -> Result<()> {
    wss::run_pair(wss::PairOptions {
        json: args.json,
        qr: args.qr,
        rotate: args.rotate,
        wss_off: args.wss_off,
        url: args.url,
    })
}

/// `termio agent install` — termio's agent integration in this machine's agent
/// configs.
///
/// The daemon owns the files, so it decides what goes in them: it reads the
/// same agent manifests the Mac app reads, works out which agent CLIs are
/// actually here, and merges. The client only says which agents the user has
/// enabled.
#[derive(Args)]
pub struct InstallArgs {
    /// Only these agent ids (repeatable). Default: every agent in the catalog
    /// whose CLI is installed here.
    #[arg(long)]
    agent: Vec<String>,
    /// Install the skill but not the hooks.
    #[arg(long)]
    no_hooks: bool,
    /// Install the hooks but not the skill.
    #[arg(long)]
    no_skills: bool,
    /// Install this Mac's skill payload instead of a box's. Hooks are identical
    /// either way — they all report to this daemon.
    #[arg(long)]
    this_mac: bool,
    /// Emit the per-agent results as JSON.
    #[arg(long)]
    json: bool,
}

pub async fn install_agents(args: InstallArgs) -> Result<()> {
    use agent::install::{HalfAction, InstallRequest, Reporter};
    let request = InstallRequest::new(
        (!args.agent.is_empty()).then_some(args.agent),
        if args.no_hooks { HalfAction::Leave } else { HalfAction::Install },
        if args.no_skills { HalfAction::Leave } else { HalfAction::Install },
        if args.this_mac { Reporter::ThisMac } else { Reporter::Device },
        Default::default(),
    );
    print_install(request, args.json).await
}

/// `termio agent uninstall` — remove every agent integration termio installed
/// on this machine.
pub async fn uninstall_agents(json: bool) -> Result<()> {
    use agent::install::{HalfAction, InstallRequest, Reporter};
    let request = InstallRequest::new(
        None,
        HalfAction::Remove,
        HalfAction::Remove,
        Reporter::Device,
        Default::default(),
    );
    print_install(request, json).await
}

async fn print_install(request: agent::install::InstallRequest, json: bool) -> Result<()> {
    use agent::install::{HalfAction, InstallStatus};
    let removing = request.hooks == HalfAction::Remove && request.skills == HalfAction::Remove;
    let results = client::install_agents(request).await?;
    if json {
        println!("{}", serde_json::to_string_pretty(&results)?);
        return Ok(());
    }
    if results.is_empty() {
        // Removal sweeps every directory termio has ever written into and has
        // nothing per-agent to report; an install with nothing to report found
        // no agent on this box at all.
        println!(
            "{}",
            if removing {
                "removed every agent integration termio installed"
            } else {
                "no agent on this box declares an integration to install"
            }
        );
        return Ok(());
    }
    for result in &results {
        let mark = match result.status {
            InstallStatus::Installed => "ok",
            InstallStatus::Failed => "failed",
            InstallStatus::Skipped => "skipped",
        };
        print!("{:<8} {:<14} {:<6} {}", mark, result.name, result.kind, result.path);
        match &result.detail {
            Some(detail) => println!(" — {detail}"),
            None => println!(),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(line: &str) -> Vec<String> {
        let argv: Vec<String> = line.split(' ').map(str::to_string).collect();
        verb_words_of(&argv).expect("a server command")
    }

    /// The host's own `termio server` must parse exactly what was typed, less
    /// the host: every spelling of `--host` goes, and nothing after `--` is
    /// touched, even a `-H`.
    #[test]
    fn the_host_is_the_only_thing_removed() {
        assert_eq!(words("termio server -H box status --json"), ["status", "--json"]);
        assert_eq!(words("termio server status --host box"), ["status"]);
        assert_eq!(words("termio server --host=box ls"), ["ls"]);
        assert_eq!(words("termio server -Hbox logs -n 5"), ["logs", "-n", "5"]);
        assert_eq!(words("termio server logs -fHbox"), ["logs", "-f"]);
        assert_eq!(words("termio server logs -fH box -n 5"), ["logs", "-f", "-n", "5"]);
        assert_eq!(
            words("termio server -H box send server -- -H x"),
            ["send", "server", "--", "-H", "x"]
        );
    }
}
