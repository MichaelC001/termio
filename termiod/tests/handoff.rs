//! `termiod handoff` against a real daemon: the claim is that the process, its
//! children and their PTYs all survive a binary replacement, and the only way
//! to check that is to run one.
//!
//! The load-bearing assertion is not the exit code. It is the counter file: a
//! shell writing to it every tenth of a second stops the instant its PTY master
//! closes, because the slave side raises `SIGHUP` and nothing in the session
//! outlives that. A counter that is still moving after the daemon has replaced
//! its own image is the whole feature, observed from outside.

use serde_json::Value;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_termiod");

static DIRECTORIES: AtomicUsize = AtomicUsize::new(0);

struct TestDir(PathBuf);

impl TestDir {
    fn new() -> TestDir {
        let nonce = DIRECTORIES.fetch_add(1, Ordering::Relaxed);
        // Unix-domain socket paths are short on macOS; the per-user temporary
        // directory can consume most of that limit before the test adds a name.
        let path = PathBuf::from(format!("/tmp/tho-{}-{nonce}", std::process::id()));
        std::fs::create_dir(&path).expect("create isolated daemon state directory");
        TestDir(path)
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Daemon {
    child: Child,
}

impl Daemon {
    fn start(socket: &Path) -> Daemon {
        let mut child = Command::new(BIN)
            .arg("serve")
            .env("TERMIOD_SOCK", socket)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn isolated daemon");
        let deadline = Instant::now() + Duration::from_secs(5);
        while !socket.exists() {
            if let Some(status) = child.try_wait().expect("poll daemon startup") {
                let mut stderr = String::new();
                if let Some(mut stream) = child.stderr.take() {
                    let _ = stream.read_to_string(&mut stderr);
                }
                panic!("daemon exited {status} before binding its socket: {stderr}");
            }
            assert!(Instant::now() < deadline, "daemon never bound its socket");
            std::thread::sleep(Duration::from_millis(20));
        }
        Daemon { child }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // The daemon this test kills is the *original* pid, which is still the
        // pid after a handoff — the whole point. Killing the process group takes
        // the session's shell with it.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn termiod(socket: &Path, args: &[&str]) -> Output {
    Command::new(BIN)
        .args(args)
        .env("TERMIOD_SOCK", socket)
        .output()
        .expect("run termiod")
}

fn status(socket: &Path) -> Value {
    let output = termiod(socket, &["status", "--json"]);
    assert!(output.status.success(), "status failed: {output:?}");
    serde_json::from_slice(&output.stdout).expect("status is json")
}

/// `list --json` — `SessionInfo`, which carries the pid that `status` omits.
fn listed(socket: &Path) -> Vec<Value> {
    let output = termiod(socket, &["list", "--json"]);
    assert!(output.status.success(), "list failed: {output:?}");
    let parsed: Value = serde_json::from_slice(&output.stdout).expect("list is json");
    match parsed {
        Value::Array(sessions) => sessions,
        Value::Object(ref map) => map
            .get("sessions")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
        _ => Vec::new(),
    }
}

fn counter(path: &Path) -> u64 {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| text.trim().parse().ok())
        .unwrap_or(0)
}

/// Block until the session's shell has written at least `target`, so "it is
/// still running" is read from the process rather than from a sleep.
fn wait_for_counter(path: &Path, target: u64) -> u64 {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let seen = counter(path);
        if seen >= target {
            return seen;
        }
        assert!(
            Instant::now() < deadline,
            "the session stopped writing at {seen}, waiting for {target}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn a_handoff_keeps_the_pid_the_sessions_and_the_screen() {
    let dir = TestDir::new();
    let socket = dir.0.join("s");
    let tally = dir.0.join("tally");
    let daemon = Daemon::start(&socket);

    // A plain `sh` on the PTY, ticking in the background: the shell keeps
    // reading stdin — which is what makes "send it something after the
    // upgrade" a question that can be asked — while the loop keeps writing,
    // which is what makes "it never got a hangup" a question that can be
    // answered.
    let created = termiod(&socket, &["create", "--name", "carried", "--", "sh"]);
    assert!(created.status.success(), "create failed: {created:?}");

    let before = status(&socket);
    let daemon_pid = before["daemon"]["pid"].as_i64().expect("daemon pid");
    let sessions = before["sessions"].as_array().expect("sessions");
    assert_eq!(sessions.len(), 1, "{before}");
    let session_id = sessions[0]["id"].as_str().expect("session id").to_string();

    let sent = termiod(
        &socket,
        &["send", &session_id, "echo MARKER-BEFORE-HANDOFF"],
    );
    assert!(sent.status.success(), "send failed: {sent:?}");
    let ticker = format!(
        "(n=0; while :; do n=$((n+1)); echo $n > {}; sleep 0.1; done) &",
        tally.display()
    );
    let sent = termiod(&socket, &["send", &session_id, &ticker]);
    assert!(sent.status.success(), "send failed: {sent:?}");

    let ticks = wait_for_counter(&tally, 3);

    let handed = termiod(&socket, &["handoff", "--json"]);
    assert!(
        handed.status.success(),
        "handoff failed: {}",
        String::from_utf8_lossy(&handed.stderr)
    );
    let outcome: Value = serde_json::from_slice(&handed.stdout).expect("handoff is json");
    assert_eq!(outcome["pid"].as_i64(), Some(daemon_pid), "{outcome}");
    assert_eq!(outcome["sessions"].as_u64(), Some(1), "{outcome}");

    // Same process, not a replacement someone autostarted over the socket.
    let after = status(&socket);
    assert_eq!(after["daemon"]["pid"].as_i64(), Some(daemon_pid), "{after}");
    let carried = after["sessions"].as_array().expect("sessions after");
    assert_eq!(carried.len(), 1, "{after}");
    assert_eq!(
        carried[0]["id"].as_str(),
        Some(session_id.as_str()),
        "{after}"
    );
    assert_eq!(carried[0]["name"].as_str(), Some("carried"), "{after}");

    // The claim, in one assertion: the shell never saw a hangup.
    wait_for_counter(&tally, ticks + 5);

    // And it is still reachable — the new image is reading and writing the same
    // master, not merely holding a descriptor open.
    let marker = format!("touch {}", dir.0.join("typed").display());
    let sent = termiod(&socket, &["send", &session_id, &marker]);
    assert!(sent.status.success(), "send failed: {sent:?}");
    let typed = dir.0.join("typed");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !typed.exists() {
        assert!(
            Instant::now() < deadline,
            "the carried shell never ran what it was sent"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    // The replay ring crossed too: what the session printed before the upgrade
    // is what a client attaching after it is shown.
    assert!(
        observed(&socket, &session_id).contains("MARKER-BEFORE-HANDOFF"),
        "the screen from before the handoff was not replayed"
    );

    drop(daemon);
}

/// What an observer sees on attach — the ring the daemon replays. Read for a
/// moment and then stopped, because `attach --observe` streams forever.
fn observed(socket: &Path, session: &str) -> String {
    let mut child = Command::new(BIN)
        .args(["attach", session, "--observe", "--no-create"])
        .env("TERMIOD_SOCK", socket)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn observer");
    std::thread::sleep(Duration::from_millis(750));
    let _ = child.kill();
    let mut seen = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        let _ = stdout.read_to_string(&mut seen);
    }
    let _ = child.wait();
    seen
}

/// A handoff to something that is not a working termiod is refused before the
/// daemon takes a single session apart — so the refusal costs nothing, and the
/// daemon that refuses is still the daemon that was running.
///
/// The impostor here is the dangerous shape, not the obvious one: it exits 0
/// and prints a plausible version, which is all `--version` ever proved. Only
/// the handoff contract itself tells it apart from a real termiod — and an
/// older termiod, which answers `--version` and has never heard of
/// `serve --handoff`, is the same case wearing the right name.
#[test]
fn a_binary_that_cannot_adopt_is_refused_and_changes_nothing() {
    let dir = TestDir::new();
    let socket = dir.0.join("s");
    let daemon = Daemon::start(&socket);

    let created = termiod(&socket, &["create", "--name", "kept", "--", "sleep", "300"]);
    assert!(created.status.success(), "create failed: {created:?}");
    let before = status(&socket);
    let daemon_pid = before["daemon"]["pid"].as_i64().expect("daemon pid");

    let impostor = dir.0.join("not-termiod");
    std::fs::write(
        &impostor,
        "#!/bin/sh\ncase \"$1\" in --version) echo 'termiod 9.9.9+9999'; exit 0;; esac\nexit 0\n",
    )
    .expect("write impostor");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&impostor, std::fs::Permissions::from_mode(0o755))
            .expect("chmod impostor");
    }

    let refused = termiod(
        &socket,
        &["handoff", "--binary", impostor.to_str().expect("path")],
    );
    assert!(
        !refused.status.success(),
        "the impostor was accepted: {refused:?}"
    );

    let after = status(&socket);
    assert_eq!(after["daemon"]["pid"].as_i64(), Some(daemon_pid), "{after}");
    assert_eq!(
        after["sessions"].as_array().map(Vec::len),
        Some(1),
        "the refused handoff cost a session: {after}"
    );

    drop(daemon);
}

/// The vet's contract, stated as the thing it actually checks. A binary that
/// answers `--version` convincingly and knows nothing about handing off is
/// refused; the real one is accepted.
#[test]
fn the_probe_is_what_separates_a_termiod_from_a_convincing_impostor() {
    let dir = TestDir::new();
    let impostor = dir.0.join("impostor");
    std::fs::write(
        &impostor,
        "#!/bin/sh\ncase \"$1\" in --version) echo 'termiod 9.9.9+9999'; exit 0;; esac\nexit 0\n",
    )
    .expect("write impostor");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&impostor, std::fs::Permissions::from_mode(0o755))
            .expect("chmod impostor");
    }
    let version = Command::new(&impostor)
        .arg("--version")
        .output()
        .expect("run impostor");
    assert!(
        version.status.success(),
        "the impostor should pass --version"
    );

