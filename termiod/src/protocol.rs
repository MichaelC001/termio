//! Protocol v0 — the wire contract between a termiod client and the daemon.
//!
//! One framed, bidirectional byte stream carries everything. A frame is:
//!
//! ```text
//! [ kind: u8 ][ len: u32 big-endian ][ payload: len bytes ]
//! ```
//!
//! Three kinds. Control frames are JSON request/response for lifecycle
//! (`create`/`list`/`kill`/`send`/`attach`). Data frames are the **raw PTY
//! byte stream** in both directions — the hot path, never re-encoded. Resize
//! frames carry a window size. Keeping data raw (not grid-diffed) is the
//! deliberate v0 scope from `docs/design/termiod-session-mux.md` §4.3.

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub const KIND_CONTROL: u8 = b'C';
pub const KIND_DATA: u8 = b'D';
pub const KIND_RESIZE: u8 = b'R';

/// A single decoded frame off the wire.
#[derive(Debug)]
pub enum Frame {
    Control(Control),
    Data(Vec<u8>),
    Resize { rows: u16, cols: u16 },
}

/// How to spawn a session's process.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateSpec {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    /// argv[0] is the program. Empty ⇒ the daemon picks the login shell.
    #[serde(default)]
    pub argv: Vec<String>,
    #[serde(default)]
    pub env: Vec<(String, String)>,
    #[serde(default = "default_rows")]
    pub rows: u16,
    #[serde(default = "default_cols")]
    pub cols: u16,
}

fn default_rows() -> u16 {
    24
}
fn default_cols() -> u16 {
    80
}

impl Default for CreateSpec {
    fn default() -> Self {
        CreateSpec {
            name: None,
            cwd: None,
            argv: Vec::new(),
            env: Vec::new(),
            rows: default_rows(),
            cols: default_cols(),
        }
    }
}

/// Control-plane messages. `op` tags the variant on the wire.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Control {
    // Client → daemon requests.
    Create(CreateSpec),
    List,
    Kill {
        id: String,
    },
    Send {
        id: String,
        data: Vec<u8>,
    },
    Attach {
        /// Session id or name to attach to.
        target: String,
        /// If the target does not exist, create it with this spec.
        #[serde(default)]
        create_if_missing: Option<CreateSpec>,
        rows: u16,
        cols: u16,
    },
    /// Client asks to leave the stream but keep the session alive.
    Detach,

    // Daemon → client responses.
    Ok,
    Created {
        id: String,
    },
    Sessions {
        sessions: Vec<SessionInfo>,
    },
    Attached {
        id: String,
        name: String,
    },
    /// Sent when the attached session's process exits.
    Exited {
        id: String,
        status: i32,
    },
    Error {
        message: String,
    },
}

/// A row in `termiod list`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: String,
    pub name: String,
    pub cwd: String,
    pub command: String,
    pub pid: i32,
    pub rows: u16,
    pub cols: u16,
    pub clients: usize,
    pub created_unix: u64,
    pub alive: bool,
}

pub async fn write_frame<W: AsyncWriteExt + Unpin>(w: &mut W, kind: u8, payload: &[u8]) -> Result<()> {
    if payload.len() > u32::MAX as usize {
        bail!("frame payload too large");
    }
    let mut header = [0u8; 5];
    header[0] = kind;
    header[1..5].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    w.write_all(&header).await?;
    w.write_all(payload).await?;
    w.flush().await?;
    Ok(())
}

pub async fn write_control<W: AsyncWriteExt + Unpin>(w: &mut W, msg: &Control) -> Result<()> {
    let payload = serde_json::to_vec(msg)?;
    write_frame(w, KIND_CONTROL, &payload).await
}

pub async fn write_data<W: AsyncWriteExt + Unpin>(w: &mut W, data: &[u8]) -> Result<()> {
    write_frame(w, KIND_DATA, data).await
}

pub async fn write_resize<W: AsyncWriteExt + Unpin>(w: &mut W, rows: u16, cols: u16) -> Result<()> {
    let mut buf = [0u8; 4];
    buf[0..2].copy_from_slice(&rows.to_be_bytes());
    buf[2..4].copy_from_slice(&cols.to_be_bytes());
    write_frame(w, KIND_RESIZE, &buf).await
}

/// Read one frame. Returns `None` on a clean EOF at a frame boundary.
pub async fn read_frame<R: AsyncReadExt + Unpin>(r: &mut R) -> Result<Option<Frame>> {
    let mut header = [0u8; 5];
    match r.read_exact(&mut header).await {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    let kind = header[0];
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload).await?;
    match kind {
        KIND_CONTROL => {
            let ctrl: Control = serde_json::from_slice(&payload)?;
            Ok(Some(Frame::Control(ctrl)))
        }
        KIND_DATA => Ok(Some(Frame::Data(payload))),
        KIND_RESIZE => {
            if payload.len() != 4 {
                bail!("malformed resize frame");
            }
            let rows = u16::from_be_bytes([payload[0], payload[1]]);
            let cols = u16::from_be_bytes([payload[2], payload[3]]);
            Ok(Some(Frame::Resize { rows, cols }))
        }
        other => bail!("unknown frame kind {other:#x}"),
    }
}
