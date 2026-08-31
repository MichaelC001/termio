//! termio — the command a person types. `termiod` is the daemon, like
//! `dockerd`; this client drives the Mac app and the session host
//! (docker-lessons RFC §1).
//!
//! This binary replaces `scripts/termio` at parity: every `sessions` verb,
//! `notify`, and `agent report` behave as the shell client did, down to help
//! text, request bytes, stderr diagnoses, and exit codes — the compat
//! harness (`termiod/tests/cli_compat.py`) holds the diff at zero. The
//! session verbs still speak the app's control socket; they migrate onto
//! the daemon's framed protocol one verb at a time (unify-server-plane
//! Stage 10), each flip retiring its Swift handler.
//!
//! The dispatcher is a hand-rolled match, not clap: `termio [DIR]` must
//! treat any non-verb first argument as a directory (the `code .` shape),
//! `remote` is an argv passthrough whose help belongs to the daemon, and
//! the help text is the shell client's, verbatim.

use anyhow::{bail, Context, Result};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;
use termiod::app_socket::{self, Outcome};
use termiod::channel::{self, Channel};
use termiod::{lifecycle, version};

const USAGE: &str = r#"usage:
  termio open [DIR]                          open DIR (default: cwd) as a project
  termio [DIR]                               shorthand for `termio open DIR`

  termio sessions list                       sessions in this project + status
  termio sessions watch [--state <s,…>]      stream status transitions until Ctrl-C (default: done,needs-you)
  termio sessions spawn "<prompt>"           start a NEW agent session on the prompt
  termio sessions run "<command>"            start a NEW terminal session running a shell command
  termio sessions send <session> "<text>"        type a prompt (or menu answer) into a session
  termio sessions read <session> [--lines N]     print a session's current screen
  termio sessions close <session> [...]      close session tabs
  termio sessions focus <session>            select the session in the app

  termio notify [--title T] "<message>"      post a macOS notification (e.g. "I'm done")

  termio remote <verb> [...]                 drive a box's termiod over SSH (deploy, list,
                                             attach, open — `termio remote --help` lists them)
  termio version                             one table: this client, the running app, the local
                                             termiod, and every known remote as of last connect

  termio agent report <state>                report this agent's activity (hook contract)

options:
  --json           machine-readable output (any `sessions` command)
  --agent <id>     agent for `spawn` (e.g. claudeCode, codex, grok, pi; default: caller's kind)
  --direction <d>  for `spawn`/`run`: where the new pane lands relative to yours — right or down
  --ratio <0..1>   for `spawn`/`run`: the new pane's share of the split (e.g. 0.25);
                   a stated ratio holds against later spawns
  --wait           for `spawn`/`run`/`send`: block until the turn settles; the reply carries
                   the final status and the transcript line range to read
                   (exit 0 settled, 1 error — including a stalled/vanished session, 3 timed out)
  --timeout <ms>   cap for --wait (default 300000, clamped 1000–600000); implies --wait
  --no-enter       for `send`: deliver the text as-is, with no Return after it —
                   the way to answer a gate that wants a bare keypress
  --key <name>     for `send`: press a named key (escape, up, tab, ctrl-c, f2, …)
                   after the text; repeatable, in order. Any --key suppresses the
                   implicit Return
  --lines <n>      for `read`: keep only the last n screen rows
  --state <s,…>    for `watch`: comma-separated states to report (working, idle, done,
                   needs-you, stalled; default done,needs-you)
  --no-snapshot    for `watch`: skip the initial per-session status snapshot
  --help, --version

`termio sessions <verb> --help` prints focused help for one verb.
<session> = a termio://session/<uuid> link or a bare id/prefix — printed by
`termio sessions list` / a `spawn` reply.
`answer` is a deprecated, agent-only alias of `send`; `send` with no target aliases `spawn`.
Every one-shot command times out after ${TERMIO_CLI_TIMEOUT:-15}s (TERMIO_CLI_TIMEOUT overrides)."#;

#[tokio::main]
async fn main() -> Result<()> {
    let (channel, provenance) = channel::resolve();
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match arguments.first().map(String::as_str) {
        None => open_project(&channel, Path::new(".")),
        Some("-h") | Some("--help") | Some("help") => {
            println!("{USAGE}");
            Ok(())
        }
        Some("--version") => {
            println!("termio {} ({})", lifecycle::BUILD_VERSION, channel.name);
            Ok(())
        }
        Some("version") => version::print_table(&channel, provenance).await,
        Some("remote") => remote_passthrough(&channel, &arguments[1..]),
        Some("sessions") => sessions(&channel, &arguments[1..]),
        Some("agent") => agent_report(&channel, &arguments[1..]),
        Some("notify") => notify(&channel, &arguments[1..]),
        Some("open") => {
            let directory = arguments.get(1).map(String::as_str).unwrap_or(".");
            open_project(&channel, Path::new(directory))
        }
        // Bare `termio [DIR]` stays as the `code .`-shaped shorthand for `open`.
        Some(directory) => open_project(&channel, Path::new(directory)),
    }
}

fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(1);
}

