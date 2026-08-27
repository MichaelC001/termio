//! Remote sessions over **system SSH only** — no custom transport, no public
//! listener. The remote `termiod` owns the PTY; SSH is the transport and the
//! ACL. This covers issue #171 (deploy + attach) and #172 (`remote open`).
//!
//! The trick that makes this ~200 lines instead of a network stack: the daemon
//! auto-starts (detached via `setsid`) on the first client op. So
//! `ssh host termiod attach <id>` runs the *client* on the remote host, whose
//! stdin/stdout are the SSH channel; the daemon it starts survives the SSH
//! disconnect because it is in its own session. Detach ≠ kill, remotely, free.
//!
//! Installing and updating the daemon on a host is the lifecycle loop
//! (`lifecycle::reconcile`); this module is its ssh arm — [`SshNode`] — plus
//! the artifact selection: which of the bundled daemons a host gets.

use anyhow::{bail, Context, Result};
use clap::Subcommand;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use crate::lifecycle::{self, DaemonHello, Node, Options, Report, Run, Unreachable};

/// Where the binary is installed on the remote host. `$HOME` is expanded by
/// the remote shell. Overridable with `TERMIOD_REMOTE_BIN` for custom install
/// paths (and to point tests at a local binary).
pub fn remote_bin() -> String {
    std::env::var("TERMIOD_REMOTE_BIN").unwrap_or_else(|_| "$HOME/.local/bin/termiod".to_string())
}

/// SSH options shared by every outbound connection.
///
/// `ControlMaster` is the load-bearing one for cloud use: the first connection
/// to a host opens a master, and every later channel — another session, the
/// resource plane, a `list` — rides it for about one round trip instead of a
/// fresh TCP and key exchange. Zed does the same thing; unlike Zed we take the
/// user's own `ControlPath` when they have set one rather than overriding it.
pub fn ssh_multiplex_args() -> Vec<String> {
    let mut args = vec![
        "-o".into(),
        "ServerAliveInterval=15".into(),
        "-o".into(),
        "ControlMaster=auto".into(),
        "-o".into(),
        "ControlPersist=10m".into(),
    ];
    if std::env::var_os("TERMIOD_SSH_KEEP_CONTROLPATH").is_none() {
        if let Some(path) = control_path() {
            args.push("-o".into());
            args.push(format!("ControlPath={path}"));
        }
    }
    args
}

/// `%C` is a hash of (host, port, user), so one path template serves every
/// host without collisions.
fn control_path() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let dir = std::path::Path::new(&home).join(".termio").join("ssh");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("%C").display().to_string())
}

/// The options every non-interactive ssh here runs with. Nobody can answer a
/// prompt on these channels — the app runs them with no terminal at all — so
/// `BatchMode` turns a passphrase prompt into a prompt failure in a second,
/// and `ConnectTimeout` bounds a host that swallows the connect.
fn batch_args() -> Vec<String> {
    let mut args = vec![
        "-o".to_string(),
        "BatchMode=yes".to_string(),
        "-o".to_string(),
        "ConnectTimeout=10".to_string(),
    ];
    args.extend(ssh_multiplex_args());
    args
}

#[derive(Subcommand)]
pub enum RemoteCmd {
    /// Install or update `termiod` on a host over SSH — `termiod deploy --host`.
    Deploy {
        /// SSH host alias from `~/.ssh/config` (or user@host).
        host: String,
        /// Use this prebuilt binary instead of the bundled or cross-compiled one.
        #[arg(long)]
        bin: Option<String>,
        /// Force a Rust target triple instead of auto-detecting from `uname`.
        #[arg(long)]
        target: Option<String>,
        /// Stop the old daemon even while its sessions are in use.
        #[arg(long)]
        force: bool,
        /// Emit the outcome as one JSON document on stdout.
        #[arg(long)]
        json: bool,
    },

    /// List sessions on a remote host.
    List {
        host: String,
        #[arg(long)]
        json: bool,
    },

    /// Attach to (or create) a session on a remote host.
    Attach {
        host: String,
        /// Session id or name.
        target: String,
        /// Stream output without allocating an SSH tty or accepting input.
        #[arg(long)]
        observe: bool,
        /// Program + args if created. Put after `--`.
        #[arg(last = true)]
        argv: Vec<String>,
    },

