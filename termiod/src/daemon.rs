//! The daemon: a session table plus a Unix-socket accept loop. Every client
//! op (`create`/`list`/`kill`/`send`/`attach`) is one connection speaking
//! protocol v0. Sessions outlive connections — this is the whole point.

use crate::paths;
use crate::protocol::{
    read_frame, write_control, write_data, Control, CreateSpec, Frame, SessionInfo,
};
use crate::session::{self, ClientEvent, ClientId, SessionHandle, SessionMsg};
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{mpsc, oneshot};

struct ManagerInner {
    sessions: HashMap<String, SessionHandle>,
    id_counter: u32,
}

#[derive(Clone)]
pub struct Manager {
    inner: Arc<Mutex<ManagerInner>>,
    next_client_id: Arc<AtomicU64>,
    on_exit: mpsc::UnboundedSender<String>,
}

impl Manager {
    fn new(on_exit: mpsc::UnboundedSender<String>) -> Manager {
        Manager {
            inner: Arc::new(Mutex::new(ManagerInner {
                sessions: HashMap::new(),
                id_counter: 0,
            })),
            next_client_id: Arc::new(AtomicU64::new(1)),
            on_exit,
        }
    }

    fn alloc_client_id(&self) -> ClientId {
        self.next_client_id.fetch_add(1, Ordering::Relaxed)
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

    fn create(&self, spec: CreateSpec) -> Result<String> {
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
            self.on_exit.clone(),
        )
        .context("spawning session")?;
        self.inner
            .lock()
            .unwrap()
            .sessions
            .insert(id.clone(), handle);
        Ok(id)
    }

    /// Resolve a session by exact id (the map key). Name lookup lives in the
    /// async `resolve`, since names require an info query.
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

    fn remove(&self, id: &str) {
        self.inner.lock().unwrap().sessions.remove(id);
    }

    async fn list(&self) -> Vec<SessionInfo> {
        let handles = self.handles();
        let mut infos = Vec::new();
        for h in handles {
            let (tx, rx) = oneshot::channel();
            if h.send(SessionMsg::Info { reply: tx }) {
                if let Ok(info) = rx.await {
                    infos.push(info);
                }
            }
        }
        infos.sort_by(|a, b| a.created_unix.cmp(&b.created_unix));
        infos
    }

    /// Resolve a target that may be an id or a name (name needs an info query).
    async fn resolve(&self, target: &str) -> Option<SessionHandle> {
        if let Some(h) = self.find(target) {
            return Some(h);
        }
        for h in self.handles() {
            let (tx, rx) = oneshot::channel();
            if h.send(SessionMsg::Info { reply: tx }) {
                if let Ok(info) = rx.await {
                    if info.name == target {
                        return Some(h);
                    }
                }
            }
        }
        None
    }
}

/// Run the daemon: bind the socket and accept forever.
pub async fn serve() -> Result<()> {
    paths::ensure_runtime_dir()?;
    let sock_path = paths::socket_path()?;

    // If a live daemon already owns the socket, refuse; if it's a stale socket
    // (no listener), remove it and take over.
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
    // Owner-only socket.
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&sock_path, std::fs::Permissions::from_mode(0o600))?;

    let (on_exit_tx, mut on_exit_rx) = mpsc::unbounded_channel::<String>();
    let manager = Manager::new(on_exit_tx);

    // Reaper: drop exited sessions from the table.
    {
        let manager = manager.clone();
        tokio::spawn(async move {
            while let Some(id) = on_exit_rx.recv().await {
                manager.remove(&id);
            }
        });
    }

    eprintln!("termiod listening on {}", sock_path.display());

    // Clean the socket file on SIGTERM/SIGINT.
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

