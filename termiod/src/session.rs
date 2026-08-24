//! A single durable session: one PTY, one child process group, and a set of
//! attached clients. It runs as an actor whose lifetime is independent of any
//! connection — detach never kills it.

use crate::protocol::{
    encode_grid_payload, encode_history_payload, Control, ErrorCode, Event, GridDiff, GridRow,
    HistoryChunk, SessionInfo, Snapshot, WireCell, WireColor, WorkstreamSpec, HISTORY_HEADER_SIZE,
    MAX_HISTORY_FRAME_SIZE, SNAPSHOT_CELL_SIZE,
};
use crate::pty::Pty;
use crate::tombstone::EndReason;
use bytes::Bytes;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, mpsc, oneshot};

pub type ClientId = String;

const RING_CAP: usize = 128 * 1024;
const READ_CHUNK: usize = 64 * 1024;
const CLIENT_BACKLOG_CAP: usize = 4 * 1024 * 1024;
/// PTY bytes allowed to sit unparsed in the VT sidecar's command FIFO. The
/// per-client budget stopped a slow socket from buying unbounded memory; this
/// stops a slow *parse* from doing the same one hop upstream.
const SIDECAR_QUEUE_CAP: usize = 16 * 1024 * 1024;
pub const SCROLLBACK_STAGE_MAX_BYTES: usize = 1024 * 1024;
pub const KEYFRAME_EVERY_FRAMES: u32 = 256;
/// How often the session asks the kernel what is running in its terminal.
/// Slow on purpose: this answers "which agent is in there", a question whose
/// answer changes when a human starts or stops a program, not per frame.
const FOREGROUND_POLL: std::time::Duration = std::time::Duration::from_secs(2);

/// A payload admitted against a client's backlog. The epoch pins it to the
/// reservation that let it through, so a forced resync can discard everything
/// already queued for that client without corrupting the count.
#[derive(Clone)]
pub struct Metered {
    pub bytes: Bytes,
    epoch: u64,
}

/// Counts PTY bytes queued anywhere between a session and its socket writer.
pub(crate) struct ClientBacklog {
    outstanding: AtomicUsize,
    /// Bumped by a forced resync. Everything reserved under an older epoch is
    /// stale: it precedes a snapshot that supersedes it, so it is dropped
    /// undelivered and never released.
    epoch: AtomicU64,
    dropped: AtomicBool,
}

impl ClientBacklog {
    pub(crate) fn new() -> Self {
        Self {
            outstanding: AtomicUsize::new(0),
            epoch: AtomicU64::new(0),
            dropped: AtomicBool::new(false),
        }
    }

    fn reserve(&self, bytes: Bytes) -> Option<Metered> {
        self.outstanding
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |outstanding| {
                outstanding
                    .checked_add(bytes.len())
                    .filter(|total| *total <= CLIENT_BACKLOG_CAP)
            })
            .ok()?;
        Some(Metered {
            bytes,
            epoch: self.epoch.load(Ordering::Acquire),
        })
    }

    /// True once the client has consumed everything the session handed it.
    #[cfg(test)]
    fn is_drained(&self) -> bool {
        self.outstanding.load(Ordering::Relaxed) == 0
    }

    /// Discard everything already queued for this client and start a new epoch.
    /// The queued payloads are dropped where they sit rather than released, so
    /// the counter is reset here instead of unwound.
    fn begin_resync(&self) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        self.outstanding.store(0, Ordering::Release);
    }

    /// True while this payload still belongs to the client's current stream.
    pub(crate) fn is_current(&self, payload: &Metered) -> bool {
        payload.epoch == self.epoch.load(Ordering::Acquire)
    }

    pub(crate) fn release(&self, payload: &Metered) {
        if !self.is_current(payload) {
            return;
        }
        let _ =
            self.outstanding
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |outstanding| {
                    Some(outstanding.saturating_sub(payload.bytes.len()))
                });
    }

    fn mark_dropped(&self) {
        self.dropped.store(true, Ordering::Release);
    }

    pub(crate) fn is_dropped(&self) -> bool {
        self.dropped.load(Ordering::Acquire)
    }
}

/// Counts PTY bytes queued for the VT sidecar but not yet parsed.
struct SidecarQueue {
    outstanding: AtomicUsize,
}

impl SidecarQueue {
    fn new() -> Self {
        Self {
            outstanding: AtomicUsize::new(0),
        }
    }

    fn try_reserve(&self, bytes: usize) -> bool {
        self.outstanding
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |outstanding| {
                outstanding
                    .checked_add(bytes)
                    .filter(|total| *total <= SIDECAR_QUEUE_CAP)
            })
            .is_ok()
    }

    fn release(&self, bytes: usize) {
        let _ =
            self.outstanding
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |outstanding| {
                    Some(outstanding.saturating_sub(bytes))
                });
    }
}

/// Pushed to an attached connection task.
#[derive(Clone)]
pub enum ClientEvent {
    Data(Metered),
    Snapshot(Snapshot),
    History(Metered),
    Grid(Metered),
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
    /// A client asks to be repainted: it lost bytes somewhere downstream and
    /// cannot reconstruct the screen from what it has.
    ResendSnapshot { id: ClientId },
    /// A client asks for the write token because its user is typing. Refused
    /// for an observer, which by §A never holds it.
    ClaimWriter {
        id: ClientId,
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
    Kill {
        reason: EndReason,
    },
}

/// What the manager needs to bury a session (§6). The session actor is the last
/// thing that can answer `Info` — by the time the manager hears about the exit
/// the actor is gone — so the record travels *with* the notification instead of
/// being asked for afterwards.
pub struct SessionEnded {
    pub info: SessionInfo,
    pub status: i32,
    pub reason: EndReason,
}

/// Cheap, cloneable reference to a session task.
#[derive(Clone)]
pub struct SessionHandle {
    pub id: String,
    pid: i32,
    tx: mpsc::UnboundedSender<SessionMsg>,
    /// PTY EOF can become ready in the same scheduler turn as `Kill`; keeping
    /// the first requested reason outside the queue makes that race deterministic.
    termination_reason: Arc<Mutex<Option<EndReason>>>,
}

impl SessionHandle {
    pub fn send(&self, msg: SessionMsg) -> bool {
        if let SessionMsg::Kill { reason } = &msg {
            let mut requested = self.termination_reason.lock().unwrap();
            if requested.is_none() {
                *requested = Some(*reason);
            }
        }
        self.tx.send(msg).is_ok()
    }

    pub fn termination_reason(&self) -> Option<EndReason> {
        *self.termination_reason.lock().unwrap()
    }

