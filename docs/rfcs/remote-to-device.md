---
title: Retire "remote" — every machine is a device
status: draft
type: rfc
created: 2026-08-14
updated: 2026-08-16
related:
  - 20260805-termiod-device-architecture.md
  - 20260730-termiod-session-protocol.md
---

# Retire "remote" — every machine is a device

> Delete "Remote" from every verb in the product, replace the per-session remote
> host with a current-device context carried by a sidebar indicator, and split
> device *reach* (a verb, sourced from `~/.ssh/config`) from device *management*
> (Settings, sourced from what termio itself learned).

## Motivation

The word "remote" is a description of the *road*, not of the thing at the end of
it. Carrying it in the UI forces every feature to exist twice — once for here,
once for there — and the second copy rots. Today that shows up as:

- Two verbs that mean the same thing as their local counterparts:
  `New Remote Terminal` (`SidebarView.swift:797`, `App.swift:1452`) and
  `Clone on Remote…` (`SidebarView.swift:830`).
- A dead end at the exact moment a new user arrives:
  `New Remote Terminal ▸ (No SSH hosts in ~/.ssh/config)` says what is missing
  and not one word about what to do next.
- Two identities for one machine on the session record — `sshHost` (a plain
  `ssh` in a *local* PTY, `Models.swift:298`) beside `termiodRemoteHost`
  (`Models.swift:311`), which the device architecture has already superseded.

The architecture side of this is settled. `20260805-termiod-device-architecture.md`
§0 already lists what it retires: the local/remote fork, `TERMIO_TERMIOD` as a
flag, per-session remote host, and **"every menu verb with 'Remote' in its
name"**. What has never been written down is the *shape* that replaces them —
where the device lives in the interface, what follows it, and who owns the list
of devices. That is this RFC.

## Already decided — do not reopen

| Decision | Where |
| --- | --- |
| A device's identity is its `termiod` `host_id`, not an SSH alias | device architecture §0.2 |
| Alias and `deviceID` **coexist**; the alias is the bootstrap identity, the device id the stable one, backfilled on first `hello_ok` | device architecture §9.5 |
| Version skew is negotiated (`proto`/`min_proto`), never lockstep; installs are content-addressed so versions coexist | device architecture §6 |
| Workspaces belong to the device, not to a viewer | device architecture §2.2 |
| The server never decides presentation | device architecture §4 |
| The user's `~/.ssh/config` is authoritative — read it, **never override it** | `CLAUDE.md`, non-negotiable #3 |

That last row was previously paraphrased here as "never write it", which is
stricter than the rule actually says (`CLAUDE.md:43-44`). The distinction is
load-bearing: appending a user-authorised `Host` block does not override
anything, which is what keeps the shipped **Add Host** legitimate.

## The ownership rule

One question decides where every piece of this belongs:

> **Did termio produce this state itself?**

Yes → termio may store it, and it belongs in Settings. No → termio reads it and
never owns a second copy. The rule is what makes "Add Device…" the wrong verb:
it implies a termio-owned roster, which would immediately fork from the
`~/.ssh/config` it was copied from — a changed port or jump host in the real
file, stale in ours.

| State | Produced by | Home |
| --- | --- | --- |
| The list of reachable machines | the user's `~/.ssh/config` | **`Settings ▸ SSH`** — it already ships; see the correction below |
| Device colour, display name, "forget" | termio | Settings ▸ Devices |
| `termiod` version, install/upgrade status | termio's probe | Settings ▸ Devices |
| Merged device identities (§9.5) | termio | Settings ▸ Devices |
| A free-form `user@host` target the user typed | termio (it cannot be written to `~/.ssh/config`) | Settings ▸ Devices, entered through the verb |