    /// One-shot: ensure deployed, create a durable session, then attach (#172).
    Open {
        /// SSH host alias from `~/.ssh/config`.
        host: String,
        /// Remote working directory (default: `~`).
        #[arg(long)]
        cwd: Option<String>,
        /// Agent/shell to launch: `shell` (default), `claude`, `codex`, …
        #[arg(long, default_value = "shell")]
        agent: String,
        /// Session name (default: derived from agent).
        #[arg(long)]
        name: Option<String>,
        /// Skip the deploy check (assume `termiod` is already installed).
        #[arg(long)]
        no_deploy: bool,
    },
}

pub async fn run(cmd: RemoteCmd) -> Result<()> {
    match cmd {
        RemoteCmd::Deploy {
            host,
            bin,
            target,
            force,
            json,
        } => {
            let mut node = SshNode::new(host);
            node.prebuilt = bin.map(PathBuf::from);
            node.target = target;
            let report = reconcile(&node, Options { force, stage_only: false }).await;
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!("{}", report.describe());
            }
            let code = report.exit_code();
            if code != 0 {
                std::process::exit(code);
            }
            Ok(())
        }
        RemoteCmd::Open {
            host,
            cwd,
            agent,
            name,
            no_deploy,
        } => {
            if !no_deploy {
                // The same loop the app runs before an attach. A daemon left
                // staged behind busy sessions is still a working daemon, so
                // that is a note rather than a stop.
                let report = reconcile(&SshNode::new(host.clone()), Options::default()).await;
                match report.outcome {
                    lifecycle::Outcome::Current { .. } => {}
                    lifecycle::Outcome::Staged { .. } => eprintln!("{}", report.describe()),
                    _ => bail!("{}", report.describe()),
                }
            }
            tokio::task::spawn_blocking(move || open(&host, cwd.as_deref(), &agent, name.as_deref()))
                .await?
        }
        // These shell out to ssh; run them on a blocking thread so the async
        // runtime stays free.
        other => tokio::task::spawn_blocking(move || run_blocking(other)).await?,
    }
}

/// The lifecycle loop against a host, for the build this binary is.
pub async fn reconcile(node: &SshNode, options: Options) -> Report {
    lifecycle::reconcile(node, lifecycle::BUILD_VERSION, options).await
}

fn run_blocking(cmd: RemoteCmd) -> Result<()> {
    match cmd {
        RemoteCmd::List { host, json } => {
            let bin = remote_bin();
            let flag = if json { " --json" } else { "" };
            let status = ssh_interactive(&host, false, &format!("{bin} list{flag}"))?;
            std::process::exit(status);
        }
        RemoteCmd::Attach {
            host,
            target,
            observe,
            argv,
        } => {
            let remote = build_attach_cmd(&target, observe, &argv);
            let status = ssh_interactive(&host, !observe, &remote)?;
            std::process::exit(status);
        }
        RemoteCmd::Deploy { .. } | RemoteCmd::Open { .. } => {
            unreachable!("handled on the async path")
        }
    }
}

/// Build the remote `termiod attach` command line.
fn build_attach_cmd(target: &str, observe: bool, argv: &[String]) -> String {
    let bin = remote_bin();
    let mut s = format!("{bin} attach {}", shell_quote(target));
    if observe {
        s.push_str(" --observe");
    }
    if !argv.is_empty() {
        s.push_str(" --");
        for a in argv {
            s.push(' ');
            s.push_str(&shell_quote(a));
        }
    }
    s
}

fn open(host: &str, cwd: Option<&str>, agent: &str, name: Option<&str>) -> Result<()> {
    let bin = remote_bin();
    let argv: Vec<String> = match agent {
        "shell" | "" => Vec::new(),
        other => vec![other.to_string()],
    };
    let session_name = name.unwrap_or(if argv.is_empty() { "shell" } else { agent });

    // Create the durable session on the remote host.
    let mut create = format!("{bin} create --name {}", shell_quote(session_name));
    if let Some(dir) = cwd {
        create.push_str(&format!(" --cwd {}", shell_quote(dir)));
    }
    if !argv.is_empty() {
        create.push_str(" --");
        for a in &argv {
            create.push(' ');
            create.push_str(&shell_quote(a));
        }
    }
    let id = ssh_capture(host, &create)?.trim().to_string();
    if id.is_empty() {
        bail!("remote create returned no session id");
    }
    eprintln!("[remote {host}] created session {id} ({session_name}); attaching…");

    let remote = format!("{bin} attach {}", shell_quote(&id));
    let status = ssh_interactive(host, true, &remote)?;
    std::process::exit(status);
}

