---
domd-id: 72a583cd-d669-4d53-b9d6-bb38ab0f2961
title: The CLI follows the object model
status: draft
type: design
created: 2026-10-28
updated: 2026-10-28
related:
  - 20261025-termiod-owns-the-view.md
  - 20260808-sessions-cli-v3-command-design.md
  - 20260724-sessions-cli-v2.md
---

# The CLI follows the object model

> Parse every `termio` command in one place, and name commands after the
> objects termiod owns. The help, the errors, the completions and the docs
> reference then come from that one parser.

## Decision

1. **One parser.** Every command is parsed by the clap tree in
   `termiod/src/bin/termio.rs`. `scripts/termio` keeps only the job of
   finding the right binary for the channel, then `exec`s it with the full
   argument list.
2. **Nouns first.** The grammar is `termio <noun> <verb>`. The nouns are the
   objects termiod already owns: session, pane, project, server. No noun
   exists only in the CLI.
3. **Four shortcuts.** `open`, `split`, `focus` and `zoom` stay at the top
   level. Each one is an alias of exactly one `<noun> <verb>`.
4. **One stream.** `termio events` streams every change the host publishes.
   Agent status is one event type in that stream. `session watch` becomes an
   alias of `events --type status`.
5. **The reference is generated.** The command reference on the docs site is
   built from the parser, the way the shortcut tables are built from
   `KeyCommandCatalog`. Prose pages stay hand-written.

Agent status stays the differentiator. `--wait` on `spawn`, `run` and `send`
blocks until an agent turn settles. Rex's `wait` blocks only until a block
ends. Nothing in this design changes `--wait`.

## Why

### The defects, as measured on 2026-10-28

The `termio` on `PATH` is `scripts/termio`, a POSIX shell script of 991
lines. It parses `open`, `session`, `notify`, `pair` and `agent report`
itself. It passes `server`, `session create|attach|kill` and part of
`agent report` to the Rust binary. These are the results of running it:

| Command | Output | Defect |
|---|---|---|
| `termio bogus` | `termio: not a directory: bogus` | The `termio [DIR]` shortcut takes every typo as a path. |
| `termio whoami` | `termio: not a directory: whoami` | Same defect. A missing command looks like a bad path. |
| `termio session --help` | the full top-level help | A noun's help does not list its own verbs. |
| `termio session bogus` | `unknown sessions command 'bogus'`, then 20 lines of usage | The error uses the old name `sessions`. The usage hides the error. |
| `termio session list --help` | hand-written prose | Not the same format as `termio server --help`, which clap writes. |
| `termio agent install` | `unknown agent command 'install'` | The Rust binary has `agent install`. The script does not route it. |

The top-level help also says `session create|attach ... (needs the Rust
client)`. That line tells the user there are two clients. The decision in
#779 and #788 says `termio` is the only CLI.

All six defects have one cause. Two parsers share one command name, and
neither of them owns the whole grammar.

### What Rex does better

I read the help of the Rex CLI, build `g2db882`. I did not run its commands.

- **Named objects.** Rex has four nouns: `session`, `window`, `block`,
  `client`. Every verb acts on one of them.
- **Layout verbs.** `split`, `focus`, `zoom`, `move`, `swap`, `resize`.
  termio can place a pane only at creation, with `--direction` and
  `--ratio`.
- **General primitives.** `events` streams all server events. `api`
  inspects and calls the server API. `actions` lists what a client offers.
  termio adds a new verb for each new use case instead.
- **Self-description.** `whoami` prints the identity, the server, and where
  the caller runs. termio has no equivalent.

termio's own design already chose this model. `20261025-termiod-owns-the-view.md`
moved projects, groups, panes, focus and zoom into termiod. The CLI did not
follow. It can read the view with `termio view`. It cannot change it.

## The command tree

The status column says what exists on `origin/main` today.

