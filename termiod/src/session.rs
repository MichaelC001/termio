//! A single durable session: one PTY, one child process group, and a set of
//! attached clients. It runs as an actor whose lifetime is independent of any
//! connection — detach never kills it.

use crate::protocol::{Control, ErrorCode, Event, SessionInfo, WorkstreamSpec};
use crate::pty::Pty;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, mpsc, oneshot};

pub type ClientId = String;

const RING_CAP: usize = 128 * 1024;
const READ_CHUNK: usize = 64 * 1024;

/// Pushed to an attached connection task.
#[derive(Clone)]
pub enum ClientEvent {
    Data(Vec<u8>),
    Control(Control),
    Event(Event),
    Exited(i32),
}

/// Messages accepted by a running session task.
pub enum SessionMsg {
    AddClient {
        id: ClientId,
        interactive: bool,
        out: mpsc::UnboundedSender<ClientEvent>,
        reply: oneshot::Sender<bool>,
    },
    RemoveClient {
        id: ClientId,
    },
    /// Interactive input from an attached client.
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
    SetStatus {
        status: String,
        title: Option<String>,
        reply: oneshot::Sender<()>,
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
    /// Interactive attach order. Highest sequence owns the write token.
    seq: u64,
    interactive: bool,
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
    status: String,
    title: Option<String>,
    workstream: Option<WorkstreamSpec>,
    pty: Arc<Pty>,
    /// A dedicated writer prevents blocked PTY writes from stalling reads.
    input_tx: mpsc::UnboundedSender<Vec<u8>>,
    clients: HashMap<ClientId, ClientEntry>,
    writer: Option<ClientId>,
    next_seq: u64,
    ring: std::collections::VecDeque<u8>,
    events: broadcast::Sender<Event>,
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
            status: self.status.clone(),
            agent_id: self.workstream.as_ref().map(|w| w.agent_id.clone()),
            title: self.title.clone(),
            attached_clients: self.clients.len(),
            writer_client_id: self.writer.clone(),
        }
    }

    fn recompute_writer(&mut self) {
        self.writer = self
            .clients
            .iter()
            .filter(|(_, entry)| entry.interactive)
            .max_by_key(|(_, entry)| entry.seq)
            .map(|(id, _)| id.clone());
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

    fn remove_dead(&mut self, dead: Vec<ClientId>) {
        if dead.is_empty() {
            return;
        }
        let old_writer = self.writer.clone();
        for id in dead {
            self.clients.remove(&id);
        }
        self.recompute_writer();
        if self.writer != old_writer {
            self.emit_writer_changed(None);
        }
    }

    /// Send a protocol event to attachments and control-channel subscribers.
    fn emit_event(&mut self, event: Event) {
        let _ = self.events.send(event.clone());
        let dead = self
            .clients
            .iter()
            .filter_map(|(id, entry)| {
                entry
                    .out
                    .send(ClientEvent::Event(event.clone()))
                    .err()
                    .map(|_| id.clone())
            })
            .collect();
        self.remove_dead(dead);
    }

    fn emit_roster(&mut self) {
        self.emit_event(Event::Roster {
            session: self.id.clone(),
            action: "updated".to_string(),
            info: Some(Box::new(self.info())),
        });
    }

    fn emit_writer_changed(&mut self, demoted: Option<ClientId>) {
        if let Some(previous) = demoted {
            if let Some(entry) = self.clients.get(&previous) {
                let _ = entry.out.send(ClientEvent::Control(Control::ResizeClaim {
                    session: self.id.clone(),
                    writer: self.writer.clone(),
                }));
            }
        }
        self.emit_event(Event::WriterChanged {
            session: self.id.clone(),
            writer: self.writer.clone(),
        });
    }

    /// Fan PTY output out to every attached client; drop dead ones.
    fn fan_out(&mut self, data: &[u8]) {
        self.push_ring(data);
        let dead = self
            .clients
            .iter()
            .filter_map(|(id, entry)| {
                entry
                    .out
                    .send(ClientEvent::Data(data.to_vec()))
                    .err()
                    .map(|_| id.clone())
            })
            .collect();
        self.remove_dead(dead);
    }

    fn reject_not_writer(&self, id: &str) {
        if let Some(entry) = self.clients.get(id) {
            let _ = entry.out.send(ClientEvent::Control(Control::Error {
                re: None,
                code: ErrorCode::NotWriter,
                message: "this attachment does not own the write token".to_string(),
                retryable: false,
            }));
        }
    }
}