// MARK: The ssh arm of the lifecycle loop

/// A machine reached with the user's own `ssh`, as `~/.ssh/config` defines it.
/// The daemon installed is whichever of the bundled builds matches the box's
/// `uname`, or this very binary for another Mac.
pub struct SshNode {
    pub host: String,
    /// A binary to install instead of choosing one — the developer override.
    pub prebuilt: Option<PathBuf>,
    /// A Rust target triple instead of asking `uname`.
    pub target: Option<String>,
}

impl SshNode {
    pub fn new(host: String) -> SshNode {
        SshNode {
            host,
            prebuilt: None,
            target: None,
        }
    }

    fn ssh(&self) -> tokio::process::Command {
        let mut command = tokio::process::Command::new("ssh");
        command.args(batch_args());
        command
    }

    /// The directory the daemon lives in, spelled for the remote shell and for
    /// scp — which does not expand `$HOME`, but resolves a relative path
    /// against it.
    fn install_directory(&self) -> (String, String) {
        let binary = remote_bin();
        let directory = match binary.rsplit_once('/') {
            Some((directory, _)) if !directory.is_empty() => directory.to_string(),
            _ => "$HOME/.local/bin".to_string(),
        };
        let for_scp = directory
            .strip_prefix("$HOME/")
            .or_else(|| directory.strip_prefix("~/"))
            .map(str::to_string)
            .unwrap_or_else(|| directory.clone());
        (directory, for_scp)
    }
}

impl Node for SshNode {
    fn label(&self) -> String {
        self.host.clone()
    }

    fn binary(&self) -> String {
        remote_bin()
    }

    async fn run(&self, command: &str) -> Result<Run> {
        let output = self
            .ssh()
            .arg(&self.host)
            .arg(command)
            .output()
            .await
            .context("spawning ssh")?;
        let code = output.status.code().unwrap_or(1);
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        // 255 is ssh's own exit status — connection or authentication, never
        // the remote command's. It is the line between "unreachable" and
        // "reached, and this failed".
        if code == 255 {
            return Err(Unreachable(last_line(&stderr)).into());
        }
        Ok(Run {
            code,
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr,
        })
    }

    async fn put(&self, local: &Path, name: &str) -> Result<()> {
        let (directory, for_scp) = self.install_directory();
        let made = self.run(&format!("mkdir -p {directory}")).await?;
        if made.code != 0 {
            bail!("creating {directory} on {}: {}", self.host, last_line(&made.stderr));
        }
        eprintln!(
            "[deploy] copying {} → {}:{for_scp}/{name}",
            local.display(),
            self.host
        );
        let output = tokio::process::Command::new("scp")
            .args(batch_args())
            .arg(local)
            .arg(format!("{}:{for_scp}/{name}", self.host))
            .output()
            .await
            .context("spawning scp")?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if output.status.code() == Some(255) {
                return Err(Unreachable(last_line(&stderr)).into());
            }
            bail!("copying the binary to {}: {}", self.host, last_line(&stderr));
        }
        Ok(())
    }

    async fn artifact(&self) -> Result<PathBuf> {
        if let Some(prebuilt) = &self.prebuilt {
            return Ok(prebuilt.clone());
        }
        let target = match &self.target {
            Some(target) => target.clone(),
            None => {
                let uname = self.run("uname -sm").await?;
                if uname.code != 0 {
                    bail!("asking {} its uname: {}", self.host, last_line(&uname.stderr));
                }
                target_for_uname(uname.stdout.trim())?
            }
        };
        if let Some(path) = shipped_binary(&target) {
            eprintln!("[deploy] using the bundled {target} binary");
            return Ok(PathBuf::from(path));
        }
        let built = tokio::task::spawn_blocking(move || cross_compile(&target)).await??;
        Ok(PathBuf::from(built))
    }

    async fn hello(&self) -> Result<DaemonHello> {
        let mut child = self
            .ssh()
            .arg(&self.host)
            .arg(format!("{} stdio", remote_bin()))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .context("spawning ssh")?;
        let mut reader = child.stdout.take().context("ssh stdout")?;
        let mut writer = child.stdin.take().context("ssh stdin")?;
        let answer = tokio::time::timeout(
            Duration::from_secs(10),
            lifecycle::handshake(&mut reader, &mut writer),
        )
        .await;
        match answer {
            Ok(Ok(hello)) => Ok(hello),
            other => {
                // The remote binary's own words are the diagnosis — "Exec
                // format error" for a wrong slice, ssh's line for auth — so
                // they are read before the child is discarded.
                let _ = child.kill().await;
                let mut stderr = String::new();
                if let Some(mut stream) = child.stderr.take() {
                    use tokio::io::AsyncReadExt;
                    let _ = tokio::time::timeout(
                        Duration::from_secs(2),
                        stream.read_to_string(&mut stderr),
                    )
                    .await;
                }
                let reason = match other {
                    Ok(Err(error)) => format!("{error:#}"),
                    _ => "no protocol reply within 10s".to_string(),
                };
                let detail = last_line(&stderr);
                if detail == "no output" {
                    bail!("{reason}")
                }
                bail!("{reason} ({detail})")
            }
        }
    }
}

