//! Reference client for Session Protocol v0.1. It negotiates `hello`, but
//! reconnects in legacy mode when talking to a v0 daemon.

use crate::paths;
use crate::protocol::{
    read_frame, write_control, write_data, write_resize, AttachMode, ChannelRole, Control,
    CreateSpec, Frame, SessionInfo, Snapshot, PROTOCOL_VERSION,
};
use anyhow::{bail, Context, Result};
use std::os::fd::AsRawFd;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;

/// Byte that detaches an interactive attach without killing the session.
/// Ctrl-\ (0x1c) — same idea as abduco's default; rarely typed by agents.
const DETACH_KEY: u8 = 0x1c;

/// Connect to the daemon, auto-starting it if the socket is dead/missing.
pub async fn connect() -> Result<UnixStream> {
    let sock = paths::socket_path()?;
    if let Ok(s) = UnixStream::connect(&sock).await {
        return Ok(s);
    }
    // No live daemon — spawn one detached and wait for it to bind.
    spawn_daemon()?;
    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(40)).await;
        if let Ok(s) = UnixStream::connect(&sock).await {
            return Ok(s);
        }
    }
    bail!("could not reach termiod at {}", sock.display());
}

fn spawn_daemon() -> Result<()> {
    let exe = std::env::current_exe().context("locating termiod binary")?;
    use std::os::unix::process::CommandExt;
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("serve");
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::null());
    cmd.stderr(std::process::Stdio::null());
    unsafe {
        cmd.pre_exec(|| {
            // Detach from the client's session so the daemon survives us.
            libc::setsid();
            Ok(())
        });
    }
    cmd.spawn().context("starting termiod daemon")?;
    Ok(())
}

async fn request(msg: &Control) -> Result<Control> {
    let mut stream = connect_channel(ChannelRole::Control).await?;
    write_control(&mut stream, msg).await?;
    match read_frame(&mut stream).await? {
        Some(Frame::Control(c)) => Ok(c),
        Some(_) => bail!("daemon sent an unexpected frame"),
        None => bail!("daemon closed the connection"),
    }
}

async fn connect_channel(role: ChannelRole) -> Result<UnixStream> {
    Ok(connect_channel_with_identity(role, false).await?.0)
}

async fn connect_channel_with_identity(
    role: ChannelRole,
    snapshot: bool,
) -> Result<(UnixStream, Option<String>)> {
    let mut stream = connect().await?;
    let mut caps = vec!["events".to_string(), "send_wait".to_string()];
    if snapshot {
        caps.push("snapshot".to_string());
        caps.push("scrollback".to_string());
    }
    write_control(
        &mut stream,
        &Control::Hello {
            proto: PROTOCOL_VERSION,
            min_proto: PROTOCOL_VERSION,
            role,
            caps,
            client: format!("termiod-cli/{}", env!("CARGO_PKG_VERSION")),
        },
    )
    .await?;
    match read_frame(&mut stream).await {
        Ok(Some(Frame::Control(Control::HelloOk { client_id, .. }))) => {
            Ok((stream, Some(client_id)))
        }
        Ok(Some(Frame::Control(Control::HelloErr { code, supported }))) => {
            bail!("protocol negotiation failed ({code:?}); host supports {supported:?}")
        }
        // A v0 host either closes on the unknown hello op or returns its
        // legacy error. Reconnect and send the original v0-shaped request.
        Ok(Some(_)) | Ok(None) | Err(_) => Ok((connect().await?, None)),
    }
}

pub async fn create(spec: CreateSpec) -> Result<String> {
    match request(&Control::Create { spec, seq: Some(1) }).await? {
        Control::Created { id, .. } => Ok(id),
        Control::Error { message, .. } => bail!(message),
        other => bail!("unexpected reply: {other:?}"),
    }
}

pub async fn list() -> Result<Vec<SessionInfo>> {
    match request(&Control::List { seq: Some(1) }).await? {
        Control::Sessions { sessions, .. } => Ok(sessions),
        Control::Error { message, .. } => bail!(message),
        other => bail!("unexpected reply: {other:?}"),
    }
}

pub async fn kill(id: &str) -> Result<()> {
    match request(&Control::Kill {
        id: id.to_string(),
        seq: Some(1),
    })
    .await?
    {
        Control::Ok { .. } => Ok(()),
        Control::Error { message, .. } => bail!(message),
        other => bail!("unexpected reply: {other:?}"),
    }
}

pub async fn send(id: &str, data: Vec<u8>) -> Result<()> {
    match request(&Control::Send {
        id: id.to_string(),
        data,
        seq: Some(1),
    })
    .await?
    {
        Control::Ok { .. } => Ok(()),
        Control::Error { message, .. } => bail!(message),
        other => bail!("unexpected reply: {other:?}"),
    }
}

