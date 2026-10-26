//! `termio session` with no Termio app: every verb that can act on a session
//! goes to this machine's termiod, and `--host` hands the typed words to the
//! host's own termio.
//!
//! Each test gets its own `HOME`, so no app socket exists, and its own daemon
//! directory, so the serve lock beside the socket is never shared. Every
//! client runs on its own channel, `routingtest`, whose app is never a running
//! process — a real Termio on this Mac cannot make a fake app socket look
//! alive.

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
        .env("TERMIO_SESSION_CHANNEL", CHANNEL)
        .stdin(Stdio::null())
        .output()
        .expect("run termio")
}

const CHANNEL: &str = "routingtest";

fn app_directory(home: &Path) -> PathBuf {
    home.join("Library/Application Support").join(format!("termio-{CHANNEL}"))
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
    let ran = termio(&daemon, &["session", "run", "--json", "echo ran-on-termiod"]);
    assert!(ran.status.success(), "run failed: {ran:?}");
    let reply: serde_json::Value = serde_json::from_slice(&ran.stdout).expect("run --json");
    let id = reply["id"].as_str().expect("an id").to_string();
    // The command has exited; its output is still there to read, under a
    // shell, the way the app's `run` leaves it.
    assert!(screen_shows(&daemon, &id, "ran-on-termiod"));
    std::thread::sleep(Duration::from_millis(500));
    assert!(screen_shows(&daemon, &id, "ran-on-termiod"), "the session ended with its command");

    let placed = termio(&daemon, &["session", "run", "--direction", "down", "--json", "true"]);
    assert!(!placed.status.success(), "placing a pane needs the app");
    let refusal: serde_json::Value = serde_json::from_slice(&placed.stdout).expect("a JSON refusal");
    assert_eq!(refusal["error"], "needs_app");
}

/// With no app, the replies keep the shapes and codes the app's replies have.
#[test]
fn without_the_app_the_replies_keep_the_contract() {
    let daemon = start_daemon("contract");
    // A line the shell cannot finish still leaves a session, waiting for more.
    let ran = termio(&daemon, &["session", "run", "--json", "echo 'unterminated"]);
    let reply: serde_json::Value = serde_json::from_slice(&ran.stdout).expect("run --json");
    assert_eq!(reply["queued"], true);
    let id = reply["id"].as_str().expect("an id").to_string();
    std::thread::sleep(Duration::from_millis(500));
    let read = termio(&daemon, &["session", "read", &id]);
    assert!(read.status.success(), "the session ended: {read:?}");

    let created = termio(&daemon, &["session", "create", "--name", "Build", "--", "/bin/cat"]);
    assert!(created.status.success(), "create failed: {created:?}");
    let read = termio(&daemon, &["session", "read", "--json", "Build"]);
    let reply: serde_json::Value = serde_json::from_slice(&read.stdout).expect("read --json");
    let target = reply["target"].as_str().expect("a target").to_string();
    let again = termio(&daemon, &["session", "read", &target]);
    assert!(again.status.success(), "the reply's target does not resolve: {again:?}");

    let empty = termio(&daemon, &["session", "send", "--json", "Build"]);
    let reply: serde_json::Value = serde_json::from_slice(&empty.stdout).expect("send --json");
    assert_eq!(reply["error"], "no_text");

    let spawned = termio(&daemon, &["session", "spawn", "--json", "hello"]);
    assert!(!spawned.status.success());
    let reply: serde_json::Value = serde_json::from_slice(&spawned.stdout).expect("spawn --json");
    assert_eq!(reply["error"], "needs_app");

    // Two sessions may share a name; each id reads its own screen.
    let mut ids = Vec::new();
    for word in ["first-dup", "second-dup"] {
        let script = format!("echo {word}; exec cat");
        let made = termio(&daemon, &["session", "create", "--json", "--name", "Dup", "--", "sh", "-c", &script]);
        let reply: serde_json::Value = serde_json::from_slice(&made.stdout).expect("create --json");
        ids.push(reply["id"].as_str().expect("an id").to_string());
    }
    assert!(screen_shows(&daemon, &ids[0], "first-dup"), "the first id read another screen");
    assert!(screen_shows(&daemon, &ids[1], "second-dup"));
    let shared = termio(&daemon, &["session", "read", "--json", "Dup"]);
    let reply: serde_json::Value = serde_json::from_slice(&shared.stdout).expect("read --json");
    assert_eq!(reply["error"], "ambiguous", "a shared name: {reply}");

    let listed = termio(&daemon, &["session", "ls", "--all", "--json"]);
    assert!(!stdout(&listed).contains("null"), "ls --all --json: {}", stdout(&listed));
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

    // `session` goes out under its old name, which every build parses.
    let remote = run(&["-H", "box", "session", "ls", "--all"]);
    let lines: Vec<&str> = remote.lines().collect();
    assert!(lines.contains(&"box"), "ssh host: {remote}");
    let command = lines.last().expect("a remote command");
    assert!(command.ends_with(" sessions ls --all"), "remote command: {command}");

    let remote = run(&["server", "--host", "box", "status", "--json"]);
    assert!(remote.trim_end().ends_with(" server status --json"), "remote command: {remote}");

    // After the command word, `-H` is the verb's text, never a host.
    let text = Command::new(CLIENT)
        .args(["session", "send", "8de0b387", "-Hello"])
        .env("HOME", &daemon.home)
        .env("PATH", &path)
        .output()
        .expect("run termio");
    assert_eq!(text.status.code(), Some(2), "`-Hello` must not become a host: {text:?}");

    let refused = Command::new(CLIENT)
        .args(["-H", "box", "open"])
        .env("HOME", &daemon.home)
        .env("PATH", &path)
        .output()
        .expect("run termio");
    assert!(!refused.status.success(), "`open` with --host must refuse");
}