    /// A session actor normally owns termination and reports the exact reason.
    /// This is only for the shutdown deadline: killing the process releases the
    /// blocking child waiter even if the actor itself stopped making progress.
    pub fn force_kill(&self) {
        unsafe {
            libc::kill(-self.pid, libc::SIGKILL);
        }
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
    /// Backlog strikes taken by this attachment. The first buys a forced
    /// resync; the second is the drop. Strikes are never forgiven — the resync
    /// already zeroed the count of what the client owes, so a second overflow
    /// means it could not keep up even from a clean start.
    backlog_strikes: u32,
}

enum ClientDelivery {
    Live,
    SnapshotPending {
        request_id: u64,
        data: VecDeque<Metered>,
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
    sidecar_queue: Arc<SidecarQueue>,
    /// Set once the VT has been denied bytes it needed. The screen it holds no
    /// longer describes any boundary in the output stream, so it can never
    /// answer a snapshot again — attach and resync fall back to ring replay.
    vt_stale: Option<String>,
    /// Last sample of who is in the tty's foreground and where the child is.
    /// `info()` reads this cache so a roster request never turns into a burst
    /// of syscalls.
    foreground: ForegroundSample,
    /// A resolution is in flight on a blocking thread. One at a time: the poll
    /// is slower than the work, and piling up would only queue answers about
    /// groups that have already lost the terminal.
    foreground_pending: bool,
    /// The binary the child is running, pinned on the first sample that finds
    /// it. One-shot on purpose: this is the *launch* baseline that
    /// `was_replaced()` compares against, and resampling would paper over the
    /// in-place upgrade it exists to notice.
    child_executable: Option<crate::proc::ExecutableIdentity>,
}

/// What the session believes about its foreground right now.
///
/// Split deliberately along what it costs to learn. `pgid` and `job` come from
/// one `tcgetpgrp` and are refreshed on the actor; everything below them is a
/// process-table walk and arrives later, from [`ForegroundResolution`].
#[derive(Default, Clone, PartialEq, Eq)]
struct ForegroundSample {
    /// The foreground process *group*, exactly as `tcgetpgrp` reported it.
    /// Kept even when no member of it could be read, because "is a job
    /// running?" is answered by comparing this against the session's own child
    /// and must not turn into "no" the moment a pipeline's leader exits.
    pgid: Option<i32>,
    /// The member of that group whose argv is reported below. Equal to `pgid`
    /// whenever the group leader is still usable, which is the common case.
    pid: Option<i32>,
    argv: Option<Vec<String>>,
    job: bool,
    cwd: Option<String>,
}

/// The expensive half of a foreground sample, computed on a blocking thread and
/// handed back to the actor.
///
/// Reading argv means a `KERN_PROCARGS2` sysctl on macOS and a file read on
/// Linux, and finding *which* pid to read it for can mean walking every process
/// on the box when a pipeline's leader has exited. None of that may happen on
/// the session actor: that task also runs the PTY read and the fan-out, so a
/// process-table walk there is time the byte path spends waiting — the
/// anti-100× invariant, which is about more than the VT parse.
struct ForegroundResolution {
    /// The group this answer describes. The foreground can move while the
    /// resolution is in flight, and an answer about a group that has since lost
    /// the terminal is not a stale version of the truth — it is the answer to a
    /// different question, and gets dropped.
    pgid: Option<i32>,
    pid: Option<i32>,
    argv: Option<Vec<String>>,
    cwd: Option<String>,
    /// Only set when the session had not pinned its binary yet.
    executable: Option<crate::proc::ExecutableIdentity>,
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
            foreground_pid: self.foreground.pid,
            foreground_argv: self.foreground.argv.clone(),
            foreground_job: self.foreground.job,
            child_cwd: self.foreground.cwd.clone(),
            child_executable: self
                .child_executable
                .as_ref()
                .map(|identity| identity.path.clone()),
            // Checked here rather than cached from the last tick: the record
            // that matters most is the one built on the exit path, and a binary
            // swapped during the seconds before the child quit is exactly the
            // case this answers.
            child_executable_replaced: self
                .child_executable
                .as_ref()
                .is_some_and(|identity| identity.was_replaced()),
        }
    }

    /// The cheap half of the poll, and the only half that runs here: one
    /// `tcgetpgrp` on the master. Returns whether anything moved, so a quiet
    /// session emits no roster traffic.
    ///
    /// The expensive half is dispatched to a blocking thread and applied later
    /// by [`Session::apply_foreground`]. Both halves have to exist because they
    /// answer different questions on different deadlines: "is a job running?"
    /// is read at close time and must be current, and it is answerable from the
    /// group id alone; "what is that job?" drives an icon and can be a beat
    /// late.
    fn sample_foreground(
        &mut self,
        resolved: &mpsc::UnboundedSender<ForegroundResolution>,
    ) -> bool {
        if self.pid <= 0 {
            return false;
        }
        let pgid = self.pty.foreground_pgid();
        // Compared against the *group*: a foreground group that is not the
        // child's own is a running job whether or not any member of it could
        // be read.
        let job = pgid.is_some_and(|pgid| pgid != self.pid);
        let mut changed = false;
        if self.foreground.pgid != pgid {
            self.foreground.pgid = pgid;
            // The cached identity described a group that no longer holds the
            // terminal. Dropping it is an honest gap the resolution below
            // fills; keeping it would name a program that has already exited.
            self.foreground.pid = None;
            self.foreground.argv = None;
            changed = true;
        }
        if self.foreground.job != job {
            self.foreground.job = job;
            changed = true;
        }
        self.request_foreground(pgid, resolved);
        changed
    }

    /// Hand the process-table work to a blocking thread.
    fn request_foreground(
        &mut self,
        pgid: Option<i32>,
        resolved: &mpsc::UnboundedSender<ForegroundResolution>,
    ) {
        if self.foreground_pending {
            return;
        }
        self.foreground_pending = true;
        let child = self.pid;
        let pin_executable = self.child_executable.is_none();
        let resolved = resolved.clone();
        tokio::task::spawn_blocking(move || {
            // A group id is not a pid. The shell names each job's group after
            // its leader, so the two agree for as long as that leader is alive
            // — and stop agreeing in a pipeline the moment it is not, which is
            // why the pid comes from the host rather than from that assumption.
            let pid = pgid.and_then(crate::proc::foreground_member);
            let _ = resolved.send(ForegroundResolution {
                pgid,
                pid,
                argv: pid.and_then(crate::proc::process_arguments),
                cwd: crate::proc::working_directory(child),
                executable: pin_executable
                    .then(|| crate::proc::executable_identity(child))
                    .flatten(),
            });
        });
    }

