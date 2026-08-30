//! Where the control socket lives.
//!
//! Prefer `$XDG_RUNTIME_DIR/termiod/` (per-user, tmpfs, auto-cleaned on
//! logout). Fall back to a uid-scoped dir under the system temp dir. Either
//! way the directory is created 0700 so no other user can connect.

use crate::id::SessionId;
use anyhow::{bail, Context, Result};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::PathBuf;

/// `"-dev"` for a side-by-side dev build, `""` for a release one.
///
/// Mirrors `AppChannel.suffix` in the app, and must keep mirroring it: the two
/// derive it separately and a disagreement puts them on different sockets. Only
/// a plain name becomes a path component, so a typo in `TERMIO_CHANNEL` falls
/// back to the release channel instead of opening a stray directory. The app
/// reads its channel off its bundle identifier, which a spawned binary cannot
/// see, so whoever starts the daemon has to say which channel it serves.
pub fn channel_suffix() -> String {
    let requested = std::env::var("TERMIO_CHANNEL")
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    if requested.is_empty() || requested == "release" {
        return String::new();
    }
    if requested
        .chars()
        .all(|character| character.is_alphanumeric() || character == '-')
    {
        return format!("-{requested}");
    }
    String::new()
}

/// Directory holding the socket (and, later, logs / pid files).
///
/// Scoped by channel as well as by user. The socket is the rendezvous for a
/// whole session table, so sharing one between the release app and a dev build
/// beside it makes them one device: each is handed the other's entire roster,
/// draws every row of it as a session nothing accounts for, and can kill it.
pub fn runtime_dir() -> Result<PathBuf> {
    let suffix = channel_suffix();
    let base = if let Some(xdg) = std::env::var_os("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg).join(format!("termiod{suffix}"))
    } else {
        let uid = unsafe { libc::getuid() };
        std::env::temp_dir().join(format!("termiod-{uid}{suffix}"))
    };
    Ok(base)
}

/// Where the daemon writes its own diagnostics.
///
/// Deliberately **not** under `runtime_dir()` in the ordinary case: that lives in
/// `$TMPDIR`, which the OS may sweep, and a log whose whole purpose is to explain
/// a crash that happened yesterday has to outlive the socket beside it. On macOS
/// that means `~/Library/Logs`, the directory Console.app opens and the one place
/// a user can be told to look without being handed a path. Elsewhere it is
/// `$XDG_STATE_HOME/termio{suffix}`, which is already the path
/// `RemoteTunnelPaths.daemonLog` names for a published Linux box.
///
/// An explicit `TERMIOD_SOCK` overrides that and puts the log beside the socket,
/// for the same reason `host_id_path` and the graveyard hang off `state_dir`: a
/// daemon pointed at its own socket is its own daemon, and its files must not
/// land on the real one's. Without this the test suite — which gives each daemon
/// a temp socket but no channel — appends its runs to the installed app's log.
/// That is the same accident `AppChannel.isRunningTests` exists to prevent on the
/// Swift side, where it once overwrote a real user's session tree.
///
/// `TERMIOD_LOG` names the file outright, for tests and for anyone who wants it
/// somewhere else.
pub fn log_path() -> Result<PathBuf> {
    if let Some(explicit) = std::env::var_os("TERMIOD_LOG") {
        return Ok(PathBuf::from(explicit));
    }
    if std::env::var_os("TERMIOD_SOCK").is_some() {
        return Ok(state_dir()?.join("termiod.log"));
    }
    durable_log_dir(&channel_suffix())?.map_or_else(
        || state_dir().map(|dir| dir.join("termiod.log")),
        |dir| Ok(dir.join("termiod.log")),
    )
}

/// The per-user log directory for a channel, or `None` when there is no home to
/// hang it off — in which case the caller falls back beside the socket rather
/// than failing to start over a log file.
fn durable_log_dir(suffix: &str) -> Result<Option<PathBuf>> {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return Ok(None);
    };
    let directory = if cfg!(target_os = "macos") {
        home.join("Library").join("Logs").join(format!("termio{suffix}"))
    } else if let Some(state) = std::env::var_os("XDG_STATE_HOME") {
        PathBuf::from(state).join(format!("termio{suffix}"))
    } else {
        home.join(".local").join("state").join(format!("termio{suffix}"))
    };
    Ok(Some(directory))
}

