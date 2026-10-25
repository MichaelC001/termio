//! `termio session` with no Termio app: every verb that can act on a session
//! goes to this machine's termiod, and `--host` hands the typed words to the
//! host's own termio.
//!
//! Each test gets its own `HOME`, so no app socket exists, and its own daemon
//! directory, so the serve lock beside the socket is never shared.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_termiod");
const CLIENT: &str = env!("CARGO_BIN_EXE_termio");

struct Daemon {
    child: Child,
    home: PathBuf,
    socket: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

fn start_daemon(tag: &str) -> Daemon {
    // Short, under /tmp: a Unix socket path has a 104-byte limit on macOS.
    let home = PathBuf::from(format!("/tmp/termio-routing-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).expect("a home directory");
    let socket = home.join("d.sock");
    let child = Command::new(BIN)
        .arg("serve")
        .env("HOME", &home)
        .env("TERMIOD_SOCK", &socket)
        .env("TERMIOD_KEEP_AWAKE", "off")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        assert!(Instant::now() < deadline, "daemon never bound the socket");
        std::thread::sleep(Duration::from_millis(30));
    }
    Daemon {
        child,
        home,
        socket,
    }
}

fn termio(daemon: &Daemon, args: &[&str]) -> Output {
    Command::new(CLIENT)
        .args(args)
        .env("HOME", &daemon.home)
        .env("TERMIOD_SOCK", &daemon.socket)
        .env_remove("TERMIO_SESSION")
        .env_remove("TERMIO_CHANNEL")
        .env_remove("TERMIO_SESSION_CHANNEL")
        .stdin(Stdio::null())
        .output()
        .expect("run termio")
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// Polls `read` until the screen holds `needle`; the program writes after the
/// command returns.
fn screen_shows(daemon: &Daemon, target: &str, needle: &str) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let read = termio(daemon, &["session", "read", target]);
        if read.status.success() && stdout(&read).contains(needle) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    false
}

#[test]
fn without_the_app_every_session_verb_goes_to_termiod() {
    let daemon = start_daemon("verbs");

    let created = termio(&daemon, &["session", "create", "--name", "build", "--json", "--", "/bin/cat"]);
    assert!(created.status.success(), "create failed: {created:?}");
    let reply: serde_json::Value = serde_json::from_slice(&created.stdout).expect("create --json");
    assert_eq!(reply["ok"], true);

    // `ls` lists the daemon's sessions, because there is no project to scope to.
    let listed = termio(&daemon, &["session", "ls"]);
    assert!(listed.status.success(), "ls failed: {listed:?}");
    assert!(stdout(&listed).contains("build"), "ls: {}", stdout(&listed));

    let sent = termio(&daemon, &["session", "send", "build", "routed-to-termiod"]);
    assert!(sent.status.success(), "send failed: {sent:?}");
    assert!(screen_shows(&daemon, "build", "routed-to-termiod"));

    // Named keys need the app's encoder; the daemon must refuse, not type text.
    let keyed = termio(&daemon, &["session", "send", "build", "--key", "escape"]);
    assert!(!keyed.status.success(), "--key without the app must fail");

    let closed = termio(&daemon, &["session", "close", "build"]);
    assert!(closed.status.success(), "close failed: {closed:?}");
    let listed = termio(&daemon, &["session", "ls", "--json"]);
    let reply: serde_json::Value = serde_json::from_slice(&listed.stdout).expect("ls --json");
    assert_eq!(reply["schema_version"], 1);
    assert_eq!(reply["sessions"].as_array().map(Vec::len), Some(0), "close left: {reply}");

    let missing = termio(&daemon, &["session", "send", "build", "x"]);
    assert!(!missing.status.success(), "a send to no session must fail");
}

#[test]
fn run_without_the_app_starts_a_session_on_termiod() {
    let daemon = start_daemon("run");
    let ran = termio(&daemon, &["session", "run", "--json", "echo ran-on-termiod; cat"]);
    assert!(ran.status.success(), "run failed: {ran:?}");
    let reply: serde_json::Value = serde_json::from_slice(&ran.stdout).expect("run --json");
    let id = reply["id"].as_str().expect("an id").to_string();
    assert!(screen_shows(&daemon, &id, "ran-on-termiod"));

    let placed = termio(&daemon, &["session", "run", "--direction", "down", "true"]);
    assert!(!placed.status.success(), "placing a pane needs the app");
}

/// The old names still parse: shipped hooks, skills and apps run them.
#[test]
fn the_old_names_still_work() {
    let daemon = start_daemon("aliases");
    let created = termio(&daemon, &["server", "create", "--name", "old", "--", "/bin/cat"]);
    assert!(created.status.success(), "server create failed: {created:?}");
    let listed = termio(&daemon, &["sessions", "list"]);
    assert!(stdout(&listed).contains("old"), "sessions list: {listed:?}");
    let listed = termio(&daemon, &["server", "ls"]);
    assert!(stdout(&listed).contains("old"), "server ls: {listed:?}");
    let killed = termio(&daemon, &["server", "kill", "old"]);
    assert!(killed.status.success(), "server kill failed: {killed:?}");
}

/// `--host` anywhere on the line hands the rest of the words, unchanged, to
/// the host's termio. A fake `ssh` prints what it was asked to run.
#[test]
fn host_runs_the_same_words_on_the_host() {
    let daemon = start_daemon("host");
    let bin = daemon.home.join("bin");
    std::fs::create_dir_all(&bin).expect("a bin directory");
    let ssh = bin.join("ssh");
    std::fs::write(&ssh, "#!/bin/sh\nfor word in \"$@\"; do printf '%s\\n' \"$word\"; done\n")
        .expect("a fake ssh");
    make_executable(&ssh);
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());

    let run = |args: &[&str]| -> String {
        let output = Command::new(CLIENT)
            .args(args)
            .env("HOME", &daemon.home)
            .env("PATH", &path)
            .env("TERMIOD_SOCK", &daemon.socket)
            .stdin(Stdio::null())
            .output()
            .expect("run termio");
        assert!(output.status.success(), "{args:?}: {output:?}");
        stdout(&output)
    };

    let remote = run(&["-H", "box", "session", "ls", "--all"]);
    let lines: Vec<&str> = remote.lines().collect();
    assert!(lines.contains(&"box"), "ssh host: {remote}");
    let command = lines.last().expect("a remote command");
    assert!(command.ends_with(" session ls --all"), "remote command: {command}");

    let remote = run(&["server", "--host", "box", "status", "--json"]);
    assert!(remote.trim_end().ends_with(" server status --json"), "remote command: {remote}");

    let refused = Command::new(CLIENT)
        .args(["-H", "box", "open"])
        .env("HOME", &daemon.home)
        .env("PATH", &path)
        .output()
        .expect("run termio");
    assert!(!refused.status.success(), "`open` with --host must refuse");
}

/// A stand-in for the app's control socket that answers every request with
/// success and counts them.
fn fake_app(home: &Path) -> std::sync::Arc<std::sync::atomic::AtomicUsize> {
    use std::io::{Read, Write};
    use std::sync::atomic::{AtomicUsize, Ordering};
    let directory = home.join("Library/Application Support/termio");
    std::fs::create_dir_all(&directory).expect("the app's support directory");
    let listener =
        std::os::unix::net::UnixListener::bind(directory.join("app.sock")).expect("bind app.sock");
    let requests = std::sync::Arc::new(AtomicUsize::new(0));
    let counted = requests.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let mut request = [0u8; 4096];
            let _ = stream.read(&mut request);
            counted.fetch_add(1, Ordering::SeqCst);
            let _ = stream.write_all(b"{\"ok\":true}\n");
        }
    });
    requests
}

