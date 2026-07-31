//! The daemon: a session table plus a Unix-socket accept loop. Connections
//! speak Session Protocol v0.1, with a transparent legacy-v0 first-message
//! fallback.

use crate::paths;
use crate::protocol::{
    read_frame, write_control, write_data, write_event, write_snapshot, AttachMode, Control,
    ErrorCode, Event, Frame, SessionInfo, Snapshot, HOST_CAPABILITIES, PROTOCOL_VERSION,
    SUPPORTED_PROTOCOLS,
};
use crate::session::{self, ClientBacklog, ClientEvent, ClientId, SessionHandle, SessionMsg};
use anyhow::{Context, Result};
use bytes::Bytes;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc, oneshot};

const EVENT_BUFFER: usize = 1024;

struct ManagerInner {
    sessions: HashMap<String, SessionHandle>,
    id_counter: u32,
}

#[derive(Clone)]
pub struct Manager {
    inner: Arc<Mutex<ManagerInner>>,
    next_client_id: Arc<AtomicU64>,
    on_exit: mpsc::UnboundedSender<String>,
    events: broadcast::Sender<Event>,
    host_id: Arc<String>,
}

impl Manager {
    fn new(on_exit: mpsc::UnboundedSender<String>, host_id: String) -> Manager {
        let (events, _) = broadcast::channel(EVENT_BUFFER);
        Manager {
            inner: Arc::new(Mutex::new(ManagerInner {
                sessions: HashMap::new(),
                id_counter: 0,
            })),
            next_client_id: Arc::new(AtomicU64::new(1)),
            on_exit,
            events,
            host_id: Arc::new(host_id),
        }
    }

    fn alloc_client_id(&self) -> ClientId {
        let id = self.next_client_id.fetch_add(1, Ordering::Relaxed);
        format!("c_{id:x}")
    }

    fn new_session_id(&self) -> String {
        let seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        let mut guard = self.inner.lock().unwrap();
        guard.id_counter = guard.id_counter.wrapping_add(1);
        format!("{:08x}", seed ^ guard.id_counter.wrapping_mul(2654435761))
    }

    fn create(&self, spec: crate::protocol::CreateSpec) -> Result<String> {
        let id = self.new_session_id();
        let name = spec.name.clone().unwrap_or_else(|| id.clone());
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
        self.inner
            .lock()
            .unwrap()
            .sessions
            .insert(id.clone(), handle);
        Ok(id)
    }

    fn find(&self, id: &str) -> Option<SessionHandle> {
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

    fn remove(&self, id: &str) -> bool {
        self.inner.lock().unwrap().sessions.remove(id).is_some()
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

    async fn publish_created(&self, id: &str) {
        let Some(handle) = self.find(id) else {
            return;
        };
        let info = self.info(&handle).await.map(Box::new);
        self.publish(Event::Roster {
            session: id.to_string(),
            action: "created".to_string(),
            info,
        });
    }

    fn publish_removed(&self, id: &str) {
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

    /// Resolve a target that may be an id or a name.
    async fn resolve(&self, target: &str) -> Option<SessionHandle> {
        if let Some(handle) = self.find(target) {
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
                    session: session_id,
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
                session: session_id,
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
                    }) if session == session_id && until.iter().any(|wanted| wanted == &status) => {
                        return Ok((status, None));
                    }
                    Ok(Event::SessionExited { session, status })
                        if session == session_id
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
                session: session_id,
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
                        session: session_id,
                        status: "exited".to_string(),
                        timed_out: false,
                        exit_status: None,
                        re,
                    };
                }
                Control::WaitResult {
                    session: session_id,
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
pub async fn serve() -> Result<()> {
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

    let host_id = paths::load_or_create_host_id()?;
    let (on_exit_tx, mut on_exit_rx) = mpsc::unbounded_channel::<String>();
    let manager = Manager::new(on_exit_tx, host_id);

    {
        let manager = manager.clone();
        tokio::spawn(async move {
            while let Some(id) = on_exit_rx.recv().await {
                if manager.remove(&id) {
                    manager.publish_removed(&id);
                }
            }
        });
    }

    eprintln!("termiod listening on {}", sock_path.display());

    {
        let sock_path = sock_path.clone();
        tokio::spawn(async move {
            let mut term =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = term.recv() => {}
            }
            let _ = std::fs::remove_file(&sock_path);
            std::process::exit(0);
        });
    }

    loop {
        let (stream, _addr) = listener.accept().await?;
        let manager = manager.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_conn(stream, manager).await {
                eprintln!("termiod: connection error: {e:#}");
            }
        });
    }
}