pub async fn set_status(id: &str, status: &str, title: Option<String>) -> Result<()> {
    match request(&Control::SetStatus {
        id: id.to_string(),
        status: status.to_string(),
        title,
        seq: Some(1),
    })
    .await?
    {
        Control::Ok { .. } => Ok(()),
        Control::Error { message, .. } => bail!(message),
        other => bail!("unexpected reply: {other:?}"),
    }
}

/// Local terminal window size via TIOCGWINSZ, with a sane fallback.
pub fn term_size() -> (u16, u16) {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::ioctl(libc::STDIN_FILENO, libc::TIOCGWINSZ, &mut ws) };
    if rc == 0 && ws.ws_row > 0 && ws.ws_col > 0 {
        (ws.ws_row, ws.ws_col)
    } else {
        (24, 80)
    }
}

/// RAII raw-mode guard for stdin; restores the saved termios on drop.
struct RawMode {
    fd: i32,
    saved: libc::termios,
    active: bool,
}

impl RawMode {
    fn enable() -> Result<RawMode> {
        let fd = std::io::stdin().as_raw_fd();
        let mut saved: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(fd, &mut saved) } != 0 {
            bail!("stdin is not a tty (tcgetattr failed)");
        }
        let mut raw = saved;
        unsafe { libc::cfmakeraw(&mut raw) };
        if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) } != 0 {
            bail!("tcsetattr failed");
        }
        Ok(RawMode {
            fd,
            saved,
            active: true,
        })
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        if self.active {
            unsafe {
                libc::tcsetattr(self.fd, libc::TCSANOW, &self.saved);
            }
        }
    }
}

/// Observe a session without interacting with it. PTY data is copied directly
/// to stdout until the session exits, the pipe closes, or SIGINT arrives.
pub async fn observe(target: &str, create_if_missing: Option<CreateSpec>) -> Result<()> {
    let (local_rows, local_cols) = term_size();
    let mut stream = connect_channel(ChannelRole::Attach).await?;
    write_control(
        &mut stream,
        &Control::Attach {
            target: target.to_string(),
            create_if_missing,
            rows: 24,
            cols: 80,
            mode: AttachMode::Observe,
            seq: Some(1),
        },
    )
    .await?;

    match read_frame(&mut stream).await? {
        Some(Frame::Control(Control::Attached { rows, cols, .. })) => {
            if (rows, cols) != (local_rows, local_cols) {
                eprintln!(
                    "session is {rows}x{cols}; your terminal is {local_rows}x{local_cols} \
                     — display may wrap differently"
                );
            }
        }
        Some(Frame::Control(Control::Error { message, .. })) => bail!(message),
        other => bail!("unexpected attach reply: {other:?}"),
    }

    let mut stdout = tokio::io::stdout();
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())
        .context("installing SIGINT handler")?;

    loop {
        tokio::select! {
            _ = interrupt.recv() => return Ok(()),
            frame = read_frame(&mut stream) => {
                match frame {
                    Ok(Some(Frame::Data(bytes))) => {
                        if stdout.write_all(&bytes).await.is_err()
                            || stdout.flush().await.is_err()
                        {
                            return Ok(());
                        }
                    }
                    Ok(Some(Frame::Control(Control::Exited { .. }))) => return Ok(()),
                    Ok(Some(_)) => {}
                    Ok(None) => return Ok(()),
                    Err(error) => return Err(error),
                }
            }
        }
    }
}

