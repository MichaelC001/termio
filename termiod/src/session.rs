//! A single durable session: one PTY, one child process group, and a set of
//! attached clients. It runs as an actor whose lifetime is independent of any
//! connection — detach never kills it.

use crate::protocol::{
    encode_grid_payload, encode_history_payload, Control, ErrorCode, Event, GridDiff, GridRow,
    HistoryChunk, SessionInfo, Snapshot, WireCell, WorkstreamSpec, HISTORY_HEADER_SIZE,
    MAX_HISTORY_FRAME_SIZE, SNAPSHOT_CELL_SIZE,
};
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
pub const SCROLLBACK_STAGE_MAX_BYTES: usize = 1024 * 1024;
pub const KEYFRAME_EVERY_FRAMES: u32 = 256;

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
    History(Bytes),
    Grid(Bytes),
    Control(Control),
    Event(Event),
    Exited(i32),
}

pub struct AddClientReply {
    pub writer: bool,
    pub rows: u16,
    pub cols: u16,
}

/// Messages accepted by a running session task.
pub enum SessionMsg {
    AddClient {
        id: ClientId,
        interactive: bool,
        out: mpsc::UnboundedSender<ClientEvent>,
        backlog: Arc<ClientBacklog>,
        snapshot: bool,
        scrollback: bool,
        grid_diff: bool,
        reply: oneshot::Sender<AddClientReply>,
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

/// What the manager needs to bury a session (§6). The session actor is the last
/// thing that can answer `Info` — by the time the manager hears about the exit
/// the actor is gone — so the record travels *with* the notification instead of
/// being asked for afterwards.
pub struct SessionEnded {
    pub info: SessionInfo,
    pub status: i32,
    /// A client asked for this end (`kill`), rather than the process choosing it.
    pub killed: bool,
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
    snapshot_capable: bool,
    grid_diff: bool,
    delivery: ClientDelivery,
    /// Attach-only history staging. Resize barriers discard any remainder and
    /// deliberately do not restage it; resize/reflow history is a later policy.
    staged_history: VecDeque<Bytes>,
}

enum ClientDelivery {
    Live,
    SnapshotPending {
        request_id: u64,
        data: VecDeque<Bytes>,
        deferred: VecDeque<ClientEvent>,
    },
}

enum SidecarCommand {
    Write(Bytes),
    Resize {
        rows: u16,
        cols: u16,
    },
    Snapshot {
        client_id: ClientId,
        request_id: u64,
        scrollback: bool,
    },
    SetGridDiff(bool),
    Shutdown,
}

/// Snapshot replies and live grid updates share this single FIFO channel.
/// Separate channels could let a post-boundary G overtake its S and regress
/// rows after the client applies the newer snapshot.
enum SidecarResult {
    Snapshot {
        client_id: ClientId,
        request_id: u64,
        result: Result<SidecarCapture, String>,
    },
    Grid(GridDiff),
    Keyframe(termiod_vt::Snapshot),
}

struct SidecarCapture {
    snapshot: termiod_vt::Snapshot,
    /// The same screen serialised back to VT sequences. `None` only if the
    /// formatter failed, in which case delivery falls back to packed cells.
    vt: Option<Vec<u8>>,
    scrollback: Option<Result<termiod_vt::Scrollback, String>>,
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
    next_snapshot_request: u64,
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

    fn allocate_snapshot_request(&mut self) -> u64 {
        let request_id = self.next_snapshot_request;
        self.next_snapshot_request = self.next_snapshot_request.wrapping_add(1);
        request_id
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

    fn wants_grid_diffs(&self) -> bool {
        self.clients.values().any(|entry| entry.grid_diff)
    }

    fn sync_grid_diff_interest(&mut self) {
        self.send_sidecar(SidecarCommand::SetGridDiff(self.wants_grid_diffs()));
    }

    fn begin_snapshot_barrier(&mut self) {
        let snapshot_clients: Vec<ClientId> = self
            .clients
            .iter()
            .filter(|(_, entry)| entry.snapshot_capable)
            .map(|(id, _)| id.clone())
            .collect();
        let mut requests = Vec::with_capacity(snapshot_clients.len());

        for client_id in snapshot_clients {
            let request_id = self.allocate_snapshot_request();
            let entry = self
                .clients
                .get_mut(&client_id)
                .expect("snapshot client disappeared during barrier setup");
            // Attach history is tied to its original snapshot boundary. A
            // resize cancels any unfinished stage and does not recapture it;
            // history reflow/restaging semantics are intentionally deferred.
            entry.staged_history.clear();
            let previous = std::mem::replace(&mut entry.delivery, ClientDelivery::Live);
            let deferred = match previous {
                ClientDelivery::Live => VecDeque::new(),
                ClientDelivery::SnapshotPending { data, deferred, .. } => {
                    // The new snapshot includes every write queued before the
                    // resize, so replaying older buffered data would overlap.
                    release_buffered(&entry.backlog, data);
                    deferred
                }
            };
            entry.delivery = ClientDelivery::SnapshotPending {
                request_id,
                data: VecDeque::new(),
                deferred,
            };
            requests.push((client_id, request_id));
        }

        // The session actor cannot read the PTY while this handler runs, so
        // these requests are adjacent to the Resize command in the sidecar
        // FIFO, with no intervening Write command.
        for (client_id, request_id) in requests {
            if !self.send_sidecar(SidecarCommand::Snapshot {
                client_id: client_id.clone(),
                request_id,
                scrollback: false,
            }) {
                let _ = self.finish_snapshot(
                    &client_id,
                    request_id,
                    Err("VT sidecar is unavailable".to_string()),
                );
            }
        }
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
        self.sync_grid_diff_interest();
        self.recompute_writer();
        if self.writer != old_writer {
            self.emit_writer_changed(self.writer.clone());
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

    fn emit_writer_changed(&mut self, resize_claim_target: Option<ClientId>) {
        if let Some(target) = resize_claim_target {
            if let Some(entry) = self.clients.get_mut(&target) {
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
                // The parsed plane is opt-in: G clients never reserve or
                // receive downstream PTY bytes. Raw clients keep this exact
                // byte-blind path regardless of sidecar lag.
                if entry.grid_diff {
                    return None;
                }
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

    fn fan_out_grid(&mut self, grid: GridDiff) {
        let payload = match encode_grid_payload(&grid) {
            Ok(payload) => Bytes::from(payload),
            Err(error) => {
                eprintln!(
                    "termiod: failed to encode grid diff for session {}: {error}",
                    self.id
                );
                return;
            }
        };
        let dead = self
            .clients
            .iter_mut()
            .filter_map(|(id, entry)| {
                if !entry.grid_diff
                    || matches!(entry.delivery, ClientDelivery::SnapshotPending { .. })
                {
                    // An ordered G observed while pending precedes this
                    // client's S boundary, so the S supersedes it.
                    return None;
                }
                if !entry.backlog.try_reserve(payload.len()) {
                    entry.backlog.mark_dropped();
                    eprintln!(
                        "termiod: dropping slow grid-diff client {id} from session {}: output backlog exceeded {} MiB",
                        self.id,
                        CLIENT_BACKLOG_CAP / (1024 * 1024)
                    );
                    return Some(id.clone());
                }
                if entry.out.send(ClientEvent::Grid(payload.clone())).is_err() {
                    entry.backlog.release(payload.len());
                    return Some(id.clone());
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

    fn reject_resize(&mut self, id: &str, error: &anyhow::Error) {
        let message = format!("resize failed: {error}");
        eprintln!(
            "termiod: resize failed for writer {id} in session {}: {error}",
            self.id
        );
        if let Some(entry) = self.clients.get_mut(id) {
            Self::queue_non_data(
                entry,
                ClientEvent::Control(Control::Error {
                    re: None,
                    code: ErrorCode::Internal,
                    message,
                    retryable: true,
                }),
            );
        }
    }

    fn queue_history_chunk(
        session_id: &str,
        client_id: &str,
        entry: &mut ClientEntry,
    ) -> Result<bool, ()> {
        let Some(payload) = entry.staged_history.front() else {
            return Ok(false);
        };
        if !entry.backlog.try_reserve(payload.len()) {
            entry.backlog.mark_dropped();
            eprintln!(
                "termiod: dropping slow client {client_id} from session {session_id}: scrollback backlog exceeded {} MiB",
                CLIENT_BACKLOG_CAP / (1024 * 1024)
            );
            return Err(());
        }
        let payload = entry
            .staged_history
            .pop_front()
            .expect("history payload disappeared after reservation");
        let len = payload.len();
        if entry.out.send(ClientEvent::History(payload)).is_err() {
            entry.backlog.release(len);
            return Err(());
        }
        Ok(!entry.staged_history.is_empty())
    }

    fn continue_history(&mut self, client_id: &str) -> bool {
        let result = self
            .clients
            .get_mut(client_id)
            .map(|entry| Self::queue_history_chunk(&self.id, client_id, entry));
        match result {
            Some(Ok(more)) => more,
            Some(Err(())) => {
                self.remove_dead(vec![client_id.to_string()]);
                false
            }
            None => false,
        }
    }

    /// Every successful snapshot, whether attach bootstrap or resize/resync
    /// barrier, is followed immediately by `ready`. Attach-only history starts
    /// after `ready`, with buffered live data allowed between staged chunks.
    fn finish_snapshot(
        &mut self,
        client_id: &str,
        request_id: u64,
        result: Result<SidecarCapture, String>,
    ) -> bool {
        let is_current = self.clients.get(client_id).is_some_and(|entry| {
            matches!(
                entry.delivery,
                ClientDelivery::SnapshotPending {
                    request_id: current,
                    ..
                } if current == request_id
            )
        });
        if !is_current {
            return false;
        }
        let Some(mut entry) = self.clients.remove(client_id) else {
            return false;
        };
        let ClientDelivery::SnapshotPending {
            mut data,
            mut deferred,
            ..
        } = std::mem::replace(&mut entry.delivery, ClientDelivery::Live)
        else {
            self.clients.insert(client_id.to_string(), entry);
            return false;
        };

        let capture = match result {
            Ok(capture) => capture,
            Err(error) => {
                if entry.grid_diff {
                    eprintln!(
                        "termiod: grid-diff snapshot unavailable for client {client_id} in session {}: {error}; disconnecting client",
                        self.id
                    );
                    release_buffered(&entry.backlog, data);
                    let _ = entry.out.send(ClientEvent::Control(Control::Error {
                        re: None,
                        code: ErrorCode::Internal,
                        message: format!("grid-diff sidecar unavailable: {error}"),
                        retryable: true,
                    }));
                    self.remove_finished_client(client_id);
                    return false;
                }
                self.fallback_snapshot(client_id, entry, data, deferred, &error);
                return false;
            }
        };
        let engine = capture.snapshot;
        // Raw-plane clients get VT sequences so their own libghostty decides
        // colour (their theme, their palette, full SGR). Grid-diff clients are
        // server-state by design and need packed cells to seed the grid.
        let snapshot_vt = if entry.grid_diff { None } else { capture.vt };
        if let Some(scrollback) = capture.scrollback {
            match scrollback {
                Ok(scrollback) => {
                    if scrollback.total_rows > scrollback.rows.len() {
                        eprintln!(
                            "termiod: scrollback stage for client {client_id} in session {} truncated from {} to {} rows at {} MiB",
                            self.id,
                            scrollback.total_rows,
                            scrollback.rows.len(),
                            SCROLLBACK_STAGE_MAX_BYTES / (1024 * 1024)
                        );
                    }
                    match encode_scrollback_chunks(engine.cols, scrollback.rows) {
                        Ok(chunks) => entry.staged_history = chunks,
                        Err(error) => eprintln!(
                            "termiod: scrollback stage unavailable for client {client_id} in session {}: {error}",
                            self.id
                        ),
                    }
                }
                Err(error) => eprintln!(
                    "termiod: scrollback capture unavailable for client {client_id} in session {}: {error}",
                    self.id
                ),
            }
        }
        let snapshot = self.protocol_snapshot(engine, snapshot_vt);

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
            return false;
        }

        let history_pending = match Self::queue_history_chunk(&self.id, client_id, &mut entry) {
            Ok(more) => more,
            Err(()) => {
                release_buffered(&entry.backlog, data);
                self.remove_finished_client(client_id);
                return false;
            }
        };
        while let Some(bytes) = data.pop_front() {
            let len = bytes.len();
            if entry.out.send(ClientEvent::Data(bytes)).is_err() {
                entry.backlog.release(len);
                release_buffered(&entry.backlog, data);
                self.remove_finished_client(client_id);
                return false;
            }
        }
        while let Some(event) = deferred.pop_front() {
            if entry.out.send(event).is_err() {
                self.remove_finished_client(client_id);
                return false;
            }
        }
        self.clients.insert(client_id.to_string(), entry);
        history_pending
    }

    fn protocol_snapshot(&self, engine: termiod_vt::Snapshot, vt: Option<Vec<u8>>) -> Snapshot {
        Snapshot {
            vt,
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
        }
    }

    fn fan_out_keyframe(&mut self, engine: termiod_vt::Snapshot) {
        // Keyframes only reach grid-diff clients, which want cells.
        let snapshot = self.protocol_snapshot(engine, None);
        let dead = self
            .clients
            .iter_mut()
            .filter_map(|(id, entry)| {
                if !entry.grid_diff
                    || matches!(entry.delivery, ClientDelivery::SnapshotPending { .. })
                {
                    return None;
                }
                (entry
                    .out
                    .send(ClientEvent::Snapshot(snapshot.clone()))
                    .is_err()
                    || entry
                        .out
                        .send(ClientEvent::Event(Event::Ready {
                            session: self.id.clone(),
                        }))
                        .is_err())
                .then(|| id.clone())
            })
            .collect();
        self.remove_dead(dead);
    }

    fn disconnect_grid_clients(&mut self, error: &str) {
        let ids: Vec<ClientId> = self
            .clients
            .iter()
            .filter(|(_, entry)| entry.grid_diff)
            .map(|(id, _)| id.clone())
            .collect();
        if ids.is_empty() {
            return;
        }
        eprintln!(
            "termiod: disconnecting {} grid-diff client(s) from session {}: {error}",
            ids.len(),
            self.id
        );
        let old_writer = self.writer.clone();
        for id in ids {
            if let Some(entry) = self.clients.remove(&id) {
                if let ClientDelivery::SnapshotPending { data, .. } = entry.delivery {
                    release_buffered(&entry.backlog, data);
                }
                let _ = entry.out.send(ClientEvent::Control(Control::Error {
                    re: None,
                    code: ErrorCode::Internal,
                    message: format!("grid-diff sidecar unavailable: {error}"),
                    retryable: true,
                }));
            }
        }
        self.recompute_writer();
        if self.writer != old_writer {
            self.emit_writer_changed(self.writer.clone());
        }
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
        self.sync_grid_diff_interest();
        if self.writer != old_writer {
            self.emit_writer_changed(self.writer.clone());
        }
    }

    fn fallback_all_pending(&mut self, error: &str) {
        let pending: Vec<(ClientId, u64)> = self
            .clients
            .iter()
            .filter_map(|(id, entry)| match entry.delivery {
                ClientDelivery::SnapshotPending { request_id, .. } => {
                    Some((id.clone(), request_id))
                }
                ClientDelivery::Live => None,
            })
            .collect();
        for (id, request_id) in pending {
            self.finish_snapshot(&id, request_id, Err(error.to_string()));
        }
    }
}

fn scrollback_row_limit(cols: u16) -> usize {
    let row_bytes = usize::from(cols).saturating_mul(SNAPSHOT_CELL_SIZE);
    SCROLLBACK_STAGE_MAX_BYTES
        .checked_div(row_bytes)
        .unwrap_or(0)
}

fn encode_scrollback_chunks(
    cols: u16,
    rows: Vec<Vec<termiod_vt::Cell>>,
) -> Result<VecDeque<Bytes>, String> {
    if rows.is_empty() {
        return Ok(VecDeque::new());
    }
    let row_bytes = usize::from(cols)
        .checked_mul(SNAPSHOT_CELL_SIZE)
        .ok_or_else(|| "scrollback row length overflow".to_string())?;
    let rows_per_chunk = MAX_HISTORY_FRAME_SIZE
        .checked_sub(HISTORY_HEADER_SIZE)
        .and_then(|available| available.checked_div(row_bytes))
        .unwrap_or(0)
        .min(usize::from(u16::MAX));
    if rows_per_chunk == 0 {
        return Err(format!(
            "one {cols}-column row cannot fit in a {MAX_HISTORY_FRAME_SIZE}-byte H frame"
        ));
    }

    let mut rows = rows.into_iter();
    let mut chunks = VecDeque::new();
    let mut first_offset = 1u32;
    loop {
        let mut cells = Vec::with_capacity(rows_per_chunk * usize::from(cols));
        let mut row_count = 0u16;
        for _ in 0..rows_per_chunk {
            let Some(row) = rows.next() else {
                break;
            };
            if row.len() != usize::from(cols) {
                return Err(format!(
                    "scrollback row has {} cells, expected {cols}",
                    row.len()
                ));
            }
            cells.extend(row.into_iter().map(wire_cell));
            row_count += 1;
        }
        if row_count == 0 {
            break;
        }
        let payload = encode_history_payload(&HistoryChunk {
            cols,
            first_offset,
            row_count,
            cells,
        })
        .map_err(|error| error.to_string())?;
        chunks.push_back(Bytes::from(payload));
        first_offset = first_offset
            .checked_add(u32::from(row_count))
            .ok_or_else(|| "scrollback offset overflow".to_string())?;
    }
    Ok(chunks)
}

fn wire_cell(cell: termiod_vt::Cell) -> WireCell {
    WireCell {
        codepoint: cell.codepoint,
        foreground: [cell.foreground.r, cell.foreground.g, cell.foreground.b],
        background: [cell.background.r, cell.background.g, cell.background.b],
        attributes: cell.attributes,
    }
}

fn grid_from_damage(frame_seq: u32, damage: termiod_vt::Damage) -> GridDiff {
    GridDiff {
        frame_seq,
        rows: damage.rows,
        cols: damage.cols,
        cursor_x: damage.cursor_x,
        cursor_y: damage.cursor_y,
        alt_screen: damage.alt_screen,
        dirty_rows: damage
            .dirty_rows
            .into_iter()
            .map(|row| GridRow {
                row_index: row.row_index,
                cells: row.cells.into_iter().map(wire_cell).collect(),
            })
            .collect(),
    }
}

fn keyframe_every_frames() -> u32 {
    std::env::var("TERMIOD_KEYFRAME_EVERY")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(KEYFRAME_EVERY_FRAMES)
}

fn should_emit_keyframe(frame_seq: u32, every: u32) -> bool {
    every > 0 && frame_seq.is_multiple_of(every)
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
    on_exit: mpsc::UnboundedSender<SessionEnded>,
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
        next_snapshot_request: 1,
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
    mpsc::UnboundedReceiver<SidecarResult>,
    JoinHandle<()>,
)> {
    // Deliberately unbounded and fire-and-forget: PTY delivery must never wait
    // for VT parsing. The consumer drains adjacent Bytes writes in batches.
    // Only opt-in grid-diff clients depend on this consumer's progress.
    let (command_tx, command_rx) = std_mpsc::channel::<SidecarCommand>();
    let (result_tx, result_rx) = mpsc::unbounded_channel::<SidecarResult>();
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
            let mut grid_diff_wanted = false;
            let mut frame_seq = 0u32;
            let keyframe_every = keyframe_every_frames();

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
                        if grid_diff_wanted && fault.is_none() {
                            let damage =
                                match terminal.as_mut().expect("live VT terminal").take_damage() {
                                    Ok(damage) => damage,
                                    Err(error) => {
                                        eprintln!("termiod: VT damage drain failed: {error}");
                                        break;
                                    }
                                };
                            if !damage.dirty_rows.is_empty() {
                                frame_seq = frame_seq.wrapping_add(1);
                                if frame_seq == 0 {
                                    frame_seq = 1;
                                }
                                let result = if should_emit_keyframe(frame_seq, keyframe_every) {
                                    match terminal.as_mut().expect("live VT terminal").snapshot() {
                                        Ok(snapshot) => SidecarResult::Keyframe(snapshot),
                                        Err(error) => {
                                            eprintln!(
                                                "termiod: VT keyframe capture failed: {error}"
                                            );
                                            break;
                                        }
                                    }
                                } else {
                                    SidecarResult::Grid(grid_from_damage(frame_seq, damage))
                                };
                                if result_tx.send(result).is_err() {
                                    break;
                                }
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
                    SidecarCommand::Snapshot {
                        client_id,
                        request_id,
                        scrollback,
                    } => {
                        let result = match (&fault, terminal.as_mut()) {
                            (Some(error), _) => Err(error.clone()),
                            (None, Some(terminal)) => match terminal.snapshot() {
                                Ok(snapshot) => {
                                    let history = scrollback.then(|| {
                                        terminal
                                            .scrollback(scrollback_row_limit(snapshot.cols))
                                            .map_err(|error| error.to_string())
                                    });
                                    // Captured at the same FIFO boundary as the
                                    // cell snapshot so both describe one screen.
                                    let vt = terminal.format_vt().ok();
                                    Ok(SidecarCapture {
                                        snapshot,
                                        vt,
                                        scrollback: history,
                                    })
                                }
                                Err(error) => Err(error.to_string()),
                            },
                            (None, None) => Err("VT sidecar is unavailable".to_string()),
                        };
                        if result_tx
                            .send(SidecarResult::Snapshot {
                                client_id,
                                request_id,
                                result,
                            })
                            .is_err()
                        {
                            break;
                        }
                    }
                    SidecarCommand::SetGridDiff(wanted) => grid_diff_wanted = wanted,
                    SidecarCommand::Shutdown => break,
                }
            }
        })
        .map_err(|error| anyhow::anyhow!("spawning VT sidecar thread: {error}"))?;
    Ok((command_tx, result_rx, thread))
}

async fn run(
    mut session: Session,
    mut rx: mpsc::UnboundedReceiver<SessionMsg>,
    waiter: tokio::task::JoinHandle<i32>,
    on_exit: mpsc::UnboundedSender<SessionEnded>,
    mut sidecar_results: mpsc::UnboundedReceiver<SidecarResult>,
    sidecar_thread: JoinHandle<()>,
) {
    let mut buf = vec![0u8; READ_CHUNK];
    let mut waiter = Some(waiter);
    let mut sidecar_results_open = true;
    let mut history_stages = VecDeque::<ClientId>::new();
    let mut killed = false;

    loop {
        tokio::select! {
            _ = tokio::task::yield_now(), if !history_stages.is_empty() => {
                let client_id = history_stages
                    .pop_front()
                    .expect("history stage queue became empty");
                if session.continue_history(&client_id) {
                    history_stages.push_back(client_id);
                }
            }
            msg = rx.recv() => {
                let Some(msg) = msg else { break };
                if handle_msg(&mut session, msg) {
                    // `handle_msg` only asks to stop for `Kill`, so this is the
                    // one end a client chose — the distinction a tombstone keeps.
                    killed = true;
                    break;
                }
            }
            result = sidecar_results.recv(), if sidecar_results_open => {
                match result {
                    Some(SidecarResult::Snapshot { client_id, request_id, result }) => {
                        if session.finish_snapshot(&client_id, request_id, result) {
                            history_stages.push_back(client_id);
                        }
                    }
                    Some(SidecarResult::Grid(grid)) => session.fan_out_grid(grid),
                    Some(SidecarResult::Keyframe(snapshot)) => {
                        session.fan_out_keyframe(snapshot);
                    }
                    None => {
                        sidecar_results_open = false;
                        session.sidecar_tx.take();
                        session.disconnect_grid_clients("VT sidecar response channel closed");
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
    // `alive: false` — this record only ever describes a session that has ended,
    // and a tombstone built from it must not claim otherwise.
    let mut info = session.info();
    info.alive = false;
    let _ = on_exit.send(SessionEnded {
        info,
        status: code,
        killed,
    });
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
            scrollback,
            grid_diff,
            reply,
        } => {
            let seq = session.next_seq;
            session.next_seq += 1;
            let old_writer = session.writer.clone();
            let snapshot_request = snapshot.then(|| session.allocate_snapshot_request());
            let grid_diff = grid_diff && snapshot;

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
                    snapshot_capable: snapshot,
                    grid_diff,
                    delivery: if let Some(request_id) = snapshot_request {
                        ClientDelivery::SnapshotPending {
                            request_id,
                            data: VecDeque::new(),
                            deferred: VecDeque::new(),
                        }
                    } else {
                        ClientDelivery::Live
                    },
                    staged_history: VecDeque::new(),
                },
            );
            // Enabling precedes this client's in-band Snapshot request, so
            // later Writes can only produce G results after its S boundary.
            session.sync_grid_diff_interest();
            if interactive {
                session.writer = Some(id.clone());
            }
            let is_writer = session.writer.as_deref() == Some(id.as_str());
            let _ = reply.send(AddClientReply {
                writer: is_writer,
                rows: session.rows,
                cols: session.cols,
            });

            if let Some(request_id) = snapshot_request {
                if !session.send_sidecar(SidecarCommand::Snapshot {
                    client_id: id.clone(),
                    request_id,
                    scrollback,
                }) {
                    let _ = session.finish_snapshot(
                        &id,
                        request_id,
                        Err("VT sidecar is unavailable".to_string()),
                    );
                }
            }

            if session.writer != old_writer {
                session.emit_writer_changed(old_writer);
            }
            session.emit_roster();
        }
        SessionMsg::RemoveClient { id } => {
            let old_writer = session.writer.clone();
            session.clients.remove(&id);
            session.sync_grid_diff_interest();
            if old_writer.as_deref() == Some(id.as_str()) {
                session.recompute_writer();
            }
            if session.writer != old_writer {
                session.emit_writer_changed(session.writer.clone());
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
                if let Err(error) = session.pty.resize(rows, cols) {
                    session.reject_resize(&id, &error);
                    return false;
                }
                session.rows = rows;
                session.cols = cols;
                session.send_sidecar(SidecarCommand::Resize { rows, cols });
                session.begin_snapshot_barrier();
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
    use super::{
        handle_msg, scrollback_row_limit, should_emit_keyframe, spawn_sidecar, ClientBacklog,
        ClientDelivery, ClientEntry, ClientEvent, Session, SessionMsg, SidecarCommand,
        SidecarResult, CLIENT_BACKLOG_CAP, SCROLLBACK_STAGE_MAX_BYTES, SNAPSHOT_CELL_SIZE,
    };
    use crate::protocol::{Control, ErrorCode};
    use crate::pty::Pty;
    use bytes::Bytes;
    use std::collections::{HashMap, VecDeque};
    use std::sync::{mpsc as std_mpsc, Arc};
    use tokio::sync::{broadcast, mpsc};

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
    fn scrollback_stage_cap_is_measured_in_encoded_rows() {
        let cols = 80u16;
        let row_bytes = usize::from(cols) * SNAPSHOT_CELL_SIZE;
        let rows = scrollback_row_limit(cols);

        assert!(rows * row_bytes <= SCROLLBACK_STAGE_MAX_BYTES);
        assert!((rows + 1) * row_bytes > SCROLLBACK_STAGE_MAX_BYTES);
    }

    #[test]
    fn keyframe_cadence_replaces_every_nth_grid_flush() {
        assert!(!should_emit_keyframe(1, 4));
        assert!(!should_emit_keyframe(3, 4));
        assert!(should_emit_keyframe(4, 4));
        assert!(should_emit_keyframe(8, 4));
    }

    #[test]
    fn resize_snapshot_request_is_an_exact_sidecar_fifo_boundary() {
        let (sidecar, mut snapshots, thread) = spawn_sidecar(2, 16).unwrap();
        sidecar
            .send(SidecarCommand::Write(Bytes::from_static(b"BEFORE")))
            .unwrap();
        sidecar
            .send(SidecarCommand::Resize { rows: 3, cols: 20 })
            .unwrap();
        sidecar
            .send(SidecarCommand::Snapshot {
                client_id: "client".to_string(),
                request_id: 1,
                scrollback: false,
            })
            .unwrap();
        sidecar
            .send(SidecarCommand::Write(Bytes::from_static(b"AFTER")))
            .unwrap();

        let SidecarResult::Snapshot {
            request_id, result, ..
        } = snapshots.blocking_recv().unwrap()
        else {
            panic!("snapshot request returned a grid result");
        };
        assert_eq!(request_id, 1);
        let snapshot = result.unwrap().snapshot;
        assert_eq!((snapshot.rows, snapshot.cols), (3, 20));
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

    #[tokio::test]
    async fn failed_pty_resize_preserves_state_and_reports_error() {
        let pty = Arc::new(Pty::non_pty_for_resize_failure_test().unwrap());
        let (input_tx, _input_rx) = mpsc::unbounded_channel();
        let (events, mut event_rx) = broadcast::channel(8);
        let (client_tx, mut client_rx) = mpsc::unbounded_channel();
        let backlog = Arc::new(ClientBacklog::new());
        let (sidecar_tx, sidecar_rx) = std_mpsc::channel();
        let mut session = Session {
            id: "session".to_string(),
            name: "test".to_string(),
            cwd: String::new(),
            command: "cat".to_string(),
            pid: 0,
            rows: 24,
            cols: 80,
            created_unix: 0,
            status: "unknown".to_string(),
            title: None,
            workstream: None,
            pty,
            input_tx,
            clients: HashMap::from([(
                "writer".to_string(),
                ClientEntry {
                    out: client_tx,
                    backlog,
                    seq: 1,
                    interactive: true,
                    snapshot_capable: false,
                    grid_diff: false,
                    delivery: ClientDelivery::Live,
                    staged_history: VecDeque::new(),
                },
            )]),
            writer: Some("writer".to_string()),
            next_seq: 2,
            next_snapshot_request: 1,
            ring: VecDeque::new(),
            ring_bytes: 0,
            events,
            sidecar_tx: Some(sidecar_tx),
        };

        assert!(!handle_msg(
            &mut session,
            SessionMsg::Resize {
                id: "writer".to_string(),
                rows: 40,
                cols: 120,
            },
        ));

        assert_eq!((session.rows, session.cols), (24, 80));
        assert!(matches!(
            sidecar_rx.try_recv(),
            Err(std_mpsc::TryRecvError::Empty)
        ));
        assert!(matches!(
            event_rx.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
        match client_rx.recv().await.unwrap() {
            ClientEvent::Control(Control::Error {
                code,
                message,
                retryable,
                ..
            }) => {
                assert_eq!(code, ErrorCode::Internal);
                assert!(message.starts_with("resize failed: TIOCSWINSZ failed:"));
                assert!(retryable);
            }
            _ => panic!("failed resize did not return a typed control error"),
        }
        assert!(client_rx.try_recv().is_err());
    }
}
