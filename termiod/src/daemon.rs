//! The daemon: a session table plus a Unix-socket accept loop. Connections
//! speak Session Protocol v0.1, with a transparent legacy-v0 first-message
//! fallback.

use crate::paths;
use crate::protocol::{
    encode_file_chunk, read_frame, write_control, write_data, write_event, write_file_payload,
    write_grid_payload, write_history_payload, write_snapshot, AttachMode, Control, ErrorCode,
    Event, FileChunk, Frame, SessionInfo, Snapshot, FILE_CHUNK_HEADER_SIZE, HOST_CAPABILITIES,
    MAX_FILE_FRAME_SIZE, PROTOCOL_VERSION, SUPPORTED_PROTOCOLS,
};
use crate::id::{ClientId, SessionId};
use crate::resource::Registry;
use crate::session::{
    self, ClientBacklog, ClientEvent, Metered, SessionEnded, SessionHandle, SessionMsg,
};
use crate::tombstone::{EndReason, Graveyard};
use anyhow::{Context, Result};
use bytes::Bytes;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc, oneshot, watch, Notify};

const EVENT_BUFFER: usize = 1024;
const SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_secs(5);

struct ManagerInner {
    sessions: HashMap<SessionId, SessionHandle>,
    id_counter: u32,
    draining: bool,
}

#[derive(Clone)]
pub struct Manager {
    inner: Arc<Mutex<ManagerInner>>,
    next_client_id: Arc<AtomicU64>,
    on_exit: mpsc::UnboundedSender<SessionEnded>,
    events: broadcast::Sender<Event>,
    host_id: Arc<String>,
    /// Durable non-session state clients can resume against (§C.10). Shared by
    /// every connection so one workspace costs one watcher, not one per client.
    resources: Registry,
    /// In-flight uploads (§C.12). Daemon-wide, not per-connection, so a client
    /// that reconnects mid-upload can idempotently re-open its transfer.
    uploads: crate::files::Uploads,
    /// What died and why (§6). The daemon is now the only PTY owner, so its own
    /// death has to leave evidence — an empty session list otherwise reads as
    /// "nothing was running" rather than "everything was lost".
    graveyard: Arc<Graveyard>,
    session_removed: Arc<Notify>,
}

impl Manager {
    fn new(
        on_exit: mpsc::UnboundedSender<SessionEnded>,
        host_id: String,
        graveyard: Arc<Graveyard>,
    ) -> Manager {
        let (events, _) = broadcast::channel(EVENT_BUFFER);
        Manager {
            inner: Arc::new(Mutex::new(ManagerInner {
                sessions: HashMap::new(),
                id_counter: 0,
                draining: false,
            })),
            next_client_id: Arc::new(AtomicU64::new(1)),
            on_exit,
            events,
            host_id: Arc::new(host_id),
            resources: Registry::new(),
            uploads: crate::files::Uploads::new(),
            graveyard,
            session_removed: Arc::new(Notify::new()),
        }
    }

    fn alloc_client_id(&self) -> ClientId {
        let id = self.next_client_id.fetch_add(1, Ordering::Relaxed);
        ClientId::new(format!("c_{id:x}"))
    }

    fn create(&self, spec: crate::protocol::CreateSpec) -> Result<SessionId> {
        // The lock makes the transition to draining an exact boundary: a
        // create either installs its handle before the shutdown snapshot or
        // observes `draining` and never spawns a child.
        let mut guard = self.inner.lock().unwrap();
        if guard.draining {
            anyhow::bail!("daemon is draining");
        }
        let seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        guard.id_counter = guard.id_counter.wrapping_add(1);
        let id = SessionId::new(format!(
            "{:08x}",
            seed ^ guard.id_counter.wrapping_mul(2654435761)
        ));
        let name = spec.name.clone().unwrap_or_else(|| id.to_string());
        let cwd = spec.cwd.clone().unwrap_or_default();
        let command = if spec.argv.is_empty() {
            format!(
                "{} (login shell)",
                std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into())
            )
        } else {
            spec.argv.join(" ")
        };
        let handle = session::spawn(
            id.clone(),
            name,
            cwd,
            command,
            spec.argv,
            spec.env,
            spec.rows,
            spec.cols,
            spec.workstream,
            self.on_exit.clone(),
            self.events.clone(),
        )
        .context("spawning session")?;
        guard.sessions.insert(id.clone(), handle);
        Ok(id)
    }

    fn find(&self, id: &SessionId) -> Option<SessionHandle> {
        self.inner.lock().unwrap().sessions.get(id).cloned()
    }

    fn handles(&self) -> Vec<SessionHandle> {
        self.inner
            .lock()
            .unwrap()
            .sessions
            .values()
            .cloned()
            .collect()
    }

    fn remove(&self, id: &SessionId) -> bool {
        let removed = self.inner.lock().unwrap().sessions.remove(id).is_some();
        if removed {
            self.session_removed.notify_one();
        }
        removed
    }

    fn begin_draining(&self, reason: EndReason) {
        let mut guard = self.inner.lock().unwrap();
        guard.draining = true;
        for handle in guard.sessions.values() {
            handle.send(SessionMsg::Kill { reason });
        }
    }

    async fn wait_until_empty(&self) {
        loop {
            let removed = self.session_removed.notified();
            if self.inner.lock().unwrap().sessions.is_empty() {
                return;
            }
            removed.await;
        }
    }

    async fn finish_draining(&self, reason: EndReason) -> Result<()> {
        if tokio::time::timeout(SHUTDOWN_DRAIN_TIMEOUT, self.wait_until_empty())
            .await
            .is_ok()
        {
            return self.graveyard.bury_remaining(reason);
        }

        eprintln!(
            "termiod: shutdown drain exceeded {} seconds; forcing remaining sessions",
            SHUTDOWN_DRAIN_TIMEOUT.as_secs()
        );
        // Mark the surviving roster entries before the direct kill. If their
        // actors wake and reap concurrently, the graveyard's runtime dedupe
        // preserves this deliberate-stop reason.
        let persisted = self.graveyard.bury_remaining(reason);
        for handle in self.handles() {
            handle.force_kill();
        }
        persisted
    }

    fn publish(&self, event: Event) {
        let _ = self.events.send(event);
    }

    async fn info(&self, handle: &SessionHandle) -> Option<SessionInfo> {
        let (tx, rx) = oneshot::channel();
        if handle.send(SessionMsg::Info { reply: tx }) {
            rx.await.ok()
        } else {
            None
        }
    }

    async fn publish_created(&self, id: &SessionId) {
        let Some(handle) = self.find(id) else {
            return;
        };
        let info = self.info(&handle).await;
        // The roster file is what lets the *next* daemon notice this session was
        // never buried. Recorded at creation, cleared at burial.
        if let Some(info) = &info {
            self.graveyard.note_live(info);
        }
        self.publish(Event::Roster {
            session: id.to_string(),
            action: "created".to_string(),
            info: info.map(Box::new),
        });
    }

    fn publish_removed(&self, id: &SessionId) {
        self.publish(Event::Roster {
            session: id.to_string(),
            action: "removed".to_string(),
            info: None,
        });
    }

    async fn list(&self) -> Vec<SessionInfo> {
        let handles = self.handles();
        let mut infos = Vec::new();
        for handle in handles {
            if let Some(info) = self.info(&handle).await {
                infos.push(info);
            }
        }
        infos.sort_by_key(|info| info.created_unix);
        infos
    }

    /// Resolve a target that may be an id or a name. The only door into the
    /// session table for a string that came off the wire: `find` takes a
    /// `SessionId`, so nothing else can index the table with an unresolved
    /// target.
    async fn resolve(&self, target: &str) -> Option<SessionHandle> {
        if let Some(handle) = self.find(&SessionId::new(target)) {
            return Some(handle);
        }
        for handle in self.handles() {
            if let Some(info) = self.info(&handle).await {
                if info.name == target {
                    return Some(handle);
                }
            }
        }
        None
    }

    async fn wait_response(
        &self,
        target: String,
        until: Vec<String>,
        timeout_ms: u64,
        re: Option<u64>,
    ) -> Control {
        // Subscribe before resolving/querying so an exit cannot slip through
        // between the state check and the event wait.
        let mut events = self.events.subscribe();
        let Some(handle) = self.resolve(&target).await else {
            return error(
                re,
                ErrorCode::NoSuchSession,
                format!("no such session: {target}"),
                false,
            );
        };
        let session_id = handle.id.clone();
        let Some(initial_info) = self.info(&handle).await else {
            return if until.iter().any(|wanted| wanted == "exited") {
                Control::WaitResult {
                    session: session_id.to_string(),
                    status: "exited".to_string(),
                    timed_out: false,
                    exit_status: None,
                    re,
                }
            } else {
                error(
                    re,
                    ErrorCode::AlreadyExited,
                    "session already exited",
                    false,
                )
            };
        };
        let initial = initial_info.status;
        if until.iter().any(|wanted| wanted == &initial) {
            return Control::WaitResult {
                session: session_id.to_string(),
                status: initial,
                timed_out: false,
                exit_status: None,
                re,
            };
        }

        let wait = async {
            loop {
                match events.recv().await {
                    Ok(Event::Status {
                        session, status, ..
                    }) if session == session_id.as_str()
                        && until.iter().any(|wanted| wanted == &status) =>
                    {
                        return Ok((status, None));
                    }
                    Ok(Event::SessionExited {
                        session, status, ..
                    }) if session == session_id.as_str()
                        && until.iter().any(|wanted| wanted == "exited") =>
                    {
                        return Ok(("exited".to_string(), Some(status)));
                    }
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => {
                        return Err("event stream closed");
                    }
                }
            }
        };

        match tokio::time::timeout(Duration::from_millis(timeout_ms), wait).await {
            Ok(Ok((status, exit_status))) => Control::WaitResult {
                session: session_id.to_string(),
                status,
                timed_out: false,
                exit_status,
                re,
            },
            Ok(Err(message)) => error(re, ErrorCode::Internal, message, true),
            Err(_) => {
                let current = self.info(&handle).await.map(|info| info.status);
                if current.is_none() && until.iter().any(|wanted| wanted == "exited") {
                    return Control::WaitResult {
                        session: session_id.to_string(),
                        status: "exited".to_string(),
                        timed_out: false,
                        exit_status: None,
                        re,
                    };
                }
                Control::WaitResult {
                    session: session_id.to_string(),
                    status: current.unwrap_or_else(|| "exited".to_string()),
                    timed_out: true,
                    exit_status: None,
                    re,
                }
            }
        }
    }
}

