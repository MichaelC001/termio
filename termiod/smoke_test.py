#!/usr/bin/env python3
"""End-to-end smoke test for the termiod POC (#170 acceptance).

Drives the `termiod` binary through real PTYs and asserts the durable-session
contract: attach → type → detach → the session survives → reattach sees the
same process; multi-client fan-out; single-writer input; newest-client resize;
inject-without-attach; kill.

Usage:
    cargo build && python3 smoke_test.py [path/to/termiod]

Exits 0 if every check passes, 1 otherwise.
"""

import fcntl
import json
import os
import pty
import select
import socket
import struct
import subprocess
import sys
import termios
import time

BIN = sys.argv[1] if len(sys.argv) > 1 else "./target/debug/termiod"
SOCK_DIR = "/tmp/termiod-smoke"
ENV = dict(os.environ, TERMIOD_SOCK=f"{SOCK_DIR}/termiod.sock", TERM="xterm-256color")

FAILURES = []


def check(name, ok):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    if not ok:
        FAILURES.append(name)


def cli(*args):
    return subprocess.run(
        [BIN, *args], env=ENV, capture_output=True, text=True
    )


def cli_out(*args):
    return cli(*args).stdout.strip()


def recv_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("socket closed mid-frame")
        data += chunk
    return data


def decode_snapshot(payload):
    """Decode the Phase 1a S payload enough to assert its visible grid."""
    if len(payload) < 12 or payload[0] != 1:
        raise ValueError("invalid snapshot header")
    rows, cols, cursor_x, cursor_y = struct.unpack(">HHHH", payload[1:9])
    alt_screen = payload[9] == 1
    title_len = struct.unpack(">H", payload[10:12])[0]
    cells_offset = 12 + title_len
    title = payload[12:cells_offset].decode()
    cell_bytes = payload[cells_offset:]
    if len(cell_bytes) != rows * cols * 16:
        raise ValueError("invalid snapshot cell count")
    lines = []
    for row in range(rows):
        line = []
        for col in range(cols):
            offset = (row * cols + col) * 16
            codepoint = struct.unpack(">I", cell_bytes[offset : offset + 4])[0]
            line.append(chr(codepoint) if codepoint else " ")
        lines.append("".join(line))
    return {
        "rows": rows,
        "cols": cols,
        "cursor_x": cursor_x,
        "cursor_y": cursor_y,
        "alt_screen": alt_screen,
        "title": title,
        "lines": lines,
    }


class WireClient:
    """Small protocol client used to test the v0.1 wire directly."""

    def __init__(self, role="control", caps=None, hello=True, proto=1, min_proto=1):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(ENV["TERMIOD_SOCK"])
        self.hello = None
        if hello:
            self.send_control(
                {
                    "op": "hello",
                    "proto": proto,
                    "min_proto": min_proto,
                    "role": role,
                    "caps": caps or [],
                    "client": "smoke-test/0.1",
                }
            )
            kind, self.hello = self.recv_frame()
            assert kind == "C"

    def send_frame(self, kind, payload):
        if isinstance(payload, dict):
            payload = json.dumps(payload, separators=(",", ":")).encode()
        self.sock.sendall(kind.encode() + struct.pack(">I", len(payload)) + payload)

    def send_control(self, message):
        self.send_frame("C", message)

    def send_data(self, data):
        self.send_frame("D", data)

    def recv_frame(self, timeout=3.0):
        self.sock.settimeout(timeout)
        header = recv_exact(self.sock, 5)
        kind = chr(header[0])
        payload = recv_exact(self.sock, struct.unpack(">I", header[1:])[0])
        if kind in ("C", "E"):
            payload = json.loads(payload)
        return kind, payload

    def recv_matching(self, predicate, timeout=4.0):
        end = time.time() + timeout
        seen = []
        while time.time() < end:
            try:
                frame = self.recv_frame(max(0.05, end - time.time()))
            except (socket.timeout, EOFError):
                break
            seen.append(frame)
            if predicate(*frame):
                return frame, seen
        return None, seen

    def drain(self, duration=0.25):
        end = time.time() + duration
        frames = []
        while time.time() < end:
            try:
                frames.append(self.recv_frame(max(0.01, end - time.time())))
            except (socket.timeout, EOFError):
                break
        return frames

    def close(self):
        self.sock.close()


