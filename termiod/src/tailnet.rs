//! Built-in Tailscale: the daemon joins the user's tailnet as a device of its
//! own, so a box with no Tailscale install is still reachable from a paired
//! Mac or iPhone.
//!
//! The tailnet itself lives in `termio-tailnet`, a Go helper built on Tailscale's
//! tsnet library and installed beside this binary. termiod never links it:
//! the helper is the one place WireGuard runs, and the only thing it shares
//! with the daemon is a Unix socket it pipes admitted connections into and one
//! JSON status line per state change. The session protocol, the pairing token
//! and the origin check all stay here, the same as on the loopback listener.
//!
//! State is three files. `tailscale-config.json` beside the pairing token says whether
//! the user turned it on, and survives reboots. The node's own Tailscale state
//! is the `tailscale/` directory next to it. `tailscale-status.json` beside the
//! socket is what the running helper last reported, and lives only as long as
//! the daemon does.

use crate::paths;
use crate::wss::{self, OriginPolicy};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::UnixListener;
use tokio::process::{Child, Command};
use tokio::sync::watch;

pub const HELPER: &str = "termio-tailnet";
pub const DEFAULT_HOSTNAME: &str = "termio";

/// The port the helper answers on, on the node's own tailnet addresses, when
/// the tailnet has no HTTPS certificates. Same number as the loopback default.
pub const PLAIN_PORT: u16 = 8790;

const CONFIG_POLL: Duration = Duration::from_secs(2);
const STOP_GRACE: Duration = Duration::from_secs(5);
const RESTART_FLOOR: Duration = Duration::from_secs(2);
const RESTART_CEILING: Duration = Duration::from_secs(60);
const OWNER_WAIT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Config {
    pub enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hostname: Option<String>,
    /// Bumped with each new auth key. The helper reads a key only when it
    /// starts, so a new key has to look like a new config to restart it.
    #[serde(default)]
    pub auth_key_generation: u64,
}