/// Run the daemon: bind the socket and accept forever.
pub async fn serve(
    wss_bind: Option<std::net::SocketAddr>,
    wss_origins: Vec<crate::wss::Origin>,
) -> Result<()> {
    paths::ensure_runtime_dir()?;
    let sock_path = paths::socket_path()?;

    if sock_path.exists() {
        match UnixStream::connect(&sock_path).await {
            Ok(_) => {
                anyhow::bail!("termiod already running at {}", sock_path.display());
            }
            Err(_) => {
                let _ = std::fs::remove_file(&sock_path);
            }
        }
    }

    let listener = UnixListener::bind(&sock_path)
        .with_context(|| format!("binding {}", sock_path.display()))?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&sock_path, std::fs::Permissions::from_mode(0o600))?;

    // Resolved before anything else starts, because an explicit `--wss` with
    // no pairing token refuses the whole start: the operator asked for a
    // listener that cannot authenticate.
    let wss = crate::wss::resolve(wss_bind, &wss_origins)?;

    let host_id = paths::load_or_create_host_id()?;
    // Scratch dirs are session-scoped and every session died with the
    // previous daemon, so the whole tree is stale by definition here.
    if let Ok(scratch) = paths::scratch_root() {
        let _ = std::fs::remove_dir_all(&scratch);
    }
    // Opening the graveyard is also the crash check: anything the previous
    // daemon left on its roster is adopted as `daemon_lost` here, before this
    // one accepts a single connection.
    let graveyard = Arc::new(Graveyard::open(&paths::state_dir()?)?);
    let (on_exit_tx, mut on_exit_rx) = mpsc::unbounded_channel::<SessionEnded>();
    let manager = Manager::new(on_exit_tx, host_id, graveyard);

    {
        let manager = manager.clone();
        tokio::spawn(async move {
            while let Some(ended) = on_exit_rx.recv().await {
                // The end record is a wire struct, so its id crosses back into
                // the host's vocabulary here.
                let id = SessionId::new(ended.info.id.clone());
                // A termination request can win after PTY EOF but before this
                // task receives the actor's end record. The handle retains the
                // first requested reason until burial completes.
                let reason = manager
                    .find(&id)
                    .and_then(|handle| handle.termination_reason())
                    .unwrap_or(ended.reason);
                manager
                    .graveyard
                    .bury(&ended.info, reason, Some(ended.status));
                // The scratch dir is reaped with the session (§C.12 `temp:`),
                // in-flight uploads first so no dotfile survives the sweep.
                manager.uploads.drop_session(&id);
                if let Ok(scratch) = paths::scratch_root() {
                    let _ = std::fs::remove_dir_all(scratch.join(format!("session-{id}")));
                }
                if manager.remove(&id) {
                    manager.publish_removed(&id);
                }
            }
        });
    }

    eprintln!("termiod listening on {}", sock_path.display());

    // The WSS listener stops accepting and drops its splices on the same signal
    // that ends the accept loop, so nothing attaches into a daemon that is
    // already burying its sessions.
    let (wss_shutdown, wss_shutdown_rx) = watch::channel(false);
    if let Some(config) = wss {
        crate::wss::start(config, wss_shutdown_rx).await?;
    }

    let mut terminate =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .context("installing SIGTERM handler")?;
    let shutdown_signal = async move {
        tokio::select! {
            result = tokio::signal::ctrl_c() => result.context("waiting for SIGINT"),
            _ = terminate.recv() => Ok(()),
        }
    };
    tokio::pin!(shutdown_signal);

    loop {
        tokio::select! {
            biased;
            result = &mut shutdown_signal => {
                result?;
                break;
            }
            accepted = listener.accept() => {
                let (stream, _addr) = accepted?;
                let manager = manager.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_conn(stream, manager).await {
                        eprintln!("termiod: connection error: {e:#}");
                    }
                });
            }
        }
    }

    let _ = wss_shutdown.send(true);
    manager.begin_draining(EndReason::DaemonStopped);
    let drained = manager.finish_draining(EndReason::DaemonStopped).await;
    // Keeping the bound listener through the drain prevents an autostarting
    // client from placing a replacement daemon over state still being buried.
    drop(listener);
    match std::fs::remove_file(&sock_path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => eprintln!("termiod: could not remove socket during shutdown: {error}"),
    }
    drained
}

#[derive(Clone)]
struct Connection {
    client_id: ClientId,
    negotiated: bool,
    capabilities: HashSet<String>,
}

enum Outbound {
    Control(Control),
    Data(Metered),
    Event(Event),
    Snapshot(Snapshot),
    History(Metered),
    Grid(Metered),
    File(Bytes),
}

