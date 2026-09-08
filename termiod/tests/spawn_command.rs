//! Acceptance for `CreateSpec.command`: a spec that names a command line and
//! no argv spawns that command through the account's login shell — the path a
//! remote agent launch rides — and the host advertises `spawn_command` so a
//! client can tell this daemon from one that would ignore the field.

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
    dir: String,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn start_daemon(tag: &str) -> Daemon {
    // The serve lock lives beside the socket, so the socket gets its own
    // directory — a bare /tmp path would contend for /tmp/termiod.lock with
    // whatever real daemon this box is running.
    let dir = format!("/tmp/termiod-spawn-command-test-{tag}");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("socket dir");
    let child = Command::new(BIN)
        .arg("serve")
        .env("TERMIOD_SOCK", format!("{dir}/termiod.sock"))
        .env("TERMIOD_KEEP_AWAKE", "off")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !std::path::Path::new(&format!("{dir}/termiod.sock")).exists() {
        assert!(Instant::now() < deadline, "daemon never bound the socket");
        std::thread::sleep(Duration::from_millis(30));
    }
    Daemon { child, dir }
}

#[test]
fn a_command_spec_spawns_through_the_login_shell() {
    let daemon = start_daemon("attach");
    let mut stream = UnixStream::connect(format!("{}/termiod.sock", daemon.dir)).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("read timeout");

    let hello = br#"{"op":"hello","proto":1,"min_proto":1,"role":"attach","caps":["snapshot","spawn_command"],"client":"spawn-command-test"}"#;
    write_frame(&mut stream, b'C', hello);
    let (kind, payload) = read_frame(&mut stream).expect("hello reply");
    assert_eq!(kind, b'C');
    let hello_ok = String::from_utf8_lossy(&payload).into_owned();
    assert!(
        hello_ok.contains("spawn_command"),
        "host did not advertise spawn_command: {hello_ok}"
    );

    // The command proves the login-shell wrap by *needing* a shell: the
    // redirect only exists if a shell parsed the line, and the file's content
    // only exists if the command ran to completion on the daemon's box.
    let marker = format!("{}/marker", daemon.dir);
    let attach = format!(
        r#"{{"op":"attach","target":"cmdspawn","rows":24,"cols":80,"mode":"interact","create_if_missing":{{"argv":[],"command":"printf shellran > {marker}","rows":24,"cols":80}}}}"#
    );
    write_frame(&mut stream, b'C', attach.as_bytes());

    let deadline = Instant::now() + Duration::from_secs(8);
    let mut saw_attached = false;
    let mut saw_clean_exit = false;
    while Instant::now() < deadline && !(saw_attached && saw_clean_exit) {
        let Some((kind, payload)) = read_frame(&mut stream) else {
            break;
        };
        if kind != b'C' {
            continue;
        }
        let control = String::from_utf8_lossy(&payload);
        if control.contains("\"op\":\"attached\"") {
            saw_attached = true;
        }
        if control.contains("\"op\":\"exited\"") {
            assert!(
                control.contains("\"status\":0"),
                "command exited non-zero: {control}"
            );
            saw_clean_exit = true;
        }
    }
    assert!(saw_attached, "attach was never acknowledged");
    assert!(saw_clean_exit, "the spawned command never exited cleanly");

    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Ok(content) = std::fs::read_to_string(&marker) {
            assert_eq!(content, "shellran");
            return;
        }
        assert!(
            Instant::now() < deadline,
            "the login-shell command never wrote its marker"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}