    let probe = Command::new(BIN)
        .args(["handoff", "--probe"])
        .output()
        .expect("probe the real binary");
    assert!(probe.status.success());
    let token = String::from_utf8_lossy(&probe.stdout).trim().to_string();
    assert!(token.starts_with("termiod-handoff "), "{token}");

    let impostor_probe = Command::new(&impostor)
        .args(["handoff", "--probe"])
        .output()
        .expect("probe the impostor");
    assert_ne!(
        String::from_utf8_lossy(&impostor_probe.stdout).trim(),
        token,
        "the impostor answered the handoff contract"
    );
}

/// The invariant that must hold however a handoff goes: a session is either in
/// the roster or its process is gone. Never both absent.
///
/// A carried master that reaches the new image without a session around it
/// would break exactly this — the program would keep running, un-hung-up, in a
/// session nothing can list, attach to, or kill. That is why the descriptor is
/// handed over owned; dropping it is what turns a session that cannot be
/// carried into an ordinary loss.
#[test]
fn a_session_is_either_listed_or_gone_never_both() {
    let dir = TestDir::new();
    let socket = dir.0.join("s");
    let daemon = Daemon::start(&socket);

    let created = termiod(&socket, &["create", "--name", "kept", "--", "sh"]);
    assert!(created.status.success(), "create failed: {created:?}");
    let session_pid = listed(&socket)[0]["pid"].as_i64().expect("session pid");
    let daemon_pid = status(&socket)["daemon"]["pid"]
        .as_i64()
        .expect("daemon pid");

    let handed = termiod(&socket, &["handoff", "--json"]);
    assert!(handed.status.success(), "handoff failed: {handed:?}");
    assert_eq!(
        status(&socket)["daemon"]["pid"].as_i64(),
        Some(daemon_pid),
        "the daemon was replaced rather than handed off"
    );

    let sessions = listed(&socket);
    let accounted = sessions
        .iter()
        .any(|session| session["pid"].as_i64() == Some(session_pid));
    let alive = unsafe { libc::kill(session_pid as i32, 0) } == 0;
    assert!(
        accounted || !alive,
        "pid {session_pid} is running but no session accounts for it: {sessions:?}"
    );
    assert!(accounted, "the session should have survived: {sessions:?}");

    drop(daemon);
}