fn exit_outcome(outcome: Outcome) -> ! {
    std::process::exit(match outcome {
        Outcome::Ok => 0,
        Outcome::Error => 1,
        Outcome::Timeout => 3,
    })
}

fn sessions(channel: &Channel, arguments: &[String]) -> Result<()> {
    let op = arguments.first().map(String::as_str).unwrap_or("list");
    let rest = if arguments.is_empty() { &[][..] } else { &arguments[1..] };

    match op {
        "list" | "watch" | "spawn" | "run" | "send" | "answer" | "read" | "close" | "focus" => {}
        "-h" | "--help" | "help" => {
            println!("{USAGE}");
            std::process::exit(0);
        }
        _ => {
            eprintln!("termio: unknown sessions command '{op}'");
            eprintln!("{USAGE}");
            std::process::exit(1);
        }
    }

    // Per-verb help never needs the app: dispatch it before the socket check.
    if rest.iter().any(|argument| argument == "-h" || argument == "--help") {
        println!("{}", verb_usage(op));
        std::process::exit(0);
    }

    app_socket::require_socket(channel);

    let mut format = "text";
    let mut agent = String::new();
    let mut direction = String::new();
    let mut ratio = String::new();
    let mut targets: Vec<String> = Vec::new();
    let mut text = String::new();
    let mut states = String::new();
    let mut no_snapshot = false;
    let mut no_enter = false;
    let mut keys_json = String::new();
    let mut wait = false;
    let mut timeout_ms: Option<u64> = None;
    let mut lines = String::new();
    let mut seen_positional = false;

    let mut cursor = 0;
    while cursor < rest.len() {
        let argument = rest[cursor].as_str();
        let mut value = |name: &str, missing: &str| -> String {
            if cursor + 1 >= rest.len() {
                fail(missing);
            }
            let _ = name;
            cursor += 1;
            rest[cursor].clone()
        };
        match argument {
            "--json" => format = "json",
            "--no-snapshot" => no_snapshot = true,
            "--no-enter" => no_enter = true,
            "--key" => {
                let key = value("--key", "termio: --key needs a key name (e.g. escape, ctrl-c)");
                // Order matters — the app presses them in the order named — so
                // they accumulate into a JSON array rather than a set. The name
                // itself is validated by the app, the one place that knows the
                // vocabulary.
                if !keys_json.is_empty() {
                    keys_json.push(',');
                }
                keys_json.push('"');
                keys_json.push_str(&app_socket::json_escape(&key));
                keys_json.push('"');
            }
            "--wait" => wait = true,
            "--timeout" => {
                let raw = value("--timeout", "termio: --timeout needs a value in ms");
                let Ok(parsed) = raw.parse::<u64>() else {
                    fail("termio: --timeout needs whole milliseconds");
                };
                timeout_ms = Some(parsed);
                wait = true;
            }
            "--agent" => agent = value("--agent", "termio: --agent needs a value"),
            "--direction" => {
                let parsed = value("--direction", "termio: --direction needs right or down");
                if parsed != "right" && parsed != "down" {
                    fail("termio: --direction is right or down");
                }
                direction = parsed;
            }
            "--ratio" => {
                let parsed = value(
                    "--ratio",
                    "termio: --ratio needs a number between 0 and 1 (e.g. 0.25)",
                );
                // Strictly `0.<digits>` — anything else (".5", "0.", "50%")
                // would land on the wire as invalid JSON or a share the app
                // rejects.
                let fraction = parsed.strip_prefix("0.");
                let valid = fraction
                    .is_some_and(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()));
                if !valid {
                    fail("termio: --ratio needs a number between 0 and 1 (e.g. 0.25)");
                }
                ratio = parsed;
            }
            "--state" => states = value("--state", "termio: --state needs a value"),
            "--lines" => {
                let parsed = value("--lines", "termio: --lines needs a value");
                if parsed.is_empty() || !parsed.bytes().all(|b| b.is_ascii_digit()) {
                    fail("termio: --lines needs a whole number");
                }
                lines = parsed;
            }
            positional => {
                if op == "close" {
                    // Every positional is a tab to close.
                    targets.push(positional.to_string());
                } else if op == "spawn" || op == "run" {
                    // `spawn`/`run` take no target — every positional is the payload.
                    push_word(&mut text, positional);
                } else if !seen_positional && (op == "answer" || op == "focus" || op == "read") {
                    targets = vec![positional.to_string()];
                } else if !seen_positional && op == "send" && app_socket::is_address(positional) {
                    // A leading address targets an existing session. Without
                    // one, `send` is a back-compat alias for `spawn`; the
                    // strict is_address shape check keeps a prompt that merely
                    // opens with a word from being mistaken for an address.
                    targets = vec![positional.to_string()];
                } else {
                    push_word(&mut text, positional);
                }
                seen_positional = true;
            }
        }
        cursor += 1;
    }
    let target = targets.join(" ");

    match op {
        "answer" | "focus" | "read" => {
            if target.is_empty() {
                fail(&format!(
                    "termio: {op} needs a session link or id (see `termio sessions list`)"
                ));
            }
        }
        "close" => {
            if target.is_empty() {
                fail("termio: close needs at least one session link or id");
            }
        }
        "spawn" => {
            if text.is_empty() {
                fail("termio: spawn needs a prompt (e.g. `termio sessions spawn \"fix the build\" --agent codex`)");
            }
            // One job, one entry point: spawn creates agents, run creates
            // terminals. The wire cannot tell `spawn --agent terminal` from
            // `run` (both arrive as an empty-target send with the shell
            // pinned), so the split is enforced here, where the user's intent
            // is still visible.
            if agent.eq_ignore_ascii_case("terminal") || agent.eq_ignore_ascii_case("shell") {
                fail("termio: spawn starts agents — for a plain terminal running a command, use `termio sessions run \"<command>\"`");
            }
        }
        "run" => {
            if text.is_empty() {
                fail("termio: run needs a command (e.g. `termio sessions run \"pnpm dev\"`)");
            }
        }
        _ => {}
    }

    // One sync vocabulary: --wait/--timeout mean the same thing on every verb
    // that accepts them (spawn/run + send), and nothing else silently ignores
    // them.
    let mut extra_json = String::new();
    let mut client_timeout = app_socket::client_timeout();
    if wait {
        match op {
            "spawn" | "run" | "send" | "answer" => {}
            _ => fail("termio: --wait applies to spawn, run, and send only"),
        }
        extra_json.push_str("\"wait\":true");
        if let Some(milliseconds) = timeout_ms {
            extra_json.push_str(&format!(",\"timeout_ms\":{milliseconds}"));
        }
        // The client read bound must outlive the server-side wait (which the
        // app clamps to 1s–600s), or the read would hang up mid-wait and
        // report a false timeout. An explicit TERMIO_CLI_TIMEOUT still wins —
        // the escape hatch.
        if !app_socket::explicit_client_timeout() {
            client_timeout = timeout_ms.unwrap_or(300_000) / 1000 + 30;
        }
    }

    // Placement flags only mean something on a verb that creates a pane.
    if !direction.is_empty() || !ratio.is_empty() {
        match op {
            "spawn" | "run" => {}
            _ => fail("termio: --direction/--ratio apply to spawn and run only"),
        }
        if !direction.is_empty() {
            push_extra(&mut extra_json, &format!("\"direction\":\"{direction}\""));
        }
        if !ratio.is_empty() {
            push_extra(&mut extra_json, &format!("\"ratio\":{ratio}"));
        }
    }

    // --no-enter only reads on a send to an existing session: a spawn's prompt
    // has to be submitted or the fresh agent just sits on a filled composer.
    if no_enter {
        match op {
            "send" | "answer" => {
                if target.is_empty() {
                    fail("termio: --no-enter needs a session to send to");
                }
            }
            _ => fail("termio: --no-enter applies to send only"),
        }
        push_extra(&mut extra_json, "\"enter\":false");
    }

    // --key, like --no-enter, only reads on a send to an existing session: a
    // key is pressed against a TUI that is already drawn, and a booting agent
    // has none.
    if !keys_json.is_empty() {
        match op {
            "send" | "answer" => {
                if target.is_empty() {
                    fail("termio: --key needs a session to press it in");
                }
            }
            _ => fail("termio: --key applies to send only"),
        }
        push_extra(&mut extra_json, &format!("\"keys\":[{keys_json}]"));
    }

    if op == "watch" {
        // Exit codes tell a supervising agent how the watch ended: Ctrl-C is
        // the normal end of supervision (0, via the handler); an immediate
        // error reply (control disabled, no scope) is 1; the stream reaching
        // EOF means the *app* closed it — 2, "termio died", the case to
        // escalate.
        unsafe {
            libc::signal(libc::SIGINT, watch_interrupted as usize);
        }
        let extra = if no_snapshot { "\"snapshot\":false" } else { "" };
        let code = app_socket::watch(channel, format, &states, extra);
        if code == 2 {
            eprintln!("termio: watch stream closed by the app (termio quit or died)");
        }
        std::process::exit(code);
    }

    if op == "close" {
        // One request per tab; any failure fails the whole command, but every
        // target still gets its attempt and its own reply line.
        let mut failed = 0;
        for target in &targets {
            if app_socket::request_once(channel, client_timeout, "close", format, target, "", "", "")
                != Outcome::Ok
            {
                failed = 1;
            }
        }
        std::process::exit(failed);
    }

    // `spawn` and the no-target `send` alias both start a fresh session: the
    // app spawns whenever a `send` request carries an empty target. `run` is
    // the same spawn with the agent pinned to the plain shell — the payload is
    // a command line, not a prompt. `answer` is a thin alias for sending to an
    // existing session. All fold onto the wire `send`; every other verb maps
    // straight through.
    let wire_op = match op {
        "spawn" | "answer" => "send",
        "run" => {
            agent = "terminal".to_string();
            "send"
        }
        "read" => {
            if !lines.is_empty() {
                extra_json = format!("\"lines\":{lines}");
            }
            "read"
        }
        other => other,
    };
    exit_outcome(app_socket::request_once(
        channel,
        client_timeout,
        wire_op,
        format,
        &target,
        &agent,
        &text,
        &extra_json,
    ));
}