def set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def spawn_attach(extra_args, rows=24, cols=80):
    """Spawn `termiod attach <extra_args>` wired to a fresh PTY."""
    master, slave = pty.openpty()
    set_winsize(master, rows, cols)
    p = subprocess.Popen(
        [BIN, "attach", *extra_args],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=ENV,
        close_fds=True,
    )
    os.close(slave)
    return p, master


def read_until(master, needle, timeout=4.0):
    if isinstance(needle, str):
        needle = needle.encode()
    data = b""
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.2)
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
            if needle in data:
                return data
    return data


def drain(master, dur=0.4):
    end = time.time() + dur
    data = b""
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.1)
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
    return data


def session_pid(name):
    try:
        rows = json.loads(cli_out("list", "--json"))
    except Exception:
        return None
    for s in rows:
        if s["name"] == name or s["id"] == name:
            return s["pid"]
    return None


def session_size(name):
    for s in json.loads(cli_out("list", "--json")):
        if s["name"] == name or s["id"] == name:
            return (s["rows"], s["cols"])
    return None


def session_info(name):
    for session in json.loads(cli_out("list", "--json")):
        if session["name"] == name or session["id"] == name:
            return session
    return None


def cleanup():
    try:
        for s in json.loads(cli_out("list", "--json")):
            cli("kill", s["id"])
    except Exception:
        pass


