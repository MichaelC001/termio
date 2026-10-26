---
title: termiod owns the view
status: draft
type: design
created: 2026-10-25
updated: 2026-10-25
related:
  - 20260730-termiod-session-protocol.md
  - 20261024-client-vt-follows-the-stream.md
  - 20260831-companion-second-protocol-retires.md
  - 20260901-pty-size-is-not-the-write-token.md
---

# termiod owns the view

> Move termio to Rex's state model. Each host's termiod owns what exists on it and
> how it is arranged: projects, groups, panes, focus and zoom. Every client draws
> that view and keeps only its own viewport. The CLI drives the UI from any box.

## Why

The Mac app owns the session tree today. `StateFile` stores workspaces,
projects, sessions, split groups, selection and inspector layouts. termiod owns
the PTYs and a roster. Two places answer "which sessions exist, and where do
they belong?". Four problems follow from that split.

1. **`termio .` fails on a remote box.** It prints "termio open drives the Mac
   app; there is none on this machine" (`termiod/src/bin/termio.rs:1338`). The
   box has no project object, so nothing on the box can create one.
2. **The Mac reconciles two truths.** A closed-session journal, adoption of
   unknown sessions, kill-on-sight, tombstones, `remoteCheckouts` and a
   `legacyDevice` migration all exist to merge the roster into the tree. In
   `Sources/termio` there are 100 matches for `reconcile`, 94 for `adopt`, 60
   for `journal` and 48 for `tombstone`. Adoption files a session by matching
   its cwd against project paths. When nothing matches, the session lands as a
   loose terminal, and the `project` field in its roster row is ignored.
3. **The roster is polled.** `rosterFetches` asks again on a refresh. A
   session started on a box shows up in the Mac only on the next fetch.
4. **The CLI cannot drive the UI from a box.** `termio sim` and `termio notify`
   go over `app.sock`, which exists only on the Mac.

## What Rex does

Sources: Rex Beta 0.1.0 (build 1408). I read the API documentation embedded in
the server binary and the symbol names in the Swift client binary. I did not
run Rex. Rex is Superlogical's product, the same company §H.7 of the session
protocol cites.

| State | Owner | Evidence |
| --- | --- | --- |
| Sessions, windows, window order, labels | server | `session.view` |
| Tiled splits and floating layers | server | `session.new_split`, `session.float_block` |
| Focus | server | "Each window keeps its own focused block, which then receives typing." |
| Zoom | server | "the zoom ends when focus moves to another block in the window" |
| Block owner and terminal size | server | "the terminal's size, its owner, and the size each client last requested" |
| Keymap and config | server | `init.lua`, pushed with a `generation` |
| Which session a client shows | client | `session.select` is a client action |
| Sidebar, font size | client | `client.sidebar.toggle`, `client.font.*`, `blockFontPointSizeOverrides` |
| Scroll position, text selection | client | `autoscroll` and selection symbols live only in the client binary |

Mechanisms:

- **Revision.** "`revision` starts at zero for a new session and goes up by one
  each time the view changes. Compare revisions only within one session, and
  keep the view with the highest revision." Every mutation returns the new
  revision.
- **Events.** `window_created`, `window_closed`, `active_window_changed` and
  similar events arrive before the `session_view_changed` event for the same
  change.
- **Blocks have flavors.** A pane is a block of a type: `com.superlogical.terminal`
  and `com.superlogical.onboarding` ship today. Server-side block plugins add
  more. The onboarding block shows the split: "Each client draws the walkthrough
  itself, and the block only records which step it is on."
- **Client actions.** The CLI can drive client-only UI. `rex -C studio do
  client.sidebar.toggle` goes through the server to the named client. With no
  client connected, the server answers "no app client is connected".
- **The CLI inside a pane** finds its server through `REX_SESSION`,
  `REX_BLOCK` and `REX_SERVER`, over a local unix socket. A Rex project is a
  server session: `rex new Project -c "$project_dir" --window Terminal`.
- **Held changes.** A change made while the home server is away "is held on
  this machine and sent the next time".

Rex's rule: **what exists and where it sits is shared. What this screen shows
right now is local.**