| Command | Calls | Status |
|---|---|---|
| `termio session list \| new \| run \| send \| read \| close \| attach` | session ops | Exists. `new` is the current `spawn`. |
| `termio session focus <session>` | `pane.focus` on the session's pane | Exists on the app socket. Moves to the view op in phase 3. |
| `termio pane split \| focus \| zoom \| resize \| move \| close` | `pane_split`, `pane_focus`, `pane_zoom`, `split_resize`, `pane_move`, `pane_close` | Only `pane_close` exists. The rest is phase 2 of the view design. |
| `termio project list \| open \| remove` | `view`, `project_add`, `project_remove` | The ops exist. The CLI verbs do not. |
| `termio view [--json]` | `view` | In the source. Not in the installed CLI. |
| `termio events [--type <t,…>]` | the `ViewChanged` and status streams | New verb. `ViewChanged` exists. |
| `termio api list \| describe \| call` | the framed protocol | New. |
| `termio whoami` | none; reads the environment | New. |
| `termio skill show \| install \| uninstall` | none; writes skill files | New. Splits the skill out of `agent install`. |
| `termio agent report \| install \| uninstall` | hook contract | Exists. `install` keeps the hooks. |
| `termio server status \| logs \| stop \| deploy \| tailscale` | `termiod` lifecycle | Exists. Already in clap. |
| `termio pair`, `termio notify`, `termio sim`, `termio version`, `termio completion` | unchanged | Exist. |

The shortcuts:

| Shortcut | Means |
|---|---|
| `termio open [DIR]` | `termio project open [DIR]` |
| `termio split [--right\|--down] [-- CMD]` | `termio pane split` beside `TERMIO_PANE` |
| `termio focus <pane>` | `termio pane focus <pane>` |
| `termio zoom [--off]` | `termio pane zoom` on `TERMIO_PANE` |

The bare form `termio DIR` stays, with one change. It is accepted only when
`DIR` exists as a path. Any other word is an unknown command, and the error
suggests the closest command.

### `whoami`

`whoami` answers the first question an agent has inside a pane: where am I?
It prints these fields, and the same fields with `--json`:

- the session link, from `TERMIO_SESSION`
- the pane id, from `TERMIO_PANE`
- the project and the host
- the channel, `release` or `dev`, and the socket it talks to

It sends nothing to the host. When a field is missing, it prints `none`. It
does not guess.

### `skill`

`agent install` installs two things today: the status hooks and the
`termio` skill. They change at different rates. The skill changes with every
CLI release. The hooks change rarely. `termio skill install` writes only the
skill. `termio skill show` prints the skill that this CLI would install, so a
user can compare it with the installed copy.

### `events`

`events` replaces the idea of one streaming verb per subject. The first
types are `status`, which is today's `watch`, and `view`, which is
`ViewChanged`. Each line in `--json` mode is one event object with a `type`
field. Later types are added without new verbs.

### `api`

`api list` prints the control ops that the host negotiated. `api describe
<op>` prints its fields. `api call <op> --json '<fields>'` sends one op and
prints the reply. This gives scripts the full protocol without a new verb
for each op. It also makes the protocol testable by hand.

## Rules for every command

- **One meaning per flag.** `--json`, `--wait` and `--timeout` behave the
  same on every verb that takes them. `--timeout` takes a duration, such as
  `30s` or `5m`. A plain number still means milliseconds for one release.
- **JSON is the contract.** Every command takes `--json`, including `server`
  and `version`. The shape is the protocol object, not a reformatted copy.
  Changes to it are additive only.
- **Exit codes stay as v3 set them.** `0` ok, `1` error, `2` termio is not
  running, `3` timed out with the target still running. A usage error exits
  `2` in clap. That collides with "termio is not running". Use clap's
  `exit_code` override to make usage errors exit `64`, the BSD `EX_USAGE`.
- **Errors are one line plus one next step.** An unknown command prints the
  error and `did you mean …?`. It never prints the full usage.