/// Full path to the control socket. Overridable with `TERMIOD_SOCK` so tests
/// (and side-by-side daemons) can isolate.
/// Claims the exclusive right to serve this channel's socket. The returned
/// file *is* the claim — hold it for the daemon's life; dropping it (or the
/// process ending, however it ends) releases it.
pub fn acquire_serve_lock() -> Result<std::fs::File> {
    // Beside the socket, not in `runtime_dir()`: a `TERMIOD_SOCK` override
    // moves the socket, and a lock guarding a different directory would
    // serialize nothing.
    let dir = state_dir()?;
    let _ = std::fs::create_dir_all(&dir);
    flock_exclusive(&dir.join("termiod.lock"))
}

fn flock_exclusive(path: &std::path::Path) -> Result<std::fs::File> {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .open(path)
        .with_context(|| format!("opening {}", path.display()))?;
    let taken = unsafe {
        libc::flock(
            std::os::fd::AsRawFd::as_raw_fd(&file),
            libc::LOCK_EX | libc::LOCK_NB,
        )
    };
    if taken != 0 {
        bail!(
            "another termiod is starting or serving this channel (lock held at {})",
            path.display()
        );
    }
    Ok(file)
}

pub fn socket_path() -> Result<PathBuf> {
    if let Some(explicit) = std::env::var_os("TERMIOD_SOCK") {
        return Ok(PathBuf::from(explicit));
    }
    Ok(runtime_dir()?.join("termiod.sock"))
}

/// The directory the *configured* socket lives in — which is not always
/// `runtime_dir()`, because `TERMIOD_SOCK` may point anywhere. Anything that
/// belongs to one daemon (its identity, its graveyard) must hang off this, or
/// two daemons on two sockets silently share one file and report each other's
/// sessions as their own.
pub fn state_dir() -> Result<PathBuf> {
    Ok(socket_path()?
        .parent()
        .map(|path| path.to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".")))
}

/// Stable host identity, persisted beside the configured socket.
pub fn host_id_path() -> Result<PathBuf> {
    Ok(state_dir()?.join("host.id"))
}

/// The pairing secret that authenticates a WebSocket pipe — never the session
/// write token, which arbitrates who may type into a PTY. Beside `host.id`
/// because two daemons on two sockets must not share a secret.
pub fn pair_token_path() -> Result<PathBuf> {
    Ok(state_dir()?.join("pair.token"))
}

/// The durable WSS bind, so a crash restart or a `spawn_daemon` child that
/// execs bare `termiod serve` keeps listening.
pub fn wss_bind_path() -> Result<PathBuf> {
    Ok(state_dir()?.join("wss.bind"))
}

/// The durable allowed origin. Not in the web-client RFC's file table, but
/// `pair --qr` runs in a different process from the daemon and the listener
/// binds loopback by design, so without this the reachable name is knowable
/// only to whoever typed the daemon's argv.
pub fn wss_origin_path() -> Result<PathBuf> {
    Ok(state_dir()?.join("wss.origin"))
}

/// 24 random bytes as base64url. No padding: 24 is a multiple of 3.
fn encode_base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        let symbols = match chunk.len() {
            1 => 2,
            2 => 3,
            _ => 4,
        };
        for index in 0..symbols {
            let sextet = (triple >> (18 - 6 * index)) & 0x3f;
            out.push(ALPHABET[sextet as usize] as char);
        }
    }
    out
}

fn random_bytes(count: usize) -> Result<Vec<u8>> {
    let mut buffer = vec![0u8; count];
    std::fs::File::open("/dev/urandom")
        .context("opening OS random source")?
        .read_exact(&mut buffer)
        .context("reading OS random source")?;
    Ok(buffer)
}

/// Create a 0600 file that must not already exist.
fn write_new_secret(path: &std::path::Path, value: &str) -> Result<()> {
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("writing {}", path.display()))?;
    file.write_all(value.as_bytes())
        .with_context(|| format!("writing {}", path.display()))?;
    file.sync_all()
        .with_context(|| format!("syncing {}", path.display()))?;
    Ok(())
}