fn last_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .last()
        .unwrap_or("no output")
        .to_string()
}

/// A daemon for `target` shipped beside this executable.
///
/// This is what makes deploying possible for someone who installed Termio rather
/// than cloning it: `cross_compile` below needs cargo, the musl target, and this
/// crate's source tree at the path baked into it, none of which a `.app` from the
/// DMG has. `scripts/build-app.sh` puts both Linux binaries in `Contents/Resources`
/// next to the daemon that reads this, so the common case is a copy.
///
/// A Mac takes the daemon that is *already* there — the one running this code. It
/// is built universal for the same reason the app is, so one file serves both
/// architectures and there is nothing per-target to ship. Sent as a plain copy:
/// `scp` sets no quarantine attribute, so a Developer-ID-signed binary landing on
/// another Mac runs without a Gatekeeper prompt.
///
/// Found by the executable's own directory rather than by a bundle path or an
/// environment variable: the daemon is run by absolute path out of whatever
/// shipped it, and this keeps that the single source of truth. Building from the
/// repo puts no siblings there, so a contributor still gets `cross_compile` — the
/// path that proves the source tree actually cross-builds.
fn shipped_binary(target: &str) -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    if target.contains("apple-darwin") {
        return exe.to_str().map(str::to_owned);
    }
    let candidate = exe.parent()?.join(format!("termiod-{target}"));
    candidate
        .is_file()
        .then(|| candidate.to_string_lossy().into_owned())
}

/// The `uname -sm` half of target detection, split out so the mapping can be
/// checked without a machine to ask.
///
/// Macs are here because a device is a machine the user owns, and plenty of them
/// are a Mac mini or a Studio on the same desk — "remote" describes the road, not
/// the thing at the end of it. The daemon's own build already covers Darwin (it is
/// what runs local sessions), so supporting it costs a branch here rather than a
/// new artifact.
fn target_for_uname(uname: &str) -> Result<String> {
    let arm = uname.contains("aarch64") || uname.contains("arm64");
    let intel = uname.contains("x86_64") || uname.contains("amd64");
    let target = match (uname.split_whitespace().next(), arm, intel) {
        (Some("Linux"), true, _) => "aarch64-unknown-linux-musl",
        (Some("Linux"), _, true) => "x86_64-unknown-linux-musl",
        (Some("Darwin"), true, _) => "aarch64-apple-darwin",
        (Some("Darwin"), _, true) => "x86_64-apple-darwin",
        (Some("Linux" | "Darwin"), _, _) => {
            bail!("unrecognized remote arch (uname: '{uname}'); pass --target explicitly")
        }
        _ => bail!("remote host is neither Linux nor macOS (uname: '{uname}'); pass --target explicitly"),
    };
    Ok(target.to_string())
}

/// `cargo build --release --target <triple>` for this crate; returns the
/// binary path. Falls back to a clear message if the cross-linker is missing.
fn cross_compile(target: &str) -> Result<String> {
    let manifest = format!("{}/Cargo.toml", env!("CARGO_MANIFEST_DIR"));
    eprintln!("[deploy] cross-compiling for {target}…");
    let status = Command::new("cargo")
        .args([
            "build",
            "--release",
            "--target",
            target,
            "--manifest-path",
            &manifest,
        ])
        .status()
        .context("running cargo build (is cargo on PATH?)")?;
    if !status.success() {
        bail!(
            "cross-compile for {target} failed.\n\
             The target's std is usually the missing piece — the link itself needs no\n\
             external toolchain (termiod/.cargo/config.toml uses the bundled rust-lld):\n  \
             • rustup target add {target}\n  \
             • or build on the host and deploy with: termiod remote deploy <host> --bin <path>"
        );
    }
    let dir = env!("CARGO_MANIFEST_DIR");
    // With a workspace-less crate, target/ sits next to Cargo.toml.
    let bin = format!("{dir}/target/{target}/release/termiod");
    if !std::path::Path::new(&bin).exists() {
        bail!("expected built binary at {bin} but it is missing");
    }
    Ok(bin)
}

