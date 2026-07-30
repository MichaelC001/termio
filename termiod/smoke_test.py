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
import os
import pty
import select
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
    import json

    try:
        rows = json.loads(cli_out("list", "--json"))
    except Exception:
        return None
    for s in rows:
        if s["name"] == name or s["id"] == name:
            return s["pid"]
    return None


def session_size(name):
    import json

    for s in json.loads(cli_out("list", "--json")):
        if s["name"] == name or s["id"] == name:
            return (s["rows"], s["cols"])
    return None


def cleanup():
    import json

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

    print("\n# 3. inject-without-attach + kill")
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
