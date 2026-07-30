//! A single durable session: one PTY, one child process group, and a set of
//! attached clients. Runs as an independent tokio task (an actor) reached only
//! through a `SessionHandle`. Its lifetime is independent of any client —
//! detach never kills it; only `kill` or the process exiting ends it.

use crate::protocol::SessionInfo;
use crate::pty::Pty;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{mpsc, oneshot};

pub type ClientId = u64;

const RING_CAP: usize = 128 * 1024;
const READ_CHUNK: usize = 64 * 1024;

/// Pushed to an attached client's connection task.
#[derive(Clone)]
pub enum ClientEvent {
    Data(Vec<u8>),
    Exited(i32),
}

/// Messages accepted by a running session task.
pub enum SessionMsg {
    AddClient {
        id: ClientId,
        out: mpsc::UnboundedSender<ClientEvent>,
    },
    RemoveClient {
        id: ClientId,
    },
    /// Interactive input from an attached client (applied only if writer).
    Input {
        id: ClientId,
        data: Vec<u8>,
    },
    Resize {
        id: ClientId,
        rows: u16,
        cols: u16,
    },
    /// `termiod send` — inject input without attaching. Always applied.
    Inject {
        data: Vec<u8>,
    },
    Info {
        reply: oneshot::Sender<SessionInfo>,
    },
    Kill,
}

/// Cheap, cloneable reference to a session task.
#[derive(Clone)]
pub struct SessionHandle {
    pub id: String,
    tx: mpsc::UnboundedSender<SessionMsg>,
}

impl SessionHandle {
    pub fn send(&self, msg: SessionMsg) -> bool {
        self.tx.send(msg).is_ok()
    }
}

struct ClientEntry {
    out: mpsc::UnboundedSender<ClientEvent>,
    /// Attach order; the highest-seq client is the writer (newest-client claim).
    seq: u64,
}

struct Session {
    id: String,
    name: String,
    cwd: String,
    command: String,
    pid: i32,
    rows: u16,
    cols: u16,
    created_unix: u64,
    pty: Arc<Pty>,
    /// Interactive/injected input is handed to a dedicated writer task so a
    /// blocked PTY write can never stall the read+control loop (the classic
    /// PTY write deadlock — see repo memory `termio-pty-write-deadlock`).
    input_tx: mpsc::UnboundedSender<Vec<u8>>,
    clients: HashMap<ClientId, ClientEntry>,
    writer: Option<ClientId>,
    next_seq: u64,
    ring: std::collections::VecDeque<u8>,
}

impl Session {
    fn info(&self) -> SessionInfo {
        SessionInfo {
            id: self.id.clone(),
            name: self.name.clone(),
            cwd: self.cwd.clone(),
            command: self.command.clone(),
            pid: self.pid,
            rows: self.rows,
            cols: self.cols,
            clients: self.clients.len(),
            created_unix: self.created_unix,
            alive: true,
        }
    }

    fn recompute_writer(&mut self) {
        self.writer = self
            .clients
            .iter()
            .max_by_key(|(_, e)| e.seq)
            .map(|(id, _)| *id);
    }

    fn push_ring(&mut self, data: &[u8]) {
        if data.len() >= RING_CAP {
            self.ring.clear();
            self.ring.extend(&data[data.len() - RING_CAP..]);
            return;
        }
        let overflow = (self.ring.len() + data.len()).saturating_sub(RING_CAP);
        for _ in 0..overflow {
            self.ring.pop_front();
        }
        self.ring.extend(data);
    }

    /// Fan PTY output out to every attached client; drop dead ones.
    fn fan_out(&mut self, data: &[u8]) {
        self.push_ring(data);
        let mut dead = Vec::new();
        for (id, entry) in &self.clients {
            if entry.out.send(ClientEvent::Data(data.to_vec())).is_err() {
                dead.push(*id);
            }
        }
        if !dead.is_empty() {
            for id in dead {
                self.clients.remove(&id);
            }
            self.recompute_writer();
        }
    }
}