### Layout in the host is not the tmux tax

§H.7 rejects "panes/tabs/layout in `termiod`" as "the tmux dead end". The tax
that §A measured is something else: tmux parses every byte into a grid and
diffs the grid to clients. Layout is a small tree. It changes at human speed,
on the control plane, and never touches the byte path. Rex keeps layout in its
server and still tees raw bytes. This design does the same, and the anti-100×
invariant stands unchanged.

## The design

### Names

The protocol's §B already uses **workspace** for a directory scope, and the
Mac app uses **workspace** for the set of machines a window shows. This doc
avoids the bare word.

| Name | Meaning | Rex equivalent |
| --- | --- | --- |
| **host** | one termiod on one machine | server |
| **project** | a directory registered on a host | session |
| **group** | an arranged set of panes inside a project | window |
| **pane** | one cell of a group, of one kind | block |
| **session** | one PTY and its process; a terminal pane shows one | terminal block's process |
| **view** | everything above for one host, with a revision | `session.view` |
| **Mac workspace** | the hosts one Mac window shows; client state | none |

A host also keeps groups with no project, for loose terminals. Today these are
the rows under TERMINALS.

### The view

Each host keeps one view:

```
view {
  revision: u64
  projects: [ { id, path, label, pinned, groups: [group] } ]
  loose:    [group]                      // groups with no project
}
group { id, label, root: node, focused: pane_id, zoomed: pane_id? }
node  = split { direction, ratio, before: node, after: node } | pane
pane  { id, kind, label, state }        // state is the kind's own record
```

- `revision` rises by one on every change, across the whole host. One counter
  per host is enough. A host's view is one object, and a client never compares
  revisions across hosts.
- Each mutation is one atomic step under one lock. Mutations are validated on
  the host and fail with the existing error model: `NoSuchSession`, `Conflict`
  and a new `NotFound`.
- The host writes the view atomically to its state directory after each
  change, coalesced. The view survives a termiod restart and a handoff.
  PTYs do not survive a reboot. A terminal pane whose session ended stays in
  the view and shows its end reason from the existing tombstones.

### Sync: the view is a §C.10 resource

The view is a new resource kind, `view:host`. Its `seq` is the revision. This
reuses the subscribe, ring, replay and `gap` rules that §C.10 already defines,
so there is no second reconnect path.

```
→ subscribe_resource {resource:"view:host", since?:41}
← subscribed {resource:"view:host", seq:44, gap:false}
← E {ev:"view_changed", resource:"view:host", seq:42, view:{…}}
```

Each `view_changed` carries the **whole view**, not a delta. A view is a few
kilobytes. The client replaces its copy and never merges. A `gap` means
nothing special, because every event is already complete.

The roster keeps its role for live per-session facts that change often:
status, title, foreground process. The view stores only placement.

### Mutations

New control ops, all `c→h`, each replying `{seq}` with the new revision:

| Op | Effect |
| --- | --- |
| `project.add {path, label?}` | registers a directory; idempotent on the canonical path |
| `project.remove {project}` | removes the row; kills its sessions, as Remove Project does today |
| `project.set {project, label?, pinned?, index?}` | rename, pin, reorder |
| `group.new {project?, label?, pane}` | a new group with one pane |
| `pane.split {pane, direction, ratio?, new}` | splits a pane; `new` describes the new pane |
| `pane.close {pane}` | closes a pane; closing a terminal pane kills its session |
| `pane.move {pane, to_group, beside?, direction?}` | moves a pane, including Group with and Ungroup |
| `pane.focus {pane}` / `pane.zoom {pane, on}` | focus and zoom, stored per group |
| `pane.set {pane, state}` | changes a pane's kind state, such as the open file |
| `split.resize {group, node, ratio}` | moves a divider |

A new terminal pane is created in the same step as its session. `create`
gains an optional `place {group | project}`. Without it, the host makes a new
group in the project that contains the cwd, or a loose group. So **every
session on a host has a pane.** Adoption has nothing left to do.

User-facing copy keeps VOICE.md's vocabulary: "Group with", "Ungroup",
"Close Session". The op names above are protocol names only.

### Pane kinds

