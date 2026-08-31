#!/usr/bin/env python3
"""Byte-compatibility harness: the Rust `termio` client against `scripts/termio`.

Runs both clients against a mock app-control socket (and against no socket at
all) and diffs four surfaces per case: the request bytes each client puts on
the wire, stdout, stderr, and the exit code. The shell client is the frozen
contract; any divergence fails the run. Cases that need no server (validation
errors, help text) diff the client surfaces only.

The mock lives under a short /private/tmp home because AF_UNIX paths cap at
104 bytes, and /private/tmp (not /tmp) keeps $PWD logical-path semantics
identical between sh and the Rust client.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "scripts", "termio")
RUST = os.environ.get(
    "TERMIO_CLI_TEST_BIN",
    os.path.join(REPO, "termiod", "target", "debug", "termio"),
)

HOME = f"/private/tmp/termio-compat-{os.getpid()}"
SOCK_DIR = os.path.join(HOME, "Library/Application Support/termio")
SOCK = os.path.join(SOCK_DIR, "app.sock")
# The name the app bound before it was named for its binder. Both clients fall back
# to it so a checkout CLI can drive an older app; they must agree on when.
LEGACY_SOCK = os.path.join(SOCK_DIR, "session-control.sock")

failures = []
passes = 0


def check(name, condition, detail=""):
    global passes
    if condition:
        passes += 1
        print(f"  [PASS] {name}")
    else:
        failures.append(name)
        print(f"  [FAIL] {name}\n{detail}")


class MockApp:
    """One listener; each connection reads a request, replies from a queue."""

    def __init__(self, replies, hold=False):
        os.makedirs(SOCK_DIR, exist_ok=True)
        if os.path.exists(SOCK):
            os.unlink(SOCK)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(SOCK)
        self.server.listen(8)
        self.replies = list(replies)
        self.hold = hold
        self.requests = []
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            connection.settimeout(3)
            data = b""
            while True:
                if data:
                    try:
                        json.loads(data)
                        break
                    except ValueError:
                        pass
                try:
                    chunk = connection.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    break
                data += chunk
            self.requests.append(data)
            if self.hold:
                time.sleep(3)
                connection.close()
                continue
            reply = self.replies.pop(0) if self.replies else b'{"ok":true}'
            try:
                connection.sendall(reply)
            except OSError:
                pass
            connection.close()

    def close(self):
        self.server.close()
        if os.path.exists(SOCK):
            os.unlink(SOCK)


def run(client, args, env_extra=None):
    env = {
        "HOME": HOME,
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "PWD": HOME,
        "TERMIO_SESSION": "TEST-SESSION",
    }
    if env_extra:
        env.update(env_extra)
    completed = subprocess.run(
        [client] + args, env=env, cwd=HOME, capture_output=True, text=True, timeout=30
    )
    return completed.returncode, completed.stdout, completed.stderr


def compare(name, args, replies=None, env_extra=None, hold=False, no_server=False):
    """Run both clients; diff request bytes, stdout, stderr, and exit code."""
    surfaces = []
    for client in (SCRIPT, RUST):
        mock = None if no_server else MockApp(replies or [b'{"ok":true}'], hold=hold)
        code, out, err = run(client, args, env_extra)
        requests = [] if mock is None else list(mock.requests)
        if mock:
            mock.close()
        surfaces.append((code, out, err, requests))
    (s_code, s_out, s_err, s_req), (r_code, r_out, r_err, r_req) = surfaces
    detail = (
        f"    exit: script={s_code} rust={r_code}\n"
        f"    stdout: script={s_out!r}\n            rust={r_out!r}\n"
        f"    stderr: script={s_err!r}\n            rust={r_err!r}\n"
        f"    requests: script={s_req!r}\n              rust={r_req!r}"
    )
    check(
        name,
        (s_code, s_out, s_err, s_req) == (r_code, r_out, r_err, r_req),
        detail,
    )


def main():
    shutil.rmtree(HOME, ignore_errors=True)
    os.makedirs(SOCK_DIR)
    if not os.path.exists(RUST):
        print(f"missing rust client at {RUST}; cargo build first", file=sys.stderr)
        return 2

    ok = b'{"ok":true,"schema_version":1,"sessions":[]}'
    err = b'{"error":"no_scope","message":"Couldn\xe2\x80\x99t tell.","ok":false,"schema_version":1}'

    print("== requests and replies ==")
    compare("list text", ["sessions", "list"], [ok])
    compare("list json", ["sessions", "list", "--json"], [ok])
    compare("list default op", ["sessions"], [ok])
    compare("error reply exits 1", ["sessions", "list", "--json"], [err])
    compare("text error prefix exits 1", ["sessions", "list"], [b"error: nope\n"])
    compare("send to target", ["sessions", "send", "8de0b387", "hello", "world"], [ok])
    compare("send full link", ["sessions", "send", "termio://session/8de0b387-485a-4016-8990-cbcbfff03199", "hi"], [ok])
    compare("send no-enter with key", ["sessions", "send", "8de0b387", "t", "--no-enter", "--key", "escape", "--key", "enter"], [ok])
    compare("send no target aliases spawn", ["sessions", "send", "fix", "the", "build"], [ok])
    compare("send 7-hex token is text", ["sessions", "send", "deadbee", "tail"], [ok])
    compare("answer", ["sessions", "answer", "8de0b387", "yes"], [ok])
    compare("spawn with placement", ["sessions", "spawn", "fix it", "--agent", "codex", "--direction", "down", "--ratio", "0.25"], [ok])
    compare("run", ["sessions", "run", "pnpm dev", "--direction", "right"], [ok])
    compare("read with lines", ["sessions", "read", "8de0b387", "--lines", "12"], [ok])
    compare("focus", ["sessions", "focus", "8de0b387"], [ok])
    compare("close two targets", ["sessions", "close", "8de0b387", "deadbeef"], [ok, ok])
    compare("close second fails", ["sessions", "close", "8de0b387", "deadbeef"], [ok, err])
    compare("notify", ["notify", "tests", "passed"], [ok])
    compare("timeout leading plus", ["sessions", "send", "8de0b387", "x", "--timeout", "+5"], [ok])
    compare("timeout negative", ["sessions", "send", "8de0b387", "x", "--timeout", "-5"], [ok])
    compare("trailing newline eaten", ["sessions", "spawn", "hello\n"], [ok])
    compare("interior newline survives", ["sessions", "spawn", "a\nb"], [ok])
    compare("two trailing newlines keep one", ["sessions", "spawn", "a\n\n"], [ok])
    compare("close splits one argument", ["sessions", "close", "one two"], [ok, ok])
    compare("close whitespace-only argument", ["sessions", "close", "  "], [ok])
    compare("send text then address is all text", ["sessions", "send", "fix", "8de0b387aa", "please"], [ok])
    compare("json after positionals", ["sessions", "send", "8de0b387", "hi", "--json"], [ok])
    compare("ok-false inside text reply", ["sessions", "list"], [b'something "ok":false something\n'])
    compare("notify with title", ["notify", "--title", "ci", "done", "--json"], [ok])

    print("== --wait ==")
    waited = b'{"ok":true,"status":"done","timed_out":false}'
    timed = b'{"ok":true,"status":"working","timed_out":true}'
    compare("wait settled", ["sessions", "send", "8de0b387", "go", "--wait", "--timeout", "5000", "--json"], [waited])
    compare("wait timeout exits 3 json", ["sessions", "send", "8de0b387", "go", "--wait", "--timeout", "5000", "--json"], [timed])
    compare("wait timeout exits 3 text", ["sessions", "spawn", "go", "--wait"], [b"working \xe2\x80\x94 timed out after 300s\ndetail\n"])
    compare("wait timeout marker on later line", ["sessions", "spawn", "go", "--wait"], [b"working\nlater \xe2\x80\x94 timed out\n"])

    print("== watch ==")
    stream = b'{"snapshot":true,"session":"a"}\n{"session":"a","status":"done"}\n'
    compare("watch stream then eof", ["sessions", "watch", "--json"], [stream])
    compare("watch error first line", ["sessions", "watch"], [b'error: control disabled\n'])
    compare("watch no-snapshot state filter", ["sessions", "watch", "--state", "done,stalled", "--no-snapshot", "--json"], [stream])
    compare("watch unterminated final line", ["sessions", "watch", "--json"], [b'{"snapshot":true}\n{"session":"a","status":"done"}'])
    compare("watch unterminated first line", ["sessions", "watch", "--json"], [b'{"snapshot":true}'])

    print("== validation (no server contact) ==")
    for name, args in [
        ("spawn empty", ["sessions", "spawn"]),
        ("spawn terminal refused", ["sessions", "spawn", "x", "--agent", "terminal"]),
        ("spawn Shell refused", ["sessions", "spawn", "x", "--agent", "Shell"]),
        ("run empty", ["sessions", "run"]),
        ("read no target", ["sessions", "read"]),
        ("answer no target", ["sessions", "answer"]),
        ("focus no target", ["sessions", "focus"]),
        ("close no target", ["sessions", "close"]),
        ("ratio bare5", ["sessions", "spawn", "x", "--ratio", ".5"]),
        ("ratio trailing dot", ["sessions", "spawn", "x", "--ratio", "0."]),
        ("ratio percent", ["sessions", "spawn", "x", "--ratio", "50%"]),
        ("direction bad", ["sessions", "spawn", "x", "--direction", "left"]),
        ("timeout not ms", ["sessions", "send", "8de0b387", "x", "--timeout", "5s"]),
        ("lines not number", ["sessions", "read", "8de0b387", "--lines", "two"]),
        ("wait on list", ["sessions", "list", "--wait"]),
        ("placement on send", ["sessions", "send", "8de0b387", "x", "--direction", "down"]),
        ("no-enter on spawn", ["sessions", "spawn", "x", "--no-enter"]),
        ("no-enter without target", ["sessions", "send", "x", "--no-enter"]),
        ("key without target", ["sessions", "send", "x", "--key", "escape"]),
        ("key missing value", ["sessions", "send", "8de0b387", "--key"]),
        ("agent missing value", ["sessions", "spawn", "x", "--agent"]),
        ("state missing value", ["sessions", "watch", "--state"]),
        ("title missing value", ["notify", "--title"]),
        ("notify empty", ["notify"]),
    ]:
        compare(name, args, [ok])
    compare("unknown sessions cmd", ["sessions", "bogus"], no_server=True)

    print("== error taxonomy ==")
    compare("no socket at all", ["sessions", "list"], no_server=True)
    compare("socket error before flag validation", ["sessions", "spawn", "x", "--ratio", "bad"], no_server=True)
    compare("notify body error before socket check", ["notify"], no_server=True)
    compare("notify no socket", ["notify", "hi"], no_server=True)
    # A plain file where the socket should be: the -S pre-check refuses.
    with open(SOCK, "w") as handle:
        handle.write("")
    compare("socket is a plain file", ["sessions", "list"], no_server=True)
    os.unlink(SOCK)
    # An app older than the socket rename: both clients fall back to the name it
    # binds, and both must name the same path when what sits there is not a socket.
    legacy = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    legacy.bind(LEGACY_SOCK)
    legacy.close()
    compare("falls back to the pre-rename socket", ["sessions", "list"], no_server=True)
    os.unlink(LEGACY_SOCK)
    with open(LEGACY_SOCK, "w") as handle:
        handle.write("")
    compare("pre-rename plain file is not an older app", ["sessions", "list"], no_server=True)
    os.unlink(LEGACY_SOCK)
    # A socket file whose listener is gone: connect refused.
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(SOCK)
    stale.close()
    compare("stale socket refused", ["sessions", "list"], no_server=True)
    os.unlink(SOCK)
    compare(
        "silent app times out",
        ["sessions", "list"],
        hold=True,
        env_extra={"TERMIO_CLI_TIMEOUT": "1"},
    )

    print("== agent report ==")
    compare("report outside session", ["agent", "report", "done"], no_server=True)
    compare("report outside session reply", ["agent", "report", "done", "--reply"], no_server=True)
    compare("report no state", ["agent", "report"], no_server=True)
    compare("report unknown flag", ["agent", "report", "done", "--bogus"], no_server=True)
    compare("unknown agent cmd", ["agent", "bogus"], no_server=True)
    # With a session id and a recorder daemon: both clients must exec the
    # daemon with identical argv.
    recorder = os.path.join(HOME, "record-termiod")
    argv_log = os.path.join(HOME, "argv")
    with open(recorder, "w") as handle:
        handle.write(f'#!/bin/sh\nprintf \'%s\\n\' "$@" > "{argv_log}"\n')
    os.chmod(recorder, 0o755)
    argvs = []
    for client in (SCRIPT, RUST):
        if os.path.exists(argv_log):
            os.unlink(argv_log)
        code, out, err = run(
            client,
            ["agent", "report", "working", "--transcript", "--tool-from", "tool name", "--reply"],
            {"TERMIOD_SESSION_ID": "S1", "TERMIOD_BIN": recorder},
        )
        argv = open(argv_log).read() if os.path.exists(argv_log) else "(none)"
        argvs.append((code, out, err, argv))
    check(
        "report execs identical set-status argv",
        argvs[0] == argvs[1],
        f"    script={argvs[0]!r}\n    rust={argvs[1]!r}",
    )

    print("== help ==")
    for name, args in [
        ("usage", ["--help"]),
        ("usage via help", ["help"]),
        ("sessions usage", ["sessions", "--help"]),
        ("list help", ["sessions", "list", "--help"]),
        ("watch help", ["sessions", "watch", "--help"]),
        ("spawn help", ["sessions", "spawn", "--help"]),
        ("run help", ["sessions", "run", "--help"]),
        ("send help", ["sessions", "send", "--help"]),
        ("answer help", ["sessions", "answer", "--help"]),
        ("read help", ["sessions", "read", "--help"]),
        ("close help", ["sessions", "close", "--help"]),
        ("focus help", ["sessions", "focus", "--help"]),
        ("notify help", ["notify", "--help"]),
        ("not a directory", ["/nonexistent-dir"]),
        ("open not a directory", ["open", "/nonexistent-dir"]),
    ]:
        compare(name, args, no_server=True)

    shutil.rmtree(HOME, ignore_errors=True)
    print()
    if failures:
        print(f"{passes} passed, {len(failures)} FAILED: {failures}")
        return 1
    print(f"ALL {passes} CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
