---
title: "Adversarial review: What ten years of docker/dockerd teach the termio/termiod split"
status: archived
type: rfc
created: 2026-08-31
updated: 2026-08-31
related:
  - 20260831-docker-dockerd-lessons.md
  - 20260730-termiod-session-protocol.md
  - 20260819-unify-server-plane.md
---

# Adversarial review: What ten years of docker/dockerd teach the termio/termiod split

## Verdict

> Request changes. The command-name direction may be worth discussing, but the
> RFC misstates the protocol and current listener security model, then schedules
> a CLI migration ahead of the prerequisites the server-plane RFC explicitly
> puts before it.

Do not approve the work order as written. Protocol-version range negotiation is
already present: every `hello` sends `min_proto` and `proto`, and the host
selects the highest overlap or returns `hello_err`. The proposed work is a
support-window policy, tests, and client-side handling of the selected version —
not adding ranges to the handshake.

The security section is more serious. `termiod` already has an opt-in TCP
listener: `serve --wss` accepts only a loopback address, but it is still TCP and
is documented as carrying the same framed protocol onto the daemon socket.
`DEPLOY.md` warns that possession of its pairing token gives “full access to the
daemon.” The RFC instead calls the token a bounded session-plane credential and
declares “No TCP listener, ever.” Those are not descriptions of the current
tree or the cited protocol document; they are a breaking authorization redesign.

Finally, §8 treats P2 as a near-term port after protocol work. The accepted
server-plane ordering puts the CLI move at Stage 10, after the device connection,
daemon supervision, companion decoupling, a default-on release, and deletion of
the local PTY fork. It gives a concrete reason: moving the CLI while two session
backends remain creates the same work twice. This RFC needs either to preserve
that dependency order or explicitly supersede it with gates that address the
same risks.

## Current-tree audit

| RFC claim | Current tree | Finding |
| --- | --- | --- |
| `HOST_CAPABILITIES` is an existing string list of planes. | `termiod/src/protocol.rs:27-40` exports a string slice: `events`, `send_wait`, `snapshot`, `scrollback`, `grid_diff`, `resources`, `fs_watch`, `files`, `upload`, `git`, `agents`, `handoff`. | Correct, though it also contains feature-level flags, not only the broad “planes” named in §6. It cannot by itself be the promised extraction seam without defining that distinction. |
| Snapshot v3, history v2, and grid v2 carry per-payload version bytes and hard-refuse unknown versions. | `protocol.rs:51-64`, `1519-1552`, `1642-1663`, and `1712-1745` encode the leading byte; unknown snapshot, history, and grid versions return an error. | Correct. Snapshot has two accepted current encodings, however: packed cells v3 and VT repaint v2. Calling this simply “snapshot v3” hides that compatibility shape. |
| The handshake needs protocol ranges added beside capabilities. | `Control::Hello` already has `proto` and `min_proto` (`protocol.rs:520-526`). `20260730-termiod-session-protocol.md` §C.3 already specifies both sides advertise the range and use the highest overlap. | Incorrect. The RFC’s proposed error wording is also not current: `HelloErr` carries `supported: Vec<u32>`, not two named ranges (`protocol.rs:552-555`). |
| The current shell CLI has the app-plane verbs `sessions`, `agent report`, `notify`, and `open`. | `scripts/termio:17-58,745-779` implements those top-level forms; the script is currently 779 lines. | Correct, with an important qualification: `agent report` now execs `termiod set-status` when `TERMIOD_SESSION_ID` is set (`scripts/termio:662-686`). It is not solely app-plane. |
| The daemon-plane verbs “today live under `termiod remote …` (`open`, `deploy`, `attach`, `list`).” | `termiod remote` has `deploy`, `list`, `attach`, and `open` (`termiod/src/remote.rs:79-136`). But `termiod deploy --host`, `list --host`, and `attach --host` are also top-level forms (`termiod/src/main.rs:157-177,242-281,325-339`). | Incomplete and misleading. The RFC should inventory both spellings before choosing a public migration, rather than treating `remote` as the whole existing surface. |
| `termiod` is only for machine invocations today. | Its current public CLI includes `logs`, `pair`, `create`, `list`, `kill`, `send`, `attach`, `watch`, `status`, `deploy`, `remote`, and `service` (`termiod/src/main.rs:51-351`). `DEPLOY.md` teaches people to type many of them. | This is an intended future decision, not current fact. The migration needs a deprecation map for every user-facing subcommand, not only `remote` verbs. |
| A second Rust `termio` binary is mechanically cheap because the crate can reuse its modules. | `Cargo.toml` declares one `[[bin]]`, `termiod`, rooted at `src/main.rs`. The modules are declared from that binary crate root (`main.rs:14-29`), not a shared library. | Unsupported. A second bin cannot directly import this binary’s private module tree. It requires a library extraction, duplicated module declarations, or another explicit refactor; that may be reasonable, but it is not the claimed one-line `[[bin]]` change. |
| `DEPLOY.md` examples can simply become `termio remote open ukvps`. | `termiod/DEPLOY.md` is a daemon deployment guide. It instructs remote users to invoke `~/.local/bin/termiod`, including over SSH, and says a bare `termiod` depends on the remote `PATH` (`DEPLOY.md:122-217`). | The proposed example has no established installation or routing story on the VPS. A Mac-bundled `scripts/termio` cannot be assumed to exist on that box. The RFC must distinguish a local client command from commands an SSH user runs on the host. |