def main():
    os.makedirs(SOCK_DIR, exist_ok=True)
    cleanup()

    print("\n# 1. attach → type → detach → session survives → reattach")
    p1, m1 = spawn_attach(["demo", "--", "bash", "--norc"], rows=30, cols=120)
    read_until(m1, "attached to demo")
    os.write(m1, b"PS1=P>; echo MARKER_ONE\r")
    got = read_until(m1, "MARKER_ONE")
    check("attach: session echoes typed command", b"MARKER_ONE" in got)
    check("resize: newest client claim (30x120)", session_size("demo") == (30, 120))
    pid_before = session_pid("demo")
    check("session has a pid", pid_before is not None)

    # Detach with Ctrl-\ (0x1c). Session must survive.
    os.write(m1, b"\x1c")
    try:
        p1.wait(timeout=5)
        detached_clean = True
    except subprocess.TimeoutExpired:
        p1.kill()
        detached_clean = False
    check("detach: attach client exits cleanly", detached_clean)
    time.sleep(0.3)
    check("detach ≠ kill: session still listed", session_pid("demo") is not None)

    # Reattach: different window size (newest-client claim), same process.
    p2, m2 = spawn_attach(["demo"], rows=40, cols=100)
    read_until(m2, "attached to demo")
    replay = drain(m2, 0.4)
    check("reattach: ring replay shows prior output", b"MARKER_ONE" in replay)
    os.write(m2, b"echo MARKER_TWO\r")
    check("reattach: input works", b"MARKER_TWO" in read_until(m2, "MARKER_TWO"))
    check("reattach: same process (pid unchanged)", session_pid("demo") == pid_before)
    check("reattach: newest-client resize (40x100)", session_size("demo") == (40, 100))
    os.write(m2, b"\x1c")
    p2.wait(timeout=5)
    cli("kill", "demo")

    print("\n# 2. multi-client fan-out + single-writer input")
    a1p, a1 = spawn_attach(["fan", "--", "cat"])
    read_until(a1, "attached to fan")
    a2p, a2 = spawn_attach(["fan"])  # second viewer, becomes newest ⇒ writer
    read_until(a2, "attached to fan")

    # Inject via `send` (always applied); cat echoes to *both* clients.
    cli("send", "fan", "PINGPONG")
    check("fan-out: client 1 sees injected output", b"PINGPONG" in read_until(a1, "PINGPONG"))
    check("fan-out: client 2 sees injected output", b"PINGPONG" in read_until(a2, "PINGPONG"))

    # Single writer = newest (a2). Input from a1 (not writer) is ignored.
    os.write(a1, b"FROM_A1\r")
    time.sleep(0.4)
    leaked = drain(a2, 0.4)
    check("single-writer: non-writer input ignored", b"FROM_A1" not in leaked)
    os.write(a2, b"FROM_A2\r")
    check("single-writer: writer input applied", b"FROM_A2" in read_until(a2, "FROM_A2"))

    os.write(a1, b"\x1c")
    os.write(a2, b"\x1c")
    a1p.wait(timeout=5)
    a2p.wait(timeout=5)
    cli("kill", "fan")

    print("\n# 3. observe streams full output without claiming writer")
    observe_writer, observe_master = spawn_attach(
        ["observe-pipe", "--", "bash", "--norc"]
    )
    read_until(observe_master, "attached to observe-pipe")
    before_observe = session_info("observe-pipe") or {}
    writer_before = before_observe.get("writer_client_id")

    observer = subprocess.Popen(
        [BIN, "attach", "observe-pipe", "--observe", "--no-create"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=ENV,
    )
    observer_attached = False
    writer_unchanged = False
    for _ in range(50):
        observed = session_info("observe-pipe") or {}
        if observed.get("attached_clients") == 2:
            observer_attached = True
            writer_unchanged = (
                writer_before is not None
                and observed.get("writer_client_id") == writer_before
            )
            break
        time.sleep(0.05)
    check(
        "observe: stdin EOF does not detach the observer",
        observer_attached and observer.poll() is None,
    )
    check("observe: writer ownership is unchanged", writer_unchanged)

    observe_payload = (
        "OBSERVE_FULL_0123456789" * 2048 + "OBSERVE_END_UNIQUE"
    ).encode()
    os.write(
        observe_master,
        b"python3 -c 'import sys;sys.stdout.write(\"OBSERVE_FULL_0123456789\"*2048+bytes([79,66,83,69,82,86,69,95,69,78,68,95,85,78,73,81,85,69]).decode());sys.stdout.flush()'\r",
    )
    read_until(observe_master, "OBSERVE_END_UNIQUE")
    cli("kill", "observe-pipe")
    try:
        observed_stdout, _ = observer.communicate(timeout=5)
        observer_clean = observer.returncode == 0
    except subprocess.TimeoutExpired:
        observer.kill()
        observed_stdout, _ = observer.communicate()
        observer_clean = False
    check(
        "observe: stdout pipe receives the full payload",
        observer_clean and observe_payload in observed_stdout,
    )
    try:
        observe_writer.wait(timeout=5)
    except subprocess.TimeoutExpired:
        observe_writer.kill()
    os.close(observe_master)

    print("\n# 4. inject-without-attach + kill")
    sid = cli_out("create", "--name", "inj", "--", "bash", "--norc")
    check("create returns an id", bool(sid))
    time.sleep(0.3)
    cli("send", "inj", f"echo INJECTED > {SOCK_DIR}/inj.txt")
    time.sleep(0.5)
    ok = os.path.exists(f"{SOCK_DIR}/inj.txt") and "INJECTED" in open(f"{SOCK_DIR}/inj.txt").read()
    check("send: inject without attach reaches the shell", ok)
    cli("kill", "inj")
    time.sleep(0.3)
    check("kill: session removed", session_pid("inj") is None)

    print("\n# 5. v0.1 hello negotiation + legacy fallback + request ids")
    h1 = WireClient(caps=["events", "not-a-host-cap"])
    h2 = WireClient(caps=["events"])
    check(
        "hello: negotiates protocol and capability intersection",
        h1.hello["op"] == "hello_ok"
        and h1.hello["proto"] == 1
        and h1.hello["caps"] == ["events"],
    )
    check(
        "hello: host id is stable and client ids are connection-scoped",
        h1.hello["host_id"] == h2.hello["host_id"]
        and h1.hello["client_id"] != h2.hello["client_id"],
    )
    h1.close()
    h2.close()

    incompatible = WireClient(hello=False)
    incompatible.send_control(
        {
            "op": "hello",
            "proto": 2,
            "min_proto": 2,
            "role": "control",
            "caps": [],
            "client": "future-client",
        }
    )
    kind, refused = incompatible.recv_frame()
    try:
        incompatible.sock.settimeout(1)
        closed = incompatible.sock.recv(1) == b""
    except socket.timeout:
        closed = False
    check(
        "hello: incompatible range is refused and closed",
        kind == "C"
        and refused["op"] == "hello_err"
        and refused["code"] == "incompatible"
        and refused["supported"] == [1]
        and closed,
    )
    incompatible.close()

    legacy = WireClient(hello=False)
    legacy.send_control({"op": "list"})
    kind, legacy_reply = legacy.recv_frame()
    check(
        "legacy: first non-hello v0 request still works",
        kind == "C" and legacy_reply["op"] == "sessions",
    )
    legacy.close()

    sequenced = WireClient()
    sequenced.send_control({"op": "list", "seq": 41})
    kind, seq_reply = sequenced.recv_frame()
    check(
        "request ids: response echoes seq as re",
        kind == "C" and seq_reply["op"] == "sessions" and seq_reply["re"] == 41,
    )
    sequenced.close()

    print("\n# 6. snapshot bootstrap boundary + legacy ring replay")
    snapshot_id = cli_out(
        "create",
        "--name",
        "snapshot-boundary",
        "--",
        "python3",
        "-u",
        "-c",
        "import time; print('SNAPSHOT_KNOWN', flush=True); "
        "time.sleep(1.5); print('LIVE_AFTER_READY', flush=True); time.sleep(30)",
    )
    time.sleep(0.3)

    snapshot_client = WireClient(role="attach", caps=["snapshot"])
    snapshot_client.send_control(
        {
            "op": "attach",
            "target": snapshot_id,
            "mode": "observe",
            "rows": 24,
            "cols": 80,
            "seq": 70,
        }
    )
    attached = snapshot_client.recv_frame()
    snapshot_frame = snapshot_client.recv_frame()
    ready_frame = snapshot_client.recv_frame()
    decoded = (
        decode_snapshot(snapshot_frame[1]) if snapshot_frame[0] == "S" else None
    )
    check(
        "snapshot: attached is followed by S with the known grid, then ready",
        attached[0] == "C"
        and attached[1].get("op") == "attached"
        and snapshot_frame[0] == "S"
        and decoded is not None
        and "SNAPSHOT_KNOWN" in "\n".join(decoded["lines"])
        and ready_frame[0] == "E"
        and ready_frame[1].get("ev") == "ready"
        and ready_frame[1].get("session") == snapshot_id,
    )
    live, _ = snapshot_client.recv_matching(
        lambda kind, payload: kind == "D" and b"LIVE_AFTER_READY" in payload,
        timeout=3.0,
    )
    check("snapshot: live D starts only after ready", live is not None)
    snapshot_client.close()

    legacy_attach = WireClient(role="attach", caps=[])
    legacy_attach.send_control(
        {
            "op": "attach",
            "target": snapshot_id,
            "mode": "observe",
            "rows": 24,
            "cols": 80,
            "seq": 71,
        }
    )
    legacy_frames = legacy_attach.drain(0.5)
    check(
        "snapshot: client without cap gets ring D and never S",
        any(kind == "D" and b"SNAPSHOT_KNOWN" in payload for kind, payload in legacy_frames)
        and all(kind != "S" for kind, _ in legacy_frames),
    )
    legacy_attach.close()
    cli("kill", snapshot_id)

    print("\n# 7. v0.1 single-writer errors and writer events")
    wire_id = cli_out("create", "--name", "wire-writer", "--", "cat")
    w1 = WireClient(role="attach", caps=["events"])
    w1.send_control(
        {
            "op": "attach",
            "target": wire_id,
            "mode": "interact",
            "rows": 24,
            "cols": 80,
            "seq": 1,
        }
    )
    attached1, _ = w1.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "attached"
    )
    w1.drain()

    w2 = WireClient(role="attach", caps=["events"])
    w2.send_control(
        {
            "op": "attach",
            "target": wire_id,
            "mode": "interact",
            "rows": 30,
            "cols": 100,
            "seq": 2,
        }
    )
    attached2, _ = w2.recv_matching(
        lambda kind, msg: kind == "C" and msg.get("op") == "attached"
    )
    changed, _ = w1.recv_matching(
        lambda kind, msg: kind == "E"
        and msg.get("ev") == "writer_changed"
        and msg.get("writer") == w2.hello["client_id"]
    )
    check(
        "writer policy: newest interactive attach wins and emits writer_changed",
        attached1 is not None
        and attached2 is not None
        and attached2[1]["writer"] is True
        and changed is not None,
    )
    w1.send_data(b"REJECT_ME\r")
    rejected, _ = w1.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "error"
        and msg.get("code") == "not_writer"
    )
    check(
        "writer policy: non-writer D receives typed not_writer",
        rejected is not None and rejected[1]["retryable"] is False,
    )
    w1.close()
    w2.close()
    cli("kill", wire_id)

    print("\n# 8. v0.1 subscriptions, status metadata, and waits")
    sub = WireClient(caps=["events", "send_wait"])
    sub.send_control(
        {"op": "subscribe", "events": ["roster", "status"], "seq": 50}
    )
    subscribed, _ = sub.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "ok"
        and msg.get("re") == 50
    )
    sub.send_control(
        {
            "op": "create",
            "name": "metadata",
            "argv": ["cat"],
            "workstream": {
                "agent_id": "codex",
                "project": "termio",
                "worktree": "termiod-v01",
            },
            "seq": 51,
        }
    )
    created, seen = sub.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "created"
        and msg.get("re") == 51
    )
    metadata_id = created[1]["id"] if created else None
    roster = next(
        (
            frame
            for frame in seen
            if frame[0] == "E"
            and frame[1].get("ev") == "roster"
            and frame[1].get("action") == "created"
        ),
        None,
    )
    if roster is None and metadata_id:
        roster, _ = sub.recv_matching(
            lambda kind, msg: kind == "E"
            and msg.get("ev") == "roster"
            and msg.get("action") == "created"
            and msg.get("session") == metadata_id
        )
    check(
        "subscribe: roster creation streams as an E frame",
        subscribed is not None and metadata_id is not None and roster is not None,
    )

    sub.send_control(
        {
            "op": "set_status",
            "id": metadata_id,
            "status": "needs_you",
            "title": "Review requested",
            "seq": 52,
        }
    )
    status_event, seen = sub.recv_matching(
        lambda kind, msg: kind == "E"
        and msg.get("ev") == "status"
        and msg.get("session") == metadata_id
        and msg.get("status") == "needs_you"
    )
    status_ok = any(
        kind == "C" and msg.get("op") == "ok" and msg.get("re") == 52
        for kind, msg in seen
    )
    if not status_ok:
        ok_frame, _ = sub.recv_matching(
            lambda kind, msg: kind == "C"
            and msg.get("op") == "ok"
            and msg.get("re") == 52
        )
        status_ok = ok_frame is not None
    check(
        "set_status: update fans out E status and correlates its reply",
        status_event is not None
        and status_event[1].get("title") == "Review requested"
        and status_ok,
    )
    metadata = next(
        (s for s in json.loads(cli_out("list", "--json")) if s["id"] == metadata_id),
        {},
    )
    check(
        "metadata: list exposes status, agent id, title, attachment roster",
        metadata.get("status") == "needs_you"
        and metadata.get("agent_id") == "codex"
        and metadata.get("title") == "Review requested"
        and metadata.get("attached_clients") == 0
        and metadata.get("writer_client_id") is None,
    )

    wait_id = cli_out("create", "--name", "wait-exit", "--", "sleep", "30")
    waiter = WireClient(caps=["send_wait"])
    waiter.send_control(
        {
            "op": "wait",
            "target": wait_id,
            "until": ["exited"],
            "timeout_ms": 5000,
            "seq": 61,
        }
    )
    time.sleep(0.1)
    cli("kill", wait_id)
    wait_result, _ = waiter.recv_matching(
        lambda kind, msg: kind == "C"
        and msg.get("op") == "wait_result"
        and msg.get("re") == 61
    )
    check(
        "wait: exited event resolves wait_result before timeout",
        wait_result is not None
        and wait_result[1]["status"] == "exited"
        and wait_result[1].get("timed_out", False) is False,
    )
    waiter.close()
    sub.close()
    if metadata_id:
        cli("kill", metadata_id)

    print()
    if FAILURES:
        print(f"FAILED ({len(FAILURES)}): " + ", ".join(FAILURES))
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        cleanup()
