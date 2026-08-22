//! Where the control socket lives.
//!
//! Prefer `$XDG_RUNTIME_DIR/termiod/` (per-user, tmpfs, auto-cleaned on
//! logout). Fall back to a uid-scoped dir under the system temp dir. Either
//! way the directory is created 0700 so no other user can connect.

use anyhow::{bail, Context, Result};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::PathBuf;

/// `"-dev"` for a side-by-side dev build, `""` for a release one.
///
/// Mirrors `AppChannel.suffix` in the app, and must keep mirroring it: the two
/// sides derive this separately and a disagreement puts them on different
/// sockets. Only a plain name becomes a path component, so a typo in
/// `TERMIO_CHANNEL` can never open a stray directory beside the real ones — it
/// falls back to the release channel instead.
///
/// The daemon cannot read this the way the app does. The app's channel comes
/// off its bundle identifier, which a spawned binary has no way to see, so
/// whoever starts the daemon has to say which channel it serves.
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

/// Full path to the control socket. Overridable with `TERMIOD_SOCK` so tests
/// (and side-by-side daemons) can isolate.
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

/// Root of the per-session upload scratch dirs (§C.12 `temp:` dests). Lives
/// beside the socket for the same reason as the graveyard: two daemons on two
/// sockets must not share scratch space.
pub fn scratch_root() -> Result<PathBuf> {
    Ok(state_dir()?.join("scratch"))
}

/// One session's scratch dir, created 0700 on first use and reaped with the
/// session.
pub fn session_scratch_dir(session_id: &str) -> Result<PathBuf> {
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