## Contradictions with the settled protocol and server-plane RFCs

### The proposed negotiation mechanism already exists

The protocol RFC does not merely suggest versioning. §C.3 specifies the same
`min_proto..proto` exchange, highest-common selection, and an incompatible
error. It also commits old-client/new-host and new-client/old-host operation at
the intersection for `proto:1`. Calling the current model “hard-refuse on
mismatch” conflates two distinct boundaries:

- Protocol versions correctly hard-refuse when no common range exists.
- Payload encodings currently refuse unknown bytes, because snapshot encoding is
  deliberately unstable until v1 and the old snapshot encoding lost necessary
  theme information.

The RFC can propose a one-version support window, but it must say it changes the
payload-encoding policy in §C.3 rather than discovering a missing protocol
mechanism. It also needs a selected-protocol field in `hello_ok` semantics if
clients are to behave differently by negotiated version; today `HelloOk` has
`proto`, capabilities, identity, build version, and home, but no explicit
support range.

### “No TCP listener, ever” directly contradicts both tree and protocol

The protocol RFC says Unix socket only is the **default**, not that TCP is
forbidden. Its transport table reserves WSS + relay for later. The current tree
has implemented that later path: `termiod serve --wss` binds only loopback,
requires a pairing token, and forwards the framed protocol to the local daemon.
`DEPLOY.md` §“Serving a phone or a browser” documents the tunnel/TLS setup.

The scope claim is also aspirational, not descriptive. `DEPLOY.md` says the QR
token gives its holder full access to the daemon. The WSS bridge carries the
same protocol; no token claim enum, per-verb authorization check, or
loopback-invisible control catalog exists in `protocol.rs`. A closed
session-plane-only tier needs explicit authorization carried through every
transport and enforced in the daemon before the docs can promise it. Until
then, the safe current statement is the opposite: do not disclose the pairing
token to a party you would not trust with the daemon.

### P1/P2 collide with the server-plane migration

`20260819-unify-server-plane.md` §6 places the CLI move at Stage 10, after:

1. device file reads and foreground parity;
2. a per-device connection object and reconnect model;
3. supervision on both platforms;
4. companion decoupling from `PTYProcess`;
5. one full default-on release; and
6. deletion of the local PTY fork.

That RFC says the ordering is deliberate: the CLI should move only once there
is one session backend, otherwise every port is built twice. §8’s #5 ignores
that order by placing the Rust CLI port immediately after the handshake change.
Its #6 “single API policy” is also impossible to enforce as phrased while the
document retains `termio sessions --json` as a public app-socket contract and
P1 forwards its new `remote` namespace through `termiod`.

There is a further named-binary conflict. The server-plane RFC §7.8 rejects a
daemon named `termio`: installed hooks have an absolute `termio` support-copy
path, and a router named `termio` cannot dispatch to another binary with that
same name. This RFC does not propose renaming the daemon, but P2’s “Rust
`termio` bin” plus a script shim has the same path-ownership question. It must
name the installed binary paths and invocation graph for release and dev before
claiming `argv[0]` channel selection removes the existing build-time rewrite.

## §8 ordering defects

1. **#1 cannot be a useful skew diagnostic before its data sources exist.** The
   script can print its own stamped version, but it has no current remote-host
   registry, no stated source for “recent `remote` targets,” and cannot obtain
   the running app version or daemon protocol without defining failures and
   transport calls. `termiod status --json` already knows binary/daemon state
   locally; decide whether `termio version` wraps that first instead of creating
   a parallel probe.

2. **#2 changes public documentation before the target command is deployed.**
   The shell script can proxy a bundled daemon on this Mac, but that does not
   make `termio remote …` available on Linux boxes, where DEPLOY currently
   teaches `termiod`. Establish the supported invocation locations and binary
   layout before rewriting DEPLOY examples.

3. **#3 is not “prose only” if it promises token scoping.** Documenting the
   current full-authority token is prose. Turning it into a bounded credential
   needs protocol and daemon authorization work, so it must not be scheduled
   alongside a doc-only command rename.

4. **#4 should be split.** Range negotiation is already shipped. The remaining
   tasks are support-window policy, compatibility tests, payload dual-decoding
   rules, and a structured incompatible error with both advertised ranges. They
   should precede any payload-format change, not be described as a prerequisite
   for unrelated CLI packaging.

5. **#5 must wait for the server-plane Stage 10 prerequisites or explicitly
   replace them.** A Rust client is not inherently blocked on range policy; it
   is blocked on the two-session-backend fork and unresolved command ownership.
   Moving it early repeats the work the accepted plan intentionally avoids.

6. **#6 cannot be a standing policy without an exception list.** `open` and
   `notify` are explicitly app-plane. `sessions --json` remains app-socket
   backed during the migration. The policy should name these temporary public
   contracts, their replacement protocol verbs, and deletion gates; otherwise
   review has no objective way to reject a new app-socket command.

