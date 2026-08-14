---
title: Retire "remote" — every machine is a device
status: draft
type: rfc
created: 2026-08-14
updated: 2026-08-14
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
| The user's `~/.ssh/config` is authoritative — read it, never write it | `CLAUDE.md`, non-negotiable #3 |

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
| The list of reachable machines | the user's `~/.ssh/config` | read-only; no Settings entry |
| Device colour, display name, "forget" | termio | Settings ▸ Devices |
| `termiod` version, install/upgrade status | termio's probe | Settings ▸ Devices |
| Merged device identities (§9.5) | termio | Settings ▸ Devices |
| A free-form `user@host` target the user typed | termio (it cannot be written to `~/.ssh/config`) | Settings ▸ Devices, entered through the verb |

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

**This lands after PR #177.** That branch is 73 commits ahead of `main` at
+20,084/−660 and still a draft; `main` has no `termiod/` directory and no
`Sources/termio/Terminal/Termiod/` at all. Renaming now enlarges the diff that is
already hard to merge, and no worktree cut from `main` can build against a device
model that does not exist there.

1. **Vocabulary and switcher.** Menu titles, the indicator, `Connect to…`,
   single-device collapse. Client-only, no persistence change, independently
   revertable.
2. **Settings ▸ Devices.** Colour, name, forget, install status.
3. **Data model.** Retire `sshHost`, demote `termiodRemoteHost`, migrate.
4. **Merge** (§9.5), which only becomes safe once identities are primary.

## Open questions

1. **Colour assignment.** Auto-assign on first handshake from a fixed palette, or
   make the user pick? Auto is friendlier; a user-picked colour is the one they
   will actually remember under stress.
2. **How far colour bleeds.** Dia goes as far as theming the whole space. A
   terminal's colours belong to the user's theme — the presentation boundary says
   the viewer decides. The tint probably has to stop at chrome (sidebar, title
   bar, indicator) and never touch the grid.
3. **Guardrail strength** for destructive actions on a non-local device: extra
   confirmation, hold-to-confirm, or typed device name.
4. **Does `Connect to…` belong in the `+` menu too?** Every item in that menu is
   global by rule; `Connect to…` qualifies, but it may not deserve the weight.