/// Spawn a session task. On process exit the session id is sent to the
/// manager so it can remove the handle from the table.
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
    workstream: Option<WorkstreamSpec>,
    on_exit: mpsc::UnboundedSender<String>,
    events: broadcast::Sender<Event>,
) -> anyhow::Result<SessionHandle> {
    let cwd_opt = if cwd.is_empty() {
        None
    } else {
        Some(cwd.as_str())
    };
    let (pty, child) = Pty::spawn(&argv, cwd_opt, &env, rows, cols)?;
    let pty = Arc::new(pty);
    let pid = pty.pid;
    let created_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

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
        status: "unknown".to_string(),
        title: None,
        workstream,
        pty,
        input_tx,
        clients: HashMap::new(),
        writer: None,
        next_seq: 0,
        ring: std::collections::VecDeque::new(),
        events,
    };

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
                    break;
                }
            }
            read = session.pty.read(&mut buf) => {
                match read {
                    Ok(0) => break,
                    Ok(n) => {
                        let chunk = buf[..n].to_vec();
                        session.fan_out(&chunk);
                    }
                    // Linux delivers EIO when the slave side closes.
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
    let exit_event = Event::SessionExited {
        session: session.id.clone(),
        status: code,
    };
    let _ = session.events.send(exit_event.clone());
    for entry in session.clients.values() {
        let _ = entry.out.send(ClientEvent::Event(exit_event.clone()));
        let _ = entry.out.send(ClientEvent::Exited(code));
    }
    let _ = on_exit.send(session.id.clone());
}

/// Returns true if the session should terminate (`kill`).
fn handle_msg(session: &mut Session, msg: SessionMsg) -> bool {
    match msg {
        SessionMsg::AddClient {
            id,
            interactive,
            out,
            reply,
        } => {
            let seq = session.next_seq;
            session.next_seq += 1;
            let old_writer = session.writer.clone();

            if !session.ring.is_empty() {
                let replay = session.ring.iter().copied().collect();
                let _ = out.send(ClientEvent::Data(replay));
            }
            session.clients.insert(
                id.clone(),
                ClientEntry {
                    out,
                    seq,
                    interactive,
                },
            );
            if interactive {
                session.writer = Some(id.clone());
            }
            let is_writer = session.writer.as_deref() == Some(id.as_str());
            let _ = reply.send(is_writer);

            if session.writer != old_writer {
                session.emit_writer_changed(old_writer);
            }
            session.emit_roster();
        }
        SessionMsg::RemoveClient { id } => {
            let old_writer = session.writer.clone();
            session.clients.remove(&id);
            if old_writer.as_deref() == Some(id.as_str()) {
                session.recompute_writer();
            }
            if session.writer != old_writer {
                session.emit_writer_changed(None);
            }
            session.emit_roster();
        }
        SessionMsg::Input { id, data } => {
            if session.writer.as_ref() == Some(&id) {
                let _ = session.input_tx.send(data);
            } else {
                session.reject_not_writer(&id);
            }
        }
        SessionMsg::Resize { id, rows, cols } => {
            if session.writer.as_ref() == Some(&id) {
                session.rows = rows;
                session.cols = cols;
                let _ = session.pty.resize(rows, cols);
                session.emit_event(Event::Resized {
                    session: session.id.clone(),
                    rows,
                    cols,
                });
            } else {
                session.reject_not_writer(&id);
            }
        }
        SessionMsg::Inject { data } => {
            let _ = session.input_tx.send(data);
        }
        SessionMsg::SetStatus {
            status,
            title,
            reply,
        } => {
            session.status = status;
            if title.is_some() {
                session.title = title;
            }
            session.emit_event(Event::Status {
                session: session.id.clone(),
                status: session.status.clone(),
                title: session.title.clone(),
            });
            let _ = reply.send(());
        }
        SessionMsg::Info { reply } => {
            let _ = reply.send(session.info());
        }
        SessionMsg::Kill => {
            // The child is a session leader, so pgid == pid.
            unsafe {
                libc::kill(-session.pid, libc::SIGKILL);
            }
            return true;
        }
    }
    false
}
