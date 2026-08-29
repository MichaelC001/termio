//! Replacing the daemon's binary without replacing the daemon.
//!
//! Every other way of upgrading the host ends with the sessions dead, and not
//! by oversight. A PTY's master is a descriptor held by this process; when this
//! process goes the descriptor closes, the slave side raises `SIGHUP`, and the
//! agent that was mid-task goes with it. Writing state down does not help — a
//! file can describe a session but cannot hold a running process.
//!
//! `execve` is the exception. It replaces the process *image* while keeping the
//! *process*: same pid, same children, same open descriptors (anything without
//! `FD_CLOEXEC`), same session and process group. So the PTY masters stay open,
//! the shells never see a hangup, and the only thing that changes is which code
//! is on the other end of the descriptor. This is what makes "detach ≠ kill"
//! survive an upgrade rather than only a disconnect: the lifecycle loop can
//! stop asking the user to close their work before a new build goes on.
//!
//! What it costs is that nothing in memory survives. Tasks, the session table,
//! the replay rings, the client connections: gone the instant `execve` succeeds.
//! Whatever the new image needs, this one has to write down first and pass along
//! by descriptor number. That is what a [`Blob`] is.
//!
//! The blob is written to a file that is unlinked before a byte goes into it,
//! so it has no name for anything to open and the kernel frees it when the last
//! descriptor closes. That matters: it holds every session's replay ring, which
//! is raw terminal output — an agent's transcript, whatever `env` printed, a
//! token someone echoed. A handoff must not become a way of writing that to
//! disk behind the user's back.
//!
//! Not everything crosses:
//!
//! - **Client connections.** A Mac or a phone is holding a socket to us; that
//!   socket dies with the image. Clients reconnect and re-attach by session id,
//!   which is the path they already use after any restart — except that this
//!   time the attach finds the session alive, with its ring and its running
//!   program.
//! - **The WebSocket listener.** Re-bound by the new image from the same
//!   on-disk configuration rather than carried, so its splices end the way a
//!   dropped tunnel already does.
//! - **The VT sidecar.** A parser is state in memory, not a descriptor. The new
//!   image starts a fresh one and replays the carried ring through it, which
//!   reconstructs the screen from the same bytes that produced it.
//!
//! The Unix listener *is* carried, on its own descriptor. Re-binding would mean
//! unlinking and re-creating the socket, and a client connecting in that window
//! would find nothing there and autostart a second daemon over a state
//! directory this one still owns. Carrying it means connects queue in the
//! kernel's backlog and are served by whichever image is up when they are
//! accepted.

use anyhow::{bail, Context, Result};
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};

/// The flag that tells a starting daemon it is the far side of a handoff. Its
/// value is the descriptor number the blob can be read from.
pub const HANDOFF_FLAG: &str = "--handoff";

const MAGIC: &[u8; 8] = b"TERMIOD\x01";

/// How long the daemon waits for a session actor to hand its PTY over. A
/// session that misses this is left behind rather than holding the upgrade
/// open, and is named in the daemon's log on the way out.
pub const CARRY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

/// One session, packed for the crossing. The descriptor numbers are meaningless
/// to anything but the process that wrote them, which is the same process that
/// reads them back — that is the whole point of the exec.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CarriedSession {
    pub id: String,
    pub name: String,
    pub cwd: String,
    pub command: String,
    pub pid: i32,
    pub rows: u16,
    pub cols: u16,
    pub created_unix: u64,
    pub status: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub workstream: Option<crate::protocol::WorkstreamSpec>,
    /// The PTY master, as a descriptor number in the process about to `execve`.
    pub master_fd: RawFd,
    /// How many bytes of replay ring follow this session's header in the blob.
    pub ring_len: u64,
}

/// The header the new image reads before it has any state of its own. Ring
/// bytes follow it, one run per session in `sessions` order.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Blob {
    /// The build that packed this. Recorded for the log line the new image
    /// writes: "0.46.0+1201 handed off to 0.47.0+1240" is the one fact that
    /// makes an upgrade legible after the fact.
    pub from_build: String,
    /// The already-bound Unix listener. See the module docs for why this is
    /// carried rather than re-bound.
    pub listener_fd: RawFd,
    pub sessions: Vec<CarriedSession>,
}