extern "C" fn watch_interrupted(_: libc::c_int) {
    unsafe { libc::_exit(0) }
}

fn push_word(text: &mut String, word: &str) {
    if !text.is_empty() {
        text.push(' ');
    }
    text.push_str(word);
}

fn push_extra(extra: &mut String, fragment: &str) {
    if !extra.is_empty() {
        extra.push(',');
    }
    extra.push_str(fragment);
}

/// The public hook contract: `termio agent report <state> …` keeps its name,
/// its states and every flag, because users hand-write hooks against it. The
/// report forwards to `termiod set-status`, which takes the same flag names
/// and reads the same stdin blob, so the payload is parsed once, by
/// whichever binary the hook actually invoked.
fn agent_report(channel: &Channel, arguments: &[String]) -> Result<()> {
    let op = arguments.first().map(String::as_str).unwrap_or("");
    let rest = if arguments.is_empty() { &[][..] } else { &arguments[1..] };
    if op != "report" {
        eprintln!("termio: unknown agent command '{op}'");
        eprintln!("usage: termio agent report <working|attention|done|idle> [--transcript] [--conversation <id>] [--conversation-from <field>] [--tool-from <field>] [--prompt-title-from <field>] [--reply]");
        std::process::exit(1);
    }

    let mut state = String::new();
    let mut forwarded: Vec<String> = Vec::new();
    let mut reply = false;
    let mut cursor = 0;
    while cursor < rest.len() {
        let argument = rest[cursor].as_str();
        match argument {
            "--transcript" => forwarded.push("--transcript".to_string()),
            "--reply" => reply = true,
            "--conversation" | "--conversation-from" | "--tool-from" | "--prompt-title-from" => {
                if cursor + 1 >= rest.len() {
                    fail(&format!("termio: {argument} needs a value"));
                }
                forwarded.push(argument.to_string());
                cursor += 1;
                forwarded.push(rest[cursor].clone());
            }
            "working" | "attention" | "done" | "idle" => state = argument.to_string(),
            _ => fail(&format!("termio: unknown agent report argument '{argument}'")),
        }
        cursor += 1;
    }
    if state.is_empty() {
        fail("termio: agent report needs a state (working|attention|done|idle)");
    }

    // A hook outside a termiod session has nothing to report to, and
    // reporting with an empty target is a call the daemon rejects. Silent,
    // because hooks fire constantly and a hook that talks is worse than one
    // that does not.
    let session = std::env::var("TERMIOD_SESSION_ID").unwrap_or_default();
    if session.is_empty() {
        if reply {
            print!("{{}}");
        }
        return Ok(());
    }
    let Some(daemon) = channel::daemon_binary(channel) else {
        if reply {
            print!("{{}}");
        }
        return Ok(());
    };

    // `--reply` is handled by the daemon binary, which prints `{}` itself
    // even when the report could not be delivered — one implementation of
    // Cursor's stdout contract rather than two. `channel::resolve` already
    // pinned `TERMIO_CHANNEL`, which the exec inherits.
    let mut command = Command::new(&daemon);
    command.arg("set-status").arg(&session).arg(&state).args(&forwarded);
    if reply {
        command.arg("--reply");
    }
    let error = command.exec();
    Err(error).with_context(|| format!("running {}", daemon.display()))
}