/// A stand-in for the app's control socket. It knows one session, `8de0b387`,
/// whose screen reads like an error, answers "not found" for any other target
/// the way the app words it, and counts the requests it receives. With
/// `no_scope`, it answers every request as the app does outside any project.
fn fake_app(home: &Path, no_scope: bool) -> std::sync::Arc<std::sync::atomic::AtomicUsize> {
    use std::io::{Read, Write};
    use std::sync::atomic::{AtomicUsize, Ordering};
    let directory = app_directory(home);
    std::fs::create_dir_all(&directory).expect("the app's support directory");
    let listener =
        std::os::unix::net::UnixListener::bind(directory.join("app.sock")).expect("bind app.sock");
    let requests = std::sync::Arc::new(AtomicUsize::new(0));
    let counted = requests.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let mut buffer = [0u8; 4096];
            let read = stream.read(&mut buffer).unwrap_or(0);
            // `app_running` connects and closes without a request.
            if read == 0 {
                continue;
            }
            counted.fetch_add(1, Ordering::SeqCst);
            let request: serde_json::Value =
                serde_json::from_slice(&buffer[..read]).unwrap_or_default();
            let target = request["target"].as_str().unwrap_or("");
            let reply = if no_scope {
                if request["format"] == "json" {
                    "{\"error\":\"no_scope\",\"message\":\"x\",\"ok\":false,\"schema_version\":1}\n"
                        .to_string()
                } else {
                    "error: Couldn’t tell which project you’re in. Run this from inside a Termio session.\n"
                        .to_string()
                }
            } else if request["op"] == "read" && target == "8de0b387" {
                "{\"ok\":true,\"schema_version\":1,\"screen\":\"error: No session 'x' in this project.\"}\n"
                    .to_string()
            } else if target.is_empty() || target == "8de0b387" {
                "{\"ok\":true}\n".to_string()
            } else if request["format"] == "json" {
                "{\"error\":\"not_found\",\"message\":\"x\",\"ok\":false,\"schema_version\":1}\n"
                    .to_string()
            } else {
                format!("error: No session '{target}' in this project.\n")
            };
            let _ = stream.write_all(reply.as_bytes());
        }
    });
    requests
}