/// Whether `binary` can be handed off to at all, checked *before* the running
/// daemon takes a single session apart.
///
/// The order matters more than the checks do. Once the session actors have
/// given up their PTYs there is no way back: the actors are gone, the rings are
/// in a blob, and the only paths left are `execve` or death. So everything that
/// can say no says it here, while the daemon is still whole and the client is
/// still holding a socket that can carry the refusal.
///
/// The last check is the strong one: the candidate is *run*. A binary for the
/// wrong architecture, or missing an interpreter, or truncated by an upload
/// that lost its connection, all fail `--version` and all look fine to `stat`.
pub fn vet(binary: &Path) -> Result<PathBuf> {
    if !binary.is_absolute() {
        bail!("{} is not an absolute path", binary.display());
    }
    let binary = binary
        .canonicalize()
        .with_context(|| format!("resolving {}", binary.display()))?;
    let metadata =
        std::fs::metadata(&binary).with_context(|| format!("reading {}", binary.display()))?;
    if !metadata.is_file() {
        bail!("{} is not a regular file", binary.display());
    }
    let probe = std::process::Command::new(&binary)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .output()
        .with_context(|| format!("running {} --version", binary.display()))?;
    if !probe.status.success() {
        bail!(
            "{} --version exited {}: {}",
            binary.display(),
            probe.status,
            String::from_utf8_lossy(&probe.stderr).trim()
        );
    }
    if String::from_utf8_lossy(&probe.stdout).trim().is_empty() {
        bail!("{} --version printed nothing", binary.display());
    }
    Ok(binary)
}

/// Write the blob to an unlinked file and return its descriptor, rewound and
/// exec-safe.
pub fn pack(blob: &Blob, rings: &[Vec<Bytes>], state_dir: &Path) -> Result<OwnedFd> {
    let path = state_dir.join(format!("handoff.{}", std::process::id()));
    let mut file = std::fs::OpenOptions::new()
        .create_new(true)
        .read(true)
        .write(true)
        .open(&path)
        .with_context(|| format!("opening {}", path.display()))?;
    // Before a byte goes in. From here the file has no name: nothing can open
    // it, and the kernel reclaims it when the last descriptor closes — which,
    // on the success path, is the new image closing it after the read.
    std::fs::remove_file(&path).with_context(|| format!("unlinking {}", path.display()))?;

    let header = serde_json::to_vec(blob).context("encoding the handoff header")?;
    file.write_all(MAGIC)?;
    file.write_all(&(header.len() as u32).to_le_bytes())?;
    file.write_all(&header)?;
    for ring in rings {
        for chunk in ring {
            file.write_all(chunk)?;
        }
    }
    file.flush()?;
    file.seek(SeekFrom::Start(0))?;

    let fd = unsafe { OwnedFd::from_raw_fd(file.into_raw_fd()) };
    set_inheritable(fd.as_raw_fd())?;
    Ok(fd)
}

/// Read back what [`pack`] wrote. Consumes the descriptor: the blob has served
/// its purpose the moment it is in memory, and leaving it open would keep every
/// session's terminal output alive in a file for the daemon's whole life.
pub fn unpack(fd: RawFd) -> Result<(Blob, Vec<Vec<u8>>)> {
    let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
    let mut magic = [0u8; 8];
    file.read_exact(&mut magic)
        .context("reading the handoff blob")?;
    if &magic != MAGIC {
        bail!("descriptor {fd} does not hold a handoff blob");
    }
    let mut length = [0u8; 4];
    file.read_exact(&mut length)?;
    let mut header = vec![0u8; u32::from_le_bytes(length) as usize];
    file.read_exact(&mut header)?;
    let blob: Blob = serde_json::from_slice(&header).context("decoding the handoff header")?;

    let mut rings = Vec::with_capacity(blob.sessions.len());
    for session in &blob.sessions {
        let mut ring = vec![0u8; session.ring_len as usize];
        file.read_exact(&mut ring)
            .with_context(|| format!("reading the replay ring for session {}", session.id))?;
        rings.push(ring);
    }
    Ok((blob, rings))
}

