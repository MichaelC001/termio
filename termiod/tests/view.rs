//! Acceptance for the host's view (`docs/design/20261025-termiod-owns-the-view.md`):
//! a registered project, a session placed in it at `create`, the `view:host`
//! resource, a kill that removes the pane, and a view that survives a restart.

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_termiod");

fn write_frame(w: &mut impl Write, kind: u8, payload: &[u8]) {
    let mut header = [0u8; 5];
    header[0] = kind;
    header[1..5].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    w.write_all(&header).unwrap();
    w.write_all(payload).unwrap();
    w.flush().unwrap();
}

fn read_frame(r: &mut impl Read) -> Option<(u8, Vec<u8>)> {
    let mut header = [0u8; 5];
    r.read_exact(&mut header).ok()?;
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload).ok()?;
    Some((header[0], payload))
}

struct Daemon {
    child: Child,
    socket: String,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The serve lock and the view file live beside the socket, so each test gets
/// its own directory and never touches a real daemon's state.
fn start_daemon(dir: &str) -> Daemon {
    let socket = format!("{dir}/termiod.sock");
    let _ = std::fs::remove_file(&socket);
    let child = Command::new(BIN)
        .arg("serve")
        .env("TERMIOD_SOCK", &socket)
        .env("TERMIOD_KEEP_AWAKE", "off")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    let deadline = Instant::now() + Duration::from_secs(5);
    while UnixStream::connect(&socket).is_err() {
        assert!(Instant::now() < deadline, "daemon never bound the socket");
        std::thread::sleep(Duration::from_millis(30));
    }
    Daemon { child, socket }
}

struct Connection {
    stream: UnixStream,
    next: u64,
}

impl Connection {
    fn open(daemon: &Daemon) -> Connection {
        let mut stream = UnixStream::connect(&daemon.socket).expect("connect");
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .expect("read timeout");
        let hello = json!({
            "op": "hello", "proto": 1, "min_proto": 1, "role": "control",
            "caps": ["view", "resources", "events"], "client": "view-test",
        });
        write_frame(&mut stream, b'C', hello.to_string().as_bytes());
        let reply = Connection::read_control(&mut stream);
        assert_eq!(reply["op"], "hello_ok", "{reply}");
        let caps = reply["caps"].as_array().expect("caps");
        assert!(
            caps.iter().any(|cap| cap == "view"),
            "the host advertises view: {reply}"
        );
        Connection { stream, next: 1 }
    }

    fn read_control(stream: &mut UnixStream) -> Value {
        loop {
            let (kind, payload) = read_frame(stream).expect("a frame");
            if kind == b'C' {
                return serde_json::from_slice(&payload).expect("control json");
            }
        }
    }

    fn request(&mut self, mut body: Value) -> Value {
        let seq = self.next;
        self.next += 1;
        body["seq"] = json!(seq);
        write_frame(&mut self.stream, b'C', body.to_string().as_bytes());
        let reply = Connection::read_control(&mut self.stream);
        assert_eq!(reply["re"], json!(seq), "{reply}");
        reply
    }

    fn view(&mut self) -> Value {
        let reply = self.request(json!({"op": "view"}));
        assert_eq!(reply["op"], "view_state", "{reply}");
        reply["view"].clone()
    }