/// With the app running, the app answers every session verb, and its project
/// scope holds: termiod is not asked behind its back, even for a session only
/// termiod holds. `create`, `attach` and `ls --all` are termiod's by name.
#[test]
fn with_the_app_the_app_answers() {
    use std::sync::atomic::Ordering;
    let daemon = start_daemon("app");
    let created = termio(&daemon, &["session", "create", "--name", "headless", "--json", "--", "/bin/cat"]);
    assert!(created.status.success(), "create failed: {created:?}");
    let reply: serde_json::Value = serde_json::from_slice(&created.stdout).expect("create --json");
    let id = reply["id"].as_str().expect("an id").to_string();
    let app = fake_app(&daemon.home, false);

    let sent = termio(&daemon, &["session", "send", &id, "not-for-termiod"]);
    assert!(!sent.status.success(), "the app's not-found must stand: {sent:?}");
    assert_eq!(app.load(Ordering::SeqCst), 1);
    let read = termio(&daemon, &["session", "ls", "--all"]);
    assert!(read.status.success() && stdout(&read).contains("headless"), "{read:?}");
    assert_eq!(app.load(Ordering::SeqCst), 1, "`ls --all` asked the app");

    let closed = termio(&daemon, &["session", "close", "headless"]);
    assert!(!closed.status.success(), "the app's not-found must stand: {closed:?}");
    let listed = termio(&daemon, &["session", "ls", "--all"]);
    assert!(stdout(&listed).contains("headless"), "termiod closed it behind the app: {listed:?}");

    let sent = termio(&daemon, &["session", "send", "8de0b387", "to-the-app"]);
    assert!(sent.status.success(), "send failed: {sent:?}");

    // A name is prompt text when the app runs: it starts an agent there.
    let before = app.load(Ordering::SeqCst);
    let spawned = termio(&daemon, &["session", "send", "headless", "the-prompt"]);
    assert!(spawned.status.success(), "send failed: {spawned:?}");
    assert_eq!(app.load(Ordering::SeqCst), before + 1);
}

/// Outside any project the app declines everything, and that stands.
#[test]
fn the_app_declining_is_the_answer() {
    let daemon = start_daemon("scope");
    let created = termio(&daemon, &["session", "create", "--name", "headless", "--", "/bin/cat"]);
    assert!(created.status.success(), "create failed: {created:?}");
    let _app = fake_app(&daemon.home, true);
    let closed = termio(&daemon, &["session", "close", "headless"]);
    assert!(!closed.status.success(), "{closed:?}");
    let listed = termio(&daemon, &["session", "ls", "--all"]);
    assert!(stdout(&listed).contains("headless"), "termiod closed it behind the app: {listed:?}");
}

/// Every target of `close` gets its attempt, even after one fails.
#[test]
fn close_tries_every_target() {
    let daemon = start_daemon("close");
    let created = termio(&daemon, &["session", "create", "--name", "alpha", "--", "/bin/cat"]);
    assert!(created.status.success(), "create failed: {created:?}");
    let closed = termio(&daemon, &["session", "close", "nosuch", "alpha"]);
    assert!(!closed.status.success(), "a missing target fails the command");
    let listed = termio(&daemon, &["session", "ls", "--all"]);
    assert!(!stdout(&listed).contains("alpha"), "alpha was skipped: {listed:?}");
}

/// The app leaves its socket file behind when it quits. A file with no
/// listener is no app.
#[test]
fn a_socket_file_with_no_listener_is_no_app() {
    let daemon = start_daemon("stale");
    let directory = app_directory(&daemon.home);
    std::fs::create_dir_all(&directory).expect("the app's support directory");
    drop(std::os::unix::net::UnixListener::bind(directory.join("app.sock")).expect("bind"));
    let created = termio(&daemon, &["session", "create", "--name", "left", "--", "/bin/cat"]);
    assert!(created.status.success(), "create failed: {created:?}");
    let listed = termio(&daemon, &["session", "ls"]);
    assert!(listed.status.success(), "ls failed: {listed:?}");
    assert!(stdout(&listed).contains("left"), "ls: {listed:?}");
}

/// A lookup that finds nothing must not start a daemon to find it.
#[test]
fn a_failed_lookup_starts_no_daemon() {
    let home = PathBuf::from(format!("/tmp/termio-routing-none-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).expect("a home directory");
    let socket = home.join("d.sock");
    for args in [
        &["session", "read", "nosuch"][..],
        &["session", "close", "nosuch"][..],
        &["session", "send", "nosuch", "x"][..],
    ] {
        let output = Command::new(CLIENT)
            .args(args)
            .env("HOME", &home)
            .env("TERMIOD_SOCK", &socket)
            .env_remove("TERMIO_SESSION")
            .env("TERMIO_SESSION_CHANNEL", CHANNEL)
            .stdin(Stdio::null())
            .output()
            .expect("run termio");
        assert!(!output.status.success(), "{args:?} must fail: {output:?}");
        assert!(!socket.exists(), "{args:?} started a daemon");
    }
    let _ = std::fs::remove_dir_all(&home);
}

fn make_executable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
}