/// Attach interactively. Creates the session first if `create_if_missing` is
/// set and the target does not exist. Returns when the user detaches (Ctrl-\)
/// or the session's process exits.
pub async fn attach(target: &str, create_if_missing: Option<CreateSpec>) -> Result<()> {
    let (rows, cols) = term_size();
    let (mut stream, negotiated_client_id) =
        connect_channel_with_identity(ChannelRole::Attach, true).await?;
    write_control(
        &mut stream,
        &Control::Attach {
            target: target.to_string(),
            create_if_missing,
            rows,
            cols,
            mode: AttachMode::Interact,
            seq: Some(1),
        },
    )
    .await?;

    let id = match read_frame(&mut stream).await? {
        Some(Frame::Control(Control::Attached { id, name, .. })) => {
            eprintln!("[attached to {name} ({id}) — detach with Ctrl-\\ ]\r");
            id
        }
        Some(Frame::Control(Control::Error { message, .. })) => bail!(message),
        other => bail!("unexpected attach reply: {other:?}"),
    };

    let _raw = RawMode::enable()?;
    let (mut rd, mut wr) = stream.into_split();

    // Reader: daemon frames → stdout. Signals the main loop via `done_tx` when
    // the stream ends (session exited or closed), carrying any exit status.
    let (done_tx, mut done_rx) = tokio::sync::oneshot::channel::<Option<i32>>();
    let (resize_claim_tx, mut resize_claim_rx) = tokio::sync::mpsc::unbounded_channel();
    let scrollback_rows = Arc::new(AtomicUsize::new(0));
    let reader_scrollback_rows = scrollback_rows.clone();
    let reader = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        let mut status = None;
        loop {
            match read_frame(&mut rd).await {
                Ok(Some(Frame::Data(bytes))) => {
                    if stdout.write_all(&bytes).await.is_err() {
                        break;
                    }
                    let _ = stdout.flush().await;
                }
                Ok(Some(Frame::Snapshot(snapshot))) => {
                    if render_snapshot(&mut stdout, &snapshot).await.is_err() {
                        break;
                    }
                }
                Ok(Some(Frame::History(history))) => {
                    reader_scrollback_rows
                        .fetch_add(usize::from(history.row_count), Ordering::Relaxed);
                }
                Ok(Some(Frame::Control(Control::ResizeClaim {
                    writer: Some(writer),
                    ..
                }))) if negotiated_client_id.as_deref() == Some(writer.as_str()) => {
                    let _ = resize_claim_tx.send(());
                }
                Ok(Some(Frame::Control(Control::Exited { status: s, .. }))) => {
                    status = Some(s);
                    break;
                }
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => break,
            }
        }
        let _ = done_tx.send(status);
    });

    // SIGWINCH → resize.
    let mut winch = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())
        .context("installing SIGWINCH handler")?;

    // stdin → daemon (watching for the detach key).
    let mut stdin = tokio::io::stdin();
    use tokio::io::AsyncReadExt;
    let mut buf = [0u8; 8192];
    let mut detached = false;
    loop {
        tokio::select! {
            _ = winch.recv() => {
                let (r, c) = term_size();
                let _ = write_resize(&mut wr, r, c).await;
            }
            Some(()) = resize_claim_rx.recv() => {
                let (r, c) = term_size();
                let _ = write_resize(&mut wr, r, c).await;
            }
            n = stdin.read(&mut buf) => {
                match n {
                    Ok(0) => break, // stdin closed
                    Ok(n) => {
                        if let Some(pos) = buf[..n].iter().position(|&b| b == DETACH_KEY) {
                            if pos > 0 {
                                let _ = write_data(&mut wr, &buf[..pos]).await;
                            }
                            detached = true;
                            break;
                        }
                        if write_data(&mut wr, &buf[..n]).await.is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            done = &mut done_rx => {
                // Reader finished: session exited or the socket closed.
                drop(_raw);
                if let Ok(Some(status)) = done {
                    eprintln!("\r\n[session exited: status {status}]");
                } else {
                    eprintln!("\r\n[disconnected]");
                }
                report_scrollback(scrollback_rows.load(Ordering::Relaxed));
                return Ok(());
            }
        }
    }

    if detached {
        let _ = write_control(&mut wr, &Control::Detach { seq: None }).await;
        eprintln!("\r\n[detached — session {id} still running]");
    }
    reader.abort();
    report_scrollback(scrollback_rows.load(Ordering::Relaxed));
    Ok(())
}

fn report_scrollback(rows: usize) {
    if rows > 0 {
        eprintln!("scrollback: {rows} rows staged");
    }
}

async fn render_snapshot<W: AsyncWriteExt + Unpin>(
    output: &mut W,
    snapshot: &Snapshot,
) -> Result<()> {
    let mut rendered = Vec::with_capacity(snapshot.cells.len() + usize::from(snapshot.rows) * 2);
    rendered.extend_from_slice(b"\x1b[2J\x1b[H");
    for row in 0..snapshot.rows {
        if row > 0 {
            rendered.extend_from_slice(b"\r\n");
        }
        let start = usize::from(row) * usize::from(snapshot.cols);
        let end = start + usize::from(snapshot.cols);
        for cell in &snapshot.cells[start..end] {
            let character = if cell.codepoint == 0 {
                ' '
            } else {
                char::from_u32(cell.codepoint).unwrap_or('\u{fffd}')
            };
            let mut encoded = [0; 4];
            rendered.extend_from_slice(character.encode_utf8(&mut encoded).as_bytes());
        }
    }
    rendered.extend_from_slice(
        format!(
            "\x1b[{};{}H",
            snapshot.cursor_y.saturating_add(1),
            snapshot.cursor_x.saturating_add(1)
        )
        .as_bytes(),
    );
    output.write_all(&rendered).await?;
    output.flush().await?;
    Ok(())
}