async fn handle_conn(stream: UnixStream, manager: Manager) -> Result<()> {
    let (mut rd, mut wr) = stream.into_split();

    let first = match read_frame(&mut rd).await? {
        Some(Frame::Control(c)) => c,
        Some(_) => {
            write_control(&mut wr, &err("expected a control frame first")).await?;
            return Ok(());
        }
        None => return Ok(()),
    };

    match first {
        Control::Create(spec) => {
            match manager.create(spec) {
                Ok(id) => write_control(&mut wr, &Control::Created { id }).await?,
                Err(e) => write_control(&mut wr, &err(&format!("{e:#}"))).await?,
            }
            Ok(())
        }
        Control::List => {
            let sessions = manager.list().await;
            write_control(&mut wr, &Control::Sessions { sessions }).await
        }
        Control::Kill { id } => {
            match manager.resolve(&id).await {
                Some(h) => {
                    h.send(SessionMsg::Kill);
                    manager.remove(&h.id);
                    write_control(&mut wr, &Control::Ok).await
                }
                None => write_control(&mut wr, &err("no such session")).await,
            }
        }
        Control::Send { id, data } => {
            match manager.resolve(&id).await {
                Some(h) => {
                    h.send(SessionMsg::Inject { data });
                    write_control(&mut wr, &Control::Ok).await
                }
                None => write_control(&mut wr, &err("no such session")).await,
            }
        }
        Control::Attach {
            target,
            create_if_missing,
            rows,
            cols,
        } => {
            let handle = match manager.resolve(&target).await {
                Some(h) => Some(h),
                None => match create_if_missing {
                    Some(mut spec) => {
                        if spec.name.is_none() {
                            spec.name = Some(target.clone());
                        }
                        spec.rows = rows;
                        spec.cols = cols;
                        match manager.create(spec) {
                            Ok(id) => manager.find(&id),
                            Err(e) => {
                                write_control(&mut wr, &err(&format!("{e:#}"))).await?;
                                return Ok(());
                            }
                        }
                    }
                    None => None,
                },
            };
            let Some(handle) = handle else {
                write_control(&mut wr, &err("no such session")).await?;
                return Ok(());
            };
            run_attach(rd, wr, handle, manager, rows, cols).await
        }
        other => {
            write_control(&mut wr, &err(&format!("unexpected op: {other:?}"))).await?;
            Ok(())
        }
    }
}

/// Bridge one attached client to a session: PTY output → socket, socket input
/// → PTY. On disconnect the client is removed but the session lives on.
async fn run_attach(
    mut rd: tokio::net::unix::OwnedReadHalf,
    mut wr: tokio::net::unix::OwnedWriteHalf,
    handle: SessionHandle,
    manager: Manager,
    rows: u16,
    cols: u16,
) -> Result<()> {
    let client_id = manager.alloc_client_id();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<ClientEvent>();

    // Report the resolved id/name to the client.
    let name = {
        let (tx, rx) = oneshot::channel();
        handle.send(SessionMsg::Info { reply: tx });
        rx.await.map(|i| i.name).unwrap_or_else(|_| handle.id.clone())
    };
    write_control(
        &mut wr,
        &Control::Attached {
            id: handle.id.clone(),
            name,
        },
    )
    .await?;

    handle.send(SessionMsg::AddClient {
        id: client_id,
        out: out_tx,
    });
    // Honor this (newest) client's window immediately.
    handle.send(SessionMsg::Resize {
        id: client_id,
        rows,
        cols,
    });

    // Writer task: session events → socket frames.
    let writer = tokio::spawn(async move {
        while let Some(ev) = out_rx.recv().await {
            match ev {
                ClientEvent::Data(bytes) => {
                    if write_data(&mut wr, &bytes).await.is_err() {
                        break;
                    }
                }
                ClientEvent::Exited(status) => {
                    let _ = write_control(
                        &mut wr,
                        &Control::Exited {
                            id: String::new(),
                            status,
                        },
                    )
                    .await;
                    break;
                }
            }
        }
    });

    // Reader loop: socket frames → session messages.
    loop {
        match read_frame(&mut rd).await {
            Ok(Some(Frame::Data(data))) => {
                handle.send(SessionMsg::Input {
                    id: client_id,
                    data,
                });
            }
            Ok(Some(Frame::Resize { rows, cols })) => {
                handle.send(SessionMsg::Resize {
                    id: client_id,
                    rows,
                    cols,
                });
            }
            Ok(Some(Frame::Control(Control::Detach))) => break,
            Ok(Some(Frame::Control(_))) => break,
            Ok(None) => break, // client closed
            Err(_) => break,
        }
    }

    handle.send(SessionMsg::RemoveClient { id: client_id });
    writer.abort();
    Ok(())
}

fn err(message: &str) -> Control {
    Control::Error {
        message: message.to_string(),
    }
}