    /// Take a resolution the blocking thread finished, unless the foreground
    /// moved while it was in flight. Returns whether anything moved.
    fn apply_foreground(&mut self, resolution: ForegroundResolution) -> bool {
        self.foreground_pending = false;
        if resolution.pgid != self.foreground.pgid {
            return false;
        }
        if self.child_executable.is_none() {
            self.child_executable = resolution.executable;
        }
        let mut changed = false;
        if self.foreground.pid != resolution.pid {
            self.foreground.pid = resolution.pid;
            changed = true;
        }
        if self.foreground.argv != resolution.argv {
            self.foreground.argv = resolution.argv;
            changed = true;
        }
        if self.foreground.cwd != resolution.cwd {
            self.foreground.cwd = resolution.cwd;
            changed = true;
        }
        changed
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

    /// The one path that puts PTY bytes into the VT. It is budgeted, and the
    /// only legal degrade is to stop feeding the VT and say so — dropping bytes
    /// silently would leave `S` describing a screen that never occurred, and
    /// blocking here would put the VT parse back on the fan-out path.
    fn write_sidecar(&mut self, chunk: Bytes) {
        if self.vt_stale.is_some() || self.sidecar_tx.is_none() {
            return;
        }
        if !self.sidecar_queue.try_reserve(chunk.len()) {
            self.mark_vt_stale(format!(
                "VT sidecar fell more than {} MiB behind the PTY",
                SIDECAR_QUEUE_CAP / (1024 * 1024)
            ));
            return;
        }
        let len = chunk.len();
        if !self.send_sidecar(SidecarCommand::Write(chunk)) {
            self.sidecar_queue.release(len);
        }
    }

    fn mark_vt_stale(&mut self, reason: String) {
        if self.vt_stale.is_some() {
            return;
        }
        eprintln!(
            "termiod: VT sidecar for session {} is stale: {reason}; snapshots now fall back to ring replay",
            self.id
        );
        self.vt_stale = Some(reason.clone());
        // Nothing more will reach the VT, so drain what is queued rather than
        // let a wedged parse hold the memory.
        self.send_sidecar(SidecarCommand::Shutdown);
        self.sidecar_tx.take();
        self.emit_event(Event::VtStale {
            session: self.id.clone(),
            reason: reason.clone(),
        });
        self.disconnect_grid_clients(&reason);
        self.fallback_all_pending(&reason);
    }

    /// Ask the sidecar for one client's snapshot, or fail it straight into the
    /// ring-replay fallback when the VT can no longer answer.
    fn request_snapshot(&mut self, client_id: ClientId, request_id: u64, scrollback: bool) {
        let refusal = self.vt_stale.clone().or_else(|| {
            self.sidecar_tx
                .is_none()
                .then(|| "VT sidecar is unavailable".to_string())
        });
        if let Some(reason) = refusal {
            self.finish_snapshot(&client_id, request_id, Err(reason));
            return;
        }
        if !self.send_sidecar(SidecarCommand::Snapshot {
            client_id: client_id.clone(),
            request_id,
            scrollback,
        }) {
            self.finish_snapshot(
                &client_id,
                request_id,
                Err("VT sidecar is unavailable".to_string()),
            );
        }
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
            self.request_snapshot(client_id, request_id, false);
        }
    }

