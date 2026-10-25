//! The `vt_stream` plane against a real daemon, PTY and program.
//!
//! A client that decodes the attach snapshot and then applies the raw bytes
//! and the `vt_resize` markers it is sent must hold the host's screen exactly,
//! with no keyframe after the attach. The program redraws an input box with
//! relative cursor moves on every SIGWINCH, the way an agent's composer does —
//! the redraw that lands a row off when a client's VT is the wrong size at the
//! wrong byte.
//!
//! The host's screen is read through a second attachment in observe mode,
//! which never resizes the session: its own attach snapshot is the host VT at
//! that moment.

use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use termiod_vt::VtTerminal;

const BIN: &str = env!("CARGO_BIN_EXE_termiod");
const CLIENT: &str = env!("CARGO_BIN_EXE_termio");
const QUIET: Duration = Duration::from_millis(800);

const COMPOSER: &str = r#"
import shutil, signal, sys, time
drawn = 0
def draw(*_):
    global drawn
    cols, rows = shutil.get_terminal_size()
    out = ""
    if drawn:
        out += "\x1b[%dA\r\x1b[J" % (drawn - 1)
    rule = "─" * cols
    lines = [rule, "❯ draft 你呢 %dx%d" % (cols, rows), rule]
    out += "\r\n".join(lines)
    drawn = len(lines)
    sys.stdout.write(out)
    sys.stdout.flush()
signal.signal(signal.SIGWINCH, draw)
for i in range(30):
    sys.stdout.write("\x1b[3%dmline %d\x1b[0m %s\r\n" % (i % 7 + 1, i, "x" * (i * 3)))
draw()
while True:
    time.sleep(0.2)
"#;

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
    directory: std::path::PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

