//! PTY ownership. The daemon opens a pseudo-terminal, spawns the session's
//! program on the slave side with the **login_tty shape** (setsid +
//! TIOCSCTTY + dup to 0/1/2), and keeps the master for byte I/O.
//!
//! The login_tty shape is deliberate: termio's macOS app learned the hard way
//! that a `posix_spawn`-without-controlling-tty PTY breaks agents' resize
//! repaint (see the repo's `terminal-resize-no-reflow` handoff). We reproduce
//! the `forkpty`/`login_tty` layout here so a remote `claude`/`codex` reflows
//! correctly on resize.

use anyhow::{bail, Context, Result};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use tokio::io::unix::AsyncFd;

/// The PTY master for a session. The child `Child` is handed back separately
/// so the session task can reap it in a blocking wait without borrowing this.
pub struct Pty {
    master: AsyncFd<OwnedFd>,
    pub pid: i32,
}

fn set_winsize(fd: RawFd, rows: u16, cols: u16) -> Result<()> {
    let ws = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &ws) };
    if rc != 0 {
        bail!("TIOCSWINSZ failed: {}", std::io::Error::last_os_error());
    }
    Ok(())
}

fn set_nonblocking(fd: RawFd) -> Result<()> {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 {
            bail!("F_GETFL: {}", std::io::Error::last_os_error());
        }
        if libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
            bail!("F_SETFL O_NONBLOCK: {}", std::io::Error::last_os_error());
        }
    }
    Ok(())
}