/// With the app running, a session the app made (a UUID name) is the app's to
/// drive, and a session only termiod holds by another name is termiod's.
#[test]
fn with_the_app_a_session_it_did_not_make_goes_to_termiod() {
    use std::sync::atomic::Ordering;
    let daemon = start_daemon("app");
    let created = termio(&daemon, &["session", "create", "--name", "headless", "--", "/bin/cat"]);
    assert!(created.status.success(), "create failed: {created:?}");
    let app = fake_app(&daemon.home);

    let sent = termio(&daemon, &["session", "send", "headless", "to-the-daemon"]);
    assert!(sent.status.success(), "send failed: {sent:?}");
    assert_eq!(app.load(Ordering::SeqCst), 0, "a termiod-only session reached the app");
    assert!(screen_shows(&daemon, "headless", "to-the-daemon"));

    let sent = termio(&daemon, &["session", "send", "8de0b387", "to-the-app"]);
    assert!(sent.status.success(), "send failed: {sent:?}");
    assert_eq!(app.load(Ordering::SeqCst), 1, "an app session did not reach the app");

    let listed = termio(&daemon, &["session", "ls"]);
    assert!(listed.status.success(), "ls failed: {listed:?}");
    assert_eq!(app.load(Ordering::SeqCst), 2, "`ls` with the app running asks the app");

    let closed = termio(&daemon, &["session", "close", "headless"]);
    assert!(closed.status.success(), "close failed: {closed:?}");
    assert_eq!(app.load(Ordering::SeqCst), 2, "closing a termiod-only session reached the app");
}

fn make_executable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
}
