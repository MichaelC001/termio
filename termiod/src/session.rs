//! A single durable session: one PTY, one child process group, and a set of
//! attached clients. It runs as an actor whose lifetime is independent of any
//! connection — detach never kills it.

use crate::protocol::{Control, ErrorCode, Event, SessionInfo, Snapshot, WireCell, WorkstreamSpec};
use crate::pty::Pty;
use bytes::Bytes;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc as std_mpsc;
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, mpsc, oneshot};

pub type ClientId = String;

const RING_CAP: usize = 128 * 1024;
const READ_CHUNK: usize = 64 * 1024;
const CLIENT_BACKLOG_CAP: usize = 4 * 1024 * 1024;

/// Counts PTY bytes queued anywhere between a session and its socket writer.
pub(crate) struct ClientBacklog {
    outstanding: AtomicUsize,
    dropped: AtomicBool,
}

impl ClientBacklog {
    pub(crate) fn new() -> Self {
        Self {
            outstanding: AtomicUsize::new(0),
            dropped: AtomicBool::new(false),
        }
    }

    fn try_reserve(&self, bytes: usize) -> bool {
        self.outstanding
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |outstanding| {
                outstanding
                    .checked_add(bytes)
                    .filter(|total| *total <= CLIENT_BACKLOG_CAP)
            })
            .is_ok()
    }

    pub(crate) fn release(&self, bytes: usize) {
        let previous = self.outstanding.fetch_sub(bytes, Ordering::Relaxed);
        debug_assert!(previous >= bytes);
    }

    fn mark_dropped(&self) {
        self.dropped.store(true, Ordering::Release);
    }

    pub(crate) fn is_dropped(&self) -> bool {
        self.dropped.load(Ordering::Acquire)
    }
}

/// Pushed to an attached connection task.
#[derive(Clone)]
pub enum ClientEvent {
    Data(Bytes),
    Snapshot(Snapshot),
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
        backlog: Arc<ClientBacklog>,
        snapshot: bool,
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
    backlog: Arc<ClientBacklog>,
    /// Interactive attach order. Highest sequence owns the write token.
    seq: u64,
    interactive: bool,
    delivery: ClientDelivery,
}

enum ClientDelivery {
    Live,
    SnapshotPending {
        data: VecDeque<Bytes>,
        deferred: VecDeque<ClientEvent>,
    },
}

enum SidecarCommand {
    Write(Bytes),
    Resize { rows: u16, cols: u16 },
    Snapshot { client_id: ClientId },
    Shutdown,
}

struct SidecarSnapshot {
    client_id: ClientId,
    result: Result<termiod_vt::Snapshot, String>,
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
    ring: VecDeque<Bytes>,
    ring_bytes: usize,
    events: broadcast::Sender<Event>,
    sidecar_tx: Option<std_mpsc::Sender<SidecarCommand>>,
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

    fn push_ring(&mut self, data: Bytes) {
        self.ring_bytes += data.len();
        self.ring.push_back(data);
        while self.ring_bytes > RING_CAP {
            if let Some(evicted) = self.ring.pop_front() {
                self.ring_bytes -= evicted.len();
            }
        }
    }

    fn send_sidecar(&mut self, command: SidecarCommand) -> bool {
        let sent = self
            .sidecar_tx
            .as_ref()
            .is_some_and(|sender| sender.send(command).is_ok());
        if !sent && self.sidecar_tx.take().is_some() {
            eprintln!("termiod: VT sidecar for session {} stopped", self.id);
        }
        sent
    }