## Required rewrite before approval

- Replace the handshake premise with the actual existing range negotiation and
  specify only the missing support-window, error-shape, and payload-compatibility
  work.
- Reconcile the security section with the shipped loopback WSS listener. Either
  document its current full authority or design and stage real scoped-token
  enforcement; do not label the latter as zero-code policy.
- Inventory every person-facing `termiod` command, including top-level and
  `remote` aliases, and state its destination, compatibility period, and host
  installation story.
- Replace the “second bin is cheap” assertion with the necessary crate/module
  architecture and a concrete release/dev/hook path plan.
- Rebase §8 on `unify-server-plane` Stage 10, or explicitly supersede that
  ordering with prerequisite gates for one session backend, connection
  ownership, supervision, companion decoupling, and the default-on soak.

## Round 2

The rewrite resolves the first review's central objections: it now treats
range negotiation as shipped, accurately describes the loopback WSS listener
and its full-authority token, costs scoped authorization as protocol/daemon
work, distinguishes Mac-side from on-box documentation, and puts P2 inside
`unify-server-plane` Stage 10. The lib-extraction correction is also directionally
right: `Cargo.toml` has one `termiod` bin and `main.rs` owns the module tree, so
a second client needs a library/module refactor rather than only another
`[[bin]]` entry. The current build really does rewrite the shell client's three
top-of-file bindings for the dev bundle (`scripts/build-app.sh:188-198`), and
`CommandLineTool.supportCopyURL` is the stable hook path the rewrite must keep.

Two factual defects remain, and one new one was introduced.

### 1. §1.1 is still not a full verb inventory

The section labels its list “in full,” but `termiod/src/main.rs` also exposes
`serve`, `handoff`, `stop`, `set-status`, and `agent` (whose public subcommands
are `install` and `uninstall`). They are absent from the claimed top-level
inventory. The destination table mentions most of them later, but that does not
make the source inventory complete; it even names `daemon`, which is **not** a
current `termiod` subcommand. The host command is `serve`.

This matters for the stated deprecation map. `stop` is an operator command with
destructive consequences, `handoff` is the upgrade path, `agent install` owns
host integration, and `set-status` is the hook target. They need an explicit
destination and compatibility decision, rather than disappearing between the
two tables. The `scripts/termio:670-687` citation itself is now sound: those
lines select and `exec` the daemon for `agent report`.

### 2. §2 overstates what the wire presently sends back

The prose says `hello` carries `proto` and `min_proto` “in both directions.”
The current Rust wire shape does not: `Control::Hello` carries both fields, but
`Control::HelloOk` has only `proto` (`termiod/src/protocol.rs:520-555`). The
daemon currently accepts only protocol 1 (`daemon.rs:1115-1158`), so the
distinction has not bitten yet, but a genuine range negotiation needs the host
range represented in its reply or a precisely defined meaning for `HelloOk.proto`.

This is also an unresolved tension between the protocol document and the tree:
§C.3 says host and client each advertise `[min_proto, proto]`, while the
implemented `hello_ok` does not carry the host minimum. The RFC should call out
that implementation/document gap instead of saying the two-direction mechanism
is already fully present.

### 3. §3's “no new probe” table lacks the retained data

`HelloOk.version` is correctly described as the running daemon's build stamp;
`termiod status --json` correctly reports the local binary and running daemon
versions. But the Mac registry does not retain complete `hello_ok` results or a
protocol value. `TermiodDevice` persists only `id`, `daemonVersion`, and routes
(`Sources/termio/Terminal/Termiod/TermiodDevice.swift:62-80`); its handshake
path records `payload.version ?? payload.host` and drops `proto`
(`TermiodClient.swift:615-634`). Thus “stored `hello_ok` results for remotes the
daemon has spoken to” is wrong twice: they are stored device observations from
the **Mac client**'s handshake, not daemon history, and they contain no remote
protocol number.

Consequently the proposed remote `proto 1` row cannot be produced from the
claimed sources without either treating protocol 1 as a hard-coded current
constant, persisting the negotiated protocol/build observation, or making a new
probe. Pick one and say how staleness is marked. This is the one required-rewrite
item still materially incomplete: the version display has an inventory/source
story for builds, but not yet for every displayed field.

### 4. The Stage-10 deference is now correct, with one scope caveat

§1.4 and §8 #6 correctly defer the Rust client to
`unify-server-plane` Stage 10 and retain that stage's one-backend gate. P1 is
separately described as a shell-only command collection, so it does not revive
the rejected early Rust port.

The remaining design decision is implementation-facing rather than a
contradiction: P1 says the shell will exec “the bundled `termiod`,” but the
current shell has no bundled-daemon locator; its only daemon lookup in
`agent report` is `TERMIOD_BIN`, then `~/.local/bin/termiod`, then `PATH`
(`scripts/termio:670-677`). Define the release/dev resource path or a single
helper before calling P1 independently shippable. Without that, a PATH-installed
`termio` can select a different daemon than the app bundle that P1 intends.