**Correction — `Settings ▸ SSH` already ships, and it writes.** The first row as
originally drafted said "read-only; no Settings entry". Both halves are false.
`Sources/termio/Settings/SSHSettingsTab.swift` is a shipped tab that lists every
alias, probes reachability per host, opens the raw config in the editor, and
appends `Host` blocks through **Add Host** — "a block indistinguishable from a
hand-written one". So this RFC as drafted proposes `Settings ▸ Devices` beside an
existing `Settings ▸ SSH`: two lists of machines, built from overlapping sources,
with no stated boundary. That is the two-copies problem instantiated inside the
Settings window by the document that exists to delete it.

The ownership test cannot resolve it either, because reachability is produced by
termio's own probe and therefore qualifies as "termio produced this state itself".
**Decided in Open question 5: the two tabs coexist, split at the handshake** —
SSH owns routes, Devices owns identities. The ownership rule survives as a
tiebreaker for *fields*, but it is not what separates the two surfaces; the
handshake is.

This is why the analogy to `Settings ▸ Agents` misleads: an agent manifest **is**
a termio-owned list, so `Add Agent` belongs there. A device list is not.

## Vocabulary

Dead words, in the same sense that "Close Pane" and "Unsplit" are dead:

| Dead | Replacement |
| --- | --- |
| New Remote Terminal | **New Terminal** — one plain item when there is a single device; a device submenu once there are more |
| Clone on Remote… | **Clone to \<device\>…** |
| "remote session", "remote host" | "a session on \<device\>" |
| — (new) | **Connect to…** — the verb that reaches a machine not used before |

## Interface

Three moves, each with a precedent that has shipped.

**1. A device indicator, always visible, never loud.** Dia puts one in the
sidebar header and a second in the pinned-tab dock
(`TabSidebar.SidebarProfileIndicatorButton`,
`TabSurface.TabDockProfileIndicatorButton`, driven by a dedicated
`ProfileIndicator` framework module). Clicking it opens the switcher;
`MenuBar.ProfileSwitcherMenuBuilder` mirrors it into the menu bar.

**2. Colour is the identity, and it bleeds into the surface.** Dia carries a
per-profile colour (`MenuIcons.ProfileColorSwatches`,
`Preferences.ProfileColorButton`) and back-fills it into the theme of everything
that profile owns (`applyProfileColorIfNeeded(destinationProfileID:arcSpaceInfo:)`,
`didBackfillSpaceThemesFromProfileColor`).

This matters more for a terminal than for a browser. Picking the wrong profile
logs you into the wrong account; picking the wrong machine runs `rm -rf` on the
wrong disk. Colour is readable in peripheral vision; a text label is not.

**3. The whole concept collapses when there is one device.** Dia keeps a
`singleProfileCaseNewWindowMenuItem` for exactly this: with one profile the menu
is the plain verb, and only a second profile grows the submenu. **Someone who
never leaves their laptop must never pay for this feature** — no indicator, no
submenu, no Settings tab.

**Where each entry point goes**, following Dia's own split
(`createProfileClicked` on the switcher, `ManageProfileSettingsView` in
preferences), and Apple's (Finder's `Connect to Server` is a verb; accounts are
in Settings):

- Switcher (sidebar) — known devices, then **Connect to…** at the bottom, which
  lists `~/.ssh/config` aliases not yet used and accepts a typed `user@host`.
  First use installs `termiod` (`ensureRemoteReady` already does this).
- **Settings ▸ Devices** — colour, display name, forget, install/upgrade status,
  merge.

## What the current device scopes

VS Code Remote binds a window to a host: switching means reopening the window and
reloading everything. That is rejected — it destroys the one thing termio is for,
seeing every agent at once. But an unscoped roster is equally wrong, which is the
substance of the pushback that produced this RFC: without a current device,
"which machine am I about to type on" has no answer.

| Follows the current device | Does not |
| --- | --- |
| New Terminal / New Project | Sessions already running — **switching evicts nothing** |
| File tree, git panel, search, editor | The session list, which stays cross-device with a device column |
| Clone to… | — |

Cross-device awareness is carried by a **badge on the indicator** when another
device has an agent in `needs-you`, not by flattening every device into one list.
This closes device architecture §9.3, which currently records the question as
"Unproven in use".

