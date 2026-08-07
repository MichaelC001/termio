# VOICE.md

How termio writes. Read this before writing anything a user reads: UI strings,
the landing site, `docs/`, release notes, issues, PR bodies.

Every rule below came from copy already in the repo. The Do examples are real
termio sentences; the Don't examples are the same sentence written the way it
would have gone wrong. When a rule and a shipped string disagree, the rule wins
and the string is a bug.

`AGENTS.md` carries the five hardest rules so an agent that never opens this file
still can't get them wrong. This is the long form.

## The voice in one line

**A colleague who built the thing, telling you what it does and what it costs
you.** Not a manual, not a pitch.

| We are | We are not |
| --- | --- |
| Direct — the sentence states the fact and stops | Not chatty; no warm-up clauses |
| Concrete — names the file, the flag, the key | Not abstract; no "seamlessly", "powerful" |
| Honest — says what a control won't do | Not promotional; no overclaiming |
| Plain — ordinary words, full names | Not clever; no puns in UI, no jargon for its own sake |

The reader's time is the scarce resource. Say the thing, then stop.

## UI copy

This is termio's largest writing surface and the one Apple's own conventions
govern most tightly. When in doubt, open System Settings and read how Apple
writes the same kind of control.

### Subtexts describe the control, not the user

One sentence. Present tense. The subject is the control, not "you".

**Do:**

> Posts a notification when an agent finishes or needs you while termio is in the background.

> Takes Codex out of the new-session menu. Its settings are kept.

> Reads ~/.ssh/config directly — termio keeps no separate host list.

**Don't:**

> You can enable this option if you would like to be notified when your agents complete their tasks.

> This powerful setting allows you to seamlessly manage which agents appear in your menu.

The second sentence, when there is one, exists to answer the question the first
one raises — usually "what happens to my stuff?". "Its settings are kept."
"Existing sessions keep running." "Private keys are never read."

Two sentences is the ceiling. If a control needs three, the control is wrong.

### Say the mechanism only when the user pays for it

Mechanism belongs in copy when it changes what the user should expect or do —
a file termio reads, a command it runs, a limit it has. Not otherwise.

**Do:**

> The command is run in a login shell, so anything on your PATH works.

> Line height applies to the file editor and diffs; the terminal keeps the font's own.

**Don't:**

> termio spawns the process via forkpty with a login_tty shape so the child inherits the controlling terminal.

The first tells you why your PATH works. The second is a design doc sentence
that wandered into a settings pane.

### Empty states name the next action

An empty state that only says "nothing here" wastes the one moment the user is
looking for a way forward.

**Do:**

> No hosts yet — add one, or write a Host block in ~/.ssh/config.

> No local usage yet — run `claude` once, then Refresh.

> Enable Claude Code or Codex in the Agents tab to see their usage here.

**Don't:**

> No hosts found.

> There is no data to display at this time.

### Errors say what happened, then what to do

Name the thing that failed in the user's terms. If there is an action, give it
in the same breath. Never blame the user, never apologize.

**Do:**

> Couldn't tell which project you're in. Run this from inside a termio session.

> No coding agent is enabled — pass `--agent <name>`.

> Notifications for termio are turned off in System Settings.

**Don't:**

> An unexpected error occurred. Please try again later.

> Sorry! We couldn't figure out your project. 😞

Prefer `Couldn't` over `Could not` — it is what Apple uses and it is shorter.
Use the curly apostrophe (`’`), consistently, in every user-facing string.

### Buttons and menu items are verbs

The label says what happens when you click it, in sentence case, no trailing
punctuation.

**Do:** `Show Original` · `Group with` · `Ungroup` · `Close Session` ·
`Remove from List` · `Reveal in Finder`

**Don't:** `OK` for a destructive action · `Submit` · `Click here` ·
`Are you sure?` as a button

Destructive labels name the destruction: "Delete", "Remove from List", not
"Yes".

### Fixed vocabulary

These words are decided. Using a synonym is a bug, not a style choice.

| Use | Never |
| --- | --- |
| Group with / Ungroup | Split / Unsplit |
| Close Session | Close Pane |
| session | tab, window (for a session) |
| project | workspace, folder (in the sidebar) |
| agent | assistant, bot, AI |
| needs you | blocked, waiting for input (as a status label) |

`termio` is lowercase, including at the start of a sentence — that is what the
README, the docs, and every UI string do. Never `TermIO`.

**Open:** the landing site is split, roughly 79 `Termio` to 49 `termio`. Either
it converges on lowercase like the rest of the repo, or the marketing surface
gets a stated exception. Until that is decided, don't "fix" landing strings
either way as a drive-by.

### Never describe termio as paid

termio is free. There is no tier, no trial, no seat, no license key. Copy that
implies otherwise is wrong everywhere — UI, landing site, README, release notes,
replies to users. The words that give it away: "upgrade", "unlock", "pro",
"premium", "free for now".

## The landing site and README

Marketing copy is the same voice with the volume up, not a different voice. It
may lead with a claim; it may not make one it can't cash.

**Do:**