/// `termio notify [--title T] "<message>"` — post a macOS notification on
/// demand, routed through the running app so the banner wears termio's
/// identity and a click focuses the calling session.
fn notify(channel: &Channel, arguments: &[String]) -> Result<()> {
    let mut format = "text";
    let mut title = String::new();
    let mut body = String::new();
    let mut cursor = 0;
    while cursor < arguments.len() {
        match arguments[cursor].as_str() {
            "--json" => format = "json",
            "--title" => {
                if cursor + 1 >= arguments.len() {
                    fail("termio: --title needs a value");
                }
                cursor += 1;
                title = arguments[cursor].clone();
            }
            "-h" | "--help" => {
                println!("{}", NOTIFY_USAGE);
                std::process::exit(0);
            }
            word => push_word(&mut body, word),
        }
        cursor += 1;
    }
    if body.is_empty() {
        fail("termio: notify needs a message (e.g. `termio notify \"tests passed\"`)");
    }
    app_socket::require_socket(channel);
    let extra = if title.is_empty() {
        String::new()
    } else {
        format!("\"title\":\"{}\"", app_socket::json_escape(&title))
    };
    exit_outcome(app_socket::request_once(
        channel,
        app_socket::client_timeout(),
        "notify",
        format,
        "",
        "",
        &body,
        &extra,
    ));
}

