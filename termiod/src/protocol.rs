//! Session Protocol v0.1 — the wire contract between clients and `termiod`.
//!
//! Framing is frozen from v0:
//!
//! ```text
//! [ kind: u8 ][ len: u32 big-endian ][ payload: len bytes ]
//! ```
//!
//! Control and event payloads are JSON. PTY data stays raw and resize stays a
//! four-byte binary payload, so v0 clients remain byte-compatible.

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub const KIND_CONTROL: u8 = b'C';
pub const KIND_DATA: u8 = b'D';
pub const KIND_RESIZE: u8 = b'R';
pub const KIND_EVENT: u8 = b'E';

pub const MAX_FRAME_SIZE: usize = 16 * 1024 * 1024;
pub const MAX_DATA_FRAME_SIZE: usize = 64 * 1024;
pub const PROTOCOL_VERSION: u32 = 1;
pub const SUPPORTED_PROTOCOLS: &[u32] = &[PROTOCOL_VERSION];
pub const HOST_CAPABILITIES: &[&str] = &["events", "send_wait"];

/// A single decoded frame off the wire.
#[derive(Debug)]
pub enum Frame {
    Control(Control),
    Data(Vec<u8>),
    Resize { rows: u16, cols: u16 },
    Event(Event),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChannelRole {
    Control,
    Attach,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttachMode {
    #[default]
    Interact,
    Observe,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    Incompatible,
    ProtoError,
    NoSuchSession,
    NotWriter,
    AlreadyExited,
    CreateFailed,
    Denied,
    Busy,
    #[default]
    Internal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkstreamSpec {
    pub agent_id: String,
    pub project: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workstream: Option<WorkstreamSpec>,
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
            workstream: None,
        }
    }
}

/// Control-plane messages. `op` tags the variant on the wire.
///
/// Optional `seq`/`re` fields are omitted when absent, preserving the exact v0
/// shapes. Unknown operations deserialize to `Unknown` and are ignored.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Control {
    // Handshake.
    Hello {
        proto: u32,
        min_proto: u32,
        role: ChannelRole,
        #[serde(default)]
        caps: Vec<String>,
        client: String,
    },
    HelloOk {
        proto: u32,
        #[serde(default)]
        caps: Vec<String>,
        host_id: String,
        host: String,
        client_id: String,
    },
    HelloErr {
        code: ErrorCode,
        supported: Vec<u32>,
    },

