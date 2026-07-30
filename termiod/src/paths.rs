//! Where the control socket lives.
//!
//! Prefer `$XDG_RUNTIME_DIR/termiod/` (per-user, tmpfs, auto-cleaned on
//! logout). Fall back to a uid-scoped dir under the system temp dir. Either
//! way the directory is created 0700 so no other user can connect.

use anyhow::{Context, Result};
use std::path::PathBuf;

/// Directory holding the socket (and, later, logs / pid files).
pub fn runtime_dir() -> Result<PathBuf> {
    let base = if let Some(xdg) = std::env::var_os("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg).join("termiod")
    } else {
        let uid = unsafe { libc::getuid() };
        std::env::temp_dir().join(format!("termiod-{uid}"))
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

/// Create the runtime dir with 0700 permissions if it does not exist.
pub fn ensure_runtime_dir() -> Result<PathBuf> {
    use std::os::unix::fs::DirBuilderExt;
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