/// Spawn a session task. Returns a handle; on process exit the session id is
/// sent on `on_exit` so the manager can drop it from the table.
#[allow(clippy::too_many_arguments)]
pub fn spawn(
    id: String,
    name: String,
    cwd: String,
    command: String,
    argv: Vec<String>,
    env: Vec<(String, String)>,
    rows: u16,
    cols: u16,
    on_exit: mpsc::UnboundedSender<String>,
) -> anyhow::Result<SessionHandle> {
    let cwd_opt = if cwd.is_empty() { None } else { Some(cwd.as_str()) };
    let (pty, child) = Pty::spawn(&argv, cwd_opt, &env, rows, cols)?;
    let pty = Arc::new(pty);
    let pid = pty.pid;
    let created_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Dedicated writer task: drains input and writes it to the PTY. Runs
    // concurrently with the reader so neither can deadlock the other.
    let (input_tx, mut input_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let writer_pty = pty.clone();
    tokio::spawn(async move {
        while let Some(bytes) = input_rx.recv().await {
            if writer_pty.write_all(&bytes).await.is_err() {
                break;
            }
        }
    });

    let (tx, rx) = mpsc::unbounded_channel();
    let session = Session {
        id: id.clone(),
        name,
        cwd,
        command,
        pid,
        rows,
        cols,
        created_unix,
        pty,
        input_tx,
        clients: HashMap::new(),
        writer: None,
        next_seq: 0,
        ring: std::collections::VecDeque::new(),
    };

    // Reap the child in a blocking thread; hand back an exit code.
    let waiter = tokio::task::spawn_blocking(move || {
        let mut child = child;
        match child.wait() {
            Ok(status) => status.code().unwrap_or_else(|| {
                use std::os::unix::process::ExitStatusExt;
                status.signal().map(|s| 128 + s).unwrap_or(-1)
            }),
            Err(_) => -1,
        }
    });

    tokio::spawn(run(session, rx, waiter, on_exit));
    Ok(SessionHandle { id, tx })
}

async fn run(
    mut session: Session,
    mut rx: mpsc::UnboundedReceiver<SessionMsg>,
    waiter: tokio::task::JoinHandle<i32>,
    on_exit: mpsc::UnboundedSender<String>,
) {
    let mut buf = vec![0u8; READ_CHUNK];
    let mut waiter = Some(waiter);

    loop {
        tokio::select! {
            msg = rx.recv() => {
                let Some(msg) = msg else { break };
                if handle_msg(&mut session, msg) {
                    break; // Kill requested; wait for EOF below.
                }
            }
            read = session.pty.read(&mut buf) => {
                match read {
                    Ok(0) => break,
                    Ok(n) => {
                        let chunk = buf[..n].to_vec();
                        session.fan_out(&chunk);
                    }
                    // Linux delivers EIO (not EOF) when the slave side closes.
                    Err(e) if e.raw_os_error() == Some(libc::EIO) => break,
                    Err(_) => break,
                }
            }
        }
    }

    let code = match waiter.take() {
        Some(w) => w.await.unwrap_or(-1),
        None => -1,
    };
    for entry in session.clients.values() {
        let _ = entry.out.send(ClientEvent::Exited(code));
    }
    let _ = on_exit.send(session.id.clone());
}

// (writes go through the dedicated writer task; see `spawn`.)

/// Returns true if the session should terminate (Kill).
fn handle_msg(session: &mut Session, msg: SessionMsg) -> bool {
    match msg {
        SessionMsg::AddClient { id, out } => {
            let seq = session.next_seq;
            session.next_seq += 1;
            // Replay recent output so a (re)attaching client sees the screen.
            if !session.ring.is_empty() {
                let snapshot: Vec<u8> = session.ring.iter().copied().collect();
                let _ = out.send(ClientEvent::Data(snapshot));
            }
            session.clients.insert(id, ClientEntry { out, seq });
            session.writer = Some(id); // newest-client claim
        }
        SessionMsg::RemoveClient { id } => {
            session.clients.remove(&id);
            if session.writer == Some(id) {
                session.recompute_writer();
            }
        }
        SessionMsg::Input { id, data } => {
            if session.writer == Some(id) {
                let _ = session.input_tx.send(data);
            }
        }
        SessionMsg::Resize { id, rows, cols } => {
            // Only the newest client (writer) drives the shared window size.
            if session.writer == Some(id) {
                session.rows = rows;
                session.cols = cols;
                let _ = session.pty.resize(rows, cols);
            }
        }
        SessionMsg::Inject { data } => {
            let _ = session.input_tx.send(data);
        }
        SessionMsg::Info { reply } => {
            let _ = reply.send(session.info());
        }
        SessionMsg::Kill => {
            // Kill the whole process group (child is a session leader after
            // setsid, so pgid == pid).
            unsafe {
                libc::kill(-session.pid, libc::SIGKILL);
            }
            return true;
        }
    }
    false
}