async fn write_outbound(
    mut wr: tokio::net::unix::OwnedWriteHalf,
    mut rx: mpsc::UnboundedReceiver<Outbound>,
    backlog: Arc<ClientBacklog>,
) {
    while let Some(message) = rx.recv().await {
        // A forced resync retires everything queued under the old epoch. Those
        // payloads precede a snapshot that supersedes them, so writing them
        // would only make the client that could not keep up wait longer.
        if let Outbound::Data(payload) | Outbound::History(payload) | Outbound::Grid(payload) =
            &message
        {
            if !backlog.is_current(payload) {
                continue;
            }
        }
        let result = match message {
            Outbound::Control(control) => write_control(&mut wr, &control).await,
            Outbound::Data(payload) => {
                let result = write_data(&mut wr, &payload.bytes).await;
                backlog.release(&payload);
                result
            }
            Outbound::Event(event) => write_event(&mut wr, &event).await,
            Outbound::Snapshot(snapshot) => write_snapshot(&mut wr, &snapshot).await,
            Outbound::History(payload) => {
                let result = write_history_payload(&mut wr, &payload.bytes).await;
                backlog.release(&payload);
                result
            }
            Outbound::Grid(payload) => {
                let result = write_grid_payload(&mut wr, &payload.bytes).await;
                backlog.release(&payload);
                result
            }
            Outbound::File(payload) => write_file_payload(&mut wr, &payload).await,
        };
        if result.is_err() {
            break;
        }
    }
}

async fn handle_conn(stream: UnixStream, manager: Manager) -> Result<()> {
    let (mut rd, mut wr) = stream.into_split();
    let client_id = manager.alloc_client_id();

    let first = match read_frame(&mut rd).await {
        Ok(Some(frame)) => frame,
        Ok(None) => return Ok(()),
        Err(e) => {
            write_control(
                &mut wr,
                &error(None, ErrorCode::ProtoError, e.to_string(), false),
            )
            .await?;
            return Ok(());
        }
    };

    let (connection, pending) = match first {
        Frame::Control(Control::Hello {
            proto,
            min_proto,
            role: _,
            caps,
            client: _,
        }) => {
            if min_proto > PROTOCOL_VERSION || proto < PROTOCOL_VERSION {
                write_control(
                    &mut wr,
                    &Control::HelloErr {
                        code: ErrorCode::Incompatible,
                        supported: SUPPORTED_PROTOCOLS.to_vec(),
                    },
                )
                .await?;
                return Ok(());
            }
            let mut seen = HashSet::new();
            let mut negotiated_caps: Vec<String> = caps
                .into_iter()
                .filter(|cap| HOST_CAPABILITIES.contains(&cap.as_str()))
                .filter(|cap| seen.insert(cap.clone()))
                .collect();
            // The parsed plane uses S for bootstrap and recovery. A client
            // offering grid_diff without snapshot therefore does not
            // negotiate grid_diff.
            if negotiated_caps.iter().any(|cap| cap == "grid_diff")
                && !negotiated_caps.iter().any(|cap| cap == "snapshot")
            {
                negotiated_caps.retain(|cap| cap != "grid_diff");
            }
            write_control(
                &mut wr,
                &Control::HelloOk {
                    proto: PROTOCOL_VERSION,
                    caps: negotiated_caps.clone(),
                    host_id: (*manager.host_id).clone(),
                    host: format!(
                        "termiod/{} {}-{}",
                        env!("CARGO_PKG_VERSION"),
                        std::env::consts::OS,
                        std::env::consts::ARCH
                    ),
                    client_id: client_id.to_string(),
                    home: std::env::var("HOME").unwrap_or_default(),
                },
            )
            .await?;
            (
                Connection {
                    client_id,
                    negotiated: true,
                    capabilities: negotiated_caps.into_iter().collect(),
                },
                None,
            )
        }
        Frame::Control(control) => (
            Connection {
                client_id,
                negotiated: false,
                capabilities: HashSet::new(),
            },
            Some(control),
        ),
        _ => {
            write_control(
                &mut wr,
                &error(
                    None,
                    ErrorCode::ProtoError,
                    "expected a control frame first",
                    false,
                ),
            )
            .await?;
            return Ok(());
        }
    };

    let (out, out_rx) = mpsc::unbounded_channel();
    let backlog = Arc::new(ClientBacklog::new());
    let writer = tokio::spawn(write_outbound(wr, out_rx, backlog.clone()));
    let departing = connection.client_id.clone();
    let resources = manager.resources.clone();
    let result = run_connection(
        rd,
        out.clone(),
        connection,
        pending,
        manager,
        backlog.clone(),
    )
    .await;
    // Resource subscriptions are per-connection: a dropped client releases its
    // interest, and the last one out stops the underlying watch.
    resources.drop_client(&departing);
    drop(out);
    if backlog.is_dropped() {
        writer.abort();
    }
    let _ = writer.await;
    result
}

/// In-flight cancellable requests on one control connection, keyed by their
/// request id (§C.12 `fs.search`). Dropping a sender — via `cancel`, or the
/// whole map going away with the connection — stops the work.
type SearchMap = Arc<Mutex<HashMap<u64, oneshot::Sender<()>>>>;

struct AttachRequest {
    handle: SessionHandle,
    rows: u16,
    cols: u16,
    mode: AttachMode,
    re: Option<u64>,
}

enum ControlFlow {
    Continue,
    Attach(AttachRequest),
    Close,
}