**One guardrail a browser does not need.** Destructive actions — Close Session,
file deletion — deserve a heavier confirmation when the focused device is not
this machine. Colour is a reminder, not a stop.

## Data model

The rename does **not** collapse the two identities; §9.5 explains why it cannot
(a container must exist synchronously at session creation, before any handshake).

| Field | Now | After |
| --- | --- | --- |
| `Session.sshHost` (`Models.swift:298`) | plain `ssh` in a local PTY — the pre-device road | **removed**; such a session is a device session |
| `Session.termiodRemoteHost` (`Models.swift:311`) | source of truth for where a session runs | demoted to a route hint (the alias); `deviceID` is the truth |
| `Session.deviceID` | backfilled on first handshake | unchanged, promoted to primary |
| `Project.remoteCheckouts` | device-keyed already | unchanged |

Decoding stays tolerant (`decodeIfPresent`, as today) so a state file written by
any shipped build still loads.

## Staging

**PR #177 has merged** (`66b1722`), so `main` now carries `termiod/`,
`Sources/termio/Terminal/Termiod/`, and the termiod CI workflow. The blocker
this section originally described is gone.

**Corrected order.** The draft staged the switcher first and never staged the
flag at all. That reverses the settled architecture, which orders the work: own
the connection (§4) → **delete the fork, including `TERMIO_TERMIOD`** (§5) →
device switcher (§6), and marks §6 *"Only meaningful after step 5 — before it,
local is still a special case"*
(`20260805-termiod-device-architecture.md:513-531`). Since that document is
listed above under "do not reopen", the RFC cannot contradict its ordering.

The reversal is not academic. `Termiod.isEnabled` reads the flag
(`TermiodClient.swift:17-20`) and surface creation still chooses between termiod
and an in-process `PTYProcess` (`TermioStore+TerminalSurface.swift:214-231`), so
with the flag off, opening on a non-local device stops at an alert reading *"Set
TERMIO_TERMIOD=1 and relaunch termio"* (`TermioStore+Termiod.swift:468-476`). A
device switcher above that fork shows a device the product cannot open a session
on.

1. **Own the connection.** `TermiodConnection` per device — transport, health,
   reconnect — so readiness is a real state and a transport failure stops being
   reported as `exited`. Architecture §4.
2. **Delete the fork.** Remove `TERMIO_TERMIOD`, the in-process `PTYProcess`
   path, per-session remote host, and every "Remote" verb. This is the stage
   with real risk: it makes the daemon a release-critical dependency and changes
   the execution path of *every* session, local included. It is not a rename and
   must not be staged as one.

   **Blocked on foreground-job parity** (Open question 6). Until `termiod`
   reports whether a session has a foreground job, deleting the in-process path
   silently deletes the close confirmation for every local session, because the
   check reads `ptyProcesses[session.id]`. Parity ships first, or this stage
   removes a safety behaviour users already rely on.
3. **Vocabulary and switcher.** Menu titles, the indicator, `Connect to…`,
   single-device collapse, reading readiness from stage 1.
4. **Settings ▸ Devices**, once Open question 5 decides its boundary with
   `Settings ▸ SSH`.
5. **Data model.** Retire `sshHost`, demote `termiodRemoteHost`, migrate.
6. **Merge** (§9.5), which only becomes safe once identities are primary.

## Open questions

1. **Colour assignment.** Auto-assign on first handshake from a fixed palette, or
   make the user pick? Auto is friendlier; a user-picked colour is the one they
   will actually remember under stress.
2. **How far colour bleeds.** Dia goes as far as theming the whole space. A
   terminal's colours belong to the user's theme — the presentation boundary says
   the viewer decides. The tint probably has to stop at chrome (sidebar, title
   bar, indicator) and never touch the grid.