/// A carried session whose ring can no longer draw its own screen must not have
/// the host claim otherwise. The daemon answers such a snapshot by falling back
/// to ring replay — the client's terminal interpreting bytes it was handed —
/// rather than asserting a grid it reconstructed from an incomplete replay.
#[test]
fn a_resized_session_does_not_come_back_with_a_confidently_wrong_screen() {
    let dir = TestDir::new();
    let socket = dir.0.join("s");
    let daemon = Daemon::start(&socket);

    let created = termiod(&socket, &["create", "--name", "resized", "--", "sh"]);
    assert!(created.status.success(), "create failed: {created:?}");
    let before = status(&socket);
    let session_id = before["sessions"][0]["id"]
        .as_str()
        .expect("session id")
        .to_string();

    let sent = termiod(&socket, &["send", &session_id, "echo MARKER-BEFORE-RESIZE"]);
    assert!(sent.status.success(), "send failed: {sent:?}");

    // An observer attaching at a different size is what moves the session off
    // the geometry its ring was written at.
    let _ = observed(&socket, &session_id);

    let handed = termiod(&socket, &["handoff", "--json"]);
    assert!(handed.status.success(), "handoff failed: {handed:?}");

    // The session is still there and still driveable — degrading the snapshot
    // must not degrade the session.
    let marker = format!("touch {}", dir.0.join("after-resize").display());
    let sent = termiod(&socket, &["send", &session_id, &marker]);
    assert!(sent.status.success(), "send failed: {sent:?}");
    let typed = dir.0.join("after-resize");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !typed.exists() {
        assert!(
            Instant::now() < deadline,
            "the carried shell stopped responding after the handoff"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    drop(daemon);
}