/// Run an interactive/remote command over SSH. `tty` requests a PTY (`-t`),
/// needed for `attach`; list uses no tty. Returns the child's exit code.
fn ssh_interactive(host: &str, tty: bool, remote_cmd: &str) -> Result<i32> {
    let mut cmd = Command::new("ssh");
    if tty {
        cmd.arg("-t");
    }
    // ServerAliveInterval keeps the control channel honest; on disconnect the
    // remote client dies and the session detaches.
    cmd.args(["-o", "ServerAliveInterval=15"]);
    cmd.arg(host);
    cmd.arg(remote_cmd);
    let status = cmd.status().context("spawning ssh")?;
    Ok(status.code().unwrap_or(1))
}

/// One host's session table, for the cross-host view. Failure is returned per
/// host rather than aborting the sweep — a cloud fleet always has one box
/// that is rebooting, and that must not blank the other rows.
pub async fn list_json(host: &str) -> (String, Result<Vec<crate::protocol::SessionInfo>>) {
    let owned = host.to_string();
    let probe = owned.clone();
    let result = tokio::task::spawn_blocking(move || {
        let out = ssh_capture(&probe, &format!("{} list --json", remote_bin()))?;
        serde_json::from_str::<Vec<crate::protocol::SessionInfo>>(&out)
            .context("parsing remote session list")
    })
    .await;
    match result {
        Ok(inner) => (owned, inner),
        Err(e) => (owned, Err(anyhow::anyhow!("{e}"))),
    }
}

/// Run an SSH command and capture stdout (for create/list probes).
fn ssh_capture(host: &str, remote_cmd: &str) -> Result<String> {
    let mut cmd = Command::new("ssh");
    cmd.args(batch_args());
    let out = cmd
        .args([host, remote_cmd])
        .output()
        .context("spawning ssh")?;
    if !out.status.success() {
        bail!(
            "ssh {host} '{remote_cmd}' failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Minimal single-quote shell escaping for remote command args.
fn shell_quote(s: &str) -> String {
    lifecycle::shell_quote(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What `uname -sm` actually prints on the machines Termio is pointed at.
    #[test]
    fn a_machine_is_recognized_from_its_own_uname() {
        assert_eq!(target_for_uname("Linux x86_64").unwrap(), "x86_64-unknown-linux-musl");
        assert_eq!(target_for_uname("Linux aarch64").unwrap(), "aarch64-unknown-linux-musl");
        assert_eq!(target_for_uname("Darwin arm64").unwrap(), "aarch64-apple-darwin");
        assert_eq!(target_for_uname("Darwin x86_64").unwrap(), "x86_64-apple-darwin");
    }

    /// A machine Termio has no daemon for says so, and says which of the two
    /// things it could not recognise — the system or the architecture.
    #[test]
    fn an_unsupported_machine_names_what_was_not_recognized() {
        let arch = target_for_uname("Linux riscv64").unwrap_err().to_string();
        assert!(arch.contains("unrecognized remote arch"), "{arch}");

        let system = target_for_uname("FreeBSD amd64").unwrap_err().to_string();
        assert!(system.contains("neither Linux nor macOS"), "{system}");
    }

    /// The Mac case takes the daemon that is already running this code rather
    /// than a per-target sibling, because it is built universal.
    #[test]
    fn a_mac_is_served_by_the_running_daemon_itself() {
        let running = std::env::current_exe().ok().and_then(|p| p.to_str().map(str::to_owned));
        assert_eq!(shipped_binary("aarch64-apple-darwin"), running);
        assert_eq!(shipped_binary("x86_64-apple-darwin"), running);
    }

    /// scp does not expand `$HOME`; the default install path has to reach it
    /// as a path relative to the login directory, and a custom absolute path
    /// has to reach it untouched.
    #[test]
    fn the_install_directory_is_spelled_for_scp() {
        let node = SshNode::new("box".into());
        std::env::remove_var("TERMIOD_REMOTE_BIN");
        assert_eq!(
            node.install_directory(),
            ("$HOME/.local/bin".to_string(), ".local/bin".to_string())
        );
    }
}