    // Client → daemon requests.
    Create {
        #[serde(flatten)]
        spec: CreateSpec,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    List {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    Kill {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    Send {
        id: String,
        data: Vec<u8>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    Attach {
        /// Session id or name to attach to.
        target: String,
        /// If the target does not exist, create it with this spec.
        #[serde(default)]
        create_if_missing: Option<CreateSpec>,
        rows: u16,
        cols: u16,
        #[serde(default)]
        mode: AttachMode,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Client asks to leave the stream but keep the session alive.
    Detach {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    Subscribe {
        events: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    Wait {
        target: String,
        until: Vec<String>,
        timeout_ms: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    SetStatus {
        id: String,
        status: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },

    // Daemon → client responses.
    Ok {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    Created {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    Sessions {
        sessions: Vec<SessionInfo>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    Attached {
        /// v0 response field, retained for byte compatibility.
        id: String,
        name: String,
        /// Canonical v0.1 field.
        #[serde(default)]
        session_id: String,
        #[serde(default)]
        writer: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Sent when the attached session's process exits (retained for v0).
    Exited { id: String, status: i32 },
    WaitResult {
        session: String,
        status: String,
        #[serde(default)]
        timed_out: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        exit_status: Option<i32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    ResizeClaim {
        session: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        writer: Option<String>,
    },
    Error {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
        #[serde(default)]
        code: ErrorCode,
        message: String,
        #[serde(default)]
        retryable: bool,
    },

    #[serde(other)]
    Unknown,
}

impl Control {
    pub fn seq(&self) -> Option<u64> {
        match self {
            Control::Create { seq, .. }
            | Control::List { seq }
            | Control::Kill { seq, .. }
            | Control::Send { seq, .. }
            | Control::Attach { seq, .. }
            | Control::Detach { seq }
            | Control::Subscribe { seq, .. }
            | Control::Wait { seq, .. }
            | Control::SetStatus { seq, .. } => *seq,
            _ => None,
        }
    }
}

/// Event-plane messages. Unknown event types are ignored additively.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "ev", rename_all = "snake_case")]
pub enum Event {
    Status {
        session: String,
        status: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    WriterChanged {
        session: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        writer: Option<String>,
    },
    Resized {
        session: String,
        rows: u16,
        cols: u16,
    },
    SessionExited {
        session: String,
        status: i32,
    },
    /// Roster delta used by control-channel `subscribe`.
    Roster {
        session: String,
        action: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        info: Option<Box<SessionInfo>>,
    },
    #[serde(other)]
    Unknown,
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
    /// v0 field retained for old consumers.
    pub clients: usize,
    pub created_unix: u64,
    pub alive: bool,
    #[serde(default = "default_status")]
    pub status: String,
    #[serde(default)]
    pub agent_id: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub attached_clients: usize,
    #[serde(default)]
    pub writer_client_id: Option<String>,
}

fn default_status() -> String {
    "unknown".to_string()
}

pub async fn write_frame<W: AsyncWriteExt + Unpin>(
    w: &mut W,
    kind: u8,
    payload: &[u8],
) -> Result<()> {
    if payload.len() > MAX_FRAME_SIZE {
        bail!(
            "frame payload too large: {} > {MAX_FRAME_SIZE}",
            payload.len()
        );
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

pub async fn write_event<W: AsyncWriteExt + Unpin>(w: &mut W, event: &Event) -> Result<()> {
    let payload = serde_json::to_vec(event)?;
    write_frame(w, KIND_EVENT, &payload).await
}

/// Data is always split into fair-write chunks, including large ring replays.
pub async fn write_data<W: AsyncWriteExt + Unpin>(w: &mut W, data: &[u8]) -> Result<()> {
    if data.is_empty() {
        return write_frame(w, KIND_DATA, data).await;
    }
    for chunk in data.chunks(MAX_DATA_FRAME_SIZE) {
        write_frame(w, KIND_DATA, chunk).await?;
    }
    Ok(())
}

pub async fn write_resize<W: AsyncWriteExt + Unpin>(w: &mut W, rows: u16, cols: u16) -> Result<()> {
    let mut buf = [0u8; 4];
    buf[0..2].copy_from_slice(&rows.to_be_bytes());
    buf[2..4].copy_from_slice(&cols.to_be_bytes());
    write_frame(w, KIND_RESIZE, &buf).await
}

/// Read one frame. Returns `None` on EOF. Any malformed frame is a channel
/// protocol error; the daemon turns the returned error into `proto_error`.
pub async fn read_frame<R: AsyncReadExt + Unpin>(r: &mut R) -> Result<Option<Frame>> {
    let mut header = [0u8; 5];
    match r.read_exact(&mut header).await {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    let kind = header[0];
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    if len > MAX_FRAME_SIZE {
        bail!("frame length {len} exceeds maximum {MAX_FRAME_SIZE}");
    }
    if !matches!(kind, KIND_CONTROL | KIND_DATA | KIND_RESIZE | KIND_EVENT) {
        bail!("unknown frame kind {kind:#x}");
    }

    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload).await?;
    match kind {
        KIND_CONTROL => {
            let ctrl: Control = serde_json::from_slice(&payload)
                .map_err(|e| anyhow::anyhow!("invalid control JSON: {e}"))?;
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
        KIND_EVENT => {
            let event: Event = serde_json::from_slice(&payload)
                .map_err(|e| anyhow::anyhow!("invalid event JSON: {e}"))?;
            Ok(Some(Frame::Event(event)))
        }
        _ => unreachable!("frame kind validated above"),
    }
}