    /// D4(a): a client that outruns its backlog gets one forced resync before it
    /// gets dropped. Everything already queued for it is discarded — that is the
    /// point, since replaying megabytes to a client that could not keep up is
    /// what put it here — and the snapshot that follows re-establishes JOIN at a
    /// fresh boundary. No other client is touched.
    fn force_resync(&mut self, client_id: &ClientId, reason: &str) {
        let request_id = self.allocate_snapshot_request();
        let session_id = self.id.clone();
        let Some(entry) = self.clients.get_mut(client_id) else {
            return;
        };
        entry.backlog_strikes += 1;
        entry.staged_history.clear();
        entry.backlog.begin_resync();
        let previous = std::mem::replace(&mut entry.delivery, ClientDelivery::Live);
        let mut deferred = match previous {
            ClientDelivery::Live => VecDeque::new(),
            // The buffered data was reserved under the epoch just retired, so it
            // is dropped with the rest rather than replayed past the new `S`.
            ClientDelivery::SnapshotPending { deferred, .. } => deferred,
        };
        deferred.push_back(ClientEvent::Event(Event::Resynced {
            session: session_id,
            reason: reason.to_string(),
        }));
        entry.delivery = ClientDelivery::SnapshotPending {
            request_id,
            data: VecDeque::new(),
            deferred,
        };
        eprintln!(
            "termiod: resyncing client {client_id} on session {}: {reason}",
            self.id
        );
        self.request_snapshot(client_id.clone(), request_id, false);
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
        let mut resync = Vec::new();
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
                let Some(payload) = entry.backlog.reserve(data.clone()) else {
                    if entry.backlog_strikes == 0 && entry.snapshot_capable {
                        resync.push(id.clone());
                        return None;
                    }
                    entry.backlog.mark_dropped();
                    eprintln!(
                        "termiod: dropping slow client {id} from session {}: output backlog exceeded {} MiB again",
                        self.id,
                        CLIENT_BACKLOG_CAP / (1024 * 1024)
                    );
                    return Some(id.clone());
                };
                match &mut entry.delivery {
                    ClientDelivery::Live => {
                        if entry.out.send(ClientEvent::Data(payload.clone())).is_err() {
                            entry.backlog.release(&payload);
                            return Some(id.clone());
                        }
                    }
                    ClientDelivery::SnapshotPending { data: buffered, .. } => {
                        buffered.push_back(payload);
                    }
                }
                None
            })
            .collect();
        self.remove_dead(dead);
        for client_id in resync {
            self.force_resync(
                &client_id,
                &format!(
                    "output backlog exceeded {} MiB",
                    CLIENT_BACKLOG_CAP / (1024 * 1024)
                ),
            );
        }
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
                let Some(metered) = entry.backlog.reserve(payload.clone()) else {
                    entry.backlog.mark_dropped();
                    eprintln!(
                        "termiod: dropping slow grid-diff client {id} from session {}: output backlog exceeded {} MiB",
                        self.id,
                        CLIENT_BACKLOG_CAP / (1024 * 1024)
                    );
                    return Some(id.clone());
                };
                if entry.out.send(ClientEvent::Grid(metered.clone())).is_err() {
                    entry.backlog.release(&metered);
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
        let Some(metered) = entry.backlog.reserve(payload.clone()) else {
            entry.backlog.mark_dropped();
            eprintln!(
                "termiod: dropping slow client {client_id} from session {session_id}: scrollback backlog exceeded {} MiB",
                CLIENT_BACKLOG_CAP / (1024 * 1024)
            );
            return Err(());
        };
        entry.staged_history.pop_front();
        if entry
            .out
            .send(ClientEvent::History(metered.clone()))
            .is_err()
        {
            entry.backlog.release(&metered);
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
        while let Some(payload) = data.pop_front() {
            if entry.out.send(ClientEvent::Data(payload.clone())).is_err() {
                entry.backlog.release(&payload);
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
                .map(wire_cell)
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
        buffered: VecDeque<Metered>,
        deferred: VecDeque<ClientEvent>,
        error: &str,
    ) {
        eprintln!(
            "termiod: VT snapshot unavailable for client {client_id} in session {}: {error}; falling back to ring replay",
            self.id
        );
        release_buffered(&entry.backlog, buffered);

        for replay in &self.ring {
            let Some(metered) = entry.backlog.reserve(replay.clone()) else {
                entry.backlog.mark_dropped();
                self.remove_finished_client(client_id);
                return;
            };
            if entry.out.send(ClientEvent::Data(metered.clone())).is_err() {
                entry.backlog.release(&metered);
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

fn wire_color(color: termiod_vt::Color) -> WireColor {
    match color {
        termiod_vt::Color::Default => WireColor::Default,
        termiod_vt::Color::Palette(index) => WireColor::Palette(index),
        termiod_vt::Color::Rgb(value) => WireColor::Rgb([value.r, value.g, value.b]),
    }
}

fn wire_cell(cell: termiod_vt::Cell) -> WireCell {
    WireCell {
        codepoint: cell.codepoint,
        foreground: wire_color(cell.foreground),
        background: wire_color(cell.background),
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

fn release_buffered(backlog: &ClientBacklog, data: VecDeque<Metered>) {
    for payload in data {
        backlog.release(&payload);
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

    let sidecar = spawn_sidecar(rows, cols)?;

    let (tx, rx) = mpsc::unbounded_channel();
    let termination_reason = Arc::new(Mutex::new(None));
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
        sidecar_tx: Some(sidecar.commands),
        sidecar_queue: sidecar.queue,
        vt_stale: None,
        foreground: ForegroundSample::default(),
        foreground_pending: false,
        child_executable: None,
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
        sidecar.results,
        sidecar.thread,
        termination_reason.clone(),
    ));
    Ok(SessionHandle {
        id,
        pid,
        tx,
        termination_reason,
    })
}

struct Sidecar {
    commands: std_mpsc::Sender<SidecarCommand>,
    results: mpsc::UnboundedReceiver<SidecarResult>,
    queue: Arc<SidecarQueue>,
    thread: JoinHandle<()>,
}

fn spawn_sidecar(rows: u16, cols: u16) -> anyhow::Result<Sidecar> {
    // The channel itself stays unbounded and fire-and-forget — PTY delivery must
    // never wait for VT parsing. `SidecarQueue` is the budget instead: the
    // producer stops feeding the VT and declares it stale rather than blocking
    // or letting a slow parse buy unbounded memory. The consumer drains
    // adjacent Bytes writes in batches.
    let (command_tx, command_rx) = std_mpsc::channel::<SidecarCommand>();
    let (result_tx, result_rx) = mpsc::unbounded_channel::<SidecarResult>();
    let queue = Arc::new(SidecarQueue::new());
    let parsed = queue.clone();
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
                        parsed.release(bytes.len());
                        loop {
                            match command_rx.try_recv() {
                                Ok(SidecarCommand::Write(bytes)) => {
                                    if let Some(terminal) = terminal.as_mut() {
                                        terminal.vt_write(&bytes);
                                    }
                                    parsed.release(bytes.len());
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
    Ok(Sidecar {
        commands: command_tx,
        results: result_rx,
        queue,
        thread,
    })
}

async fn run(
    mut session: Session,
    mut rx: mpsc::UnboundedReceiver<SessionMsg>,
    waiter: tokio::task::JoinHandle<i32>,
    on_exit: mpsc::UnboundedSender<SessionEnded>,
    mut sidecar_results: mpsc::UnboundedReceiver<SidecarResult>,
    sidecar_thread: JoinHandle<()>,
    termination_reason: Arc<Mutex<Option<EndReason>>>,
) {
    let mut buf = vec![0u8; READ_CHUNK];
    let mut waiter = Some(waiter);
    let mut sidecar_results_open = true;
    let mut history_stages = VecDeque::<ClientId>::new();
    let mut end_reason = EndReason::Exited;
    // The first tick is immediate, so a session answers "what is running in
    // there" from its first roster request rather than after a cold two
    // seconds. Missed ticks are skipped instead of queued: a busy actor should
    // sample once when it catches up, not replay a backlog of polls.
    let mut foreground_poll = tokio::time::interval(FOREGROUND_POLL);
    foreground_poll.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    // The process-table half of each poll runs on a blocking thread and comes
    // back here. Held for the life of the loop so the branch below never sees a
    // closed channel while the session is alive.
    let (foreground_tx, mut foreground_rx) = mpsc::unbounded_channel::<ForegroundResolution>();

    loop {
        tokio::select! {
            _ = foreground_poll.tick() => {
                if session.sample_foreground(&foreground_tx) {
                    session.emit_roster();
                }
            }
            Some(resolution) = foreground_rx.recv() => {
                if session.apply_foreground(resolution) {
                    session.emit_roster();
                }
            }
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
                if let Some(reason) = handle_msg(&mut session, msg) {
                    end_reason = reason;
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
                        // fire-and-forget. Fan-out never waits for VT parsing,
                        // and it runs even when the VT has gone stale.
                        session.write_sidecar(chunk.clone());
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
    if end_reason == EndReason::Exited {
        if let Some(requested) = *termination_reason.lock().unwrap() {
            end_reason = requested;
        }
    }
    if let Some(sidecar_tx) = session.sidecar_tx.take() {
        let _ = sidecar_tx.send(SidecarCommand::Shutdown);
    }

    let code = match waiter.take() {
        Some(w) => w.await.unwrap_or(-1),
        None => -1,
    };
    // One final record, built after the reap and used for everything that
    // outlives the session: the exit event clients hear, and the tombstone the
    // manager buries. Sampling it twice would let the two disagree — the
    // interesting field, `child_executable_replaced`, is a fresh disk read every
    // time it is asked, and an agent that replaced its binary between the two
    // reads is exactly the case both consumers are for.
    //
    // `alive: false` — this record only ever describes a session that has ended.
    let mut info = session.info();
    info.alive = false;
    let exit_event = Event::SessionExited {
        session: session.id.clone(),
        status: code,
        info: Some(Box::new(info.clone())),
    };
    let _ = session.events.send(exit_event.clone());
    for entry in session.clients.values() {
        let _ = entry.out.send(ClientEvent::Event(exit_event.clone()));
        let _ = entry.out.send(ClientEvent::Exited(code));
    }
    let _ = tokio::task::spawn_blocking(move || sidecar_thread.join()).await;
    let _ = on_exit.send(SessionEnded {
        info,
        status: code,
        reason: end_reason,
    });
}

fn handle_msg(session: &mut Session, msg: SessionMsg) -> Option<EndReason> {
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
                    let Some(metered) = backlog.reserve(replay.clone()) else {
                        break;
                    };
                    if out.send(ClientEvent::Data(metered.clone())).is_err() {
                        backlog.release(&metered);
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
                    backlog_strikes: 0,
                },
            );
            // Enabling precedes this client's in-band Snapshot request, so
            // later Writes can only produce G results after its S boundary.
            session.sync_grid_diff_interest();
            // Attaching is a viewer arriving, not a device taking over. Taking
            // the token here meant a phone merely *looking* at a session pulled
            // the one shared PTY down to phone width through `run_attach`'s
            // resize, and the Mac had no answer: its own resizes are gated on
            // holding the token, so the window sat there rendering a screen
            // formatted for a grid it does not have. The token travels by
            // typing — both ends claim on input — so the only attach that takes
            // it is the one that finds nobody holding it.
            if interactive && session.writer.is_none() {
                session.writer = Some(id.clone());
            }
            let is_writer = session.writer.as_deref() == Some(id.as_str());
            let _ = reply.send(AddClientReply {
                writer: is_writer,
                rows: session.rows,
                cols: session.cols,
            });

            if let Some(request_id) = snapshot_request {
                session.request_snapshot(id.clone(), request_id, scrollback);
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
        SessionMsg::ResendSnapshot { id } => {
            if !session.clients.contains_key(&id) {
                return None;
            }
            let request_id = session.allocate_snapshot_request();
            // No scrollback: this repaints the viewport a client already has
            // room for, and history it never lost.
            session.request_snapshot(id, request_id, false);
        }
        SessionMsg::ClaimWriter { id, reply } => {
            // An observer is refused rather than promoted: it attached without
            // a tty and cannot resize, so handing it the token would strand the
            // session at whatever size the last real client left.
            let eligible = session
                .clients
                .get(&id)
                .map(|entry| entry.interactive)
                .unwrap_or(false);
            let _ = reply.send(eligible);
            if !eligible {
                return None;
            }
            if session.writer.as_ref() == Some(&id) {
                return None;
            }
            session.writer = Some(id);
            // The client that just took the token is told its own size claim is
            // now the one that counts, the same shape `AddClient` uses.
            session.emit_writer_changed(session.writer.clone());
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
                // A resize is a barrier: the session quiesces and every
                // attachment is handed a fresh keyframe to repaint from. Doing
                // that for a size the PTY already has buys nothing and costs
                // each viewer a full repaint — and one arrives on every attach,
                // because `run_attach` asks unconditionally for the size the
                // client named. The child would see no SIGWINCH from this
                // ioctl either, so nothing downstream is waiting on it.
                if rows == session.rows && cols == session.cols {
                    return None;
                }
                if let Err(error) = session.pty.resize(rows, cols) {
                    session.reject_resize(&id, &error);
                    return None;
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
        SessionMsg::Kill { reason } => {
            // The child is a session leader, so pgid == pid.
            unsafe {
                libc::kill(-session.pid, libc::SIGKILL);
            }
            return Some(reason);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{
        handle_msg, scrollback_row_limit, should_emit_keyframe, spawn_sidecar, ClientBacklog,
        ClientDelivery, ClientEntry, ClientEvent, Session, SessionHandle, SessionMsg, Sidecar,
        SidecarCommand, SidecarQueue, SidecarResult, CLIENT_BACKLOG_CAP,
        SCROLLBACK_STAGE_MAX_BYTES, SIDECAR_QUEUE_CAP, SNAPSHOT_CELL_SIZE,
    };
    use crate::protocol::{Control, ErrorCode, Event, SessionInfo};
    use crate::pty::Pty;
    use crate::tombstone::EndReason;
    use bytes::Bytes;
    use std::collections::{HashMap, VecDeque};
    use std::sync::{mpsc as std_mpsc, Arc};
    use tokio::sync::{broadcast, mpsc, oneshot};

    fn chunk(len: usize) -> Bytes {
        Bytes::from(vec![b'x'; len])
    }

    #[test]
    fn client_backlog_enforces_byte_cap() {
        let backlog = ClientBacklog::new();

        let bulk = backlog
            .reserve(chunk(CLIENT_BACKLOG_CAP - 1))
            .expect("bulk reservation");
        let last = backlog.reserve(chunk(1)).expect("last byte");
        assert!(backlog.reserve(chunk(1)).is_none());

        backlog.release(&bulk);
        backlog.release(&last);
        assert!(backlog.is_drained());
        let after = backlog
            .reserve(chunk(1))
            .expect("reservation after release");
        backlog.release(&after);
    }

    #[test]
    fn resync_retires_queued_payloads_without_unwinding_the_count() {
        let backlog = ClientBacklog::new();
        let stale = backlog
            .reserve(chunk(CLIENT_BACKLOG_CAP))
            .expect("full reservation");
        assert!(backlog.reserve(chunk(1)).is_none());

        backlog.begin_resync();

        // The queued payload is dropped where it sits, so the client starts the
        // new epoch with the whole budget rather than waiting for a drain.
        assert!(!backlog.is_current(&stale));
        assert!(backlog.is_drained());
        let fresh = backlog
            .reserve(chunk(CLIENT_BACKLOG_CAP))
            .expect("fresh reservation");

        // A late release of a retired payload must not credit the new epoch.
        backlog.release(&stale);
        assert!(backlog.reserve(chunk(1)).is_none());
        backlog.release(&fresh);
        assert!(backlog.is_drained());
    }

    #[test]
    fn sidecar_queue_stops_admitting_bytes_past_its_budget() {
        let queue = SidecarQueue::new();

        assert!(queue.try_reserve(SIDECAR_QUEUE_CAP));
        assert!(!queue.try_reserve(1));

        queue.release(SIDECAR_QUEUE_CAP);
        assert!(queue.try_reserve(1));
        queue.release(1);
        // Releasing more than was reserved is a bug, not a panic: the VT thread
        // and the session actor account independently.
        queue.release(SIDECAR_QUEUE_CAP);
        assert!(queue.try_reserve(SIDECAR_QUEUE_CAP));
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
        let Sidecar {
            commands: sidecar,
            results: mut snapshots,
            queue,
            thread,
        } = spawn_sidecar(2, 16).unwrap();
        assert!(queue.try_reserve("BEFORE".len()));
        assert!(queue.try_reserve("AFTER".len()));
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
        // Every byte the session charged to the queue is credited back once the
        // VT has parsed it, or the budget ratchets shut on a healthy session.
        assert_eq!(
            queue.outstanding.load(std::sync::atomic::Ordering::Relaxed),
            0
        );
    }

    /// A session with no clients, a live sidecar, and a PTY that only has to
    /// exist — none of the backlog paths touch it.
    fn test_session(
        sidecar_tx: std_mpsc::Sender<SidecarCommand>,
        sidecar_queue: Arc<SidecarQueue>,
    ) -> (Session, broadcast::Receiver<Event>) {
        let pty = Arc::new(Pty::non_pty_for_resize_failure_test().unwrap());
        let (input_tx, _input_rx) = mpsc::unbounded_channel();
        let (events, event_rx) = broadcast::channel(64);
        (
            Session {
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
                clients: HashMap::new(),
                writer: None,
                next_seq: 0,
                next_snapshot_request: 1,
                ring: VecDeque::new(),
                ring_bytes: 0,
                events,
                sidecar_tx: Some(sidecar_tx),
                sidecar_queue,
                vt_stale: None,
                foreground: super::ForegroundSample::default(),
                foreground_pending: false,
                child_executable: None,
            },
            event_rx,
        )
    }

    /// Hand the session the sidecar replies it is waiting on. `run` does this in
    /// its select loop; the tests do it by hand so the barrier is deterministic.
    /// The count is awaited rather than polled — the VT is a real thread, so a
    /// `try_recv` here would race it and hide a working barrier as a hang.
    async fn pump_sidecar(
        session: &mut Session,
        results: &mut mpsc::UnboundedReceiver<SidecarResult>,
        expected: usize,
    ) {
        for _ in 0..expected {
            let result = tokio::time::timeout(std::time::Duration::from_secs(10), results.recv())
                .await
                .expect("the VT sidecar never answered")
                .expect("the VT sidecar hung up");
            apply_sidecar(session, result);
        }
        while let Ok(result) = results.try_recv() {
            apply_sidecar(session, result);
        }
    }

    fn apply_sidecar(session: &mut Session, result: SidecarResult) {
        match result {
            SidecarResult::Snapshot {
                client_id,
                request_id,
                result,
            } => {
                session.finish_snapshot(&client_id, request_id, result);
            }
            SidecarResult::Grid(grid) => session.fan_out_grid(grid),
            SidecarResult::Keyframe(snapshot) => session.fan_out_keyframe(snapshot),
        }
    }

    fn attach_snapshot_client(
        session: &mut Session,
        id: &str,
    ) -> (mpsc::UnboundedReceiver<ClientEvent>, Arc<ClientBacklog>) {
        attach_client(session, id, true)
    }

    /// A client with a tty behind it — the kind that can hold the write token.
    fn attach_interactive_client(
        session: &mut Session,
        id: &str,
    ) -> mpsc::UnboundedReceiver<ClientEvent> {
        let (client_tx, client_rx) = mpsc::unbounded_channel();
        let (reply, _reply_rx) = oneshot::channel();
        handle_msg(
            session,
            SessionMsg::AddClient {
                id: id.to_string(),
                interactive: true,
                out: client_tx,
                backlog: Arc::new(ClientBacklog::new()),
                snapshot: false,
                scrollback: false,
                grid_diff: false,
                reply,
            },
        );
        client_rx
    }

    fn claim_writer(session: &mut Session, id: &str) -> bool {
        let (reply, mut reply_rx) = oneshot::channel();
        handle_msg(
            session,
            SessionMsg::ClaimWriter {
                id: id.to_string(),
                reply,
            },
        );
        reply_rx.try_recv().unwrap_or(false)
    }

    fn attach_client(
        session: &mut Session,
        id: &str,
        snapshot: bool,
    ) -> (mpsc::UnboundedReceiver<ClientEvent>, Arc<ClientBacklog>) {
        let (client_tx, client_rx) = mpsc::unbounded_channel();
        let backlog = Arc::new(ClientBacklog::new());
        let (reply, _reply_rx) = oneshot::channel();
        handle_msg(
            session,
            SessionMsg::AddClient {
                id: id.to_string(),
                interactive: false,
                out: client_tx,
                backlog: backlog.clone(),
                snapshot,
                scrollback: false,
                grid_diff: false,
                reply,
            },
        );
        (client_rx, backlog)
    }

    /// Two devices on one session — a Mac and a phone showing the same agent.
    ///
    /// Attaching is what took the token before this verb existed, so the phone
    /// permanently muted the Mac the moment it looked at a session, and the Mac
    /// could only answer by tearing its attachment down and rebuilding it. The
    /// token travels by typing instead.
    #[tokio::test]
    async fn the_write_token_follows_the_device_being_used() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client(&mut session, "mac");
        assert_eq!(session.writer.as_deref(), Some("mac"), "first in, writer");

        // Looking is not taking: the phone arrives as a reader, and the Mac —
        // whose window is the one sized for this PTY — keeps writing.
        let _phone = attach_interactive_client(&mut session, "phone");
        assert_eq!(session.writer.as_deref(), Some("mac"));

        assert!(claim_writer(&mut session, "phone"), "the phone's user typed");
        assert_eq!(session.writer.as_deref(), Some("phone"));

        assert!(claim_writer(&mut session, "mac"), "the Mac's user typed");
        assert_eq!(session.writer.as_deref(), Some("mac"));

        let _ = session.sidecar_tx.take();
        let _ = thread.join();
    }

    /// The other half of that rule. A session nobody is holding hands the token
    /// to whoever attaches next, because that attach is the reattach path: the
    /// window coming back to a detached session is what resizes the PTY to fit
    /// it, and refusing the token here would strand the session at the size the
    /// last viewer happened to leave.
    #[tokio::test]
    async fn a_session_nobody_holds_gives_the_token_to_the_next_attach() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client(&mut session, "mac");
        assert_eq!(session.writer.as_deref(), Some("mac"));

        handle_msg(
            &mut session,
            SessionMsg::RemoveClient {
                id: "mac".to_string(),
            },
        );
        assert_eq!(session.writer.as_deref(), None, "nobody is left to write");

        let _reattached = attach_interactive_client(&mut session, "mac-again");
        assert_eq!(session.writer.as_deref(), Some("mac-again"));

        let _ = session.sidecar_tx.take();
        let _ = thread.join();
    }

    /// §A: observers never claim the write token. One that could would strand
    /// the session at the last real client's size — it has no tty to resize.
    #[tokio::test]
    async fn an_observer_is_refused_the_write_token() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client(&mut session, "mac");
        let (_watcher, _backlog) = attach_client(&mut session, "watcher", false);

        assert!(!claim_writer(&mut session, "watcher"));
        assert_eq!(
            session.writer.as_deref(),
            Some("mac"),
            "a refused claim must not disturb the writer it failed to displace"
        );

        let _ = session.sidecar_tx.take();
        let _ = thread.join();
    }

    /// A claim from a client that never attached — a stale id, a racing
    /// reconnect — is refused rather than installing a writer nobody can reach.
    #[tokio::test]
    async fn a_stranger_cannot_claim_the_write_token() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client(&mut session, "mac");
        assert!(!claim_writer(&mut session, "ghost"));
        assert_eq!(session.writer.as_deref(), Some("mac"));

        let _ = session.sidecar_tx.take();
        let _ = thread.join();
    }

    /// What a client got, in the order it got it. `ClientEvent` carries wire
    /// payloads and no `Debug`, so the assertions compare this instead.
    #[derive(Debug, PartialEq, Eq)]
    enum Received {
        Data(Vec<u8>),
        Snapshot,
        Ready,
    }

    /// Everything waiting for a client, minus the control traffic an attach
    /// emits — delivery order is what the barrier can break, not the greeting.
    fn drain(client: &mut mpsc::UnboundedReceiver<ClientEvent>) -> Vec<Received> {
        let mut seen = Vec::new();
        while let Ok(event) = client.try_recv() {
            match event {
                ClientEvent::Data(payload) => seen.push(Received::Data(payload.bytes.to_vec())),
                ClientEvent::Snapshot(_) => seen.push(Received::Snapshot),
                ClientEvent::Event(Event::Ready { .. }) => seen.push(Received::Ready),
                _ => {}
            }
        }
        seen
    }

    /// JOIN's second half (§C.5): an attaching client may not affect anyone
    /// else's delivery. `tests/join_invariant.rs` can only observe that through
    /// two consumers racing a flood, where a reader that is merely behind looks
    /// exactly like a stall — so it proves the joining client's boundary and
    /// leaves this to a test that can hold the barrier open on purpose.
    ///
    /// Here the snapshot request is never answered, so the joining client sits
    /// in `SnapshotPending` for the whole test. Any stall the barrier imposed on
    /// the live client — for a moment or forever — is a missing `Data` below.
    #[tokio::test]
    async fn a_pending_snapshot_never_holds_up_another_client() {
        let Sidecar {
            commands,
            mut results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        // The control: never negotiates `snapshot`, so it stays `Live`.
        let (mut live, _live_backlog) = attach_client(&mut session, "live", false);
        session.fan_out(Bytes::from_static(b"before"));
        assert_eq!(
            drain(&mut live),
            vec![Received::Data(b"before".to_vec())],
            "the live client did not receive its pre-attach bytes"
        );

        // The barrier opens here and is deliberately left open.
        let (mut joining, _joining_backlog) = attach_client(&mut session, "joining", true);
        assert!(
            matches!(
                session.clients["joining"].delivery,
                ClientDelivery::SnapshotPending { .. }
            ),
            "the joining client is not behind a barrier, so this proves nothing"
        );

        session.fan_out(Bytes::from_static(b"during"));
        assert_eq!(
            drain(&mut live),
            vec![Received::Data(b"during".to_vec())],
            "the pending snapshot held up the live client"
        );
        assert!(
            drain(&mut joining).is_empty(),
            "the joining client received its stream before the S that opens it"
        );

        // The other half of the invariant: those bytes were buffered, not lost.
        // Once the snapshot lands they follow it, in order.
        pump_sidecar(&mut session, &mut results, 1).await;
        assert_eq!(
            drain(&mut joining),
            vec![
                Received::Snapshot,
                Received::Ready,
                Received::Data(b"during".to_vec())
            ],
            "the snapshot boundary and the bytes buffered behind it did not line up"
        );

        let _ = session.sidecar_tx.take();
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
    }

    /// D4(a): the first time a client outruns its budget it is resynced, not
    /// dropped — the queued bytes are retired, a fresh `S`/`ready` pair
    /// re-establishes JOIN, and `resynced` says why. The second overflow is the
    /// drop, because a client that cannot keep up from a clean start is wedged.
    #[tokio::test]
    async fn backlog_pressure_resyncs_a_client_once_before_dropping_it() {
        let Sidecar {
            commands,
            mut results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        let (mut client, backlog) = attach_snapshot_client(&mut session, "slow");
        pump_sidecar(&mut session, &mut results, 1).await;
        // The attach snapshot: S, then ready.
        assert!(matches!(
            client.recv().await,
            Some(ClientEvent::Snapshot(_))
        ));
        assert!(matches!(
            client.recv().await,
            Some(ClientEvent::Event(Event::Ready { .. }))
        ));

        // Nothing on the far end ever releases, so the budget fills for real.
        let mib = chunk(1024 * 1024);
        for _ in 0..(CLIENT_BACKLOG_CAP / mib.len()) {
            session.fan_out(mib.clone());
        }
        assert!(backlog.reserve(chunk(1)).is_none(), "budget is not full");
        assert!(session.clients.contains_key("slow"));

        // The overflow chunk. It is not delivered — it is what the snapshot
        // replaces — and the client survives it.
        session.fan_out(mib.clone());
        assert!(
            session.clients.contains_key("slow"),
            "the first overflow dropped the client instead of resyncing it"
        );
        assert!(
            backlog.is_drained(),
            "the resync did not retire the queued backlog"
        );
        pump_sidecar(&mut session, &mut results, 1).await;

        let mut kinds = Vec::new();
        while let Ok(event) = client.try_recv() {
            kinds.push(match event {
                ClientEvent::Data(_) => "D".to_string(),
                ClientEvent::Snapshot(_) => "S".to_string(),
                ClientEvent::Event(Event::Ready { .. }) => "ready".to_string(),
                ClientEvent::Event(Event::Resynced { reason, .. }) => format!("resynced:{reason}"),
                _ => "other".to_string(),
            });
        }
        let boundary = kinds
            .iter()
            .position(|kind| kind == "S")
            .expect("no fresh S after the forced resync");
        assert_eq!(kinds[boundary + 1], "ready", "S was not followed by ready");
        assert!(
            kinds[boundary..]
                .iter()
                .any(|kind| kind.starts_with("resynced:output backlog exceeded")),
            "the client was never told why its stream restarted: {kinds:?}"
        );

        // Second strike. The client starts from an empty budget and still
        // cannot drain, so this time it goes.
        for _ in 0..(CLIENT_BACKLOG_CAP / mib.len()) {
            session.fan_out(mib.clone());
        }
        session.fan_out(mib.clone());
        assert!(
            !session.clients.contains_key("slow"),
            "the second overflow did not drop the client"
        );
        assert!(backlog.is_dropped());

        let _ = session.sidecar_tx.take();
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
    }

    /// D4(b): the sidecar budget's only legal degrade. Bytes reach every client
    /// unchanged; what stops is the VT, which then refuses snapshots instead of
    /// answering one that describes a screen that never occurred.
    #[tokio::test]
    async fn an_over_budget_sidecar_goes_stale_without_costing_a_client_one_byte() {
        let Sidecar {
            commands,
            mut results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        // Park the whole budget so the next PTY chunk cannot be admitted. This
        // stands in for a VT parse that has stopped making progress.
        assert!(queue.try_reserve(SIDECAR_QUEUE_CAP));
        let (mut session, mut events) = test_session(commands, queue);
        let (mut client, _backlog) = attach_snapshot_client(&mut session, "raw");
        pump_sidecar(&mut session, &mut results, 1).await;
        assert!(matches!(
            client.recv().await,
            Some(ClientEvent::Snapshot(_))
        ));
        assert!(matches!(
            client.recv().await,
            Some(ClientEvent::Event(Event::Ready { .. }))
        ));

        let chunk = Bytes::from_static(b"still mine\r\n");
        session.write_sidecar(chunk.clone());
        session.fan_out(chunk.clone());

        assert!(session.vt_stale.is_some(), "the budget did not bite");
        let mut announced = false;
        while let Ok(event) = events.try_recv() {
            announced |= matches!(event, Event::VtStale { .. });
        }
        assert!(announced, "the stale VT was never announced");
        // The invariant this whole budget exists to protect: the client's bytes
        // are not what gets sacrificed.
        let mut delivered = Vec::new();
        while let Ok(event) = client.try_recv() {
            if let ClientEvent::Data(payload) = event {
                delivered.extend_from_slice(&payload.bytes);
            }
        }
        assert_eq!(delivered, chunk, "a stale VT cost the client PTY bytes");

        // A client attaching now is told the truth by falling back to the ring
        // rather than being handed a snapshot the VT can no longer vouch for.
        // No sidecar round trip this time: a stale VT is refused in-process.
        let (mut late, _late_backlog) = attach_snapshot_client(&mut session, "late");
        pump_sidecar(&mut session, &mut results, 0).await;
        let mut replayed = Vec::new();
        let mut snapshots = 0;
        while let Ok(event) = late.try_recv() {
            match event {
                ClientEvent::Snapshot(_) => snapshots += 1,
                ClientEvent::Data(payload) => replayed.extend_from_slice(&payload.bytes),
                _ => {}
            }
        }
        assert_eq!(snapshots, 0, "a stale VT still answered a snapshot");
        assert_eq!(replayed, chunk, "the ring-replay fallback did not run");

        let _ = session.sidecar_tx.take();
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
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
                    backlog_strikes: 0,
                },
            )]),
            writer: Some("writer".to_string()),
            next_seq: 2,
            next_snapshot_request: 1,
            ring: VecDeque::new(),
            ring_bytes: 0,
            events,
            sidecar_tx: Some(sidecar_tx),
            sidecar_queue: Arc::new(SidecarQueue::new()),
            vt_stale: None,
            foreground: super::ForegroundSample::default(),
            foreground_pending: false,
            child_executable: None,
        };

        assert!(handle_msg(
            &mut session,
            SessionMsg::Resize {
                id: "writer".to_string(),
                rows: 40,
                cols: 120,
            },
        )
        .is_none());

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

    /// Drive a real session until its sampled foreground satisfies `ready`, or
    /// give up. The poll runs on a fixed cadence and the first tick can land
    /// before the child has exec'd, so a test that reads once reads the wrong
    /// process.
    async fn settled_info(
        handle: &SessionHandle,
        ready: impl Fn(&SessionInfo) -> bool,
    ) -> SessionInfo {
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(15);
        let mut last = None;
        while tokio::time::Instant::now() < deadline {
            let (tx, rx) = oneshot::channel();
            if !handle.send(SessionMsg::Info { reply: tx }) {
                break;
            }
            let Ok(info) = rx.await else { break };
            if ready(&info) {
                return info;
            }
            last = Some(info);
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        panic!("the session never reported the expected foreground: {last:?}");
    }

    /// Both receivers are handed back rather than dropped here: a broadcast
    /// channel with no receiver discards every send, and the roster assertion
    /// reads one of them.
    #[allow(clippy::type_complexity)]
    fn start_session(
        argv: Vec<String>,
        cwd: &str,
    ) -> (
        SessionHandle,
        broadcast::Receiver<Event>,
        mpsc::UnboundedReceiver<super::SessionEnded>,
    ) {
        let (on_exit, on_exit_rx) = mpsc::unbounded_channel();
        let (events, events_rx) = broadcast::channel(64);
        let handle = super::spawn(
            "foreground-session".to_string(),
            "test".to_string(),
            cwd.to_string(),
            argv.join(" "),
            argv,
            Vec::new(),
            24,
            80,
            None,
            on_exit,
            events,
        )
        .expect("spawning a real session");
        (handle, events_rx, on_exit_rx)
    }

    /// The whole point: a live session can name the program in its terminal,
    /// say where that program is standing, and pin the binary behind it —
    /// against a real child, not a fixture.
    #[tokio::test]
    async fn a_session_names_the_program_running_in_its_terminal() {
        let cat = ["/bin/cat", "/usr/bin/cat"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no cat binary on this host");
        let dir = std::fs::canonicalize(std::env::temp_dir()).expect("canonical temp dir");
        let dir = dir.to_string_lossy().into_owned();
        let (handle, mut events_rx, _on_exit) = start_session(vec![cat.to_string()], &dir);

        let info = settled_info(&handle, |info| {
            info.foreground_argv
                .as_ref()
                .and_then(|argv| argv.first())
                .is_some_and(|arg| arg.ends_with("cat"))
        })
        .await;

        assert_eq!(info.foreground_argv.as_deref(), Some(&[cat.to_string()][..]));
        assert_eq!(
            info.foreground_pid,
            Some(info.pid),
            "the session's own child is the foreground group leader"
        );
        assert!(
            !info.foreground_job,
            "the session child itself is not a job running *inside* the session"
        );
        assert_eq!(info.child_cwd.as_deref(), Some(dir.as_str()));
        // Resolved, not spelled: on a busybox host /bin/cat is a symlink and the
        // kernel correctly names /bin/busybox as what is running.
        let expected = std::fs::canonicalize(cat).expect("canonical cat binary");
        assert_eq!(
            info.child_executable.as_deref().map(std::path::Path::new),
            Some(expected.as_path())
        );
        assert!(
            !info.child_executable_replaced,
            "an untouched binary must not read as replaced"
        );

        // Learning who is in there is a roster change, so clients hear about it
        // without polling. It takes two events, not one: the poll publishes the
        // process group as soon as `tcgetpgrp` answers, and the identity behind
        // it lands when the off-actor resolution comes back. Scanning for the
        // second is the point — taking the first would assert against the half
        // that is deliberately cheap.
        let identified = std::iter::from_fn(|| events_rx.try_recv().ok()).any(|event| {
            matches!(event, Event::Roster { info: Some(info), .. } if info.foreground_pid.is_some())
        });
        assert!(
            identified,
            "no roster event ever carried the resolved foreground pid"
        );

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
    }

    /// A command started *inside* the session takes the tty's foreground away
    /// from the shell. This is the distinction between "a shell is sitting at a
    /// prompt" and "something is running in there".
    #[tokio::test]
    async fn a_command_started_in_the_session_takes_the_foreground() {
        let shell = ["/bin/sh", "/usr/bin/sh"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no sh binary on this host");
        let (handle, _events_rx, _on_exit) =
            start_session(vec![shell.to_string(), "-i".to_string()], "/");

        let idle = settled_info(&handle, |info| info.foreground_pid == Some(info.pid)).await;
        assert!(!idle.foreground_job, "a bare prompt is not a running job");

        handle.send(SessionMsg::Inject {
            data: b"sleep 30\n".to_vec(),
        });

        // Settled on the argv, not on `foreground_job`. The two now land in
        // separate ticks by design — the group id is read on the actor and the
        // identity behind it arrives from a blocking thread — so waiting on the
        // cheap half and asserting the expensive one is a race.
        let busy = settled_info(&handle, |info| {
            info.foreground_argv
                .as_ref()
                .and_then(|argv| argv.first())
                .is_some_and(|arg| arg.ends_with("sleep"))
        })
        .await;
        assert!(busy.foreground_job, "a running command is a job");
        assert_ne!(busy.foreground_pid, Some(busy.pid));

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
    }

    /// The pipeline case, end to end against a real shell and a real tty: the
    /// group leader exits while a later stage keeps running.
    ///
    /// `true | sleep 30` makes a job whose leader is `true`, which finishes
    /// immediately and is left a zombie or reaped outright while `sleep` still
    /// holds the terminal. Reading argv from the process *group* id — what both
    /// hosts did before this — answers nothing here, so the pane would claim
    /// nothing is running while the user watches a command run. The assertion
    /// is deliberately on argv being present and naming `sleep`: that is the
    /// user-visible property, and it is what regressed.
    #[tokio::test]
    async fn a_pipeline_keeps_its_argv_after_the_group_leader_exits() {
        let shell = ["/bin/sh", "/usr/bin/sh"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no sh binary on this host");
        let (handle, _events_rx, _on_exit) =
            start_session(vec![shell.to_string(), "-i".to_string()], "/");

        settled_info(&handle, |info| info.foreground_pid == Some(info.pid)).await;

        handle.send(SessionMsg::Inject {
            data: b"true | sleep 30\n".to_vec(),
        });

        let piped = settled_info(&handle, |info| {
            info.foreground_job && info.foreground_argv.is_some()
        })
        .await;

        let argv = piped
            .foreground_argv
            .as_ref()
            .expect("a live pipeline must report an argv");
        assert!(
            argv.first().is_some_and(|arg| arg.ends_with("sleep")),
            "the surviving stage should name itself; argv was {argv:?}"
        );
        assert_ne!(
            piped.foreground_pid,
            Some(piped.pid),
            "the pipeline is not the session's own shell"
        );

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
    }

    /// The session actor is the last thing that can answer for a session, and
    /// once it has gone the only descriptions left are the ones it sent on its
    /// way out. Both of them — the event clients hear and the record the
    /// manager buries — have to be the *same* record, or a client and a
    /// tombstone can disagree about a session neither can re-read.
    #[tokio::test]
    async fn the_exit_event_carries_the_record_the_tombstone_is_built_from() {
        let cat = ["/bin/cat", "/usr/bin/cat"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no cat binary on this host");
        let (handle, mut events_rx, mut on_exit_rx) = start_session(vec![cat.to_string()], "/");

        // Wait for the first foreground sample, so the record under test is the
        // fully populated one rather than a session caught before its first
        // poll tick.
        let live = settled_info(&handle, |info| info.child_executable.is_some()).await;
        assert!(live.alive, "a running session says so");

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });

        let exited = loop {
            match events_rx.recv().await {
                Ok(Event::SessionExited { session, info, .. }) => break (session, info),
                Ok(_) => continue,
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(error) => panic!("the exit event never arrived: {error:?}"),
            }
        };
        let (session_id, event_info) = exited;
        assert_eq!(session_id, "foreground-session");
        let event_info = event_info.expect("the exit event carries the final record");
        assert!(
            !event_info.alive,
            "a record built on the exit path must not claim the session is alive"
        );
        assert_eq!(event_info.pid, live.pid);
        assert_eq!(event_info.child_executable, live.child_executable);

        let ended = on_exit_rx
            .recv()
            .await
            .expect("the manager is told the session ended");
        assert_eq!(
            ended.reason,
            EndReason::Killed,
            "a client asked for this end"
        );
        assert!(!ended.info.alive);
        assert_eq!(
            serde_json::to_value(&*event_info).unwrap(),
            serde_json::to_value(&ended.info).unwrap(),
            "the event and the tombstone must be one record, not two samples"
        );
    }
}