3. ~~**Guardrail strength** for destructive actions on a non-local device: extra
   confirmation, hold-to-confirm, or typed device name.~~ **Closed — the question
   was wrong.** All three options are the local/remote fork wearing a warning
   triangle. The shipped doctrine is narrower and better: `closeConfirmationReason`
   (`TermioStore+ProjectActions.swift:684-692`) confirms on exactly one condition —
   a *shell* with a live foreground job, because that command "exists nowhere
   else" — and deliberately never for agent sessions. Confirm when closing
   destroys the only copy of something; never because of where it runs.

   The live defect is the opposite of the one asked about. That check reads
   `ptyProcesses[session.id]`, and `hasForegroundJob` exists only on `PTYProcess`
   (`PTYProcess.swift:923`) with no counterpart anywhere in `termiod/src`. **So a
   remote session with a build running closes silently today, while a local one
   asks** — non-local sessions have *less* protection, not more. The work item is
   to carry the existing rule across the wire (a `tcgetpgrp` on the PTY master,
   one field on `list`), not to add a dialog. Whether that rides in this RFC or
   becomes its own protocol change is Open question 6.

   Forget device and uninstall termiod keep an explicit confirmation: those are
   device-scoped irreversible actions rather than command execution.
4. **Does `Connect to…` belong in the `+` menu too?** Every item in that menu is
   global by rule; `Connect to…` qualifies, but it may not deserve the weight.
   Proposal on the table: add no item — convert the existing dead end
   `New Remote Terminal ▸ (No SSH hosts in ~/.ssh/config)` *into* `Connect to…`,
   so the slot and weight are unchanged and the motivation's own complaint is
   answered. Both reviews accept the slot and contest what the item does.

5. ~~**Does `Settings ▸ Devices` subsume `Settings ▸ SSH`?**~~ **Decided: they
   coexist, split by handshake.**

   > `Settings ▸ SSH` owns **routes** — anything meaningful *before* `hello_ok`,
   > keyed by an SSH alias, or affecting how OpenSSH resolves and authenticates.
   > `Settings ▸ Devices` owns **identities** — anything learned *after*
   > `hello_ok`, keyed by `host_id`, or describing termiod, device lifecycle and
   > device preferences. A value is never persisted in both.

   So alias reachability stays in SSH; post-handshake device health lives in
   Devices. The rule is stated as a key test precisely so a new field can be
   placed without reopening this.

   Subsuming was rejected because an alias can exist before any device is known,
   and one `host_id` can be reached through several aliases. A single list would
   have to invent device rows for unresolved routes, or hide a second route model
   inside each device — the two-copies problem again, under one tab.

   Accepted cost: two tabs can read as competing machine lists, and users have to
   meet the route/identity distinction. The key rule, distinct status vocabulary
   for *reachable* versus *healthy*, and no duplicated persistence are what buy
   that back.

   **Add Host stays in SSH.** It is an explicit user edit to the authoritative
   file, not a termio-owned route database; after appending, termio rereads the
   file and uses OpenSSH's answer.

6. ~~**Does porting `hasForegroundJob` across the wire belong here?**~~
   **Decided: yes, and it gates stage 2.**

   Not because the rename needs it, but because *this RFC causes the regression*.
   Deleting the in-process PTY path removes a shipped safety behaviour from every
   **local** session — not merely from a remote edge case — so the document that
   proposes the deletion has to own the remedy and gate on it.

   It rides as an **optional additive field** on the existing session payload,
   which needs no `proto` bump: the protocol already treats unknown control ops
   and events as ignorable and its `caps` and error codes as additive.

   Accepted cost: this turns a vocabulary-and-UI RFC into a shipped Rust/Swift
   protocol change carrying version-skew semantics. Splitting it out would not
   remove the dependency — it would only let the convergence plan claim a parity
   it does not have.

   Skew rule: an older daemon that omits the field must preserve today's
   no-confirm behaviour. It must never be read as "unknown, so confirm", which
   would tax every close on exactly the sessions the shipped rule deliberately
   exempts.

7. **What does an unreachable device look like?** Device identity is about to
   appear in the sidebar, the menus, and the switcher, and nothing in this draft
   says what any of them render when the device cannot be reached. Both reviews
   raise it independently; there is prior pain here, where a stale tunnel URL
   produced "list works but terminal unauthorized".