/// Resolve to an absolute, symlink-free path so termio keys the project by
/// the same canonical path it stores, avoiding duplicate sidebar entries.
fn open_project(channel: &Channel, directory: &Path) -> Result<()> {
    if !directory.is_dir() {
        eprintln!("termio: not a directory: {}", directory.display());
        std::process::exit(1);
    }
    let absolute = directory
        .canonicalize()
        .with_context(|| format!("resolving {}", directory.display()))?;
    if !cfg!(target_os = "macos") {
        bail!("termio open drives the Mac app; there is none on this machine");
    }
    let error = Command::new("open")
        .arg("-b")
        .arg(&channel.bundle_id)
        .arg(&absolute)
        .exec();
    Err(error).context("running open")
}

/// `termio remote …` execs the daemon binary rather than calling
/// `remote::run` in-process: `shipped_binary()` deploys `current_exe()` to
/// Mac targets, so an in-process call from this client would ship the client
/// as the remote daemon. The in-process move happens together with a
/// daemon-sibling fix, not here. `channel::resolve` already pinned
/// `TERMIO_CHANNEL`, which the exec inherits.
fn remote_passthrough(channel: &Channel, rest: &[String]) -> Result<()> {
    let Some(daemon) = channel::daemon_binary(channel) else {
        eprintln!("termio: no termiod binary found — install the termio app, or set TERMIOD_BIN");
        std::process::exit(1);
    };
    let error = Command::new(&daemon).arg("remote").args(rest).exec();
    Err(error).with_context(|| format!("running {}", daemon.display()))
}

