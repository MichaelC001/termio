//! `termiod status` and `termiod stop` against a real daemon on an isolated
//! socket — the node half of the lifecycle loop, exercised the way the control
//! plane runs it: as the binary on disk, over the canonical socket.

use serde_json::Value;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const BIN: &str = env!("CARGO_BIN_EXE_termiod");
const VERSION: &str = env!("TERMIOD_VERSION");

struct TestDir(PathBuf);

impl TestDir {
    fn new() -> TestDir {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before epoch")
            .as_nanos();
        // Unix-domain socket paths are short on macOS; the per-user temporary
        // directory can consume most of that limit before the test adds a name.
        let path = PathBuf::from(format!("/tmp/tlc-{}-{nonce:x}", std::process::id()));
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

    fn wait_exit(&mut self) -> bool {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if self.child.try_wait().expect("poll daemon").is_some() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        false
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
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

fn json(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
        panic!(
            "stdout is not JSON ({error}): {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    })
}

/// One process, one connection: the report names this build for the binary
/// and the daemon, finds the daemon's pid from the socket, and reports its
/// sessions. Without a daemon it still reports the binary, and says so.
#[test]
fn status_reports_the_binary_the_daemon_and_its_sessions() {
    let dir = TestDir::new();
    let socket = dir.0.join("d.sock");

    let before = termiod(&socket, &["status", "--json"]);
    assert!(before.status.success());
    let report = json(&before);
    assert_eq!(report["binary"]["version"], VERSION);
    assert_eq!(report["daemon"]["running"], false);
    assert!(report["daemon"]["version"].is_null());

    let daemon = Daemon::start(&socket);
    let created = termiod(&socket, &["create", "--name", "shell", "--", "sleep", "300"]);
    assert!(created.status.success(), "{}", String::from_utf8_lossy(&created.stderr));

    let during = termiod(&socket, &["status", "--json"]);
    assert!(during.status.success(), "{}", String::from_utf8_lossy(&during.stderr));
    let report = json(&during);
    assert_eq!(report["daemon"]["running"], true);
    assert_eq!(report["daemon"]["version"], VERSION);
    assert_eq!(report["daemon"]["pid"], daemon.child.id());
    assert_eq!(report["sessions"].as_array().map(Vec::len), Some(1));
    assert_eq!(report["sessions"][0]["name"], "shell");
    assert_eq!(report["sessions"][0]["attached"], 0);
    assert!(report["host_id"].as_str().is_some_and(|id| !id.is_empty()));
}

/// An idle daemon — sessions, but nobody attached and no agent mid-task —
/// leaves on request, and the socket is gone once it has.
#[test]
fn stop_takes_an_idle_daemon_down() {
    let dir = TestDir::new();
    let socket = dir.0.join("d.sock");
    let mut daemon = Daemon::start(&socket);
    let created = termiod(&socket, &["create", "--name", "shell", "--", "sleep", "300"]);
    assert!(created.status.success());

    let stopped = termiod(&socket, &["stop", "--json"]);
    assert!(stopped.status.success(), "{}", String::from_utf8_lossy(&stopped.stderr));
    assert_eq!(json(&stopped)["stopped"], true);
    assert!(daemon.wait_exit(), "daemon still running after stop");
    assert!(!socket.exists(), "socket left behind after stop");

    // Nothing running is the state wanted, so asking again is success.
    let again = termiod(&socket, &["stop", "--json"]);
    assert!(again.status.success());
    assert_eq!(json(&again)["stopped"], true);
}

/// A session whose agent reports `working` keeps the daemon up, and the
/// refusal names it: the decision is the user's, and a count cannot inform
/// it. `--force` overrides.
#[test]
fn stop_declines_while_an_agent_is_mid_task_unless_forced() {
    let dir = TestDir::new();
    let socket = dir.0.join("d.sock");
    let mut daemon = Daemon::start(&socket);
    let created = termiod(&socket, &["create", "--name", "claude", "--", "sleep", "300"]);
    assert!(created.status.success());
    let id = String::from_utf8_lossy(&created.stdout).trim().to_string();
    let marked = termiod(&socket, &["set-status", &id, "working"]);
    assert!(marked.status.success(), "{}", String::from_utf8_lossy(&marked.stderr));

    let declined = termiod(&socket, &["stop", "--json"]);
    assert_eq!(declined.status.code(), Some(3), "{}", String::from_utf8_lossy(&declined.stderr));
    let report = json(&declined);
    assert_eq!(report["stopped"], false);
    assert_eq!(report["busy"][0]["name"], "claude");
    assert_eq!(report["busy"][0]["status"], "working");
    assert!(daemon.child.try_wait().expect("poll").is_none(), "daemon exited on a declined stop");

    let forced = termiod(&socket, &["stop", "--force", "--json"]);
    assert!(forced.status.success(), "{}", String::from_utf8_lossy(&forced.stderr));
    assert!(daemon.wait_exit(), "daemon still running after --force");
}