/// A descriptor the new image will need, duplicated so it outlives whatever
/// owns the original and cleared for exec.
///
/// Duplicating rather than leaking the original is what lets the session actor
/// be dropped normally on its way out: its `OwnedFd` closes, this copy stays,
/// and both named the same open file description all along — the same PTY
/// master, at the same offset, with the same termios.
pub fn duplicate_for_exec(fd: RawFd) -> Result<RawFd> {
    let copy = unsafe { libc::dup(fd) };
    if copy < 0 {
        bail!(
            "duplicating descriptor {fd}: {}",
            std::io::Error::last_os_error()
        );
    }
    // `dup` already clears `FD_CLOEXEC` on the copy. Set it anyway: the one
    // invariant this whole module rests on should not be an inherited default.
    set_inheritable(copy)?;
    Ok(copy)
}

fn set_inheritable(fd: RawFd) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        bail!("F_GETFD on {fd}: {}", std::io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) } < 0 {
        bail!(
            "clearing FD_CLOEXEC on {fd}: {}",
            std::io::Error::last_os_error()
        );
    }
    Ok(())
}

/// This daemon's own `serve` invocation, with any previous handoff flag taken
/// out. Re-passing the arguments verbatim is what keeps an explicit `--wss` or
/// `--wss-origin` in force across an upgrade; stripping the old `--handoff`
/// keeps the second handoff of a daemon's life from pointing the new image at a
/// descriptor number that meant something two builds ago.
pub fn serve_arguments() -> Vec<std::ffi::OsString> {
    strip_handoff(std::env::args_os().skip(1))
}

fn strip_handoff(arguments: impl Iterator<Item = std::ffi::OsString>) -> Vec<std::ffi::OsString> {
    let prefixed = format!("{HANDOFF_FLAG}=");
    let mut kept = Vec::new();
    let mut arguments = arguments.peekable();
    while let Some(argument) = arguments.next() {
        if argument == HANDOFF_FLAG {
            let _ = arguments.next();
            continue;
        }
        if argument
            .to_str()
            .is_some_and(|text| text.starts_with(&prefixed))
        {
            continue;
        }
        kept.push(argument);
    }
    kept
}

/// Become `binary`. Returns only on failure — success has no return address.
///
/// The caller has already given up every session actor by the time this runs,
/// so a failure here is not recoverable: the PTYs are held by descriptors this
/// process still owns but nothing is left that knows how to read them. The
/// error is for the log and for the exit that follows it.
pub fn exec(binary: &Path, blob_fd: RawFd) -> anyhow::Error {
    use std::os::unix::process::CommandExt;

    let mut command = std::process::Command::new(binary);
    command.args(serve_arguments());
    command.arg(HANDOFF_FLAG).arg(blob_fd.to_string());
    let error = command.exec();
    anyhow::Error::new(error).context(format!("exec {}", binary.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_packed_blob_reads_back_with_its_rings_in_order() {
        let dir = std::env::temp_dir().join(format!("termiod-handoff-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let blob = Blob {
            from_build: "0.1.0+1".to_string(),
            listener_fd: 7,
            sessions: vec![session("a", 3), session("b", 5)],
        };
        let rings = vec![
            vec![Bytes::from_static(b"abc")],
            vec![Bytes::from_static(b"de"), Bytes::from_static(b"fgh")],
        ];
        let fd = pack(&blob, &rings, &dir).unwrap();
        let (read_back, read_rings) = unpack(fd.into_raw_fd()).unwrap();
        assert_eq!(read_back.listener_fd, 7);
        assert_eq!(read_back.from_build, "0.1.0+1");
        assert_eq!(read_rings, vec![b"abc".to_vec(), b"defgh".to_vec()]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_previous_handoff_flag_never_reaches_the_next_image() {
        let kept = strip_handoff(
            ["serve", "--handoff", "9", "--wss", "127.0.0.1:8790"]
                .into_iter()
                .map(std::ffi::OsString::from),
        );
        assert_eq!(kept, ["serve", "--wss", "127.0.0.1:8790"]);
        assert_eq!(
            strip_handoff(
                ["serve", "--handoff=9"]
                    .into_iter()
                    .map(std::ffi::OsString::from)
            ),
            ["serve"]
        );
    }

    fn session(id: &str, ring_len: u64) -> CarriedSession {
        CarriedSession {
            id: id.to_string(),
            name: id.to_string(),
            cwd: String::new(),
            command: "sh".to_string(),
            pid: 1,
            rows: 24,
            cols: 80,
            created_unix: 0,
            status: "unknown".to_string(),
            title: None,
            workstream: None,
            master_fd: 10,
            ring_len,
        }
    }
}