#[derive(Clone)]
struct Connection {
    client_id: ClientId,
    negotiated: bool,
    capabilities: HashSet<String>,
}

enum Outbound {
    Control(Control),
    Data(Bytes),
    Event(Event),
    Snapshot(Snapshot),
}

async fn write_outbound(
    mut wr: tokio::net::unix::OwnedWriteHalf,
    mut rx: mpsc::UnboundedReceiver<Outbound>,
    backlog: Arc<ClientBacklog>,
) {
    while let Some(message) = rx.recv().await {
        let result = match message {
            Outbound::Control(control) => write_control(&mut wr, &control).await,
            Outbound::Data(data) => {
                let len = data.len();
                let result = write_data(&mut wr, &data).await;
                backlog.release(len);
                result
            }
            Outbound::Event(event) => write_event(&mut wr, &event).await,
            Outbound::Snapshot(snapshot) => write_snapshot(&mut wr, &snapshot).await,
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
            let negotiated_caps: Vec<String> = caps
                .into_iter()
                .filter(|cap| HOST_CAPABILITIES.contains(&cap.as_str()))
                .filter(|cap| seen.insert(cap.clone()))
                .collect();
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
                    client_id: client_id.clone(),
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
    let result = run_connection(
        rd,
        out.clone(),
        connection,
        pending,
        manager,
        backlog.clone(),
    )
    .await;
    drop(out);
    if backlog.is_dropped() {
        writer.abort();
    }
    let _ = writer.await;
    result
}

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

    loop {
        if let Some(control) = pending.take() {
            match process_control(
                control,
                &out,
                &connection,
                &manager,
                &mut subscriptions,
                &mut response_cache,
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
                    Control::Created { id, re: seq }
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
                Control::Sessions { sessions, re: seq },
            );
        }
        Control::Kill { id, seq } => {
            let response = match manager.resolve(&id).await {
                Some(handle) => {
                    handle.send(SessionMsg::Kill);
                    if manager.remove(&handle.id) {
                        manager.publish_removed(&handle.id);
                    }
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
        Control::Detach { .. } => return Ok(ControlFlow::Close),
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
        | Control::Error { .. } => {}
    }
    Ok(ControlFlow::Continue)
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
        reply: reply_tx,
    });
    let writer = reply_rx.await.unwrap_or(false);
    let name = {
        let (tx, rx) = oneshot::channel();
        handle.send(SessionMsg::Info { reply: tx });
        rx.await
            .map(|info| info.name)
            .unwrap_or_else(|_| handle.id.clone())
    };
    let _ = out.send(Outbound::Control(Control::Attached {
        id: handle.id.clone(),
        name,
        session_id: handle.id.clone(),
        writer,
        re: request.re,
    }));

    if writer {
        handle.send(SessionMsg::Resize {
            id: client_id.clone(),
            rows: request.rows,
            cols: request.cols,
        });
    }

    let supports_events = connection.capabilities.contains("events");
    let supports_snapshot = connection.capabilities.contains("snapshot");
    let negotiated = connection.negotiated;
    let event_out = out.clone();
    let session_id = handle.id.clone();
    let bridge_backlog = backlog;
    let mut bridge = tokio::spawn(async move {
        while let Some(event) = client_events.recv().await {
            match event {
                ClientEvent::Data(bytes) => {
                    let len = bytes.len();
                    if event_out.send(Outbound::Data(bytes)).is_err() {
                        bridge_backlog.release(len);
                        break;
                    }
                }
                ClientEvent::Snapshot(snapshot) if supports_snapshot => {
                    if event_out.send(Outbound::Snapshot(snapshot)).is_err() {
                        break;
                    }
                }
                ClientEvent::Snapshot(_) => {}
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
            Ok(Some(Frame::Control(Control::Detach { .. }))) => break,
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

fn error(re: Option<u64>, code: ErrorCode, message: impl Into<String>, retryable: bool) -> Control {
    Control::Error {
        re,
        code,
        message: message.into(),
        retryable,
    }
}