const NOTIFY_USAGE: &str = r#"usage: termio notify [--title T] "<message>" [--json]

Post a macOS notification from the running app. The agent uses this to ping you
directly — "build finished", "need a decision" — regardless of whether termio is
frontmost (unlike the automatic completion banner). --title overrides the default
(the calling agent's name); the banner's subtitle is the project, and clicking it
focuses the session that posted it."#;

fn verb_usage(op: &str) -> &'static str {
    match op {
        "list" => {
            r#"usage: termio sessions list [--json]

List the sessions in this project with their live status (working / idle /
done / needs-you). `--json` adds each session's transcript path once its
agent has reported one."#
        }
        "watch" => {
            r#"usage: termio sessions watch [--state <s,…>] [--no-snapshot] [--json]

Block and stream one line per session status transition until interrupted.
On attach it first prints a snapshot line per session with its current
status (tagged "snapshot":true in --json); --no-snapshot skips that.
--state takes a comma-separated filter (working, idle, done, needs-you,
stalled); the default reports the two states a supervisor acts on: done,
needs-you.
In --json mode the app writes {"heartbeat":true} after 30s of silence so a
dead stream is distinguishable from a quiet one.

`stalled` is a watch-plane signal, not a real status: the session is still
working, but for 20+ minutes has made no repo change and next-to-no
transcript growth — the unattended-runaway pattern. Sustained output (a
long build streaming logs) suppresses it. The event carries the reasoning
in `evidence` ("working 42m, no repo change, transcript +3 lines"), fires
once per quiet stretch, and re-arms when progress resumes. Opt in with
--state stalled; it is not in the default filter.

exit codes: 0 after Ctrl-C (normal end of supervision), 2 when the stream
closes from the app side (termio quit or died)."#
        }
        "spawn" => {
            r#"usage: termio sessions spawn "<prompt>" [--agent <id>] [--direction right|down]
                                        [--ratio <0..1>] [--wait [--timeout <ms>]] [--json]

Start a NEW agent session on the prompt. Replies immediately with the new
session's termio://session link; the prompt is
typed in once the agent finishes booting. --agent picks the agent (e.g. claudeCode, codex, grok,
pi); the default is the calling agent's own kind.

--direction places the new pane relative to yours (right or down) instead of
the automatic stack; --ratio is the new pane's share of the split (e.g. 0.25
for a short strip) and holds against later spawns. Panes without a stated
ratio share their run evenly.

Readiness is judged from the screen, so an agent sitting on a startup gate —
a trust prompt, a usage notice, a first-run dialog — looks ready while it is
actually waiting for a keypress, and swallows the prompt as its answer. The
reply cannot know this; it has already been sent. When it happens the session
is flagged in `sessions list` (`prompt_undelivered` in --json), so check there
before waiting on a reply that will never come, then resend with
`sessions send`.

--wait holds the reply until the spawned agent's first turn settles (or
--timeout ms elapse; default 300000, clamped 1000–600000). The reply then
carries the final status, the transcript path, and the cursor..cursor_end
line range holding the response. A session that stops to ask you something
returns immediately as needs-you, with the on-screen question in `prompt`.

A prompt that shows no effect within 5s fails fast as prompt_stalled (the
input was eaten) rather than burning the timeout; a session that closes or
whose agent exits mid-wait fails as session_closed / agent_gone.

exit codes: 0 settled, 1 error (including stalled/vanished), 3 timed out."#
        }
        "run" => {
            r#"usage: termio sessions run "<command>" [--direction right|down] [--ratio <0..1>]
                                       [--wait [--timeout <ms>]] [--json]

Start a NEW plain terminal session and type the shell command into it — a
dev server, a test run, a build — visible in a split pane, no LLM involved.
Replies immediately with the session's address; drive it further with
`send`, read its output with `read` (a plain command has no
transcript; its screen is the result), close it with `close`.

--direction places the pane relative to yours (right or down); --ratio is its
share of the split — `--direction down --ratio 0.25` is a log strip under
your pane, not a column beside it.

--wait settles when the screen goes still after the command's output (or
returns needs-you / times out, exactly as with send).

