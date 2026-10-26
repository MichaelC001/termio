//! The host answers a program's terminal queries (`vt_answers`, phase 5 of
//! `docs/design/20261024-client-vt-follows-the-stream.md`): a session with no
//! window open gets its answers, as Rex's server gives them.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_termiod");
const CLIENT: &str = env!("CARGO_BIN_EXE_termio");

struct TestDir(PathBuf);

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn termio(socket: &Path, args: &[&str]) -> Output {
    Command::new(CLIENT)
        .args(args)
        .env("TERMIOD_SOCK", socket)
        .output()
        .expect("run termio")
}

#[test]
fn a_session_with_no_window_gets_its_queries_answered() {
    // Unix-domain socket paths are short on macOS.
    let dir = TestDir(PathBuf::from(format!("/tmp/tva-{}", std::process::id())));
    let _ = std::fs::remove_dir_all(&dir.0);
    std::fs::create_dir(&dir.0).expect("test directory");
    let socket = dir.0.join("termiod.sock");
    let _daemon = Daemon(
        Command::new(BIN)
            .arg("serve")
            .env("TERMIOD_SOCK", &socket)
            .env("TERMIOD_KEEP_AWAKE", "off")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn isolated daemon"),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        assert!(Instant::now() < deadline, "daemon never bound its socket");
        std::thread::sleep(Duration::from_millis(20));
    }

    // DA1, DA2 and a cursor report, read back raw: what a program probing its
    // terminal at startup sends, and what it waits for.
    let expected = b"\x1b[?62;22;52c\x1b[>1;10;0c\x1b[1;1R";
    let answers = dir.0.join("answers");
    let script = format!(
        "stty raw -echo; printf '\\033[c\\033[>c\\033[6n'; dd bs=1 count={} of={} 2>/dev/null; sleep 30",
        expected.len(),
        answers.display()
    );
    let created = termio(&socket, &["server", "create", "--name", "asks", "--", "sh", "-c", &script]);
    assert!(created.status.success(), "create failed: {created:?}");

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let read = std::fs::read(&answers).unwrap_or_default();
        if read.len() >= expected.len() {
            assert_eq!(String::from_utf8_lossy(&read), String::from_utf8_lossy(expected));
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the program was answered {:?} of {:?}",
            String::from_utf8_lossy(&read),
            String::from_utf8_lossy(expected)
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}