> A real terminal, not a web view. Swift + AppKit on libghostty, rendered with Metal. No Electron, no xterm.js.

> Free. No account, no license keys, no paid tier. MIT-licensed.

The pattern: **claim, then the evidence, in the same breath.** Every headline
feature earns its adjective in the next clause.

**Don't:**

> The most powerful terminal ever built for AI development.

> Seamlessly orchestrate your agent workflows with cutting-edge tooling.

Claims must match what the code does. A capability that is planned, partial, or
only true on the dev channel is described as such or not at all.

## Docs

`docs/` is written for someone who will have to maintain this in a year — often
you, often an agent. Front matter carries the status; the prose carries the
reasoning.

- Open by saying what the document decides or describes. No "This document
  aims to…".
- Record **why**, and record what was rejected and why. A design doc whose
  alternatives section is empty hasn't done its job.
- Past decisions stay written down even when they were wrong; mark them, don't
  delete them. The record is the point.
- Prefer a table over four parallel paragraphs.

Design docs may be long. Runbooks may not — a runbook is a command list with
just enough prose to say when to run it.

## GitHub

- **Commit messages** follow Conventional Commits; use the
  `conventional-commit` skill. Summary is imperative, lowercase, no trailing
  period.
- **PR titles** are imperative and correctly capitalized, with no
  conventional-commit prefix and no trailing punctuation.
- **PR bodies** are written for a reviewer who knows the architecture but has
  not read the diff. Lead with what changes for the user, then how, then what
  you verified. Include a `Release Notes:` section.
- **Issue and PR comments are one clean line.** Not an essay, not a summary of
  what you just did with headers and bullets.
- **No AI attribution anywhere** — no `Co-Authored-By` trailer, no "Generated
  with", no bot signature. This applies to commits, PRs, issues, docs, and
  release notes.

## Tells that mean a machine wrote it

These show up in generated copy and read as noise. Cut them on sight.

**Hollow importance.** "plays a crucial role", "is a key component of",
"underscores the importance of", "represents a significant step". Say what it
does instead.

**Trailing gerunds.** "…, ensuring a seamless experience", "…, allowing users to
work more efficiently", "…, making it easier than ever". The clause after the
comma is almost always empty; delete it.

**Formulaic transitions.** "It's important to note that", "Additionally, it is
worth mentioning", "In today's fast-paced world". Start with the fact.

**The rule of three.** "fast, reliable, and intuitive" — three adjectives where
one specific one would do. Pick the true one.

**Promotional adjectives.** "powerful", "seamless", "robust", "cutting-edge",
"game-changing", "revolutionary". None of these survive review.

**Negation parallelism.** "It's not just a terminal — it's a home for agents."
Say what it is.

**Em dash overuse.** One per paragraph, and only for a real aside. If two
dashes appear in one sentence, rewrite it.

**Bolded pseudo-headers in lists.** A bullet that opens with a bold phrase and
a colon, repeated down a list, is a table pretending to be prose. Use a table.

**Emoji.** None, anywhere — not in UI, commits, PRs, issues, docs, or release
notes.

## Mechanics

- **Sentence case** for every heading, label, button, menu item, PR title, and
  doc title. Capitalize proper nouns normally: `PATH`, `SwiftUI`, `GitHub`,
  `Claude Code`, `libghostty`.
- **Curly quotes and apostrophes** (`’ “ ”`) in user-facing strings. Straight
  quotes only inside code, paths, and identifiers.
- **Backticks** in UI copy for literal commands, flags, and paths the user could
  type: `--agent`, `~/.ssh/config`, `termio sessions`.
- **Contractions** are fine and preferred: "won't", "doesn't", "couldn't".
- **Second person** for the reader ("you"); name termio as "termio", not "we",
  in UI copy. "We" is allowed in docs and essays where a person is speaking.
- **Numbers**: numerals everywhere in UI ("2 sessions", not "two sessions").
- **No trailing periods** on labels, buttons, or table cells. Full sentences in
  subtexts and errors do take one.

## Checklist

Run this over any copy before it ships:

- [ ] **One sentence per idea** — is anything two sentences that should be one?
- [ ] **Subject is the thing, not the user** — "Posts a notification", not "You can be notified"
- [ ] **Concrete** — does every claim name a file, flag, key, or observable behavior?
- [ ] **Honest** — does it say what the control won't do, or what it costs?
- [ ] **Next action** — do empty states and errors tell the user what to do?
- [ ] **Vocabulary** — Group with / Ungroup / Close Session / session / project / agent, lowercase `termio`?
- [ ] **Sentence case** — headings, labels, buttons, PR titles?
- [ ] **Apostrophes** — curly, and `Couldn't` rather than `Could not`?
- [ ] **Never paid** — no upgrade, unlock, pro, trial, or tier?
- [ ] **No AI tells** — no hollow importance, trailing gerunds, rule of three, promotional adjectives, emoji?
- [ ] **No AI attribution** — no co-author trailer, no "generated with"?

The `review-copy` skill runs this checklist as a scored loop; see
`skills/review-copy/`.
