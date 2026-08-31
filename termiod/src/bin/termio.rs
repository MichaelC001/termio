//! termio — the command a person types. `termiod` is the daemon, like
//! `dockerd`; this client drives the Mac app and the session host
//! (docker-lessons RFC §1).
//!
//! This binary is the Rust replacement for `scripts/termio`, growing verb by
//! verb (unify-server-plane Stage 10). Implemented here: `version`,
//! `remote`, `open`, and the bare-`DIR` shorthand. Until the port completes,
//! `sessions`, `agent report`, and `notify` stay with the shell client.
//!
//! The dispatcher is a hand-rolled match, not clap: `termio [DIR]` must
//! treat any non-verb first argument as a directory (the `code .` shape),
//! and `remote` is an argv passthrough whose help belongs to the daemon.

use anyhow::{bail, Context, Result};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use termiod::channel::{self, Channel};
use termiod::{lifecycle, version};

const USAGE: &str = "\
termio — drive the termio app and its session host from the terminal

usage:
  termio [DIR]           open DIR (default: .) as a project in termio
  termio open [DIR]      the same, spelled out
  termio version         every version in one table: client, app, local termiod, known remotes
  termio remote <verb> … drive a remote box's termiod (deploy, list, attach, open)
  termio --version       client version and channel

not yet ported from the shell client: sessions, agent, notify";

#[tokio::main]
async fn main() -> Result<()> {
    let (channel, provenance) = channel::resolve();
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match arguments.first().map(String::as_str) {
        None => open_project(&channel, Path::new(".")),
        Some("-h") | Some("--help") | Some("help") => {
            println!("{USAGE}");
            Ok(())
        }
        Some("-V") | Some("--version") => {
            println!("termio {} ({})", lifecycle::BUILD_VERSION, channel.name);
            Ok(())
        }
        Some("version") => version::print_table(&channel, provenance).await,
        Some("remote") => remote_passthrough(&channel, &arguments[1..]),
        Some("open") => {
            let directory = arguments.get(1).map(String::as_str).unwrap_or(".");
            open_project(&channel, Path::new(directory))
        }
        // Bare `termio [DIR]` stays as the `code .`-shaped shorthand for `open`.
        Some(directory) => open_project(&channel, Path::new(directory)),
    }
}

/// Resolve to an absolute, symlink-free path so termio keys the project by
/// the same canonical path it stores, avoiding duplicate sidebar entries.
fn open_project(channel: &Channel, directory: &Path) -> Result<()> {
    if !directory.is_dir() {
        eprintln!("termio: not a directory: {}", directory.display());
        std::process::exit(1);
    }
    let absolute = directory
        .canonicalize()
        .with_context(|| format!("resolving {}", directory.display()))?;
    if !cfg!(target_os = "macos") {
        bail!("termio open drives the Mac app; there is none on this machine");
    }
    let error = Command::new("open")
        .arg("-b")
        .arg(&channel.bundle_id)
        .arg(&absolute)
        .exec();
    Err(error).context("running open")
}

/// `termio remote …` execs the daemon binary rather than calling
/// `remote::run` in-process: `shipped_binary()` deploys `current_exe()` to
/// Mac targets, so an in-process call from this client would ship the client
/// as the remote daemon. The in-process move happens together with a
/// daemon-sibling fix, not here. `channel::resolve` already pinned
/// `TERMIO_CHANNEL`, which the exec inherits.
fn remote_passthrough(channel: &Channel, rest: &[String]) -> Result<()> {
    let Some(daemon) = locate_termiod(channel) else {
        eprintln!("termio: no termiod binary found — install the termio app, or set TERMIOD_BIN");
        std::process::exit(1);
    };
    let error = Command::new(&daemon).arg("remote").args(rest).exec();
    Err(error).with_context(|| format!("running {}", daemon.display()))
}

/// The shell client's `locate_termiod()`, same rungs in the same order: the
/// explicit `TERMIOD_BIN` override; the daemon bundled beside this binary
/// (`Contents/Resources` in the app, `target/{debug,release}` in a
/// checkout); the running app's bundle via `lsappinfo`, which only answers
/// for a live process so it can never name a stale bundle; then the
/// standalone install locations.
fn locate_termiod(channel: &Channel) -> Option<PathBuf> {
    if let Some(explicit) = std::env::var_os("TERMIOD_BIN") {
        let path = PathBuf::from(explicit);
        if path.is_file() {
            return Some(path);
        }
    }
    if let Ok(own) = std::env::current_exe() {
        if let Some(sibling) = own.canonicalize().ok().and_then(|resolved| {
            let candidate = resolved.parent()?.join("termiod");
            candidate.is_file().then_some(candidate)
        }) {
            return Some(sibling);
        }
    }
    if cfg!(target_os = "macos") {
        if let Ok(info) = Command::new("lsappinfo")
            .args(["info", "-only", "bundlepath", &channel.bundle_id])
            .output()
        {
            let stdout = String::from_utf8_lossy(&info.stdout);
            if let Some(bundle) = stdout
                .lines()
                .find_map(|line| line.strip_prefix("\"LSBundlePath\"=\""))
                .and_then(|rest| rest.strip_suffix('"'))
            {
                let candidate = Path::new(bundle).join("Contents/Resources/termiod");
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let candidate = Path::new(&home).join(".local/bin/termiod");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    let path_variable = std::env::var_os("PATH")?;
    std::env::split_paths(&path_variable)
        .map(|directory| directory.join("termiod"))
        .find(|candidate| candidate.is_file())
}