    fn next_event(&mut self) -> Value {
        loop {
            let (kind, payload) = read_frame(&mut self.stream).expect("an event");
            if kind == b'E' {
                return serde_json::from_slice(&payload).expect("event json");
            }
        }
    }
}

fn sessions_in(group: &Value) -> Vec<String> {
    fn walk(node: &Value, out: &mut Vec<String>) {
        if let Some(pane) = node.get("pane") {
            out.push(pane["session"].as_str().unwrap_or_default().to_string());
        } else if let Some(split) = node.get("split") {
            walk(&split["before"], out);
            walk(&split["after"], out);
        }
    }
    let mut out = Vec::new();
    walk(&group["root"], &mut out);
    out
}

fn wait_until(mut condition: impl FnMut() -> bool, what: &str) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn a_project_holds_its_sessions_and_survives_a_restart() {
    let dir = format!("/tmp/termiod-view-test-{}", std::process::id());
    let _ = std::fs::remove_dir_all(&dir);
    let checkout = format!("{dir}/checkout");
    std::fs::create_dir_all(format!("{checkout}/src")).expect("checkout dir");
    let checkout = std::fs::canonicalize(&checkout)
        .unwrap()
        .to_string_lossy()
        .into_owned();

    let daemon = start_daemon(&dir);
    let mut client = Connection::open(&daemon);

    let added = client.request(json!({"op": "project_add", "path": checkout}));
    assert_eq!(added["op"], "project_added", "{added}");
    let project = added["project"].as_str().unwrap().to_string();
    let again = client.request(json!({"op": "project_add", "path": format!("{checkout}/")}));
    assert_eq!(
        again["project"],
        json!(project),
        "one directory is one project"
    );
    assert_eq!(
        again["revision"], added["revision"],
        "a repeat changes nothing"
    );

    let missing = client.request(json!({"op": "project_add", "path": format!("{dir}/nowhere")}));
    assert_eq!(missing["code"], "not_found", "{missing}");

    // A session whose cwd is inside the project lands in it without being told.
    let created = client.request(json!({
        "op": "create", "cwd": format!("{checkout}/src"), "argv": ["/bin/sh", "-c", "sleep 60"],
    }));
    assert_eq!(created["op"], "created", "{created}");
    let session = created["id"].as_str().unwrap().to_string();
    assert!(created["pane"].is_string(), "{created}");

    let refused = client.request(json!({
        "op": "create", "cwd": "/", "argv": ["/bin/true"], "place": {"project": "project:missing"},
    }));
    assert_eq!(refused["code"], "not_found", "{refused}");

    let view = client.view();
    let row = &view["projects"][0];
    assert_eq!(row["id"], json!(project));
    assert_eq!(row["path"], json!(checkout));
    assert_eq!(sessions_in(&row["groups"][0]), vec![session.clone()]);
    let revision = view["revision"].as_u64().unwrap();

    // The resource serves the whole view at its revision, then each change.
    let subscribed = client.request(json!({"op": "subscribe_resource", "resource": "view:host"}));
    assert_eq!(subscribed["op"], "subscribed", "{subscribed}");
    assert_eq!(subscribed["seq"].as_u64(), Some(revision));
    let first = client.next_event();
    assert_eq!(first["ev"], "view_changed", "{first}");
    assert_eq!(first["seq"].as_u64(), Some(revision));

    // A kill is a close: the pane goes, and the empty group with it.
    let mut control = Connection::open(&daemon);
    let killed = control.request(json!({"op": "kill", "id": session}));
    assert_eq!(killed["op"], "ok", "{killed}");
    let changed = client.next_event();
    assert_eq!(changed["ev"], "view_changed", "{changed}");
    assert_eq!(changed["seq"].as_u64(), Some(revision + 1));
    assert_eq!(changed["view"]["projects"][0]["groups"], json!([]));

    // A session that exits on its own keeps its pane.
    let exited = control.request(json!({
        "op": "create", "cwd": checkout, "argv": ["/bin/sh", "-c", "exit 0"],
    }));
    let exited = exited["id"]
        .as_str()
        .unwrap_or_else(|| panic!("{exited}"))
        .to_string();
    wait_until(
        || {
            let list = control.request(json!({"op": "list"}));
            !list["sessions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|info| info["id"] == json!(exited))
        },
        "the short session to exit",
    );
    let before_restart = control.view();
    assert_eq!(
        sessions_in(&before_restart["projects"][0]["groups"][0]),
        vec![exited.clone()]
    );

    drop(client);
    drop(control);
    drop(daemon);
    let daemon = start_daemon(&dir);
    let mut client = Connection::open(&daemon);
    let after_restart = client.view();
    assert_eq!(
        after_restart["projects"], before_restart["projects"],
        "the view survives a restart"
    );
    assert!(
        after_restart["revision"].as_u64() > before_restart["revision"].as_u64(),
        "a restarted host never reissues a revision: {after_restart}"
    );

    // The ended session's pane is cleared by closing the pane; a kill finds
    // no session to kill.
    let killed = client.request(json!({"op": "kill", "id": exited}));
    assert_eq!(killed["code"], "no_such_session", "{killed}");
    let pane = after_restart["projects"][0]["groups"][0]["root"]["pane"]["id"].clone();
    let closed = client.request(json!({"op": "pane_close", "pane": pane}));
    assert_eq!(closed["op"], "revised", "{closed}");
    assert_eq!(client.view()["projects"][0]["groups"], json!([]));
    let again = client.request(json!({"op": "pane_close", "pane": pane}));
    assert_eq!(again["code"], "not_found", "{again}");

    // A symlinked spelling of the project's directory still lands in it.
    let link = format!("{dir}/link");
    std::os::unix::fs::symlink(&checkout, &link).expect("symlink");
    let linked = client.request(json!({
        "op": "create", "cwd": link, "argv": ["/bin/sh", "-c", "sleep 60"],
    }));
    let linked = linked["id"]
        .as_str()
        .unwrap_or_else(|| panic!("{linked}"))
        .to_string();
    assert_eq!(
        sessions_in(&client.view()["projects"][0]["groups"][0]),
        vec![linked]
    );

    let removed = client.request(json!({"op": "project_remove", "project": project}));
    assert_eq!(removed["op"], "revised", "{removed}");
    assert_eq!(client.view()["projects"], json!([]));

    drop(client);
    drop(daemon);
    let _ = std::fs::remove_dir_all(&dir);
}