/// Replace a 0600 file through a rename, so a concurrent reader sees either the
/// old value or the new one and never a truncated file.
pub fn replace_secret(path: &std::path::Path, value: &str) -> Result<()> {
    let staged = path.with_extension("staged");
    let _ = std::fs::remove_file(&staged);
    write_new_secret(&staged, value)?;
    std::fs::rename(&staged, path)
        .with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

/// The current pairing token, or `None` when the file is absent. Reading is
/// separate from minting on purpose: `serve --wss` must never mint one, or an
/// operator who forgot to pair gets a listener with a secret nobody has seen.
pub fn read_pair_token() -> Result<Option<String>> {
    let path = pair_token_path()?;
    match std::fs::read_to_string(&path) {
        Ok(contents) => {
            let token = contents.trim().to_string();
            if token.is_empty() {
                bail!("empty pairing token in {}", path.display());
            }
            Ok(Some(token))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

/// Read the pairing token, minting one on first use. Only `termiod pair` calls
/// this.
pub fn load_or_create_pair_token() -> Result<String> {
    if let Some(existing) = read_pair_token()? {
        return Ok(existing);
    }
    let token = encode_base64url(&random_bytes(24)?);
    let path = pair_token_path()?;
    match write_new_secret(&path, &token) {
        Ok(()) => Ok(token),
        // Another `pair` won the race; its token is the one on disk.
        Err(_) if path.exists() => read_pair_token()?
            .ok_or_else(|| anyhow::anyhow!("pairing token vanished during minting")),
        Err(error) => Err(error),
    }
}

/// Replace the pairing token. The only revocation there is: a live daemon
/// drops every spliced socket, and anything holding the old secret is out.
pub fn rotate_pair_token() -> Result<String> {
    let token = encode_base64url(&random_bytes(24)?);
    replace_secret(&pair_token_path()?, &token)?;
    Ok(token)
}

/// Root of the per-session upload scratch dirs (§C.12 `temp:` dests). Lives
/// beside the socket for the same reason as the graveyard: two daemons on two
/// sockets must not share scratch space.
pub fn scratch_root() -> Result<PathBuf> {
    Ok(state_dir()?.join("scratch"))
}

/// One session's scratch dir, created 0700 on first use and reaped with the
/// session.
pub fn session_scratch_dir(session_id: &SessionId) -> Result<PathBuf> {
    let dir = scratch_root()?.join(format!("session-{session_id}"));
    if !dir.exists() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .with_context(|| format!("creating scratch dir {}", dir.display()))?;
    }
    Ok(dir)
}

fn read_host_id(path: &std::path::Path) -> Result<String> {
    let id = std::fs::read_to_string(path)
        .with_context(|| format!("reading host id {}", path.display()))?
        .trim()
        .to_string();
    if id.len() != 34
        || !id.starts_with("h_")
        || !id[2..].bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        bail!("invalid host id in {}", path.display());
    }
    Ok(id)
}

/// Load the daemon's stable random 128-bit identity, minting it on first run.
pub fn load_or_create_host_id() -> Result<String> {
    let path = host_id_path()?;
    if path.exists() {
        return read_host_id(&path);
    }

    let mut random = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .context("opening OS random source")?
        .read_exact(&mut random)
        .context("reading OS random source")?;
    let id = format!(
        "h_{}",
        random
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    );

    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
    {
        Ok(mut file) => {
            file.write_all(id.as_bytes())
                .with_context(|| format!("writing host id {}", path.display()))?;
            file.sync_all()
                .with_context(|| format!("syncing host id {}", path.display()))?;
            Ok(id)
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => read_host_id(&path),
        Err(error) => Err(error).with_context(|| format!("creating host id {}", path.display())),
    }
}

/// Create the runtime dir with 0700 permissions if it does not exist.
pub fn ensure_runtime_dir() -> Result<PathBuf> {
    let dir = if let Some(explicit) = std::env::var_os("TERMIOD_SOCK") {
        PathBuf::from(explicit)
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| PathBuf::from("."))
    } else {
        runtime_dir()?
    };
    if !dir.exists() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .with_context(|| format!("creating runtime dir {}", dir.display()))?;
    }
    Ok(dir)
}

#[cfg(test)]
mod serve_lock_tests {
    #[test]
    fn the_serve_lock_is_exclusive_and_released_on_drop() {
        let path = std::env::temp_dir().join(format!(
            "termiod-lock-test-{}",
            std::process::id()
        ));
        let held = super::flock_exclusive(&path).expect("first claim");
        assert!(super::flock_exclusive(&path).is_err(), "second claim must fail");
        drop(held);
        super::flock_exclusive(&path).expect("claim after release");
        let _ = std::fs::remove_file(&path);
    }
}