fn set_cloexec(fd: RawFd) -> Result<()> {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags < 0 {
            bail!("F_GETFD: {}", std::io::Error::last_os_error());
        }
        if libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) < 0 {
            bail!("F_SETFD FD_CLOEXEC: {}", std::io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Environment variables that describe the terminal — or the agent — that
/// happened to launch the daemon, not how a session should run.
///
/// The daemon is long-lived and inherits its environment from whoever started
/// it: the macOS app hands over its own `environ` (it must, for TMPDIR), and
/// the app in turn inherits the shell that opened it. So a daemon started from
/// inside a Claude Code session carries `CLAUDE_CODE_CHILD_SESSION` forever,
/// and every session it spawns — hours or days later — inherits that agent's
/// identity. Claude Code reads that flag as "you are a sub-session" and stops
/// writing its transcript, so those sessions silently keep no history and
/// never appear in `--resume`.
///
/// The macOS app strips the same set before it spawns a PTY in-process
/// (`TermioStore.sanitizedEnvironment`), but it strips by *omission*: it sends
/// the environment it wants and omission cannot unset what this process
/// already has. Removing them here is what makes both spawn paths agree.
const LAUNCHER_ENV_KEYS: &[&str] = &[
    "CLAUDECODE",
    "CLAUDE_EFFORT",
    "TERMIO_SESSION",
    "TERM_SESSION_ID",
    "TERMINAL_EMULATOR",
    "TMUX",
    "TMUX_PANE",
    "STY",
    "INSIDE_EMACS",
    "LC_TERMINAL",
    "LC_TERMINAL_VERSION",
    "KONSOLE_VERSION",
    "GNOME_TERMINAL_SERVICE",
    "WT_SESSION",
    "NO_COLOR",
    "FORCE_COLOR",
    "CLICOLOR",
    "CLICOLOR_FORCE",
];

const LAUNCHER_ENV_PREFIXES: &[&str] = &[
    "TERM_PROGRAM",
    "VSCODE_",
    "CLAUDE_CODE_",
    "ITERM_",
    "GHOSTTY_",
    "KITTY_",
    "WEZTERM_",
    "ALACRITTY_",
];

fn is_launcher_env(key: &str) -> bool {
    LAUNCHER_ENV_KEYS.contains(&key) || LAUNCHER_ENV_PREFIXES.iter().any(|p| key.starts_with(p))
}

/// The launcher variables actually present in this daemon's environment. A
/// session that wants any of them back — `TERM_PROGRAM=termio`,
/// `TERMIO_SESSION=<this session's id>` — gets them as an explicit override,
/// which is layered after the removal.
fn inherited_launcher_keys() -> Vec<std::ffi::OsString> {
    std::env::vars_os()
        .map(|(key, _)| key)
        .filter(|key| key.to_str().is_some_and(is_launcher_env))
        .collect()
}

impl Pty {
    /// Open a PTY and spawn `argv` in `cwd`. Empty argv ⇒ the user's login
    /// shell, run as a login shell (`-<shell>`).
    pub fn spawn(
        argv: &[String],
        cwd: Option<&str>,
        env: &[(String, String)],
        rows: u16,
        cols: u16,
    ) -> Result<(Pty, Child)> {
        let mut master_raw: RawFd = -1;
        let mut slave_raw: RawFd = -1;
        let mut ws = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // `openpty`'s termp/winp pointer mutability differs between macOS
        // (`*mut`) and Linux (`*const`); `as _` coerces to whichever the target
        // libc expects.
        let rc = unsafe {
            libc::openpty(
                &mut master_raw,
                &mut slave_raw,
                std::ptr::null_mut::<libc::c_char>(),
                std::ptr::null_mut::<libc::termios>() as _,
                (&mut ws as *mut libc::winsize) as _,
            )
        };
        if rc != 0 {
            bail!("openpty failed: {}", std::io::Error::last_os_error());
        }

        // The master is ours; keep it off the child and make it async-pollable.
        let master = unsafe { OwnedFd::from_raw_fd(master_raw) };
        set_cloexec(master.as_raw_fd())?;
        set_nonblocking(master.as_raw_fd())?;

        let (program, args, login_shell) = resolve_program(argv);

        let mut cmd = Command::new(&program);
        cmd.args(&args);
        if let Some(dir) = cwd {
            cmd.current_dir(dir);
        }
        // Inherit the daemon's environment, minus whatever the daemon's own
        // launcher stamped into it, then layer session overrides.
        for key in inherited_launcher_keys() {
            cmd.env_remove(key);
        }
        if std::env::var_os("TERM").is_none() {
            cmd.env("TERM", "xterm-256color");
        }
        cmd.env("TERMIOD_SESSION", "1");
        for (k, v) in env {
            cmd.env(k, v);
        }
        if login_shell {
            // argv[0] = "-<shell>" marks a login shell to the shell itself.
            let base = std::path::Path::new(&program)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("sh");
            cmd.arg0(format!("-{base}"));
        }

        // The child's stdio is wired inside pre_exec via login_tty; don't let
        // std pre-open pipes for it.
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::null());
        cmd.stderr(Stdio::null());

        unsafe {
            cmd.pre_exec(move || {
                // login_tty shape: new session, take the slave as controlling
                // tty, and make it fds 0/1/2.
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::ioctl(slave_raw, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                for target in 0..3 {
                    if libc::dup2(slave_raw, target) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                }
                if slave_raw > 2 {
                    libc::close(slave_raw);
                }
                Ok(())
            });
        }

        let child = cmd
            .spawn()
            .with_context(|| format!("spawning session program '{program}'"))?;

        // Parent no longer needs the slave.
        unsafe {
            libc::close(slave_raw);
        }

        let pid = child.id() as i32;
        let master = AsyncFd::new(master)?;
        Ok((Pty { master, pid }, child))
    }

    #[cfg(test)]
    pub(crate) fn non_pty_for_resize_failure_test() -> Result<Pty> {
        let (socket, peer) = std::os::unix::net::UnixStream::pair()?;
        drop(peer);
        socket.set_nonblocking(true)?;
        let fd: OwnedFd = socket.into();
        Ok(Pty {
            master: AsyncFd::new(fd)?,
            pid: 0,
        })
    }

    /// The process group that currently owns the tty's foreground — the program
    /// the user is actually interacting with: the login shell until it runs a
    /// command, then that command, then the shell again once it exits.
    ///
    /// `tcgetpgrp` on the *master* is deliberate and portable: both XNU and
    /// Linux route TIOCGPGRP on a pty master to the slave's session, and the
    /// master side is exempt from the "must be your controlling terminal" check
    /// that would otherwise refuse the daemon. `None` when the slave has no
    /// session (the child is gone, or has not exec'd yet).
    pub fn foreground_pgid(&self) -> Option<i32> {
        let pgid = unsafe { libc::tcgetpgrp(self.master.get_ref().as_raw_fd()) };
        (pgid > 0).then_some(pgid)
    }

    /// Push a new window size to the PTY (TIOCSWINSZ). The kernel delivers
    /// SIGWINCH to the foreground process group.
    pub fn resize(&self, rows: u16, cols: u16) -> Result<()> {
        set_winsize(self.master.get_ref().as_raw_fd(), rows, cols)
    }

    /// Read available PTY output. `Ok(0)` means the slave closed (process
    /// gone).
    pub async fn read(&self, buf: &mut [u8]) -> std::io::Result<usize> {
        loop {
            let mut guard = self.master.readable().await?;
            let fd = self.master.get_ref().as_raw_fd();
            match guard.try_io(|_| {
                let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut _, buf.len()) };
                if n < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            }) {
                Ok(result) => return result,
                Err(_would_block) => continue,
            }
        }
    }

    /// Write client input to the PTY.
    pub async fn write_all(&self, mut data: &[u8]) -> std::io::Result<()> {
        while !data.is_empty() {
            let mut guard = self.master.writable().await?;
            let fd = self.master.get_ref().as_raw_fd();
            match guard.try_io(|_| {
                let n = unsafe { libc::write(fd, data.as_ptr() as *const _, data.len()) };
                if n < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            }) {
                Ok(Ok(n)) => data = &data[n..],
                Ok(Err(e)) => return Err(e),
                Err(_would_block) => continue,
            }
        }
        Ok(())
    }
}