exit codes: 0 settled, 1 error (including stalled/vanished), 3 timed out."#
        }
        "read" => {
            r#"usage: termio sessions read <session> [--lines N] [--json]

Print the session's current screen (its viewport, right-trimmed, trailing
blank rows dropped) without focusing it. The result channel for `run`
sessions, and a quick peek at any agent's live TUI. --lines keeps only
the last N rows. Scrollback is not included."#
        }
        "send" | "answer" => {
            r#"usage: termio sessions send <session> "<text>" [--key <name>]... [--no-enter]
                            [--wait [--timeout <ms>]] [--json]

Type text into an existing session and submit it with a real Return
keypress — a prompt to drive it, or a menu choice ("1", "yes") to answer a
permission prompt. Addresses come from `termio sessions list` or a `spawn`
reply — a termio://session link or bare id, copied verbatim.

The text reaches the terminal verbatim, so --no-enter (no Return after it)
delivers a bare keypress: the lone `t` a trust gate waits for.

--key presses a NAMED key, repeatable and in order, after the text:
`send <session> --key escape` to back out of a menu, `--key up --key enter`
to rerun the last entry. Use it instead of writing escape bytes yourself —
a key's bytes depend on the mode the program negotiated (Up is ESC[A in
normal mode, ESC O A in application mode), so only the terminal's own key
encoder can get them right. Any --key suppresses the implicit Return; name
`--key enter` when you want one. An unknown name is an error, never text.

Key names follow kitty and tmux, both spellings accepted: enter, escape,
tab, space, backspace, delete, insert, up, down, left, right, home, end,
pageup, pagedown, f1–f12, and single characters — prefixed with ctrl-/c-
or shift-/s- for chords (ctrl-c, c-c, shift-tab). Ctrl and Shift are the
modifiers a program sees: macOS spends Option composing text (option-b is
∫, not meta-b) and Command drives the app, so those chords are refused
rather than silently dropped. A meta chord is ESC then the key:
`--key escape --key b`.

--wait holds the reply until the turn the text kicked off settles (or
--timeout ms elapse; default 300000, clamped 1000–600000). The reply then
carries the final status, the transcript path, and the cursor..cursor_end
line range holding the response. A session that stops to ask you something
returns immediately as needs-you, with the on-screen question in `prompt`.

A prompt that shows no effect within 5s fails fast as prompt_stalled (the
input was eaten) rather than burning the timeout; a session that closes or
whose agent exits mid-wait fails as session_closed / agent_gone.

exit codes: 0 settled, 1 error (including stalled/vanished), 3 timed out.

`answer` is a deprecated, agent-only alias; `send` without a target aliases `spawn`."#
        }
        "close" => {
            r#"usage: termio sessions close <session> [...] [--json]

Close one or more session tabs. Each target gets its own attempt and reply
line; any failure fails the whole command."#
        }
        "focus" => {
            r#"usage: termio sessions focus <session> [--json]

Select the session in the app and bring termio to the front."#
        }
        _ => USAGE,
    }
}
