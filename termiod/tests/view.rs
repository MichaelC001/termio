//! Acceptance for the host's view (`docs/design/20261025-termiod-owns-the-view.md`):
//! a registered project, a session placed in it at `create`, the `view:host`
//! resource, a kill that removes the pane, a view that survives a restart, and
//! a view seeded once from a client's tree.

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
        Connection::open_with(daemon, &["view", "resources", "events"])
    }

    fn open_with(daemon: &Daemon, caps: &[&str]) -> Connection {
        let mut stream = UnixStream::connect(&daemon.socket).expect("connect");
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .expect("read timeout");
        let hello = json!({
            "op": "hello", "proto": 1, "min_proto": 1, "role": "control",
            "caps": caps, "client": "view-test",
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
        vec![linked.clone()]
    );

    // A removal that agreed to end only other sessions is refused whole, and
    // the live session placed in the project keeps running.
    let refused = client.request(json!({
        "op": "project_remove", "project": project, "only": ["s_someone_else"],
    }));
    assert_eq!(refused["code"], "conflict", "{refused}");
    assert_eq!(
        sessions_in(&client.view()["projects"][0]["groups"][0]),
        vec![linked.clone()]
    );

    let removed = client.request(json!({
        "op": "project_remove", "project": project, "only": [linked],
    }));
    assert_eq!(removed["op"], "revised", "{removed}");
    assert_eq!(client.view()["projects"], json!([]));

    drop(client);
    drop(daemon);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Opens `name` the way the Mac app does, by `attach` with `create_if_missing`,
/// and leaves it running.
fn attach_create(daemon: &Daemon, name: &str, spec: Value) -> Value {
    let mut connection = Connection::open_with(daemon, &["view", "view_import"]);
    let reply = connection.request(json!({
        "op": "attach", "target": name, "create_if_missing": spec,
        "rows": 24, "cols": 80, "mode": "interact",
    }));
    assert_eq!(reply["op"], "attached", "{reply}");
    reply
}

fn id_of(connection: &mut Connection, name: &str) -> String {
    let list = connection.request(json!({"op": "list"}));
    list["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|info| info["name"] == json!(name))
        .unwrap_or_else(|| panic!("{name} in {list}"))["id"]
        .as_str()
        .unwrap()
        .to_string()
}

#[test]
fn a_client_seeds_the_view_once_and_places_what_it_opens() {
    let dir = format!("/tmp/termiod-view-import-{}", std::process::id());
    let _ = std::fs::remove_dir_all(&dir);
    let alpha = format!("{dir}/alpha");
    std::fs::create_dir_all(format!("{alpha}/src")).expect("checkout dir");
    let alpha = std::fs::canonicalize(&alpha)
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let gone = format!("{dir}/gone");

    let daemon = start_daemon(&dir);
    let mut client = Connection::open_with(&daemon, &["view", "view_import", "resources"]);
    let sleeper = |cwd: &str, place: Value| {
        json!({"cwd": cwd, "argv": ["/bin/sh", "-c", "sleep 60"], "place": place})
    };

    // Every session `attach` opens has a pane: before this, only `create` placed.
    attach_create(&daemon, "row-1", sleeper(&format!("{alpha}/src"), json!({"loose": true})));
    attach_create(
        &daemon,
        "row-2",
        sleeper(&alpha, json!({"project": "project:missing"})),
    );
    let created = client.request(json!({
        "op": "create", "name": "row-3", "cwd": "/", "argv": ["/bin/sh", "-c", "sleep 60"],
    }));
    assert_eq!(created["op"], "created", "{created}");
    let (one, two, three) = (
        id_of(&mut client, "row-1"),
        id_of(&mut client, "row-2"),
        id_of(&mut client, "row-3"),
    );
    let view = client.view();
    assert_eq!(view["projects"], json!([]));
    assert_eq!(view["loose"].as_array().unwrap().len(), 3, "{view}");
    assert!(view.get("seeded").is_none(), "{view}");

    let mut plain = Connection::open(&daemon);
    let denied = plain.request(json!({"op": "view_import", "projects": []}));
    assert_eq!(denied["code"], "denied", "{denied}");

    let imported = client.request(json!({
        "op": "view_import",
        "projects": [
            {"path": format!("{alpha}/"), "label": "Alpha", "pinned": true,
             "groups": [{"sessions": ["row-2", "row-3", "row-2"]}]},
            {"path": gone, "groups": [{"sessions": ["nobody"]}]},
        ],
        "loose": [{"label": "scratch", "sessions": ["row-1"]}],
    }));
    assert_eq!(imported["op"], "imported", "{imported}");
    let ids = imported["projects"].as_array().unwrap().clone();
    assert_eq!(ids.len(), 2, "{imported}");

    let view = client.view();
    assert_eq!(view["seeded"], json!(true), "{view}");
    let first = &view["projects"][0];
    assert_eq!(first["id"], ids[0]);
    assert_eq!(first["path"], json!(alpha), "the host's own spelling");
    assert_eq!(first["label"], json!("Alpha"));
    assert_eq!(first["pinned"], json!(true));
    assert_eq!(first["groups"].as_array().unwrap().len(), 1, "{view}");
    assert_eq!(sessions_in(&first["groups"][0]), vec![two.clone(), three.clone()]);
    // A folder that is gone keeps its row, with no panes to show.
    let second = &view["projects"][1];
    assert_eq!(second["path"], json!(gone));
    assert_eq!(second["groups"], json!([]));
    let loose = view["loose"].as_array().unwrap();
    assert_eq!(loose.len(), 1, "{view}");
    assert_eq!(loose[0]["label"], json!("scratch"));
    assert_eq!(sessions_in(&loose[0]), vec![one.clone()]);

    assert!(view["seed"].is_string(), "{view}");
    let pinned = client.request(json!({"op": "project_set", "project": ids[0], "pinned": false}));
    assert_eq!(pinned["op"], "revised", "{pinned}");
    let view = client.view();
    assert!(view["projects"][0].get("pinned").is_none(), "{view}");
    let missing = client.request(json!({"op": "project_set", "project": "project:missing", "pinned": true}));
    assert_eq!(missing["code"], "not_found", "{missing}");

    let again = client.request(json!({"op": "view_import", "projects": []}));
    assert_eq!(again["code"], "conflict", "only the first import is taken: {again}");
    assert_eq!(client.view(), view);

    // A new group goes where it is told, whatever its cwd.
    let grouped = client.request(json!({
        "op": "group_new", "project": ids[0], "label": "agent",
        "spec": {"cwd": "/", "argv": ["/bin/sh", "-c", "sleep 60"]},
    }));
    assert_eq!(grouped["op"], "group_created", "{grouped}");
    let loosely = client.request(json!({
        "op": "group_new", "spec": {"cwd": alpha, "argv": ["/bin/sh", "-c", "sleep 60"]},
    }));
    assert_eq!(loosely["op"], "group_created", "{loosely}");
    let refused = client.request(json!({
        "op": "group_new", "project": "project:missing",
        "spec": {"cwd": "/", "argv": ["/bin/true"]},
    }));
    assert_eq!(refused["code"], "not_found", "{refused}");
    let view = client.view();
    let groups = view["projects"][0]["groups"].as_array().unwrap();
    let agent = groups.last().unwrap();
    assert_eq!(agent["id"], grouped["group"]);
    assert_eq!(agent["label"], json!("agent"));
    assert_eq!(sessions_in(agent), vec![grouped["id"].as_str().unwrap().to_string()]);
    assert_eq!(
        sessions_in(view["loose"].as_array().unwrap().last().unwrap()),
        vec![loosely["id"].as_str().unwrap().to_string()]
    );

    // Once seeded, a project the attach names places the session in it, and
    // a cwd inside a project places it there unless the client says loose.
    attach_create(&daemon, "row-4", sleeper("/", json!({"project": ids[0]})));
    attach_create(&daemon, "row-5", sleeper(&alpha, json!({"loose": true})));
    let (four, five) = (id_of(&mut client, "row-4"), id_of(&mut client, "row-5"));
    let view = client.view();
    let in_alpha: Vec<String> = view["projects"][0]["groups"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(sessions_in)
        .collect();
    assert!(in_alpha.contains(&four), "{view}");
    assert!(!in_alpha.contains(&five), "{view}");

    // A name reopened after its session ended takes over that pane.
    let count = |view: &Value| view["projects"][0]["groups"].as_array().unwrap().len();
    attach_create(
        &daemon,
        "row-6",
        json!({"cwd": "/", "argv": ["/bin/sh", "-c", "sleep 0.5"], "place": {"project": ids[0]}}),
    );
    let ended = id_of(&mut client, "row-6");
    wait_until(
        || {
            let list = client.request(json!({"op": "list"}));
            !list["sessions"].as_array().unwrap().iter().any(|info| info["id"] == json!(ended))
        },
        "row-6 to exit",
    );
    let before = count(&client.view());
    attach_create(&daemon, "row-6", sleeper("/", json!({"project": ids[0]})));
    let reopened = id_of(&mut client, "row-6");
    let view = client.view();
    assert_eq!(count(&view), before, "no second pane: {view}");
    let shown: Vec<String> = view["projects"][0]["groups"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(sessions_in)
        .collect();
    assert!(shown.contains(&reopened) && !shown.contains(&ended), "{view}");

    // The seed survives a restart, so a client that comes back is refused too.
    drop(client);
    drop(plain);
    drop(daemon);
    let daemon = start_daemon(&dir);
    let mut client = Connection::open_with(&daemon, &["view", "view_import"]);
    let after = client.request(json!({"op": "view_import", "projects": []}));
    assert_eq!(after["code"], "conflict", "{after}");

    drop(client);
    drop(daemon);
    let _ = std::fs::remove_dir_all(&dir);
}