/// Decide the program to exec. Empty argv ⇒ `$SHELL` (or `/bin/sh`) as a login
/// shell. Otherwise run argv verbatim.
fn resolve_program(argv: &[String]) -> (String, Vec<String>, bool) {
    if argv.is_empty() {
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        (shell, Vec::new(), true)
    } else {
        (argv[0].clone(), argv[1..].to_vec(), false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launcher_identity_is_classified_apart_from_the_session_environment() {
        assert!(is_launcher_env("CLAUDE_CODE_CHILD_SESSION"));
        assert!(is_launcher_env("CLAUDE_CODE_SESSION_ID"));
        assert!(is_launcher_env("CLAUDECODE"));
        assert!(is_launcher_env("TERM_PROGRAM"));
        assert!(is_launcher_env("TERM_PROGRAM_VERSION"));
        assert!(is_launcher_env("TERMIO_SESSION"));
        assert!(is_launcher_env("TMUX"));

        // Everything that says where the process runs, rather than who started
        // the daemon, has to survive — a session with no PATH is unusable.
        assert!(!is_launcher_env("PATH"));
        assert!(!is_launcher_env("HOME"));
        assert!(!is_launcher_env("SHELL"));
        assert!(!is_launcher_env("TMPDIR"));
        assert!(!is_launcher_env("TERM"));
        assert!(!is_launcher_env("ANTHROPIC_API_KEY"));
    }

    /// The ordering half: removal happens *before* the session's own overrides
    /// are layered, so a session can still ask for a key the daemon inherited.
    #[tokio::test]
    async fn spawned_child_gets_the_session_identity_not_the_daemon_launcher_identity() {
        std::env::set_var("CLAUDE_CODE_CHILD_SESSION", "1");
        std::env::set_var("TERM_PROGRAM", "Apple_Terminal");

        let dump = std::env::temp_dir().join(format!("termiod-env-{}", std::process::id()));
        let argv = vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            format!("env > {}", dump.display()),
        ];
        let overrides = vec![("TERM_PROGRAM".to_string(), "termio".to_string())];
        let (_pty, mut child) =
            Pty::spawn(&argv, None, &overrides, 24, 80).expect("spawn env dump");
        child.wait().expect("child exits");

        let dumped = std::fs::read_to_string(&dump).expect("env dump");
        let _ = std::fs::remove_file(&dump);
        // Process-global, so leaving it set would follow every other test in
        // this binary into whatever it spawns.
        std::env::remove_var("CLAUDE_CODE_CHILD_SESSION");
        std::env::remove_var("TERM_PROGRAM");

        assert!(!dumped.contains("CLAUDE_CODE_CHILD_SESSION="));
        assert!(dumped.contains("TERM_PROGRAM=termio"));
        assert!(!dumped.contains("TERM_PROGRAM=Apple_Terminal"));
    }
}
