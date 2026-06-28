---
title: Worktree information architecture
status: implemented (phase 1)
type: design
updated: 2026-06-28
---

# Worktree information architecture

How termio presents git worktrees in the sidebar, and why. Phase 1 (the IA + live
branch) is implemented and verified; later interaction work is listed at the end.

## The core insight: a worktree *is* a folder

`git worktree add ../fix-auth -b fix-auth` creates a real directory on disk with a
full checkout, sharing the repo's `.git`. So "worktree = folder" is not a metaphor —
it is the filesystem truth. A termio *project* is also a folder (the directory you
opened). The two are the same kind of thing (a directory); they differ only in git
semantics (same repo, different checkout).

This resolves the "is a worktree a new project?" question: **no.** A worktree is a
*folder under the project*, with an agent running inside it — not a sibling
top-level project (which would shatter the "all agents on this repo, together"
grouping that is the sidebar's whole value). This matches Conductor (its unit is a
"workspace" = worktree = folder, agent inside) and the IDEs (IntelliJ/GitLens/Tower
treat worktrees as folders/roots under the repo).

## The three levels

```
▾ acme-storefront            Level 1 — Project (the logical repo)
   ⎇ main                    Level 2 — a worktree/folder, labelled by its LIVE branch
        ● Claude Code        Level 3 — an agent/terminal session, runs IN that folder
        ● shell
   ⎇ fix-auth
        ● Claude Code
   ⎇ migrate
        ● Codex
```

- **Level 1 = Project / repo.**
- **Level 2 = folder + branch.** Node identity is the *folder* (a stable directory
  path). The branch is a *live label* read from `HEAD`. The primary checkout (the
  project's own directory) is just one of these folders — it is **not** hard-coded
  to "main"; it shows whatever branch that directory currently has.
- **Level 3 = the agent/terminal session.** Sessions attach to the **folder**, not
  the branch. So `git checkout` inside a folder changes only its label — the
  sessions stay put (they live in that directory).

### Rules

1. **Node identity = folder (stable); branch = live HEAD label.** Keying a node by
   branch would make it "jump" on checkout — wrong. The folder is the durable
   entity; the branch is its current state. (Corollary: uncommitted work belongs to
   the folder, which is why `closeSession`/`removeProject` deliberately leave
   worktrees on disk.)
2. **Branch updates live.** A file-system watch on the folder's `HEAD` container
   re-reads the branch on `git checkout` / `switch`, with no app interaction.
3. **Progressive disclosure.** The folder layer only appears when a project has
   **≥1 worktree**. With only the primary checkout, the sidebar stays flat
   (Project → sessions) — the common single-checkout case is untouched. Once any
   session runs in a worktree, the layer "grows" and the primary checkout also
   becomes a folder node (so the model is consistent). Remove the last worktree →
   it collapses back to flat.
4. **Detached HEAD** shows the short SHA (rebase in progress, bare-commit checkout).
5. **Empty worktrees** (on disk, no session) belong in a future "Manage worktrees…"
   surface, not the main list — the main list answers "where are my agents."

## Implementation (phase 1 — shipped)

Storage stays **flat**: `Project { sessions: [Session] }`, `Session.worktreePath`.
"Worktree" is a **derived grouping over sessions**, *not* a stored entity. Each
session already knows its folder (`worktreePath ?? project.path`), so grouping by
that folder yields the levels for free — without rippling a nested model through
persistence, the `termio sessions` control plane, and every session lookup. This
fits termio's "small surface area" ethos and was far lower-risk.

- **`BranchModel.swift`** — live current-branch per folder. Resolves via `git
  rev-parse` off the main thread; watches the directory containing each folder's
  `HEAD` (`git rev-parse --git-path HEAD` handles the linked-worktree path) with a
  `DispatchSource` vnode source, debounced. Watching the *directory* (not the file)
  survives git's atomic replace-of-`HEAD`. `branches: [folder: label]` is published
  on main.
- **`TermioStore`** — owns `branchModel`, forwards its `objectWillChange`, and
  `syncWatchedFolders()` (called on every `projects` change) tells it which folders
  to track: every project path + every session worktree. Exposes
  `branch(forFolder:)`.
- **`SidebarView`** — `hasWorktrees(_:)` + `worktreeGroups(for:)` derive the groups
  (primary first, then worktrees in first-seen order). When there are worktrees it
  renders a `WorktreeHeader` (the ⎇ branch node) per group with sessions at a deeper
  indent (`SessionRow.leadingIndent` 16 → 32); otherwise the original flat list.
- **`TerminalPane`** — the title-bar branch chip now reads `branch(forFolder:)` of
  the selected session's folder (live) instead of the stale stored `Project.branch`.

Verified end-to-end: a project with two injected worktrees rendered the three-level
tree; a second project with none stayed flat; and `git switch` inside a worktree
updated its node from `demo/fix-auth` to `demo/auth-v2` with no app interaction.

> `Project.branch` is now display-dead (still encoded for state compatibility; the
> UI no longer reads it). Can be removed in a later cleanup with a state migration.

## Deferred (next increments)

These were designed but intentionally not built in phase 1:

1. **Isolate-on-demand.** A worktree affordance on a session row: not-isolated =
   hover branch icon → "Isolate in worktree" (recreates the session's shell in a new
   worktree — cleanest before the agent has done work); isolated = the ⎇ badge +
   right-click `Worktree ▸` menu (Open in editor / Reveal / Remove worktree).
2. **Create-isolated entry.** `⌥`-click the project header's `+` (or a small branch
   `+`) → a new session that starts in a fresh worktree from t=0.
3. **Per-preset / per-project default** for isolation, replacing the global
   `worktreeEnabled` toggle, so creation never asks at click time (see
   `docs/maketing/` discussion — decision moved off the hot path).
4. **Manage-worktrees view** listing all worktrees incl. empty ones, with cleanup.
5. **Collapsible folder nodes** + ahead/behind or dirty markers, if wanted.