async fn run_connection(
    mut rd: tokio::net::unix::OwnedReadHalf,
    out: mpsc::UnboundedSender<Outbound>,
    connection: Connection,
    mut pending: Option<Control>,
    manager: Manager,
    backlog: Arc<ClientBacklog>,
) -> Result<()> {
    let mut subscriptions = HashSet::new();
    let mut events = manager.events.subscribe();
    let mut response_cache: HashMap<u64, Control> = HashMap::new();
    // Resource and search events are addressed to this connection alone, so
    // they take a dedicated channel rather than the roster broadcast every
    // client sees.
    let (resource_tx, mut resource_rx) = mpsc::unbounded_channel::<Event>();
    let searches: SearchMap = Arc::new(Mutex::new(HashMap::new()));

    loop {
        if let Some(control) = pending.take() {
            match process_control(
                control,
                &out,
                &connection,
                &manager,
                &mut subscriptions,
                &mut response_cache,
                &resource_tx,
                &searches,
            )
            .await?
            {
                ControlFlow::Continue => {}
                ControlFlow::Attach(request) => {
                    return run_attach(rd, out, request, connection, backlog).await;
                }
                ControlFlow::Close => return Ok(()),
            }
        }

        tokio::select! {
            frame = read_frame(&mut rd) => {
                match frame {
                    Ok(Some(Frame::Control(control))) => pending = Some(control),
                    Ok(Some(Frame::Event(event))) => {
                        // Events are host-authored. Unknown/inapplicable event
                        // types are ignored by the additive-evolution rule.
                        drop(event);
                    }
                    Ok(Some(Frame::Snapshot(_))) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            "snapshot frames are host-to-client only",
                            false,
                        )));
                        return Ok(());
                    }
                    Ok(Some(Frame::History(_))) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            "history frames are host-to-client only",
                            false,
                        )));
                        return Ok(());
                    }
                    Ok(Some(Frame::Grid(_))) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            "grid-diff frames are host-to-client only",
                            false,
                        )));
                        return Ok(());
                    }
                    Ok(Some(Frame::File(_))) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            "file frames are host-to-client only",
                            false,
                        )));
                        return Ok(());
                    }
                    Ok(Some(Frame::Upload(chunk))) => {
                        if !connection.capabilities.contains("upload") {
                            let _ = out.send(Outbound::Control(error(
                                None,
                                ErrorCode::Denied,
                                "the upload capability was not negotiated",
                                false,
                            )));
                            return Ok(());
                        }
                        // The ack is the credit: it goes back only once the
                        // chunk is written, so a client honoring credit-of-one
                        // can never queue more than one chunk in the pipe.
                        let outcome = manager.uploads.chunk(
                            &chunk.upload_id,
                            chunk.offset,
                            &chunk.data,
                        );
                        let reply = match outcome {
                            Ok(offset) => Control::UploadAck {
                                upload_id: chunk.upload_id,
                                offset,
                            },
                            Err(e) => error(None, ErrorCode::Denied, format!("{e:#}"), false),
                        };
                        let _ = out.send(Outbound::Control(reply));
                    }
                    Ok(Some(Frame::Data(_))) | Ok(Some(Frame::Resize { .. })) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            "terminal frame received before attach",
                            false,
                        )));
                        return Ok(());
                    }
                    Ok(None) => return Ok(()),
                    Err(e) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            e.to_string(),
                            false,
                        )));
                        return Ok(());
                    }
                }
            }
            event = events.recv(), if !subscriptions.is_empty() => {
                match event {
                    Ok(event) if subscribed_to(&subscriptions, &event) => {
                        if connection.capabilities.contains("events") {
                            let _ = out.send(Outbound::Event(event));
                        }
                    }
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return Ok(()),
                }
            }
            Some(event) = resource_rx.recv() => {
                let _ = out.send(Outbound::Event(event));
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn process_control(
    control: Control,
    out: &mpsc::UnboundedSender<Outbound>,
    connection: &Connection,
    manager: &Manager,
    subscriptions: &mut HashSet<String>,
    response_cache: &mut HashMap<u64, Control>,
    resource_tx: &mpsc::UnboundedSender<Event>,
    searches: &SearchMap,
) -> Result<ControlFlow> {
    let seq = control.seq();
    if let Some(cached) = seq.and_then(|id| response_cache.get(&id)) {
        let _ = out.send(Outbound::Control(cached.clone()));
        return Ok(ControlFlow::Continue);
    }

    match control {
        Control::Create { spec, seq } => {
            let response = match manager.create(spec) {
                Ok(id) => {
                    manager.publish_created(&id).await;
                    Control::Created {
                        id: id.to_string(),
                        re: seq,
                    }
                }
                Err(e) => error(seq, ErrorCode::CreateFailed, format!("{e:#}"), false),
            };
            send_response(out, response_cache, seq, response);
        }
        Control::List { seq } => {
            let sessions = manager.list().await;
            send_response(
                out,
                response_cache,
                seq,
                Control::Sessions {
                    sessions,
                    tombstones: manager.graveyard.all(),
                    re: seq,
                },
            );
        }
        Control::Kill { id, seq } => {
            let response = match manager.resolve(&id).await {
                Some(handle) => {
                    handle.send(SessionMsg::Kill {
                        reason: EndReason::Killed,
                    });
                    Control::Ok { re: seq }
                }
                None => error(
                    seq,
                    ErrorCode::NoSuchSession,
                    format!("no such session: {id}"),
                    false,
                ),
            };
            send_response(out, response_cache, seq, response);
        }
        Control::Send { id, data, seq } => {
            let response = match manager.resolve(&id).await {
                Some(handle) => {
                    handle.send(SessionMsg::Inject { data });
                    Control::Ok { re: seq }
                }
                None => error(
                    seq,
                    ErrorCode::NoSuchSession,
                    format!("no such session: {id}"),
                    false,
                ),
            };
            send_response(out, response_cache, seq, response);
        }
        Control::Attach {
            target,
            create_if_missing,
            rows,
            cols,
            mode,
            seq,
        } => {
            let handle = match manager.resolve(&target).await {
                Some(handle) => Some(handle),
                None => match create_if_missing {
                    Some(mut spec) => {
                        if spec.name.is_none() {
                            spec.name = Some(target.clone());
                        }
                        spec.rows = rows;
                        spec.cols = cols;
                        match manager.create(spec) {
                            Ok(id) => {
                                manager.publish_created(&id).await;
                                manager.find(&id)
                            }
                            Err(e) => {
                                let response =
                                    error(seq, ErrorCode::CreateFailed, format!("{e:#}"), false);
                                send_response(out, response_cache, seq, response);
                                return Ok(ControlFlow::Continue);
                            }
                        }
                    }
                    None => None,
                },
            };
            let Some(handle) = handle else {
                let response = error(
                    seq,
                    ErrorCode::NoSuchSession,
                    format!("no such session: {target}"),
                    false,
                );
                send_response(out, response_cache, seq, response);
                return Ok(ControlFlow::Continue);
            };
            return Ok(ControlFlow::Attach(AttachRequest {
                handle,
                rows,
                cols,
                mode,
                re: seq,
            }));
        }
        Control::Subscribe { events, seq } => {
            if !connection.capabilities.contains("events") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the events capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                subscriptions.extend(events);
                send_response(out, response_cache, seq, Control::Ok { re: seq });
            }
        }
        Control::SubscribeResource {
            resource,
            since,
            seq,
        } => {
            let response = if !connection.capabilities.contains("resources") {
                error(
                    seq,
                    ErrorCode::Denied,
                    "the resources capability was not negotiated",
                    false,
                )
            } else if resource.starts_with("git:") && !connection.capabilities.contains("git") {
                error(
                    seq,
                    ErrorCode::Denied,
                    "the git capability was not negotiated",
                    false,
                )
            } else {
                // Clients name a workspace root; the host canonicalises it, so
                // two spellings of one repo share a single watch.
                match crate::resource::Registry::resource_id(&resource)
                    .and_then(|id| {
                        manager
                            .resources
                            .subscribe(
                                &id,
                                connection.client_id.clone(),
                                resource_tx.clone(),
                                since,
                            )
                            .map(|reply| (id, reply))
                    }) {
                    Ok((id, reply)) => {
                        // The reply lands before any replayed batch, so the
                        // client learns whether to rescan before applying them.
                        let ack = Control::Subscribed {
                            resource: id,
                            seq: reply.seq,
                            gap: reply.gap,
                            re: seq,
                        };
                        for event in reply.replay {
                            let _ = resource_tx.send(event);
                        }
                        ack
                    }
                    Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                }
            };
            send_response(out, response_cache, seq, response);
        }
        Control::UnsubscribeResource { resource, seq } => {
            let id = crate::resource::Registry::resource_id(&resource)
                .unwrap_or_else(|_| resource.clone());
            manager.resources.unsubscribe(&id, &connection.client_id);
            send_response(out, response_cache, seq, Control::Ok { re: seq });
        }
        Control::FsSearch {
            root,
            query,
            limit,
            seq,
        } => {
            if !connection.capabilities.contains("files") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the files capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                let (cancel_tx, cancel_rx) = oneshot::channel();
                // Without a request id the search cannot be addressed by
                // `cancel`; the task holds the sender itself so only the
                // connection going away stops it.
                let retained = match seq {
                    Some(id) => {
                        searches.lock().unwrap().insert(id, cancel_tx);
                        None
                    }
                    None => Some(cancel_tx),
                };
                tokio::spawn(run_search(
                    out.clone(),
                    searches.clone(),
                    cancel_rx,
                    retained,
                    root,
                    query,
                    limit,
                    seq,
                ));
            }
        }
        Control::Cancel { request, seq } => {
            let pending = searches.lock().unwrap().remove(&request);
            if let Some(cancel) = pending {
                let _ = cancel.send(());
            }
            // Cancelling what already finished is declaring disinterest in a
            // result that no longer exists — success either way.
            send_response(out, response_cache, seq, Control::Ok { re: seq });
        }
        Control::GitDiff {
            root,
            path,
            staged,
            seq,
        } => {
            if let Some(denied) = git_denied(connection, seq) {
                send_response(out, response_cache, seq, denied);
            } else {
                let out = out.clone();
                tokio::spawn(async move {
                    let response = match crate::git::run_diff(&root, &path, staged).await {
                        Ok((diff, truncated)) => Control::GitDiffResult {
                            diff,
                            truncated,
                            re: seq,
                        },
                        Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                    };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::GitLog {
            root,
            limit,
            range,
            seq,
        } => {
            if let Some(denied) = git_denied(connection, seq) {
                send_response(out, response_cache, seq, denied);
            } else {
                let out = out.clone();
                tokio::spawn(async move {
                    let response =
                        match crate::git::run_log(&root, limit, range.as_deref()).await {
                            Ok(page) => Control::GitLogResult {
                                commits: page.commits,
                                truncated: page.truncated,
                                re: seq,
                            },
                            Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                        };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::GitShow {
            root,
            commit,
            path,
            seq,
        } => {
            if let Some(denied) = git_denied(connection, seq) {
                send_response(out, response_cache, seq, denied);
            } else {
                let out = out.clone();
                tokio::spawn(async move {
                    let response =
                        match crate::git::run_show(&root, &commit, path.as_deref()).await {
                            Ok(detail) => Control::GitShowResult {
                                commit: detail.commit,
                                files: detail.files,
                                diff: detail.diff,
                                truncated: detail.truncated,
                                files_truncated: detail.files_truncated,
                                re: seq,
                            },
                            Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                        };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::GitBranches { root, seq } => {
            if let Some(denied) = git_denied(connection, seq) {
                send_response(out, response_cache, seq, denied);
            } else {
                let out = out.clone();
                tokio::spawn(async move {
                    let response = match crate::git::run_branches(&root).await {
                        Ok(list) => Control::GitBranchesResult {
                            branches: list.branches,
                            current: list.current,
                            default_branch: list.default_branch,
                            truncated: list.truncated,
                            re: seq,
                        },
                        Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                    };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::FsList {
            root,
            paths,
            page,
            seq,
        } => {
            if !connection.capabilities.contains("files") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the files capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                // Stamp with the resource cursor *before* walking, so a change
                // landing mid-listing makes the stamp stale (client re-lists)
                // rather than falsely fresh.
                let stamp = manager.resources.fs_seq(&root);
                let out = out.clone();
                tokio::spawn(async move {
                    let listed =
                        tokio::task::spawn_blocking(move || crate::files::list(&root, &paths, page))
                            .await;
                    let response = match listed {
                        Ok(Ok(listings)) => Control::FsListed {
                            seq: stamp,
                            listings,
                            re: seq,
                        },
                        Ok(Err(e)) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                        Err(e) => error(seq, ErrorCode::Internal, e.to_string(), true),
                    };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::FsRead {
            path,
            offset,
            length,
            seq,
        } => {
            if !connection.capabilities.contains("files") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the files capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                let out = out.clone();
                tokio::spawn(async move {
                    let window = tokio::task::spawn_blocking(move || {
                        crate::files::read(&path, offset, length)
                    })
                    .await;
                    match window {
                        Ok(Ok(window)) => {
                            let _ = out.send(Outbound::Control(Control::FsFile {
                                size: window.size,
                                offset: window.offset,
                                length: window.data.len() as u64,
                                truncated: window.truncated,
                                mtime: window.mtime,
                                re: seq,
                            }));
                            send_file_chunks(&out, seq.unwrap_or(0), window.offset, &window.data);
                        }
                        Ok(Err(e)) => {
                            let _ = out.send(Outbound::Control(error(
                                seq,
                                ErrorCode::Denied,
                                format!("{e:#}"),
                                false,
                            )));
                        }
                        Err(e) => {
                            let _ = out.send(Outbound::Control(error(
                                seq,
                                ErrorCode::Internal,
                                e.to_string(),
                                true,
                            )));
                        }
                    }
                });
            }
        }
        Control::FsMatch {
            root,
            query,
            limit,
            seq,
        } => {
            if !connection.capabilities.contains("files") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the files capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                match manager.resources.name_index(&root) {
                    // No subscription yet means no index — an honest 0.0,
                    // not a walk nobody asked the watcher to keep fresh.
                    None => {
                        let response = Control::FsMatched {
                            paths: Vec::new(),
                            coverage: 0.0,
                            re: seq,
                        };
                        send_response(out, response_cache, seq, response);
                    }
                    Some(index) => {
                        let out = out.clone();
                        tokio::spawn(async move {
                            let limit = usize::try_from(limit).unwrap_or(usize::MAX);
                            let matched = tokio::task::spawn_blocking(move || {
                                index.matches(&query, limit)
                            })
                            .await;
                            let response = match matched {
                                Ok((paths, coverage)) => Control::FsMatched {
                                    paths,
                                    coverage,
                                    re: seq,
                                },
                                Err(e) => error(seq, ErrorCode::Internal, e.to_string(), true),
                            };
                            let _ = out.send(Outbound::Control(response));
                        });
                    }
                }
            }
        }
        Control::UploadOpen {
            dest,
            size,
            sha256,
            mode,
            root,
            session,
            seq,
        } => {
            let response = if !connection.capabilities.contains("upload") {
                error(
                    seq,
                    ErrorCode::Denied,
                    "the upload capability was not negotiated",
                    false,
                )
            } else {
                match resolve_upload_dest(manager, &dest, root.as_deref(), session.as_deref())
                    .await
                {
                    Ok((resolved, session_id)) => {
                        match manager
                            .uploads
                            .open(resolved, size, &sha256, mode, session_id)
                        {
                            Ok((upload_id, offset)) => Control::UploadOpened {
                                upload_id,
                                offset,
                                re: seq,
                            },
                            Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                        }
                    }
                    Err((code, message)) => error(seq, code, message, false),
                }
            };
            send_response(out, response_cache, seq, response);
        }
        Control::UploadCommit {
            upload_id,
            if_unmodified_since,
            seq,
        } => {
            let response = if !connection.capabilities.contains("upload") {
                error(
                    seq,
                    ErrorCode::Denied,
                    "the upload capability was not negotiated",
                    false,
                )
            } else {
                match manager.uploads.commit(&upload_id, if_unmodified_since) {
                    Ok((path, mtime)) => Control::UploadCommitted {
                        path: path.display().to_string(),
                        mtime,
                        re: seq,
                    },
                    // A refused *version* is not a refused request: the client
                    // asks the person whether to overwrite, so it has to be
                    // able to tell this apart from a denial.
                    Err(e) if e.to_string().starts_with("conflict: ") => {
                        error(seq, ErrorCode::Conflict, format!("{e:#}"), false)
                    }
                    Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                }
            };
            send_response(out, response_cache, seq, response);
        }
        Control::UploadAbort { upload_id, seq } => {
            // Aborting what is already gone is success, not failure — the
            // client is declaring disinterest, not asserting existence.
            manager.uploads.abort(&upload_id);
            send_response(out, response_cache, seq, Control::Ok { re: seq });
        }
        Control::Wait {
            target,
            until,
            timeout_ms,
            seq,
        } => {
            if !connection.capabilities.contains("send_wait") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the send_wait capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                let manager = manager.clone();
                let out = out.clone();
                tokio::spawn(async move {
                    let response = manager.wait_response(target, until, timeout_ms, seq).await;
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::SetStatus {
            id,
            status,
            title,
            seq,
        } => {
            let response = match manager.resolve(&id).await {
                Some(handle) => {
                    let (tx, rx) = oneshot::channel();
                    if handle.send(SessionMsg::SetStatus {
                        status,
                        title,
                        reply: tx,
                    }) && rx.await.is_ok()
                    {
                        Control::Ok { re: seq }
                    } else {
                        error(
                            seq,
                            ErrorCode::AlreadyExited,
                            "session already exited",
                            false,
                        )
                    }
                }
                None => error(
                    seq,
                    ErrorCode::NoSuchSession,
                    format!("no such session: {id}"),
                    false,
                ),
            };
            send_response(out, response_cache, seq, response);
        }
        Control::InstallAgents {
            agents,
            hooks,
            skills,
            reporter,
            hook_version,
            seq,
        } => {
            if !connection.capabilities.contains("agents") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the agents capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                let request = crate::agent::install::InstallRequest::new(
                    agents,
                    hooks,
                    skills,
                    reporter,
                    hook_version.unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string()),
                );
                // A dozen agents is a few dozen small reads, merges and renames.
                // That is blocking work, and it must not sit on the runtime that
                // is also carrying somebody's keystrokes.
                let out = out.clone();
                tokio::spawn(async move {
                    let installed =
                        tokio::task::spawn_blocking(move || crate::agent::install::run(&request))
                            .await;
                    let response = match installed {
                        Ok(results) => Control::AgentsInstalled { results, re: seq },
                        Err(e) => error(seq, ErrorCode::Internal, e.to_string(), true),
                    };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::ProbeAgents { agents, seq } => {
            if !connection.capabilities.contains("agents") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the agents capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                // The login-shell probe behind this can spawn a shell whose rc
                // takes seconds; it must not sit on the runtime carrying
                // keystrokes.
                let out = out.clone();
                tokio::spawn(async move {
                    let probed =
                        tokio::task::spawn_blocking(move || crate::agent::install::probe(agents))
                            .await;
                    let response = match probed {
                        Ok(agents) => Control::AgentsProbed { agents, re: seq },
                        Err(e) => error(seq, ErrorCode::Internal, e.to_string(), true),
                    };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::Detach { .. } => return Ok(ControlFlow::Close),
        Control::RequestSnapshot { seq } => {
            let _ = out.send(Outbound::Control(error(
                seq,
                ErrorCode::ProtoError,
                "request_snapshot needs an active attachment on this channel",
                false,
            )));
        }
        Control::ClaimWriter { seq } => {
            // The token belongs to an attachment, and this channel has none —
            // the claim is only meaningful inside the attached loop.
            let _ = out.send(Outbound::Control(error(
                seq,
                ErrorCode::ProtoError,
                "claim_writer needs an active attachment on this channel",
                false,
            )));
        }
        Control::Hello { .. } => {
            let _ = out.send(Outbound::Control(error(
                None,
                ErrorCode::ProtoError,
                "hello must be the first control frame",
                false,
            )));
            return Ok(ControlFlow::Close);
        }
        // Unknown operations are ignored. Response-direction messages sent by
        // a client are likewise harmless and ignored.
        Control::Unknown
        | Control::HelloOk { .. }
        | Control::HelloErr { .. }
        | Control::Ok { .. }
        | Control::Created { .. }
        | Control::Sessions { .. }
        | Control::Attached { .. }
        | Control::Exited { .. }
        | Control::WaitResult { .. }
        | Control::ResizeClaim { .. }
        | Control::Subscribed { .. }
        | Control::FsListed { .. }
        | Control::FsFile { .. }
        | Control::FsMatched { .. }
        | Control::FsSearched { .. }
        | Control::GitDiffResult { .. }
        | Control::GitLogResult { .. }
        | Control::GitShowResult { .. }
        | Control::GitBranchesResult { .. }
        | Control::UploadOpened { .. }
        | Control::UploadAck { .. }
        | Control::UploadCommitted { .. }
        | Control::AgentsInstalled { .. }
        | Control::AgentsProbed { .. }
        | Control::Error { .. } => {}
    }
    Ok(ControlFlow::Continue)
}

/// Matches per `search_results` event — small enough to render as they
/// arrive, large enough that a big result set is not one event per line.
const SEARCH_BATCH: usize = 50;

/// Lines of context on each side of a hit. Two is what reads as an excerpt
/// without the results pane turning into the file.
const SEARCH_CONTEXT_LINES: usize = 2;

/// Stream one `fs.search` (§C.12): `git grep` under the workspace root,
/// batched result events, one terminal `fs_searched` reply. Ends on
/// completion, on the limit, on `cancel`, or on the connection going away
/// (the cancel sender's map is dropped with it). Result events and the
/// terminal reply share `out`, which is what guarantees the reply is last.
#[allow(clippy::too_many_arguments)]
async fn run_search(
    out: mpsc::UnboundedSender<Outbound>,
    searches: SearchMap,
    mut cancel_rx: oneshot::Receiver<()>,
    _retained: Option<oneshot::Sender<()>>,
    root: String,
    query: String,
    limit: u64,
    seq: Option<u64>,
) {
    let request = seq.unwrap_or(0);
    let cleanup = |searches: &SearchMap| {
        if let Some(id) = seq {
            searches.lock().unwrap().remove(&id);
        }
    };

    let root = match crate::files::canonical_root(&root) {
        Ok(root) => root,
        Err(e) => {
            cleanup(&searches);
            let _ = out.send(Outbound::Control(error(
                seq,
                ErrorCode::Denied,
                format!("{e:#}"),
                false,
            )));
            return;
        }
    };
    let mut command = tokio::process::Command::new("git");
    command
        .arg("-C")
        .arg(&root)
        .arg("grep")
        .arg("-n")
        .arg("-I")
        .arg("--no-color")
        .arg("--untracked")
        .arg("--fixed-strings");
    // Smart case, the fzf/ripgrep default every client already expects: an
    // all-lowercase query matches insensitively, and one uppercase letter opts
    // back into exactness. Decided from the query itself rather than a flag on
    // the wire, so a client cannot ask two hosts for the same search and get two
    // different answers.
    let insensitive = query == query.to_lowercase();
    if insensitive {
        command.arg("--ignore-case");
    }
    // Context, so a client can draw an excerpt instead of a naked line. The
    // separator between runs is what makes the output parseable back into runs.
    command.arg(format!("-C{SEARCH_CONTEXT_LINES}"));
    let spawned = command
        .arg("-e")
        .arg(&query)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn();
    let mut child = match spawned {
        Ok(child) => child,
        Err(e) => {
            cleanup(&searches);
            let _ = out.send(Outbound::Control(error(
                seq,
                ErrorCode::Internal,
                format!("spawning git grep: {e}"),
                true,
            )));
            return;
        }
    };
    let Some(stdout) = child.stdout.take() else {
        cleanup(&searches);
        let _ = out.send(Outbound::Control(error(
            seq,
            ErrorCode::Internal,
            "git grep stdout unavailable",
            true,
        )));
        return;
    };

    use tokio::io::AsyncBufReadExt;
    let mut lines = tokio::io::BufReader::new(stdout).lines();
    let mut pending: Vec<crate::protocol::SearchMatch> = Vec::new();
    // Context lines seen since the last match, and the match still collecting
    // the lines after it. Both are indexes into `pending`, so a batch flush has
    // to retire them — a match that has left is no longer collecting anything.
    let mut before: std::collections::VecDeque<String> = std::collections::VecDeque::new();
    let mut trailing: Option<usize> = None;
    let mut streamed = 0u64;
    let mut limit_hit = false;
    let mut canceled = false;
    loop {
        tokio::select! {
            // Err means the sender vanished without an explicit cancel — the
            // connection is gone; stop doing work nobody can receive.
            _ = &mut cancel_rx => {
                canceled = true;
                break;
            }
            // The connection itself going away. Not covered by `cancel_rx`: a
            // search addressed by a request id parks its cancel sender in the
            // shared map, and *this task* holds a reference to that map — so the
            // sender outlives the connection that owned it and the receiver never
            // resolves. Without this arm a client that hung up (a timeout, a
            // keystroke abandoning the query) leaves its grep running to
            // completion, writing into a channel nobody reads.
            _ = out.closed() => {
                canceled = true;
                break;
            }
            line = lines.next_line() => {
                match line {
                    Ok(Some(line)) => {
                        let Some(parsed) = crate::files::parse_grep_output_line(&line) else {
                            continue;
                        };
                        use crate::files::GrepLine;
                        match parsed {
                            // A run ended: whatever context was banked belongs to
                            // nothing that follows it.
                            GrepLine::Separator => {
                                before.clear();
                                trailing = None;
                                continue;
                            }
                            GrepLine::Context { line: number, text, .. } => {
                                // Context after a match, and context before the
                                // next one, are the same lines — bank them once
                                // and let both sides read them.
                                if let Some(index) = trailing {
                                    let match_at: &mut crate::protocol::SearchMatch =
                                        &mut pending[index];
                                    if match_at.after.len() < SEARCH_CONTEXT_LINES {
                                        match_at.after.push(text.clone());
                                    } else {
                                        trailing = None;
                                    }
                                }
                                before.push_back(text);
                                if before.len() > SEARCH_CONTEXT_LINES {
                                    before.pop_front();
                                }
                                let _ = number;
                                continue;
                            }
                            GrepLine::Match { path, line: number, text } => {
                                let mut found = crate::files::match_from_line(
                                    path, number, &text, &query, insensitive,
                                );
                                found.before = before.iter().cloned().collect();
                                before.clear();
                                trailing = Some(pending.len());
                                pending.push(found);
                            }
                        }
                        if streamed + pending.len() as u64 >= limit {
                            limit_hit = true;
                            break;
                        }
                        if pending.len() >= SEARCH_BATCH {
                            streamed += pending.len() as u64;
                            // The batch leaves, so nothing in it can still be
                            // collecting its trailing context.
                            trailing = None;
                            let _ = out.send(Outbound::Event(Event::SearchResults {
                                request,
                                matches: std::mem::take(&mut pending),
                            }));
                        }
                    }
                    Ok(None) | Err(_) => break,
                }
            }
        }
    }
    if !canceled && !pending.is_empty() {
        streamed += pending.len() as u64;
        let _ = out.send(Outbound::Event(Event::SearchResults {
            request,
            matches: std::mem::take(&mut pending),
        }));
    }

    let failure = if canceled || limit_hit {
        let _ = child.kill().await;
        None
    } else {
        // git grep exits 1 for "no matches" — a result, not a failure.
        match child.wait().await {
            Ok(status) if status.success() || status.code() == Some(1) => None,
            Ok(status) => Some(format!("git grep exited with {status}")),
            Err(e) => Some(format!("waiting for git grep: {e}")),
        }
    };

    cleanup(&searches);
    let response = match failure {
        Some(message) => error(seq, ErrorCode::Denied, message, false),
        None => Control::FsSearched {
            matches: streamed,
            limit_hit,
            canceled,
            re: seq,
        },
    };
    let _ = out.send(Outbound::Control(response));
}

/// Resolve an `upload.open` dest to a confined landing spot (§C.12): either
/// `temp:<name>` in the named session's scratch dir, or a path under a
/// caller-named project root. Returns the session id that owns a scratch
/// upload so the reaper can drop it with the session.
async fn resolve_upload_dest(
    manager: &Manager,
    dest: &str,
    root: Option<&str>,
    session: Option<&str>,
) -> std::result::Result<(crate::files::UploadDest, Option<SessionId>), (ErrorCode, String)> {
    if let Some(name) = dest.strip_prefix("temp:") {
        let Some(session) = session else {
            return Err((
                ErrorCode::Denied,
                "a temp: upload must name its session".to_string(),
            ));
        };
        let Some(handle) = manager.resolve(session).await else {
            return Err((
                ErrorCode::NoSuchSession,
                format!("no such session: {session}"),
            ));
        };
        let scratch = paths::session_scratch_dir(&handle.id)
            .map_err(|e| (ErrorCode::Internal, format!("{e:#}")))?;
        let resolved = crate::files::resolve_scratch_dest(&scratch, name)
            .map_err(|e| (ErrorCode::Denied, format!("{e:#}")))?;
        return Ok((resolved, Some(handle.id.clone())));
    }
    let Some(root) = root else {
        return Err((
            ErrorCode::Denied,
            "a project upload must name its workspace root".to_string(),
        ));
    };
    let resolved = crate::files::resolve_project_dest(root, dest)
        .map_err(|e| (ErrorCode::Denied, format!("{e:#}")))?;
    Ok((resolved, None))
}

/// Ship an `fs.read` window as `F` chunks: 64 KiB fair-write pieces, the last
/// one flagged, and an empty flagged chunk for an empty window so the client
/// always has one uniform termination signal.
fn send_file_chunks(out: &mpsc::UnboundedSender<Outbound>, re: u64, offset: u64, data: &[u8]) {
    let piece = MAX_FILE_FRAME_SIZE - FILE_CHUNK_HEADER_SIZE;
    let mut sent = 0usize;
    loop {
        let end = (sent + piece).min(data.len());
        let chunk = FileChunk {
            re,
            offset: offset + sent as u64,
            last: end == data.len(),
            data: data[sent..end].to_vec(),
        };
        match encode_file_chunk(&chunk) {
            Ok(payload) => {
                if out.send(Outbound::File(Bytes::from(payload))).is_err() {
                    return;
                }
            }
            Err(e) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::Internal,
                    e.to_string(),
                    true,
                )));
                return;
            }
        }
        if end == data.len() {
            return;
        }
        sent = end;
    }
}

fn send_response(
    out: &mpsc::UnboundedSender<Outbound>,
    cache: &mut HashMap<u64, Control>,
    seq: Option<u64>,
    response: Control,
) {
    if let Some(seq) = seq {
        cache.insert(seq, response.clone());
    }
    let _ = out.send(Outbound::Control(response));
}

fn subscribed_to(subscriptions: &HashSet<String>, event: &Event) -> bool {
    match event {
        Event::Status { .. } => subscriptions.contains("status"),
        Event::Roster { .. } | Event::WriterChanged { .. } | Event::SessionExited { .. } => {
            subscriptions.contains("roster")
        }
        Event::Resized { .. } => false,
        Event::Ready { .. } => false,
        // Both are addressed to one attachment's stream, not to the roster: a
        // resync is that client's own, and a stale VT only means anything to a
        // client that was going to ask for a snapshot.
        Event::Resynced { .. } | Event::VtStale { .. } => false,
        // Resource events are delivered on the subscriber's own channel, not
        // through the roster broadcast, so they never match here.
        Event::FsChanged { .. } | Event::GitChanged { .. } | Event::SearchResults { .. } => false,
        Event::Unknown => false,
    }
}

/// Bridge one attached client to a session. Disconnect removes only the
/// attachment; the session continues.
async fn run_attach(
    mut rd: tokio::net::unix::OwnedReadHalf,
    out: mpsc::UnboundedSender<Outbound>,
    request: AttachRequest,
    connection: Connection,
    backlog: Arc<ClientBacklog>,
) -> Result<()> {
    let handle = request.handle;
    let client_id = connection.client_id;
    let (client_out, mut client_events) = mpsc::unbounded_channel::<ClientEvent>();
    let (reply_tx, reply_rx) = oneshot::channel();
    handle.send(SessionMsg::AddClient {
        id: client_id.clone(),
        interactive: request.mode == AttachMode::Interact,
        out: client_out,
        backlog: backlog.clone(),
        snapshot: connection.capabilities.contains("snapshot"),
        scrollback: connection.capabilities.contains("snapshot")
            && connection.capabilities.contains("scrollback"),
        grid_diff: connection.capabilities.contains("snapshot")
            && connection.capabilities.contains("grid_diff"),
        reply: reply_tx,
    });
    let added = reply_rx.await.context("session ended while attaching")?;
    let name = {
        let (tx, rx) = oneshot::channel();
        handle.send(SessionMsg::Info { reply: tx });
        rx.await
            .map(|info| info.name)
            .unwrap_or_else(|_| handle.id.to_string())
    };
    let _ = out.send(Outbound::Control(Control::Attached {
        id: handle.id.to_string(),
        name,
        session_id: handle.id.to_string(),
        writer: added.writer,
        rows: added.rows,
        cols: added.cols,
        re: request.re,
    }));

    if added.writer {
        handle.send(SessionMsg::Resize {
            id: client_id.clone(),
            rows: request.rows,
            cols: request.cols,
        });
    }

    let supports_events = connection.capabilities.contains("events");
    let supports_snapshot = connection.capabilities.contains("snapshot");
    let supports_scrollback = supports_snapshot && connection.capabilities.contains("scrollback");
    let supports_grid_diff = supports_snapshot && connection.capabilities.contains("grid_diff");
    let negotiated = connection.negotiated;
    let event_out = out.clone();
    let session_id = handle.id.to_string();
    let bridge_backlog = backlog;
    let mut bridge = tokio::spawn(async move {
        while let Some(event) = client_events.recv().await {
            match event {
                ClientEvent::Data(payload) => {
                    if event_out.send(Outbound::Data(payload.clone())).is_err() {
                        bridge_backlog.release(&payload);
                        break;
                    }
                }
                ClientEvent::Snapshot(snapshot) if supports_snapshot => {
                    if event_out.send(Outbound::Snapshot(snapshot)).is_err() {
                        break;
                    }
                }
                ClientEvent::Snapshot(_) => {}
                ClientEvent::History(payload) if supports_scrollback => {
                    if event_out.send(Outbound::History(payload.clone())).is_err() {
                        bridge_backlog.release(&payload);
                        break;
                    }
                }
                ClientEvent::History(payload) => bridge_backlog.release(&payload),
                ClientEvent::Grid(payload) if supports_grid_diff => {
                    if event_out.send(Outbound::Grid(payload.clone())).is_err() {
                        bridge_backlog.release(&payload);
                        break;
                    }
                }
                ClientEvent::Grid(payload) => bridge_backlog.release(&payload),
                ClientEvent::Control(control) if negotiated => {
                    if event_out.send(Outbound::Control(control)).is_err() {
                        break;
                    }
                }
                ClientEvent::Control(_) => {}
                ClientEvent::Event(event @ Event::Ready { .. }) if supports_snapshot => {
                    if event_out.send(Outbound::Event(event)).is_err() {
                        break;
                    }
                }
                ClientEvent::Event(event) if supports_events => {
                    if event_out.send(Outbound::Event(event)).is_err() {
                        break;
                    }
                }
                ClientEvent::Event(_) => {}
                ClientEvent::Exited(status) => {
                    let _ = event_out.send(Outbound::Control(Control::Exited {
                        id: session_id.clone(),
                        status,
                    }));
                    break;
                }
            }
        }
    });

    loop {
        let frame = tokio::select! {
            _ = &mut bridge => break,
            frame = read_frame(&mut rd) => frame,
        };
        match frame {
            Ok(Some(Frame::Data(data))) => {
                handle.send(SessionMsg::Input {
                    id: client_id.clone(),
                    data,
                });
            }
            Ok(Some(Frame::Resize { rows, cols })) => {
                handle.send(SessionMsg::Resize {
                    id: client_id.clone(),
                    rows,
                    cols,
                });
            }
            Ok(Some(Frame::Snapshot(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    "snapshot frames are host-to-client only",
                    false,
                )));
                break;
            }
            Ok(Some(Frame::History(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    "history frames are host-to-client only",
                    false,
                )));
                break;
            }
            Ok(Some(Frame::Grid(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    "grid-diff frames are host-to-client only",
                    false,
                )));
                break;
            }
            Ok(Some(Frame::File(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    "file frames are host-to-client only",
                    false,
                )));
                break;
            }
            Ok(Some(Frame::Upload(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    "upload frames ride the control channel, not an attachment",
                    false,
                )));
                break;
            }
            Ok(Some(Frame::Control(Control::Detach { .. }))) => break,
            Ok(Some(Frame::Control(Control::ClaimWriter { seq }))) => {
                let (reply_tx, reply_rx) = oneshot::channel();
                handle.send(SessionMsg::ClaimWriter {
                    id: client_id.clone(),
                    reply: reply_tx,
                });
                // The grant itself reaches every attachment as `writer_changed`;
                // this reply only tells the asker whether it was eligible, so a
                // client that is refused can say "read-only" rather than
                // silently dropping the keystrokes that follow.
                let granted = reply_rx.await.unwrap_or(false);
                let response = if granted {
                    Control::Ok { re: seq }
                } else {
                    error(
                        seq,
                        ErrorCode::NotWriter,
                        "an observer cannot hold the write token",
                        false,
                    )
                };
                let _ = out.send(Outbound::Control(response));
            }
            Ok(Some(Frame::Control(Control::RequestSnapshot { seq }))) => {
                if supports_snapshot {
                    handle.send(SessionMsg::ResendSnapshot {
                        id: client_id.clone(),
                    });
                    let _ = out.send(Outbound::Control(Control::Ok { re: seq }));
                } else {
                    // The snapshot plane was never negotiated on this
                    // attachment, so there is nothing to answer with — say so
                    // rather than leaving the client waiting for a repaint.
                    let _ = out.send(Outbound::Control(error(
                        seq,
                        ErrorCode::ProtoError,
                        "this attachment did not negotiate snapshots",
                        false,
                    )));
                }
            }
            Ok(Some(Frame::Control(Control::Unknown))) => {}
            Ok(Some(Frame::Event(event))) => drop(event),
            Ok(Some(Frame::Control(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::Busy,
                    "attachment is already active on this channel",
                    false,
                )));
            }
            Ok(None) => break,
            Err(e) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    e.to_string(),
                    false,
                )));
                break;
            }
        }
    }

    handle.send(SessionMsg::RemoveClient { id: client_id });
    bridge.abort();
    Ok(())
}

/// Every `git:` verb is behind the one capability (§C.13), so they share one
/// gate: `Some(error)` when the channel never negotiated it.
fn git_denied(connection: &Connection, seq: Option<u64>) -> Option<Control> {
    if connection.capabilities.contains("git") {
        return None;
    }
    Some(error(
        seq,
        ErrorCode::Denied,
        "the git capability was not negotiated",
        false,
    ))
}

fn error(re: Option<u64>, code: ErrorCode, message: impl Into<String>, retryable: bool) -> Control {
    Control::Error {
        re,
        code,
        message: message.into(),
        retryable,
    }
}