| Kind | State on the host | Data comes from | Host requirement |
| --- | --- | --- | --- |
| `terminal` | `session` | the terminal plane | any |
| `files` | `root`, `open_path?`, `line?` | `fs.*`, §C.12 | any |
| `git` | `root`, `tab` (changes or history), `commit?` | `git.*`, §C.13 | any |
| `simulator` | `device` | the Mac app's simulator driver | macOS with Xcode |

- The host lists the kinds it supports in `hello` capabilities, like Rex's
  block types. A Linux host never offers `simulator`.
- Kind state is **what the pane is**. File contents, the git index and
  simulator frames are never stored. Clients read them when they draw.
- These kinds replace the inspector. `inspectorLayouts` in `StateFile`, the
  per-session panel with its tab, file path, line and open flag, becomes
  ordinary panes in the group. A docked inspector is a split with a fixed
  ratio.

### What each client keeps

| Client state | Why it stays local |
| --- | --- |
| which project and group each window shows | two screens may look at different things |
| sidebar visibility and width, font size | presentation |
| scroll position, text selection, expanded folders, diff folds | changes on every gesture; Rex keeps these local too |
| which hosts a Mac workspace shows, and their order | a view over several hosts, owned by no host |
| the last view of each host, marked stale | lets an offline host still render |
| the outbox | intents for a host that is not reachable |

Focus and zoom are **shared**, as in Rex. Focusing a pane on the phone moves
focus on the Mac.

### Client actions routed through the host

A client lists the actions it performs in `hello`: `client_name` plus
`actions`. One new op routes a call to it:

```
→ client.invoke {client:"mac", action:"sidebar.toggle", args:{}}
   host forwards to that client's control channel as E {ev:"client_action", call_id, …}
   client answers client.reply {call_id, result | error}
← ok {result} | error {code:"no_client"}
```

- `client` names a client by `client_name`. When it is omitted and exactly
  one app client is connected, that client is used, as in Rex.
- `select {project, group}` is how the CLI shows something on a screen. It
  never changes the view.
- **The simulator driver becomes client actions on the Mac.** `termio sim tap`
  from any box invokes the Mac client through the Mac's own termiod. The
  simulator pane lives only in groups on the Mac's host.
- `notify` becomes a client action too. After that, the CLI needs only the
  termiod socket, and `app.sock` retires.

### CLI

A terminal pane's environment carries `TERMIO_SESSION`, which exists today,
and a new `TERMIO_PANE`. The CLI talks to the host through `TERMIOD_SOCK` or
the default socket path.

| Command | Calls |
| --- | --- |
| `termio .` / `termio open DIR` | `project.add`, then `group.new` with a terminal pane, then `select` if a client is connected |
| `termio open FILE[:LINE]` | `pane.split` beside `TERMIO_PANE` with a `files` pane |
| `termio split [--right\|--down] [-- CMD]` | `pane.split` with a terminal pane |
| `termio focus PANE` / `termio zoom [--off]` | `pane.focus` / `pane.zoom` |
| `termio view [--json]` | prints the view |
| `termio do [--client NAME] ACTION [ARGS]` | `client.invoke` |

`termio .` now works the same on a laptop and on a VPS. On a box with no
client connected, it registers the project and prints where it will appear.

### Size is unchanged

This design does not adopt Rex's owner rule for terminal size. Size follows
`20260901-pty-size-is-not-the-write-token.md`: leaving is not using, and the
iOS keyboard occludes the screen instead of resizing it.

### Offline hosts and the outbox

- A client renders an unreachable host from its cached view, marked stale.
  Its rows can be read and opened as history. They cannot be changed in place.
- A change to such a host goes into the client's outbox: the op, the host, and
  the revision it was made against. On reconnect the client sends the outbox
  in order. An op whose target no longer exists fails with `NotFound`. The
  client drops it and logs it.
- The outbox replaces the closed-session journal (`closedDaemonSessions`) and
  kill-on-sight. A close made offline is an outbox entry, not a record the
  sweep has to match against later.

## What this deletes