/// Each daemon in a directory of its own: the daemon locks a file beside its
/// socket, so two tests sharing /tmp would wait on each other's lock.
fn start_daemon(tag: &str) -> Daemon {
    let directory = std::env::temp_dir().join(format!("termiod-vt-stream-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).unwrap();
    let socket = directory.join("termiod.sock").to_string_lossy().to_string();
    let child = Command::new(BIN)
        .arg("serve")
        .env("TERMIOD_SOCK", &socket)
        .env("TERMIOD_KEEP_AWAKE", "off")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !std::path::Path::new(&socket).exists() {
        assert!(Instant::now() < deadline, "daemon never bound the socket");
        std::thread::sleep(Duration::from_millis(30));
    }
    Daemon {
        child,
        socket,
        directory,
    }
}

struct Client {
    bridge: Child,
    to_bridge: std::process::ChildStdin,
    frames: mpsc::Receiver<(u8, Vec<u8>)>,
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.bridge.kill();
        let _ = self.bridge.wait();
    }
}

fn attach(socket: &str, session: &str, rows: u16, cols: u16, mode: &str) -> Client {
    let mut bridge = Command::new(CLIENT)
        .args(["stdio"])
        .env("TERMIOD_SOCK", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn stdio bridge");
    let mut to_bridge = bridge.stdin.take().expect("bridge stdin");
    let mut from_bridge = bridge.stdout.take().expect("bridge stdout");
    let hello = r#"{"op":"hello","proto":1,"min_proto":1,"role":"attach","caps":["snapshot","events","vt_stream"],"client":"vt-stream-test"}"#;
    write_frame(&mut to_bridge, b'C', hello.as_bytes());
    let (kind, payload) = read_frame(&mut from_bridge).expect("hello reply");
    assert_eq!(kind, b'C');
    let reply = String::from_utf8_lossy(&payload).to_string();
    assert!(
        reply.contains("\"op\":\"hello_ok\""),
        "expected hello_ok, got {reply}"
    );
    assert!(
        reply.contains("vt_stream"),
        "the host did not grant vt_stream: {reply}"
    );
    let attach = format!(
        r#"{{"op":"attach","target":"{session}","rows":{rows},"cols":{cols},"mode":"{mode}"}}"#
    );
    write_frame(&mut to_bridge, b'C', attach.as_bytes());
    let (frames, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        while let Some(frame) = read_frame(&mut from_bridge) {
            if frames.send(frame).is_err() {
                return;
            }
        }
    });
    Client {
        bridge,
        to_bridge,
        frames: receiver,
    }
}

/// The client half of the plane: one VT, replaced on every `S`, fed every
/// `D`, and resized exactly where a `vt_resize` marker says.
struct Model {
    terminal: Option<VtTerminal>,
    snapshots: usize,
    markers: usize,
}

impl Model {
    fn new() -> Self {
        Model {
            terminal: None,
            snapshots: 0,
            markers: 0,
        }
    }

    fn apply(&mut self, kind: u8, payload: &[u8]) {
        match kind {
            b'S' => {
                self.snapshots += 1;
                let rows = u16::from_be_bytes([payload[1], payload[2]]);
                let cols = u16::from_be_bytes([payload[3], payload[4]]);
                let title_len = usize::from(u16::from_be_bytes([payload[10], payload[11]]));
                let body = &payload[12 + title_len + 4..];
                self.terminal = Some(match payload[0] {
                    4 => VtTerminal::from_native_snapshot(body).expect("decode native snapshot"),
                    2 => {
                        let mut fresh = VtTerminal::new(rows, cols).expect("fresh terminal");
                        fresh.vt_write(body);
                        fresh
                    }
                    other => panic!("a vt_stream client was sent snapshot format {other}"),
                });
            }
            b'D' => self
                .terminal
                .as_mut()
                .expect("data before the attach snapshot")
                .vt_write(payload),
            b'E' => {
                let event: serde_json::Value = serde_json::from_slice(payload).expect("event json");
                if event["ev"] == "vt_resize" {
                    self.markers += 1;
                    let rows = event["rows"].as_u64().expect("rows") as u16;
                    let cols = event["cols"].as_u64().expect("cols") as u16;
                    let terminal = self.terminal.as_mut().expect("marker before the snapshot");
                    let resized = if event["reflow"].as_bool().expect("reflow") {
                        terminal.resize_reflowing(rows, cols)
                    } else {
                        terminal.resize_for_shell(rows, cols)
                    };
                    resized.expect("apply marker");
                }
            }
            _ => {}
        }
    }

    /// Applies everything the client is sent until the stream goes quiet.
    fn settle(&mut self, client: &Client) {
        while let Ok((kind, payload)) = client.frames.recv_timeout(QUIET) {
            self.apply(kind, &payload);
        }
    }
}

/// The host VT right now: an observer's attach snapshot, decoded.
fn host_screen(socket: &str, session: &str) -> (Vec<u8>, termiod_vt::Snapshot) {
    let observer = attach(socket, session, 0, 0, "observe");
    let mut model = Model::new();
    model.settle(&observer);
    let terminal = model
        .terminal
        .as_mut()
        .expect("the observer got no snapshot");
    (terminal.format_vt().unwrap(), terminal.snapshot().unwrap())
}

#[test]
fn a_stream_client_holds_the_host_screen_through_resizes_with_no_keyframe() {
    let daemon = start_daemon("composer");
    let script = std::env::temp_dir().join(format!("vt-stream-composer-{}.py", std::process::id()));
    std::fs::write(&script, COMPOSER).unwrap();
    let created = Command::new(CLIENT)
        .args([
            "server",
            "create",
            "--name",
            "composer",
            "--",
            "/usr/bin/env",
            "python3",
        ])
        .arg(&script)
        .env("TERMIOD_SOCK", &daemon.socket)
        .output()
        .expect("create session");
    assert!(created.status.success(), "create failed: {created:?}");

    let mut client = attach(&daemon.socket, "composer", 24, 80, "interact");
    let mut model = Model::new();
    model.settle(&client);
    assert_eq!(model.snapshots, 1, "the attach owes exactly one snapshot");

    for (rows, cols) in [(20, 60), (12, 40), (30, 100), (8, 30), (24, 80)] {
        let mut viewport = Vec::with_capacity(4);
        viewport.extend_from_slice(&u16::to_be_bytes(rows));
        viewport.extend_from_slice(&u16::to_be_bytes(cols));
        write_frame(&mut client.to_bridge, b'R', &viewport);
        model.settle(&client);

        let (host_vt, host_cells) = host_screen(&daemon.socket, "composer");
        let terminal = model.terminal.as_mut().unwrap();
        assert_eq!(
            terminal.snapshot().unwrap(),
            host_cells,
            "the client's cells left the host's after resizing to {rows}x{cols}"
        );
        assert_eq!(
            terminal.format_vt().unwrap(),
            host_vt,
            "the client's screen left the host's after resizing to {rows}x{cols}"
        );
    }
    assert_eq!(
        model.snapshots, 1,
        "a resize sent a vt_stream client a keyframe"
    );
    assert!(
        model.markers >= 5,
        "only {} vt_resize markers for 5 resizes",
        model.markers
    );
    let _ = std::fs::remove_file(&script);
}

fn granted(socket: &str, offered: &[&str]) -> Vec<String> {
    let mut bridge = Command::new(CLIENT)
        .args(["stdio"])
        .env("TERMIOD_SOCK", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn stdio bridge");
    let mut to_bridge = bridge.stdin.take().expect("bridge stdin");
    let mut from_bridge = bridge.stdout.take().expect("bridge stdout");
    let hello = serde_json::json!({
        "op": "hello", "proto": 1, "min_proto": 1, "role": "attach",
        "caps": offered, "client": "vt-stream-test",
    });
    write_frame(&mut to_bridge, b'C', hello.to_string().as_bytes());
    let (_, payload) = read_frame(&mut from_bridge).expect("hello reply");
    let reply: serde_json::Value = serde_json::from_slice(&payload).expect("hello json");
    let caps = reply["caps"]
        .as_array()
        .expect("caps")
        .iter()
        .filter_map(|cap| cap.as_str().map(str::to_string))
        .collect();
    let _ = bridge.kill();
    let _ = bridge.wait();
    caps
}

/// vt_stream and grid_diff are two planes, and an attachment reads one; the
/// exact one is granted, so the client is never told it has a plane it won't get.
#[test]
fn vt_stream_and_grid_diff_are_never_granted_together() {
    let daemon = start_daemon("planes");
    let caps = granted(&daemon.socket, &["snapshot", "events", "grid_diff", "vt_stream"]);
    assert!(caps.iter().any(|cap| cap == "vt_stream"), "vt_stream was not granted: {caps:?}");
    assert!(!caps.iter().any(|cap| cap == "grid_diff"), "both planes were granted: {caps:?}");
}

/// vt_stream resizes through an event, so a client that did not take the event
/// plane is not granted it: it would never see a marker.
#[test]
fn vt_stream_is_not_granted_without_events() {
    let daemon = start_daemon("caps");
    let mut bridge = Command::new(CLIENT)
        .args(["stdio"])
        .env("TERMIOD_SOCK", &daemon.socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn stdio bridge");
    let mut to_bridge = bridge.stdin.take().expect("bridge stdin");
    let mut from_bridge = bridge.stdout.take().expect("bridge stdout");
    let hello = r#"{"op":"hello","proto":1,"min_proto":1,"role":"attach","caps":["snapshot","vt_stream"],"client":"vt-stream-test"}"#;
    write_frame(&mut to_bridge, b'C', hello.as_bytes());
    let (_, payload) = read_frame(&mut from_bridge).expect("hello reply");
    let reply: serde_json::Value = serde_json::from_slice(&payload).expect("hello json");
    let caps: Vec<&str> = reply["caps"].as_array().expect("caps").iter().filter_map(|cap| cap.as_str()).collect();
    assert!(caps.contains(&"snapshot"), "snapshot was not granted: {caps:?}");
    assert!(!caps.contains(&"vt_stream"), "vt_stream was granted without events: {caps:?}");
    let _ = bridge.kill();
    let _ = bridge.wait();
}