    fn queue_non_data(entry: &mut ClientEntry, event: ClientEvent) -> bool {
        match &mut entry.delivery {
            ClientDelivery::Live => entry.out.send(event).is_ok(),
            ClientDelivery::SnapshotPending { deferred, .. } => {
                deferred.push_back(event);
                true
            }
        }
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
            .iter_mut()
            .filter_map(|(id, entry)| {
                (!Self::queue_non_data(entry, ClientEvent::Event(event.clone())))
                    .then(|| id.clone())
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
            if let Some(entry) = self.clients.get_mut(&previous) {
                Self::queue_non_data(
                    entry,
                    ClientEvent::Control(Control::ResizeClaim {
                        session: self.id.clone(),
                        writer: self.writer.clone(),
                    }),
                );
            }
        }
        self.emit_event(Event::WriterChanged {
            session: self.id.clone(),
            writer: self.writer.clone(),
        });
    }

    /// Fan PTY output out to every attached client; drop dead ones.
    fn fan_out(&mut self, data: Bytes) {
        self.push_ring(data.clone());
        let dead = self
            .clients
            .iter_mut()
            .filter_map(|(id, entry)| {
                if !entry.backlog.try_reserve(data.len()) {
                    entry.backlog.mark_dropped();
                    eprintln!(
                        "termiod: dropping slow client {id} from session {}: output backlog exceeded {} MiB",
                        self.id,
                        CLIENT_BACKLOG_CAP / (1024 * 1024)
                    );
                    return Some(id.clone());
                }
                match &mut entry.delivery {
                    ClientDelivery::Live => {
                        if entry.out.send(ClientEvent::Data(data.clone())).is_err() {
                            entry.backlog.release(data.len());
                            return Some(id.clone());
                        }
                    }
                    ClientDelivery::SnapshotPending { data: buffered, .. } => {
                        buffered.push_back(data.clone());
                    }
                }
                None
            })
            .collect();
        self.remove_dead(dead);
    }

    fn reject_not_writer(&mut self, id: &str) {
        if let Some(entry) = self.clients.get_mut(id) {
            Self::queue_non_data(
                entry,
                ClientEvent::Control(Control::Error {
                    re: None,
                    code: ErrorCode::NotWriter,
                    message: "this attachment does not own the write token".to_string(),
                    retryable: false,
                }),
            );
        }
    }

    fn finish_snapshot(&mut self, client_id: &str, result: Result<termiod_vt::Snapshot, String>) {
        let Some(mut entry) = self.clients.remove(client_id) else {
            return;
        };
        let ClientDelivery::SnapshotPending {
            mut data,
            mut deferred,
        } = std::mem::replace(&mut entry.delivery, ClientDelivery::Live)
        else {
            self.clients.insert(client_id.to_string(), entry);
            return;
        };

        let engine = match result {
            Ok(snapshot) => snapshot,
            Err(error) => {
                self.fallback_snapshot(client_id, entry, data, deferred, &error);
                return;
            }
        };
        let snapshot = Snapshot {
            rows: engine.rows,
            cols: engine.cols,
            cursor_x: engine.cursor_x,
            cursor_y: engine.cursor_y,
            alt_screen: engine.alt_screen,
            title: engine
                .title
                .or_else(|| self.title.clone())
                .unwrap_or_else(|| self.name.clone()),
            cells: engine
                .cells
                .into_iter()
                .map(|cell| WireCell {
                    codepoint: cell.codepoint,
                    foreground: [cell.foreground.r, cell.foreground.g, cell.foreground.b],
                    background: [cell.background.r, cell.background.g, cell.background.b],
                    attributes: cell.attributes,
                })
                .collect(),
        };

        if entry.out.send(ClientEvent::Snapshot(snapshot)).is_err()
            || entry
                .out
                .send(ClientEvent::Event(Event::Ready {
                    session: self.id.clone(),
                }))
                .is_err()
        {
            release_buffered(&entry.backlog, data);
            self.remove_finished_client(client_id);
            return;
        }
        while let Some(bytes) = data.pop_front() {
            let len = bytes.len();
            if entry.out.send(ClientEvent::Data(bytes)).is_err() {
                entry.backlog.release(len);
                release_buffered(&entry.backlog, data);
                self.remove_finished_client(client_id);
                return;
            }
        }
        while let Some(event) = deferred.pop_front() {
            if entry.out.send(event).is_err() {
                self.remove_finished_client(client_id);
                return;
            }
        }
        self.clients.insert(client_id.to_string(), entry);
    }

    fn fallback_snapshot(
        &mut self,
        client_id: &str,
        entry: ClientEntry,
        buffered: VecDeque<Bytes>,
        deferred: VecDeque<ClientEvent>,
        error: &str,
    ) {
        eprintln!(
            "termiod: VT snapshot unavailable for client {client_id} in session {}: {error}; falling back to ring replay",
            self.id
        );
        release_buffered(&entry.backlog, buffered);

        for replay in &self.ring {
            if !entry.backlog.try_reserve(replay.len()) {
                entry.backlog.mark_dropped();
                self.remove_finished_client(client_id);
                return;
            }
            if entry.out.send(ClientEvent::Data(replay.clone())).is_err() {
                entry.backlog.release(replay.len());
                self.remove_finished_client(client_id);
                return;
            }
        }
        for event in deferred {
            if entry.out.send(event).is_err() {
                self.remove_finished_client(client_id);
                return;
            }
        }
        self.clients.insert(client_id.to_string(), entry);
    }

    fn remove_finished_client(&mut self, client_id: &str) {
        let old_writer = self.writer.clone();
        if old_writer.as_deref() == Some(client_id) {
            self.recompute_writer();
        }
        if self.writer != old_writer {
            self.emit_writer_changed(None);
        }
    }

    fn fallback_all_pending(&mut self, error: &str) {
        let pending: Vec<ClientId> = self
            .clients
            .iter()
            .filter(|(_, entry)| matches!(entry.delivery, ClientDelivery::SnapshotPending { .. }))
            .map(|(id, _)| id.clone())
            .collect();
        for id in pending {
            self.finish_snapshot(&id, Err(error.to_string()));
        }
    }
}

fn release_buffered(backlog: &ClientBacklog, data: VecDeque<Bytes>) {
    for bytes in data {
        backlog.release(bytes.len());
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

    let (sidecar_tx, sidecar_snapshots, sidecar_thread) = spawn_sidecar(rows, cols)?;

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
        ring: VecDeque::new(),
        ring_bytes: 0,
        events,
        sidecar_tx: Some(sidecar_tx),
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

    tokio::spawn(run(
        session,
        rx,
        waiter,
        on_exit,
        sidecar_snapshots,
        sidecar_thread,
    ));
    Ok(SessionHandle { id, tx })
}

fn spawn_sidecar(
    rows: u16,
    cols: u16,
) -> anyhow::Result<(
    std_mpsc::Sender<SidecarCommand>,
    mpsc::UnboundedReceiver<SidecarSnapshot>,
    JoinHandle<()>,
)> {
    // Deliberately unbounded and fire-and-forget: PTY delivery must never wait
    // for VT parsing. The consumer drains adjacent Bytes writes in batches.
    // v1.1's desync/resync path is where this lag risk will be bounded.
    let (command_tx, command_rx) = std_mpsc::channel::<SidecarCommand>();
    let (snapshot_tx, snapshot_rx) = mpsc::unbounded_channel::<SidecarSnapshot>();
    let thread = std::thread::Builder::new()
        .name("termiod-vt".to_string())
        .spawn(move || {
            let mut terminal = match termiod_vt::VtTerminal::new(rows, cols) {
                Ok(terminal) => Some(terminal),
                Err(error) => {
                    eprintln!("termiod: failed to initialize VT sidecar: {error}");
                    None
                }
            };
            let mut fault = terminal
                .is_none()
                .then(|| "VT sidecar initialization failed".to_string());
            let mut pending = None;

            loop {
                let command = match pending.take() {
                    Some(command) => command,
                    None => match command_rx.recv() {
                        Ok(command) => command,
                        Err(_) => break,
                    },
                };
                match command {
                    SidecarCommand::Write(bytes) => {
                        if let Some(terminal) = terminal.as_mut() {
                            terminal.vt_write(&bytes);
                        }
                        loop {
                            match command_rx.try_recv() {
                                Ok(SidecarCommand::Write(bytes)) => {
                                    if let Some(terminal) = terminal.as_mut() {
                                        terminal.vt_write(&bytes);
                                    }
                                }
                                Ok(command) => {
                                    pending = Some(command);
                                    break;
                                }
                                Err(std_mpsc::TryRecvError::Empty) => break,
                                Err(std_mpsc::TryRecvError::Disconnected) => return,
                            }
                        }
                    }
                    SidecarCommand::Resize { rows, cols } => {
                        if fault.is_none() {
                            if let Some(terminal) = terminal.as_mut() {
                                if let Err(error) = terminal.resize(rows, cols) {
                                    fault = Some(format!("VT resize failed: {error}"));
                                }
                            }
                        }
                    }
                    SidecarCommand::Snapshot { client_id } => {
                        let result = match (&fault, terminal.as_mut()) {
                            (Some(error), _) => Err(error.clone()),
                            (None, Some(terminal)) => {
                                terminal.snapshot().map_err(|error| error.to_string())
                            }
                            (None, None) => Err("VT sidecar is unavailable".to_string()),
                        };
                        if snapshot_tx
                            .send(SidecarSnapshot { client_id, result })
                            .is_err()
                        {
                            break;
                        }
                    }
                    SidecarCommand::Shutdown => break,
                }
            }
        })
        .map_err(|error| anyhow::anyhow!("spawning VT sidecar thread: {error}"))?;
    Ok((command_tx, snapshot_rx, thread))
}

async fn run(
    mut session: Session,
    mut rx: mpsc::UnboundedReceiver<SessionMsg>,
    waiter: tokio::task::JoinHandle<i32>,
    on_exit: mpsc::UnboundedSender<String>,
    mut sidecar_snapshots: mpsc::UnboundedReceiver<SidecarSnapshot>,
    sidecar_thread: JoinHandle<()>,
) {
    let mut buf = vec![0u8; READ_CHUNK];
    let mut waiter = Some(waiter);
    let mut sidecar_results_open = true;

    loop {
        tokio::select! {
            msg = rx.recv() => {
                let Some(msg) = msg else { break };
                if handle_msg(&mut session, msg) {
                    break;
                }
            }
            result = sidecar_snapshots.recv(), if sidecar_results_open => {
                match result {
                    Some(result) => session.finish_snapshot(&result.client_id, result.result),
                    None => {
                        sidecar_results_open = false;
                        session.fallback_all_pending("VT sidecar response channel closed");
                    }
                }
            }
            read = session.pty.read(&mut buf) => {
                match read {
                    Ok(0) => break,
                    Ok(n) => {
                        let chunk = Bytes::copy_from_slice(&buf[..n]);
                        // This refcount clone + unbounded send is strictly
                        // fire-and-forget. Fan-out never waits for VT parsing.
                        session.send_sidecar(SidecarCommand::Write(chunk.clone()));
                        session.fan_out(chunk);
                    }
                    // Linux delivers EIO when the slave side closes.
                    Err(e) if e.raw_os_error() == Some(libc::EIO) => break,
                    Err(_) => break,
                }
            }
        }
    }

    session.fallback_all_pending("session ended before the VT snapshot completed");
    if let Some(sidecar_tx) = session.sidecar_tx.take() {
        let _ = sidecar_tx.send(SidecarCommand::Shutdown);
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
    let _ = tokio::task::spawn_blocking(move || sidecar_thread.join()).await;
    let _ = on_exit.send(session.id.clone());
}

/// Returns true if the session should terminate (`kill`).
fn handle_msg(session: &mut Session, msg: SessionMsg) -> bool {
    match msg {
        SessionMsg::AddClient {
            id,
            interactive,
            out,
            backlog,
            snapshot,
            reply,
        } => {
            let seq = session.next_seq;
            session.next_seq += 1;
            let old_writer = session.writer.clone();

            if !snapshot {
                for replay in &session.ring {
                    if backlog.try_reserve(replay.len())
                        && out.send(ClientEvent::Data(replay.clone())).is_err()
                    {
                        backlog.release(replay.len());
                        break;
                    }
                }
            }
            session.clients.insert(
                id.clone(),
                ClientEntry {
                    out,
                    backlog,
                    seq,
                    interactive,
                    delivery: if snapshot {
                        ClientDelivery::SnapshotPending {
                            data: VecDeque::new(),
                            deferred: VecDeque::new(),
                        }
                    } else {
                        ClientDelivery::Live
                    },
                },
            );
            if interactive {
                session.writer = Some(id.clone());
            }
            let is_writer = session.writer.as_deref() == Some(id.as_str());
            let _ = reply.send(is_writer);

            if snapshot
                && !session.send_sidecar(SidecarCommand::Snapshot {
                    client_id: id.clone(),
                })
            {
                session.finish_snapshot(&id, Err("VT sidecar is unavailable".to_string()));
            }

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
                if session.pty.resize(rows, cols).is_ok() {
                    session.send_sidecar(SidecarCommand::Resize { rows, cols });
                }
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

#[cfg(test)]
mod tests {
    use super::{spawn_sidecar, ClientBacklog, SidecarCommand, CLIENT_BACKLOG_CAP};
    use bytes::Bytes;

    #[test]
    fn client_backlog_enforces_byte_cap() {
        let backlog = ClientBacklog::new();

        assert!(backlog.try_reserve(CLIENT_BACKLOG_CAP - 1));
        assert!(backlog.try_reserve(1));
        assert!(!backlog.try_reserve(1));

        backlog.release(CLIENT_BACKLOG_CAP);
        assert!(backlog.try_reserve(1));
        backlog.release(1);
    }

    #[test]
    fn snapshot_request_is_an_exact_sidecar_fifo_boundary() {
        let (sidecar, mut snapshots, thread) = spawn_sidecar(2, 16).unwrap();
        sidecar
            .send(SidecarCommand::Write(Bytes::from_static(b"BEFORE")))
            .unwrap();
        sidecar
            .send(SidecarCommand::Snapshot {
                client_id: "client".to_string(),
            })
            .unwrap();
        sidecar
            .send(SidecarCommand::Write(Bytes::from_static(b"AFTER")))
            .unwrap();

        let response = snapshots.blocking_recv().unwrap();
        let snapshot = response.result.unwrap();
        let screen: String = snapshot
            .cells
            .iter()
            .map(|cell| char::from_u32(cell.codepoint).unwrap_or(' '))
            .collect();
        assert!(screen.starts_with("BEFORE"));
        assert!(!screen.contains("AFTER"));

        sidecar.send(SidecarCommand::Shutdown).unwrap();
        thread.join().unwrap();
    }
}