- The closed-session journal and kill-on-sight.
- `adoptDeviceSession`, `adoptionProjectIndex` and cwd-prefix matching.
- `remoteCheckouts` and `legacyDevice` on `Project`.
- Roster polling through `rosterFetches` for placement.
- `inspectorLayouts`, `splitRoot`, `splitGroups`, `projects` and
  `workspaceSelections` in `StateFile`. What remains is the client state in the
  table above.
- `app.sock` and the Mac-only half of the CLI.

## What stays

- The anti-100× invariant. The view is control-plane state, and no view work
  runs on the byte path.
- One protocol over every transport. The view, its ops and client actions are
  ordinary control frames.
- No embedded SSH or crypto.
- Single writer, many readers. The write token is unrelated to focus: focusing
  a pane does not claim the token.

## Supersedes

- **CLAUDE.md non-negotiable #5**, "No nested window manager in the host". New
  text: "Layout lives in termiod as control-plane state. Nothing about layout
  runs on the byte path."
- **Session protocol §H.7**, which rejects layout in termiod. It is replaced by
  the section "Layout in the host is not the tmux tax" above.
- **Session protocol §B**, where a workspace is "implicit" and "never created
  or destroyed explicitly". A project is now registered explicitly. The
  implicit directory scope for `fs:` and `git:` resources stays as it is.

## Migration

1. A new termiod starts with an empty view and builds one from its live
   sessions: one group for each session, filed in a project when its
   `workstream.project` is set, loose otherwise.
2. On its first connect to that host, an updated Mac sends `view.import`
   with the tree from its `StateFile`. The host accepts it only while no
   client has changed the view since startup. The import keeps the Mac's
   grouping, labels, pins and order, and matches sessions by daemon name.
3. A second Mac that connects later gets `Conflict` and adopts the host's
   view. Its own tree for that host is dropped.
4. The Mac keeps a copy of the old `state.json` for two releases, untouched,
   as a recovery path.

## Phases

Each phase ships on its own.

1. **View and projects.** Add the `view:host` resource with projects, groups
   and terminal panes. Add `project.add`, `group.new`, placement on `create`,
   `view.import` and `termio .` on every host. The Mac draws the sidebar from
   the view. This fixes the remote `termio .` failure.
2. **Arrangement.** Add `pane.split`, `pane.move`, `pane.close`,
   `pane.focus`, `pane.zoom` and `split.resize`. The Mac's split view draws
   from the view. Add the CLI verbs `split`, `focus`, `zoom` and `view`.
3. **Client actions.** Add `client.invoke` and `client.reply`. Move `sim` and
   `notify` onto them, then retire `app.sock`.
4. **Pane kinds.** Add `files`, `git` and `simulator` panes. Remove the
   inspector and `inspectorLayouts`.
5. **Outbox.** Replace the closed-session journal. Delete adoption.
6. **Phone.** iOS draws the view directly from termiod, together with
   `20260831-companion-second-protocol-retires.md`.

## Risks

- **Migration can lose a sidebar.** A wrong import rearranges or drops rows.
  The two-release copy of `state.json` is the recovery path, and phase 1 needs
  a test that imports a real `StateFile`.
- **Shared focus is a behavior change.** Two Macs on one host now move each
  other's focus. Rex accepts this. A person with two screens may not.
- **Remote latency on every arrangement change.** A split on a remote host
  waits for the reply before it draws. On a slow SSH link that may feel
  sluggish. Phase 2 must measure it before deciding on optimistic drawing.
- **The phone draws a Mac-shaped tree.** It shows the focused pane of a group
  full screen and switches panes without changing the tree. Zoom on the phone
  is therefore implicit, while zoom on the Mac is shared state.
- **A group cannot span hosts.** I have not checked whether "Group with" can
  join sessions from two machines today. If it can, that ability ends.

## Open questions

1. Does Rex's `session_view_changed` event carry the view, or only the
   revision? I did not check. This design sends the whole view either way.
2. Should arrangement changes draw optimistically on a remote host? See the
   latency risk.
3. Should pins and project order be per host, or should a Mac workspace that
   shows several hosts own one combined order? This design makes order per
   host and leaves the cross-host order to the client.
4. Should the Mac's "workspace" keep that name once it means only "the hosts
   this window shows"?