- **Old names are hidden aliases.** `sessions`, `answer`, `spawn` and
  `watch` keep working. Help does not list them. They are removed when the
  installed skill no longer uses them, not before. Agents on users' machines
  run the skill they installed months ago.

## How help and docs are written

The CLI has three readers: a person at a shell, an agent that reads `--help`,
and a person on the docs site. All three read text that comes from the
parser.

**Help text.** Each command's help has four parts, in this order:

1. One sentence that says what the command does.
2. The usage line, which clap writes.
3. The flags, one line each.
4. One example.

A mechanism goes in the docs page, not in help. The current help for
`session send` explains trust gates in a paragraph. That paragraph moves to
`cli.mdx`, and the help keeps one example: `termio session send <s> t
--no-enter`.

**Help sentences** follow `VOICE.md`. One verb, present tense, no em dash,
no parentheses for a limit. Use "session", "pane", "project" and "host" with
the meanings in the view design, and no other words for them.

**The docs reference.** A hidden command, `termio __reference --json`, prints
the clap tree: every command, its one-sentence summary, its flags and its
example. `pnpm cli:sync` in `web/landing` writes it to a JSON file. The page
renders the reference from that file, the way `<Keybindings>` does.
`pnpm docs:check` fails when the file is older than the parser. Prose
sections of `cli.mdx`, such as the orchestration model and `--wait`, stay
hand-written and link into the reference.

## What we refuse

- **`termio config`.** The app's Settings window owns settings. A second
  writer for the same settings is a second source of truth.
- **A scripting language.** Rex runs Lua through `do`. `api call` plus
  `--json` gives scripts the same reach with no interpreter to ship.
- **`terminfo`, `keymap`, a login server.** Those belong to Rex's scope.
- **A flat list of 30 commands.** The top level holds the nouns, the four
  shortcuts and the utility commands. That is under 20 entries.

## Supersedes

CLI v3 said: "Nothing in the CLI ever names a window or pane." The view
design reversed the reason behind that rule, because layout is now host
state. This doc adds `pane` as a noun. The rest of v3 stands: links as
addresses, JSON as the contract, push instead of poll, and the exit codes.

## Phases

Each phase ships on its own.

1. **One parser.** Move `open`, `session`, `notify`, `pair` and `agent` into
   clap. Reduce `scripts/termio` to binary resolution plus `exec`. This adds
   no commands. It fixes every defect in the table above, and it gives the
   installed CLI the `view` and `completion` commands that already exist in
   the source.
2. **`whoami` and `skill`.** Both are small and need no protocol change.
3. **`pane` and the shortcuts.** Ships with phase 2 of the view design,
   when `pane_split` and the other ops land in termiod.
4. **`events` and `api`.** `watch` becomes an alias.
5. **Generated reference.** `__reference`, `pnpm cli:sync`, and the check in
   `docs:check`.

## Risks

- **The hook contract.** Every agent hook calls `termio agent report` on
  every turn. Phase 1 must keep its flags, its output and its speed. The path
  that hooks call must not change: global agent configs never store a path
  derived from the app bundle. Measure the start time of the Rust binary
  against the script before and after.
- **Channel resolution.** The script picks the binary by `TERMIOD_BIN`, then
  by the bundle it runs from. That logic is the reason the script exists. It
  stays in the script, and it must stay correct for the dev channel.
- **App-only verbs.** `session focus` and `session list` answer from the app
  when it runs, and from termiod when it does not. Phase 1 moves the parsing,
  not that routing. Any change to routing is a separate PR.
- **Exit code 2.** Scripts that check for `2` today read it as "termio is not
  running". Moving usage errors to `64` keeps that meaning. Not checked:
  whether any current script depends on a usage error exiting `1`.

## Open questions

- Should `session new` replace `session spawn` in help, or should `spawn`
  stay the canonical name? `spawn` is in every installed skill.
- Does `api call` need the write token, or only the read capabilities? The
  single-writer rule says observers never claim the write token.
- Should `events` cover hosts the caller reaches with `-H`, or only the local
  host in phase 4?
