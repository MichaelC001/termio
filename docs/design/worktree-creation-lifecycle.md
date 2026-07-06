---
title: Git worktree creation & lifecycle (Codex-aligned)
status: draft
type: design
created: 2026-07-06
updated: 2026-07-06
related:
  - worktree-information-architecture.md
---

# Git worktree creation & lifecycle (Codex-aligned)

> How termio *creates*, *names*, *branches*, and *cleans up* git worktrees for agent
> sessions. The sibling IA doc covers how worktrees are *presented*; this covers the
> mechanics it deferred.

`worktree-information-architecture.md` shipped phase 1 (the three-level sidebar +
live branch label) and explicitly deferred "isolate-on-demand" and the
"create-isolated entry." This doc specifies that deferred creation path, aligned to
the **OpenAI Codex desktop** model — which has thought through the failure modes
(branch-in-two-places, missing `.env`, unbounded disk) that a naive version hits.

## Guiding principle

**Match Codex exactly; diverge only where termio's architecture forces it.** During
design, every reflex to *add structure* (sibling dirs, Application Support nesting,
per-project subdirs, forced branch prefixes) turned out to buy nothing over Codex's
plainer shape. The two justified divergences are both architectural, not aesthetic:

1. termio is a **terminal**, so the worktree's cwd basename is visible everywhere
   (shell prompt, tab title) → the folder name must be self-describing.
2. termio already has `Session.worktreePath` and resolves it as the PTY cwd
   everywhere → bind the worktree to a **session**, reusing existing plumbing.

## What Codex does (the model we're following)