impl Config {
    pub fn hostname(&self) -> &str {
        self.hostname.as_deref().unwrap_or(DEFAULT_HOSTNAME)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Status {
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dns_name: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ips: Vec<String>,
    #[serde(default)]
    pub https: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub tagged: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tailnet: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// The daemon that wrote this. A status whose daemon is gone describes
    /// nothing.
    #[serde(default)]
    pub pid: u32,
    /// The helper the daemon was running when it wrote this. After a handoff
    /// the new image reaps it by this number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub helper_pid: Option<u32>,
}

impl Status {
    fn new(state: &str) -> Status {
        Status {
            state: state.to_string(),
            pid: std::process::id(),
            ..Status::default()
        }
    }

    fn failed(message: impl Into<String>) -> Status {
        Status {
            message: Some(message.into()),
            ..Status::new("error")
        }
    }

    /// Where a phone reaches this node: the HTTPS name when the tailnet has
    /// certificates, otherwise the node's IPv4 address on the plain port. iOS
    /// lets an app open plain `ws://` to an IP address but not to a name.
    pub fn reachable_url(&self) -> Option<String> {
        if self.state != "running" {
            return None;
        }
        if self.https {
            if let Some(name) = self.dns_name.as_deref().filter(|name| !name.is_empty()) {
                return Some(format!("https://{name}"));
            }
        }
        let address = self
            .ips
            .iter()
            .find(|ip| ip.parse::<std::net::Ipv4Addr>().is_ok())
            .or_else(|| self.ips.first())?;
        if address.contains(':') {
            Some(format!("http://[{address}]:{PLAIN_PORT}"))
        } else {
            Some(format!("http://{address}:{PLAIN_PORT}"))
        }
    }
}

pub fn config_path() -> Result<PathBuf> {
    Ok(paths::durable_state_dir()?.join("tailscale-config.json"))
}

pub fn node_dir() -> Result<PathBuf> {
    Ok(paths::durable_state_dir()?.join("tailscale"))
}

fn auth_key_path() -> Result<PathBuf> {
    Ok(paths::durable_state_dir()?.join("tailscale-authkey.txt"))
}

pub fn status_path() -> Result<PathBuf> {
    Ok(paths::state_dir()?.join("tailscale-status.json"))
}

pub fn socket_path() -> Result<PathBuf> {
    Ok(paths::state_dir()?.join("tailnet.sock"))
}

pub fn read_config() -> Result<Config> {
    let path = config_path()?;
    match std::fs::read_to_string(&path) {
        Ok(raw) => {
            serde_json::from_str(&raw).with_context(|| format!("reading {}", path.display()))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

pub fn write_config(config: &Config) -> Result<()> {
    let path = config_path()?;
    paths::replace_secret(&path, &serde_json::to_string(config)?)
}

/// The helper's last report, or `None` when no running daemon wrote one.
pub fn read_status() -> Option<Status> {
    let raw = std::fs::read_to_string(status_path().ok()?).ok()?;
    let status: Status = serde_json::from_str(&raw).ok()?;
    process_alive(status.pid).then_some(status)
}

/// Serializes `on`, `off` and `logout` against each other. The daemon never
/// takes it: it only reads the config.
fn lock_settings() -> Result<std::fs::File> {
    use std::os::fd::AsRawFd;
    let path = paths::durable_state_dir()?.join("tailscale.lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .with_context(|| format!("opening {}", path.display()))?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("locking {}", path.display()));
    }
    Ok(file)
}

fn written_since(moment: std::time::SystemTime) -> bool {
    status_path()
        .and_then(|path| Ok(std::fs::metadata(path)?.modified()?))
        .is_ok_and(|modified| modified >= moment)
}

fn process_alive(pid: u32) -> bool {
    let Ok(pid) = i32::try_from(pid) else {
        return false;
    };
    pid > 0 && unsafe { libc::kill(pid, 0) == 0 }
}

fn write_status(status: &Status) {
    let result = status_path().and_then(|path| {
        let raw = serde_json::to_string(status)?;
        paths::replace_secret(&path, &raw)
    });
    if let Err(error) = result {
        eprintln!("termiod: tailscale: writing status: {error:#}");
    }
}

/// The helper beside this executable. `TERMIO_TAILNET_HELPER` points tests at
/// a build of their own.
pub fn helper_path() -> Option<PathBuf> {
    if let Some(explicit) = std::env::var_os("TERMIO_TAILNET_HELPER").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(explicit));
    }
    let candidate = std::env::current_exe().ok()?.parent()?.join(HELPER);
    candidate.is_file().then_some(candidate)
}

// ---------------------------------------------------------------------------
// The daemon side
// ---------------------------------------------------------------------------

/// Run for the daemon's whole life: follow `tailscale-config.json`, and keep the
/// helper and the tailnet socket up exactly while it says enabled.
pub fn start(shutdown: watch::Receiver<bool>) {
    tokio::spawn(supervise(shutdown));
}

async fn supervise(mut shutdown: watch::Receiver<bool>) {
    let rotation = wss::start_rotation_watch();
    if let Err(error) = tokio::task::spawn_blocking(reap_inherited_helper).await {
        eprintln!("termiod: tailscale: reaping the previous helper: {error}");
    }
    loop {
        if *shutdown.borrow() {
            break;
        }
        let config = match read_config() {
            Ok(config) => config,
            Err(error) => {
                write_status(&Status::failed(format!("{error:#}")));
                Config::default()
            }
        };
        if config.enabled {
            run_enabled(&config, &mut shutdown, &rotation).await;
        } else {
            write_status(&Status::new("off"));
            if wait_for_change(&config, &mut shutdown).await.is_err() {
                break;
            }
        }
    }
    if let Ok(path) = socket_path() {
        let _ = std::fs::remove_file(path);
    }
    if let Ok(path) = status_path() {
        let _ = std::fs::remove_file(path);
    }
}

/// Resolves when the file no longer says `current`. Errs on shutdown.
async fn wait_for_change(current: &Config, shutdown: &mut watch::Receiver<bool>) -> Result<(), ()> {
    loop {
        tokio::select! {
            _ = shutdown.changed() => return Err(()),
            _ = tokio::time::sleep(CONFIG_POLL) => {}
        }
        match read_config() {
            Ok(config) if &config == current => {}
            _ => return Ok(()),
        }
    }
}

async fn run_enabled(
    config: &Config,
    shutdown: &mut watch::Receiver<bool>,
    rotation: &wss::Rotation,
) {
    let Some(helper) = helper_path() else {
        write_status(&Status::failed(format!(
            "{HELPER} is not installed next to termiod, so this box cannot join the tailnet by itself"
        )));
        let _ = wait_for_change(config, shutdown).await;
        return;
    };
    let socket = match bind_socket() {
        Ok(socket) => socket,
        Err(error) => {
            write_status(&Status::failed(format!("{error:#}")));
            let _ = wait_for_change(config, shutdown).await;
            return;
        }
    };
    let (socket_path, listener) = socket;
    let accept = tokio::spawn(accept_loop(
        listener,
        shutdown.clone(),
        rotation.subscribe(),
    ));

    let mut backoff = RESTART_FLOOR;
    loop {
        write_status(&Status::new("starting"));
        let mut child = match spawn_helper(&helper, config, &socket_path) {
            Ok(child) => child,
            Err(error) => {
                write_status(&Status::failed(format!("{error:#}")));
                if wait_or_change(backoff, config, shutdown).await {
                    break;
                }
                backoff = (backoff * 2).min(RESTART_CEILING);
                continue;
            }
        };
        // Held out here because `Child::wait` closes a stdin it still owns,
        // and that end of file would tell the helper to stop.
        let mut stdin = child.stdin.take();
        let helper_pid = child.id();
        write_status(&Status {
            helper_pid,
            ..Status::new("starting")
        });
        let reports = child
            .stdout
            .take()
            .map(|stdout| tokio::spawn(follow_reports(stdout, helper_pid)));
        let started = std::time::Instant::now();

        // Ends on a config change and on shutdown alike.
        let mut probe = shutdown.clone();
        let outcome = tokio::select! {
            exit = child.wait() => Some(exit),
            _ = wait_for_change(config, &mut probe) => None,
        };
        match outcome {
            Some(exit) => {
                if let Some(reports) = reports {
                    let _ = reports.await;
                }
                let description = match exit {
                    Ok(status) => format!("{HELPER} stopped ({status})"),
                    Err(error) => format!("{HELPER} stopped: {error}"),
                };
                eprintln!("termiod: tailscale: {description}");
                let last = read_status_unchecked();
                let message = last
                    .and_then(|status| {
                        (status.state == "error")
                            .then_some(status.message)
                            .flatten()
                    })
                    .unwrap_or(description);
                write_status(&Status::failed(message));
                if started.elapsed() > RESTART_CEILING {
                    backoff = RESTART_FLOOR;
                }
                if wait_or_change(backoff, config, shutdown).await {
                    break;
                }
                backoff = (backoff * 2).min(RESTART_CEILING);
            }
            None => {
                stop_helper(&mut child, stdin.take()).await;
                if let Some(reports) = reports {
                    reports.abort();
                }
                break;
            }
        }
    }
    accept.abort();
    let _ = std::fs::remove_file(&socket_path);
}

/// Sleeps `delay`. True when the caller should stop instead of restarting: the
/// config changed or the daemon is shutting down.
async fn wait_or_change(
    delay: Duration,
    config: &Config,
    shutdown: &mut watch::Receiver<bool>,
) -> bool {
    let mut probe = shutdown.clone();
    tokio::select! {
        _ = tokio::time::sleep(delay) => *shutdown.borrow(),
        _ = shutdown.changed() => true,
        _ = wait_for_change(config, &mut probe) => true,
    }
}

/// After a handoff this process is the same pid as the image that started the
/// last helper, so that helper is still its child. Its stdin closed with the
/// `execve`, so it is on its way out. Waiting for it reaps it, and keeps two
/// helpers from running on one node directory.
fn reap_inherited_helper() {
    let Some(status) = read_status_unchecked() else {
        return;
    };
    let Some(pid) = status.helper_pid else { return };
    if status.pid != std::process::id() {
        return;
    }
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return;
    };
    let mut deadline = std::time::Instant::now() + STOP_GRACE;
    let mut signalled = false;
    loop {
        let mut code = 0;
        // Nonzero means reaped, and -1 means not our child (ECHILD): either
        // way there is nothing left to wait for.
        if unsafe { libc::waitpid(pid, &mut code, libc::WNOHANG) } != 0 {
            return;
        }
        if std::time::Instant::now() > deadline {
            if signalled {
                unsafe { libc::kill(pid, libc::SIGKILL) };
                unsafe { libc::waitpid(pid, &mut code, 0) };
                return;
            }
            unsafe { libc::kill(pid, libc::SIGTERM) };
            signalled = true;
            deadline = std::time::Instant::now() + STOP_GRACE;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn read_status_unchecked() -> Option<Status> {
    let raw = std::fs::read_to_string(status_path().ok()?).ok()?;
    serde_json::from_str(&raw).ok()
}

fn bind_socket() -> Result<(PathBuf, UnixListener)> {
    let path = socket_path()?;
    match std::fs::remove_file(&path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).with_context(|| format!("removing {}", path.display())),
    }
    let listener =
        UnixListener::bind(&path).with_context(|| format!("binding {}", path.display()))?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
        .with_context(|| format!("securing {}", path.display()))?;
    Ok((path, listener))
}

async fn accept_loop(
    listener: UnixListener,
    shutdown: watch::Receiver<bool>,
    rotation: watch::Receiver<u64>,
) {
    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let shutdown = shutdown.clone();
                // A clone inherits the listener's last-seen version, so a
                // rotation before this connection would close it at once.
                let mut rotation = rotation.clone();
                rotation.borrow_and_update();
                tokio::spawn(async move {
                    if let Err(error) = wss::serve_connection(
                        stream,
                        OriginPolicy::SameHostName,
                        shutdown,
                        rotation,
                    )
                    .await
                    {
                        eprintln!("termiod: tailscale: {error:#}");
                    }
                });
            }
            Err(error) => {
                eprintln!("termiod: tailscale: accept: {error}");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

fn spawn_helper(helper: &Path, config: &Config, socket: &Path) -> Result<Child> {
    let mut command = Command::new(helper);
    command
        .arg("serve")
        .arg("--dir")
        .arg(node_dir()?)
        .arg("--hostname")
        .arg(config.hostname())
        .arg("--forward")
        .arg(socket);
    let key = auth_key_path()?;
    if key.is_file() {
        command.arg("--auth-key-file").arg(&key);
    }
    // stdin stays open for the helper's whole life: its end of file is how
    // the helper learns that this daemon is gone, even after a SIGKILL.
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true);
    command
        .spawn()
        .with_context(|| format!("starting {}", helper.display()))
}

async fn follow_reports(stdout: tokio::process::ChildStdout, helper_pid: Option<u32>) {
    let mut lines = BufReader::new(stdout).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(mut status) = serde_json::from_str::<Status>(&line) else {
            eprintln!("termiod: tailscale: unreadable report: {line}");
            continue;
        };
        status.pid = std::process::id();
        status.helper_pid = helper_pid;
        if status.state == "running" {
            // The key is single-use, and the node keeps its login. Keeping
            // the file would only keep a secret on disk.
            if let Ok(path) = auth_key_path() {
                let _ = std::fs::remove_file(path);
            }
        }
        write_status(&status);
    }
}

async fn stop_helper(child: &mut Child, stdin: Option<tokio::process::ChildStdin>) {
    drop(stdin);
    if tokio::time::timeout(STOP_GRACE, child.wait())
        .await
        .is_err()
    {
        let _ = child.kill().await;
    }
}

// ---------------------------------------------------------------------------
// `termiod tailscale`
// ---------------------------------------------------------------------------

pub struct OnOptions {
    pub hostname: Option<String>,
    pub auth_key_file: Option<PathBuf>,
    pub no_wait: bool,
}

pub async fn run_on(options: OnOptions) -> Result<()> {
    if let Some(name) = options.hostname.as_deref() {
        validate_hostname(name)?;
    }
    if helper_path().is_none() {
        bail!("{HELPER} is not installed next to termiod. Reinstall the Termio server to get it.");
    }
    // The tailnet listener authenticates with the same token as every other
    // WebSocket, so turning it on without one would admit nobody.
    paths::load_or_create_pair_token()?;
    // Taken before the key is written: a logout running now deletes the key
    // file on its way out.
    let lock = lock_settings()?;
    if let Some(source) = options.auth_key_file.as_deref() {
        let key = if source == Path::new("-") {
            let mut key = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut key)?;
            key
        } else {
            std::fs::read_to_string(source)
                .with_context(|| format!("reading {}", source.display()))?
        };
        let key = key.trim();
        if key.is_empty() {
            bail!("the auth key is empty");
        }
        paths::replace_secret(&auth_key_path()?, key)?;
    }
    let mut config = read_config()?;
    config.enabled = true;
    if options.auth_key_file.is_some() {
        config.auth_key_generation += 1;
    }
    if options.hostname.is_some() {
        config.hostname = options.hostname;
    }
    // An error already on disk is from before this call: a helper that failed
    // and is about to be retried. Only one written after this counts.
    let asked = std::time::SystemTime::now();
    write_config(&config)?;
    drop(lock);

    // Connecting starts a daemon when none is running.
    crate::client::connect().await?;
    if options.no_wait {
        println!("Built-in Tailscale is on. `termiod tailscale status` shows its progress.");
        return Ok(());
    }

    let mut printed_link: Option<String> = None;
    let mut running_since: Option<std::time::Instant> = None;
    let deadline = std::time::Instant::now() + Duration::from_secs(600);
    loop {
        if let Some(status) = read_status() {
            match status.state.as_str() {
                "running" => {
                    // The node can be up a moment before Tailscale has said
                    // who owns it, and the owner is the line worth reading.
                    let since = *running_since.get_or_insert_with(std::time::Instant::now);
                    if status.owner.is_some() || status.tagged || since.elapsed() > OWNER_WAIT {
                        print_status(&config, Some(&status));
                        return Ok(());
                    }
                }
                "needs_login" => {
                    if let Some(url) = status.auth_url.as_ref() {
                        if printed_link.as_ref() != Some(url) {
                            println!("To add this box to your tailnet, open:\n\n  {url}\n");
                            printed_link = Some(url.clone());
                        }
                    }
                }
                "needs_approval" if printed_link.as_deref() != Some("approval") => {
                    println!("Approve this device in the Tailscale admin console: https://login.tailscale.com/admin/machines");
                    printed_link = Some("approval".into());
                }
                "error" if written_since(asked) => {
                    bail!(
                        "{}",
                        status.message.unwrap_or_else(|| "Tailscale stopped".into())
                    );
                }
                _ => {}
            }
        }
        if std::time::Instant::now() > deadline {
            bail!("still not signed in after 10 minutes. Built-in Tailscale stays on; `termiod tailscale status` shows the link.");
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

pub fn run_off() -> Result<()> {
    let _lock = lock_settings()?;
    let mut config = read_config()?;
    config.enabled = false;
    write_config(&config)?;
    println!("Built-in Tailscale is off. This box stays signed in; `termiod tailscale logout` signs it out.");
    Ok(())
}

pub async fn run_logout() -> Result<()> {
    let Some(helper) = helper_path() else {
        bail!("{HELPER} is not installed next to termiod");
    };
    // Held to the end: an `on` in the meantime would start a node on the
    // directory this is about to delete.
    let _lock = lock_settings()?;
    let mut config = read_config()?;
    config.enabled = false;
    write_config(&config)?;
    // The node's state directory is the helper's alone, so wait until the
    // running daemon has let go of it.
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while read_status().is_some_and(|status| status.state != "off") {
        if std::time::Instant::now() > deadline {
            bail!("the daemon did not stop its Tailscale node within 15 seconds");
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    let directory = node_dir()?;
    if directory.is_dir() {
        let status = Command::new(&helper)
            .arg("logout")
            .arg("--dir")
            .arg(&directory)
            .stdin(Stdio::null())
            .status()
            .await
            .with_context(|| format!("starting {}", helper.display()))?;
        if !status.success() {
            bail!("{HELPER} logout failed ({status}). Nothing was deleted.");
        }
        std::fs::remove_dir_all(&directory)
            .with_context(|| format!("removing {}", directory.display()))?;
    }
    let _ = std::fs::remove_file(auth_key_path()?);
    println!("Signed out of Tailscale. Built-in Tailscale is off.");
    Ok(())
}

pub fn run_status(json: bool) -> Result<()> {
    let config = read_config()?;
    let status = read_status();
    if json {
        println!(
            "{}",
            serde_json::to_string(&serde_json::json!({
                "enabled": config.enabled,
                "hostname": config.hostname(),
                "status": status,
                "url": status.as_ref().and_then(Status::reachable_url),
                "helper": helper_path(),
            }))?
        );
        return Ok(());
    }
    print_status(&config, status.as_ref());
    Ok(())
}

fn print_status(config: &Config, status: Option<&Status>) {
    if !config.enabled {
        println!("Built-in Tailscale: off");
        return;
    }
    let Some(status) = status else {
        println!("Built-in Tailscale: on, but the daemon is not running");
        return;
    };
    match status.state.as_str() {
        "running" => {
            println!("Built-in Tailscale: connected");
            if let Some(name) = status.dns_name.as_deref() {
                println!("  name     {name}");
            }
            if !status.ips.is_empty() {
                println!("  address  {}", status.ips.join(", "));
            }
            match (status.owner.as_deref(), status.tagged) {
                (_, true) => println!("  access   nobody: a tagged device has no owner"),
                (Some(owner), false) => println!("  access   {owner} only"),
                (None, false) => println!("  access   the account that signed it in"),
            }
            if let Some(url) = status.reachable_url() {
                println!("  url      {url}");
            }
            if !status.https {
                println!("  HTTPS certificates are off for this tailnet, so clients use the plain tailnet address.");
            }
        }
        "needs_login" => {
            println!("Built-in Tailscale: waiting for sign-in");
            if let Some(url) = status.auth_url.as_deref() {
                println!("  open     {url}");
            }
        }
        "needs_approval" => {
            println!("Built-in Tailscale: waiting for approval in the Tailscale admin console")
        }
        "error" => println!(
            "Built-in Tailscale: {}",
            status.message.as_deref().unwrap_or("stopped")
        ),
        other => println!("Built-in Tailscale: {other}"),
    }
}

/// A DNS label, which is what Tailscale turns the name into.
fn validate_hostname(name: &str) -> Result<()> {
    let valid = !name.is_empty()
        && name.len() <= 63
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        && !name.starts_with('-')
        && !name.ends_with('-');
    if !valid {
        bail!("{name:?} is not a valid device name: use letters, digits and hyphens, up to 63");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn running(https: bool, ips: &[&str]) -> Status {
        Status {
            state: "running".into(),
            dns_name: Some("termio.tail1234.ts.net".into()),
            ips: ips.iter().map(|ip| ip.to_string()).collect(),
            https,
            ..Status::default()
        }
    }

    #[test]
    fn https_names_the_node() {
        let status = running(true, &["100.64.0.7"]);
        assert_eq!(
            status.reachable_url().as_deref(),
            Some("https://termio.tail1234.ts.net")
        );
    }

    #[test]
    fn without_https_the_ipv4_address_on_the_plain_port() {
        let status = running(false, &["fd7a:115c:a1e0::7", "100.64.0.7"]);
        assert_eq!(
            status.reachable_url().as_deref(),
            Some("http://100.64.0.7:8790")
        );
        let status = running(false, &["fd7a:115c:a1e0::7"]);
        assert_eq!(
            status.reachable_url().as_deref(),
            Some("http://[fd7a:115c:a1e0::7]:8790")
        );
    }

    #[test]
    fn only_a_running_node_is_reachable() {
        let mut status = running(true, &["100.64.0.7"]);
        status.state = "needs_login".into();
        assert_eq!(status.reachable_url(), None);
    }

    #[test]
    fn device_names_are_dns_labels() {
        assert!(validate_hostname("termio").is_ok());
        assert!(validate_hostname("build-box-2").is_ok());
        assert!(validate_hostname("").is_err());
        assert!(validate_hostname("-x").is_err());
        assert!(validate_hostname("a.b").is_err());
        assert!(validate_hostname(&"a".repeat(64)).is_err());
    }

    #[test]
    fn the_tailnet_origin_rule_compares_host_names() {
        use crate::wss::origin_names_host;
        let name = "termio.tail1234.ts.net";
        assert!(origin_names_host(
            Some("https://termio.tail1234.ts.net"),
            Some(name)
        ));
        assert!(origin_names_host(
            Some("http://100.64.0.7:8790"),
            Some("100.64.0.7:8790")
        ));
        assert!(!origin_names_host(Some("https://evil.example"), Some(name)));
        assert!(!origin_names_host(None, Some(name)));
        assert!(!origin_names_host(Some("null"), Some(name)));
        assert!(!origin_names_host(
            Some("http://localhost"),
            Some("localhost")
        ));
    }
}