- **Worktree per task/thread**, auto-managed — the user never hand-picks a path.
- Central app-owned dir: `~/.codex/worktrees/thread-*`.
- **Detached HEAD by default** — no branch auto-created. A "Create branch here"
  action materializes a branch only on explicit intent (avoids branch-name
  pollution + git's one-branch-one-checkout conflict).
- Finish by commit/push/PR from the app, or "hand off" changes to the local
  checkout.
- Bounded retention (keep N most recent, snapshot before delete, pin exemptions).
- `.worktreeinclude` copies git-ignored files (`.env`, secrets) into fresh
  worktrees; a post-create setup hook runs.

## termio design

### Entry point

Right-click a project in the sidebar → **"New Worktree Session…"**. A bare worktree
is useless in termio, so the verb is *session*, not *worktree*: one action creates
the worktree **and** launches a session in it. (This is the IA doc's deferred
"create-isolated entry", item 2.)

### Location & naming

```
~/.termio/worktrees/
  termio-worktree-a1b2c3d4/      ← session a1b2c3d4, repo "termio", detached HEAD
  vibewizard-worktree-9f3e21c0/
<repo>/.worktreeinclude            ← repo root (SAME file Conductor/Claude Code use — interop)
<repo>/.termio/                    ← termio-specific config (branchPrefix, setup.sh)
```

- **`~/.termio/`, not `~/Library/Application Support/termio/`.** The Application
  Support path exists to satisfy the App Store sandbox; termio ships via
  Sparkle/direct-download and is **not sandboxed**, so a `~/.termio/` home dotfolder
  is both the Unix dev-tool idiom (`~/.ssh`, `~/.codex`) and more faithful to Codex.
  The codebase already treats `~/.termio` as a fallback location (`StateFile.swift`,
  `SessionControl.swift`, `ThemeLibrary.swift`); this promotes it for worktrees.
- **Flat**, not nested by project. Session ids are UUIDs — already globally unique —
  so a `<project>/` namespace level is redundant. The repo name lives *in the leaf*
  for orientation, not as a directory level.
- **Leaf = `<repo-dir-name>-worktree-<8char-session-id>`.** The repo name earns its
  place because termio is a terminal: a bare-UUID basename would leave you blind in
  the shell prompt / tab title. Codex's plain `thread-N` is fine for a chat-desktop
  app where the basename isn't surfaced; it isn't for us. The `<id>` is the same
  8-char id shown in `termio sessions list`, so the folder matches the id the user
  sees elsewhere. Uniqueness comes from the id, so two clones both named `termio`
  won't collide.
- **Chosen at creation, never renamed.** We start detached (no branch yet), so the
  only always-available parts are repo-name + session-id. When a branch is
  materialized later we do **not** rename the dir (`git worktree move` rewrites
  `worktreePath` + git metadata for no gain; the git-prompt shows the branch
  separately anyway).

### Branch: detached HEAD first, materialize on intent

Create with:

```sh
git worktree add --detach <path> <base>
```

- **Detached, not `-b <branch>`.** Agent worktrees are *mostly disposable* — most
  sessions are experiments you throw away. `git worktree add -b` immediately locks
  that branch out of the main checkout (git's one-branch-one-place rule) and
  pollutes the branch list with dead experiments. Detached-until-it-matters defers
  the name until the work earns one.
- **"Create branch" is a later session action** (the IA doc's item 1, "isolated =
  right-click Worktree ▸ menu"), running `git switch -c <name>` in the worktree.

### Branch naming when materializing

Single editable text field, **pre-filled with a slug of `Session.liveTitle`** (the
agent-updated title termio already tracks):

```
Session "Fix login redirect"  →  prefill: fix-login-redirect  (Enter, or edit)
```

- The user inputs the name — Codex does too, and auto-generating branch names from
  agent output yields junk (`fix-stuff-2`). It's an explicit "I'm keeping this"
  intent, so a human names it.
- **No global forced prefix.** A hard-coded `feature/` fights repos that use
  `feat/`, `username/`, or none. If a team wants a convention, it's **opt-in
  per-repo**: a `branchPrefix` key in the project-local `<repo>/.termio/` config, so
  `prefill = branchPrefix + slug(liveTitle)`, still fully editable.

### Ignored-files gap (table stakes, not gold-plating)

A fresh worktree has **no `.env`, no `node_modules`, no secrets** — so the agent's
dev server won't boot and half its commands fail. This is very likely *why worktree
creation was walked back before* (`Models.swift` says "termio no longer creates
worktrees itself"). It must be solved for the feature to be real.

#### How the field solves it (survey)

Three strategies across the AI-agent-worktree tools:

1. **Setup/init hook re-runs the package manager** (dominant) — Conductor, Cursor
   (`.cursor/worktrees.json` `setup-worktree`), Zed (`create_worktree` hook), Claude
   Code (`WorktreeCreate` hook), Vibe Kanban, uzi. A per-repo script fires on
   worktree-create and runs `pnpm/npm/pip install`.
2. **Declarative copy of gitignored files** for `.env`/secrets — Conductor and Claude
   Code use the **identical `.worktreeinclude`** format (globs, copies only files that
   are *both* matched and gitignored).
3. **Container/image-baked env** — Sculptor, container-use (sidesteps worktrees).

One trap the field warns about:

- **Symlinking `node_modules` is a trap** (Cursor explicitly discourages it): breaks
  on dependency drift, Node realpath resolution (Vite/Vitest), native addons, and
  **pnpm refuses to install into a symlinked `node_modules`**. Never automate it.

#### termio's approach — the field minimum, and that's it

Match the proven, low-surface-area answer everyone converged on. No cleverness:

- **`.worktreeinclude`** — adopt the *exact filename/format* Conductor + Claude Code
  use, for free interop (a repo already carrying one Just Works). Copies `.env` &
  small gitignored config into the new worktree. Never propagate prod secrets (skip
  `.env.production`).
- **`<repo>/.termio/setup.sh`** hook, run after the copy, with `TERMIO_WORKTREE_ROOT`
  + `TERMIO_MAIN_ROOT` env vars (mirrors Zed/Conductor). The user puts `pnpm install`
  / `npm ci` here. This alone is *correct for every ecosystem*.

That's the whole design. It's already fast where the package manager has a global
store (**pnpm/uv** hard-link from it; pnpm's `enableGlobalVirtualStore: true` is
purpose-built for multi-worktree agents). **npm / yarn-classic** re-install is
inherently slower (no global store) — we accept that; the fix is "use pnpm/uv," not
more machinery in termio.

#### Rejected: copy-on-write (APFS `clonefile`) of `node_modules`

Considered and **rejected** (2026-07-06). termio is macOS-native on APFS, so it
*could* `clonefile`-clone `node_modules` to make npm/yarn setup near-instant — and no
competitor ships this. But it was cut deliberately:

- It's a **pure speed optimization for npm/yarn only** — pnpm/uv already solve it, so
  the payoff is narrow.
- It drags in real surface area and edge cases: APFS-only + same-volume guards,
  non-APFS/cross-volume fallbacks, per-ecosystem branching, and a follow-up `npm ci`
  to reconcile the cloned tree against the branch's lockfile anyway.
- The whole field settled on "just a hook" for a reason. A setup hook is *correct and
  complete*; CoW is complexity in the name of speed the user chose not to carry.

Do **not** re-propose CoW without a concrete, measured npm/yarn pain point that pnpm
migration can't solve.

### Cleanup / retention

- On session removal → ask "also remove this worktree?" (`git worktree remove`,
  refuse if dirty, then `git worktree prune`). Uncommitted work belongs to the
  folder (per the IA doc's rule 1), so never remove silently.
- Bounded retention (keep N most recent, pin exemptions) mirrors Codex. **Phase
  this**, and honestly: plain retention (remove old *clean* worktrees) is cheap;
  Codex's *snapshot-before-delete* of dirty ones is real engineering — ship
  retention-of-clean first, add snapshotting when the flow is trusted.

## Implementation touchpoints

Existing plumbing already honors worktrees end-to-end (see IA doc); creation is
mostly UI + one git command + setting a field:

- `SidebarView.swift` `projectMenuItems` (~L121) — add "New Worktree Session…".
- `TermioStore+ProjectActions.swift` `addSession` (~L6) — add optional
  `worktreePath:` param.
- New `TermioStore` method — `git worktree add --detach` into `~/.termio/worktrees/`,
  copy `worktreeinclude` globs, then `addSession(worktreePath:)`.
- Session action "Create branch…" — `git switch -c`, prefill from `liveTitle`.
- `BranchModel` / `syncWatchedFolders()` — already auto-picks-up the new folder; no
  change.

## Open decisions

1. Retention default N (Codex uses 15) and whether to ship any retention in the
   first cut, or rely on manual "remove worktree?" on session close only.
2. Whether `.worktreeinclude` + `setup.sh` land with the first cut or a fast-follow
   (leaning: with the first cut — without them the feature is half-broken).
3. Readable-name cosmetics: `<repo>-worktree-<id>` vs. also folding in a title slug.
