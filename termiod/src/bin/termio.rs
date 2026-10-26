//! termio — the command a person types. `termiod` is the daemon, like
//! `dockerd`; this client drives the Mac app and the session host
//! (docker-lessons RFC §1).
//!
//! Argument parsing is clap, like `termiod`'s. The hand-rolled dispatcher
//! this replaces was a faithful port of `scripts/termio`, and it inherited
//! the shell client's two parsing defects: a `case` that matched exact flag
//! strings swallowed any unrecognized `--flag` into the payload (so
//! `spawn "hi" --agnet codex` ran on the default agent, silently, exit 0),
//! and `--flag=value` was never a form it understood. Both are structural in
//! clap. A payload that genuinely starts with `--` stays expressible after
//! the `--` separator.
//!
//! What clap could not express stays hand-rolled, in the dispatch below
//! rather than the parser: `termio [DIR]` treats any non-verb first argument
//! as a directory (the `code .` shape, an `external_subcommand`), `remote` is
//! an argv passthrough whose help belongs to the daemon, and `send`'s first
//! positional is a target only if it looks like an address.
//!
//! The per-verb prose is the shell client's, verbatim, carried as clap
//! `long_about`. `termiod/tests/cli_compat.py` still holds the wire bytes,
//! the exit codes and the JSON shapes against the shell client; it no longer
//! diffs help text or error wording, which are this client's own.

use anyhow::{bail, Context, Result};
use clap::{Args, CommandFactory, FromArgMatches, Parser, Subcommand, ValueEnum};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use termiod::app_socket::{self, Outcome};
use termiod::channel::{self, Channel};
use termiod::{lifecycle, version};

const AFTER_HELP: &str = "\
<session> = a termio://session/<uuid> link or a bare id/prefix — printed by
`termio sessions list` / a `spawn` reply.

Every one-shot command times out after ${TERMIO_CLI_TIMEOUT:-15}s
(TERMIO_CLI_TIMEOUT overrides).";

#[derive(Parser)]
#[command(
    name = "termio",
    about = "Drive the running termio app — open projects, run agent sessions, report status.",
    after_long_help = AFTER_HELP
)]
struct Cli {
    #[command(subcommand)]
    verb: Option<Verb>,
}

#[derive(Subcommand)]
enum Verb {
    /// Open DIR (default: cwd) as a project.
    Open {
        #[arg(value_name = "DIR")]
        dir: Option<PathBuf>,
    },

    /// This machine's projects and how their sessions are grouped.
    View {
        /// Output the view as JSON.
        #[arg(long)]
        json: bool,
    },

    /// Sessions in this project — list, start, drive, close.
    Sessions {
        #[command(subcommand)]
        verb: Option<SessionVerb>,
    },

    /// Post a macOS notification (e.g. "I'm done").
    #[command(long_about = NOTIFY_HELP)]
    Notify(NotifyArgs),

    /// Report this agent's activity (hook contract).
    Agent {
        #[command(subcommand)]
        verb: AgentVerb,
    },

    /// Drive the iOS Simulator shown in the Simulator pane — look, tap, type.
    #[command(long_about = SIM_HELP)]
    Sim {
        #[command(subcommand)]
        verb: SimVerb,
    },

    /// Print the pairing token that lets a phone or a browser attach.
    ///
    /// The token authenticates the WebSocket pipe. It is not the session write
    /// token, and it never expires: `--rotate` is the only revocation.
    Pair(termiod::server::PairArgs),

    /// A machine's termiod — status, logs, sessions, deploy, Tailscale.
    ///
    /// This machine's by default; `--host` reaches another over SSH.
    Server(termiod::server::ServerArgs),

    /// Bridge the framed protocol over stdin/stdout to the local daemon.
    ///
    /// Non-interactive: no tty, no raw mode. Run as `ssh <host> termio stdio`,
    /// it lets a native client speak the same framed protocol to a remote host
    /// that it speaks to a local Unix socket. The daemon auto-starts.
    #[command(hide = true)]
    Stdio,

    /// One table: this client, the running app, the local termiod, and every
    /// known remote as of last connect.
    Version {
        /// Output the table as JSON.
        #[arg(long)]
        json: bool,
    },

    /// Print a shell completion script.
    ///
    /// For zsh: `termio completion zsh > ~/.zfunc/_termio`, with `~/.zfunc` on
    /// `fpath`. For bash: `termio completion bash > ~/.local/share/bash-completion/completions/termio`.
    Completion {
        #[arg(value_enum)]
        shell: clap_complete::Shell,
    },

    /// `termio [DIR]` — the `code .`-shaped shorthand for `open DIR`.
    #[command(external_subcommand)]
    Directory(Vec<String>),
}

#[derive(Subcommand)]
enum SessionVerb {
    /// List the sessions in this project with their live status.
    #[command(long_about = LIST_HELP, visible_alias = "ls")]
    List(ListArgs),

    /// Stream status transitions until Ctrl-C.
    #[command(long_about = WATCH_HELP)]
    Watch(WatchArgs),

    /// Start a NEW agent session on the prompt.
    #[command(long_about = SPAWN_HELP)]
    Spawn(SpawnArgs),

    /// Start a NEW terminal session running a shell command.
    #[command(long_about = RUN_HELP)]
    Run(RunArgs),

    /// Type a prompt (or menu answer) into a session.
    #[command(long_about = SEND_HELP)]
    Send(SendArgs),

    /// Deprecated, agent-only alias of `send`.
    #[command(long_about = SEND_HELP, hide = true)]
    Answer(SendArgs),

    /// Print a session's current screen.
    #[command(long_about = READ_HELP)]
    Read(ReadArgs),

    /// Close session tabs.
    #[command(long_about = CLOSE_HELP)]
    Close(CloseArgs),

    /// Select the session in the app.
    #[command(long_about = FOCUS_HELP)]
    Focus(FocusArgs),
}

#[derive(Subcommand)]
enum SimVerb {
    /// List simulators; `*` marks the one the Simulator pane shows.
    List(SimDevice),

    /// Open the Simulator pane on a device; boots it if needed. Run before building.
    Attach(SimDevice),

    /// Close the pane's live view of the device. The device keeps running.
    Detach(SimDevice),

    /// Install a built .app and launch it, replacing a running copy.
    Launch {
        /// The .app bundle, e.g. DerivedData/…/Debug-iphonesimulator/MyApp.app.
        #[arg(value_name = "APP")]
        app: PathBuf,
        /// The bundle identifier (default: read from the app's Info.plist).
        #[arg(long, value_name = "ID")]
        bundle_id: Option<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Open a URL or deep link (myapp://…, https://…).
    OpenUrl {
        #[arg(value_name = "URL")]
        url: String,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Save the screen as a PNG and print its path.
    Screenshot {
        /// Where to write the PNG (default: a new file in the temp directory).
        #[arg(long, value_name = "PATH")]
        out: Option<PathBuf>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Print the frontmost app's accessibility tree, the element at X Y, or the
    /// first element matching --marker.
    #[command(long_about = SIM_INSPECT_HELP)]
    Inspect {
        #[arg(value_name = "X", requires = "y")]
        x: Option<f64>,
        #[arg(value_name = "Y")]
        y: Option<f64>,
        /// Print only the first element whose --match attribute contains this
        /// (case-sensitive), with its descendants.
        #[arg(long, value_name = "TEXT", conflicts_with = "x")]
        marker: Option<String>,
        /// What --marker is compared with.
        #[arg(long, value_name = "ATTRIBUTE", requires = "marker",
              value_parser = ["label", "value", "role", "id"])]
        r#match: Option<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Tap at X Y (device points), or the element whose label contains --label.
    Tap {
        #[arg(value_name = "X", requires = "y", conflicts_with = "label")]
        x: Option<f64>,
        #[arg(value_name = "Y")]
        y: Option<f64>,
        /// Tap the first element whose label contains this (case-sensitive).
        #[arg(long, value_name = "TEXT")]
        label: Option<String>,
        /// Hold for this many seconds; over 0.5 is a long press.
        #[arg(long, value_name = "SECONDS")]
        duration: Option<f64>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Drag from X Y to X2 Y2 (device points). Starting within 4 points of an
    /// edge is the system edge gesture: back, notifications, Home, Control Center.
    Swipe {
        #[arg(value_name = "X")]
        x: f64,
        #[arg(value_name = "Y")]
        y: f64,
        #[arg(value_name = "X2")]
        x2: f64,
        #[arg(value_name = "Y2")]
        y2: f64,
        /// How long the drag takes, in seconds (default 0.3).
        #[arg(long, value_name = "SECONDS")]
        duration: Option<f64>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// One finger along a path: --points '[{"x":200,"y":600,"dt_ms":0},{"x":200,"y":300,"dt_ms":16},…]'.
    TouchPath {
        /// JSON samples; dt_ms (0–1000) is the delay before each, 30 s in all.
        #[arg(long, value_name = "JSON")]
        points: String,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Two fingers, for pinch and rotate: --points '[{"x1":…,"y1":…,"x2":…,"y2":…,"dt_ms":16},…]'.
    Touch2Path {
        #[arg(long, value_name = "JSON")]
        points: String,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Type text into the focused field — any language; non-US text is pasted.
    Text {
        #[arg(value_name = "TEXT", required = true)]
        words: Vec<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Press a key, or an editing command.
    Key {
        #[arg(value_name = "NAME", value_parser = [
            "return", "enter", "tab", "delete", "backspace", "forward-delete",
            "escape", "esc", "space", "up", "down", "left", "right",
            "home", "end", "page-up", "page-down",
            "select-all", "copy", "cut", "paste", "undo", "redo",
        ])]
        name: String,
        /// Press it this many times (1–20).
        #[arg(long, value_name = "N")]
        count: Option<u32>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Press a hardware button.
    Button {
        #[arg(value_name = "NAME", value_parser = [
            "home", "lock", "side", "siri", "volume-up", "volume-down", "apple-pay",
        ])]
        name: String,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Turn the device a quarter left or right, or to --orientation.
    Rotate {
        #[arg(value_name = "DIRECTION", value_parser = ["left", "right"], conflicts_with = "orientation")]
        direction: Option<String>,
        #[arg(long, value_name = "ORIENTATION",
              value_parser = ["portrait", "landscapeLeft", "landscapeRight", "portraitUpsideDown"])]
        orientation: Option<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Print an app's log: the last 100 lines of the last 5 minutes by default.
    Logs {
        /// The app (default: the one `launch` last started on the device).
        #[arg(long, value_name = "ID")]
        bundle_id: Option<String>,
        /// How many lines, newest last (1–1000).
        #[arg(long, value_name = "N")]
        tail: Option<u32>,
        /// How far back to look, in minutes.
        #[arg(long, value_name = "MINUTES")]
        minutes: Option<u32>,
        /// Only lines after this cursor — the `next:` a previous read printed.
        #[arg(long, value_name = "CURSOR")]
        since: Option<String>,
        /// The least severe level to show.
        #[arg(long, value_name = "LEVEL", value_parser = ["debug", "info", "default", "error", "fault"])]
        level: Option<String>,
        /// Only lines containing this (case-insensitive).
        #[arg(long, value_name = "TEXT")]
        filter: Option<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Summarise the app's latest crash on this device: exception, reason, crashed thread.
    CrashReport {
        #[arg(long, value_name = "ID")]
        bundle_id: Option<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Show or hide the on-screen keyboard (hiding connects the Mac's keyboard).
    Keyboard {
        #[arg(value_name = "STATE", value_parser = ["show", "hide"])]
        state: String,
        #[command(flatten)]
        device: SimDevice,
    },
}

#[derive(Args)]
struct SimDevice {
    /// The simulator to act on, by UDID or name (default: a booted one, see
    /// `termio sim --help`).
    #[arg(long, value_name = "DEVICE", global = true)]
    device: Option<String>,

    #[command(flatten)]
    output: Output,
}

#[derive(Subcommand)]
enum AgentVerb {
    /// Report this agent's activity to the session that owns it.
    Report(ReportArgs),

    /// Install status hooks and the termio skill for the agents on this machine.
    Install(termiod::server::InstallArgs),

    /// Remove every agent integration termio has installed on this machine.
    Uninstall {
        #[arg(long)]
        json: bool,
    },
}

/// `--json` reads the same on every verb that answers, so it is declared once.
#[derive(Args)]
struct Output {
    /// Machine-readable output.
    #[arg(long)]
    json: bool,
}

impl Output {
    fn format(&self) -> &'static str {
        if self.json {
            "json"
        } else {
            "text"
        }
    }
}

/// One sync vocabulary: `--wait`/`--timeout` mean the same thing on every verb
/// that accepts them, and no other verb declares them, so a `--wait` on `list`
/// is a parse error rather than a flag that is silently ignored.
#[derive(Args)]
struct Wait {
    /// Block until the turn settles; the reply carries the final status and
    /// the transcript line range to read (exit 0 settled, 1 error — including
    /// a stalled or vanished session, 3 timed out).
    #[arg(long)]
    wait: bool,

    /// Cap for --wait (default 300000, clamped 1000–600000); implies --wait.
    #[arg(
        long,
        value_name = "MS",
        allow_hyphen_values = true,
        value_parser = parse_timeout
    )]
    timeout: Option<u64>,
}

impl Wait {
    /// A stated timeout is a wait, so `--timeout 5000` alone still blocks.
    fn waiting(&self) -> bool {
        self.wait || self.timeout.is_some()
    }
}

/// Placement only means something on a verb that creates a pane, so only
/// `spawn` and `run` carry it.
#[derive(Args)]
struct Placement {
    /// Where the new pane lands relative to yours.
    #[arg(long, value_enum)]
    direction: Option<Direction>,

    /// The new pane's share of the split (e.g. 0.25); a stated ratio holds
    /// against later spawns.
    #[arg(long, value_name = "0..1", value_parser = parse_ratio)]
    ratio: Option<String>,
}

#[derive(Clone, Copy, ValueEnum)]
enum Direction {
    Right,
    Down,
}

impl Direction {
    fn wire(self) -> &'static str {
        match self {
            Direction::Right => "right",
            Direction::Down => "down",
        }
    }
}

#[derive(Clone, Copy, ValueEnum)]
enum AgentState {
    Working,
    Attention,
    Done,
    Idle,
}

impl AgentState {
    fn wire(self) -> &'static str {
        match self {
            AgentState::Working => "working",
            AgentState::Attention => "attention",
            AgentState::Done => "done",
            AgentState::Idle => "idle",
        }
    }
}

#[derive(Args)]
struct ListArgs {
    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct WatchArgs {
    /// Comma-separated states to report (working, idle, done, needs-you,
    /// stalled).
    #[arg(long, value_name = "STATES", default_value = "")]
    state: String,

    /// Skip the initial per-session status snapshot.
    #[arg(long)]
    no_snapshot: bool,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct SpawnArgs {
    /// The prompt, e.g. `termio sessions spawn "fix the build"`.
    #[arg(value_name = "PROMPT", required = true)]
    words: Vec<String>,

    /// Agent to start (e.g. claudeCode, codex, grok, pi; default: caller's kind).
    #[arg(long, value_name = "ID")]
    agent: Option<String>,

    #[command(flatten)]
    placement: Placement,

    #[command(flatten)]
    wait: Wait,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct RunArgs {
    /// The shell command, e.g. `termio sessions run "pnpm dev"`.
    #[arg(value_name = "COMMAND", required = true)]
    words: Vec<String>,

    #[command(flatten)]
    placement: Placement,

    #[command(flatten)]
    wait: Wait,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct SendArgs {
    /// A session address followed by the text — or text alone, which spawns.
    #[arg(value_name = "SESSION|TEXT", required = true)]
    words: Vec<String>,

    /// Press a named key (escape, up, tab, ctrl-c, f2, …) after the text;
    /// repeatable, in order. Any --key suppresses the implicit Return.
    #[arg(long = "key", value_name = "NAME")]
    keys: Vec<String>,

    /// Deliver the text as-is, with no Return after it — the way to answer a
    /// gate that wants a bare keypress.
    #[arg(long)]
    no_enter: bool,

    #[command(flatten)]
    wait: Wait,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct ReadArgs {
    /// The session to read, as a termio://session link or a bare id.
    #[arg(value_name = "SESSION")]
    session: String,

    /// Keep only the last N screen rows.
    #[arg(long, value_name = "N")]
    lines: Option<u64>,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct CloseArgs {
    /// The sessions to close, as termio://session links or bare ids.
    #[arg(value_name = "SESSION", required = true)]
    sessions: Vec<String>,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct FocusArgs {
    /// The session to select, as a termio://session link or a bare id.
    #[arg(value_name = "SESSION")]
    session: String,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct NotifyArgs {
    #[arg(value_name = "MESSAGE", required = true)]
    words: Vec<String>,

    /// Override the banner's title (the default is the calling agent's name).
    #[arg(long, value_name = "TITLE")]
    title: Option<String>,

    #[command(flatten)]
    output: Output,
}

/// `read`'s daemon half. `None` means the target is not a session the local
/// daemon owns and the app should answer instead; `Some(code)` means the
/// reply (success or error) was printed here.
async fn daemon_read(
    channel: &Channel,
    target: &str,
    lines: Option<u64>,
    format: &str,
) -> Option<i32> {
    let token = read_token(channel, target)?;
    let sessions = match termiod::client::sessions_of_running_daemon().await {
        Ok(Some(sessions)) => sessions,
        _ => return None,
    };
    let token_lower = token.to_lowercase();
    // Daemon-first claims only the canonical app-created population:
    // sessions whose daemon name is a UUID, matched by a hex/dash token. An
    // adopted session keeps whatever name it had, which the app may scope
    // and resolve differently — those targets stay with the app.
    if token_lower.is_empty()
        || !token_lower.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
    {
        return None;
    }
    let matches: Vec<&termiod::protocol::SessionInfo> = sessions
        .iter()
        .filter(|info| {
            let name = info.name.to_lowercase();
            uuid_shaped(&name) && (name == token_lower || name.starts_with(&token_lower))
        })
        .collect();
    match matches.len() {
        0 => None,
        1 => Some(serve_daemon_read(channel, matches[0], lines, format).await),
        _ => {
            control_error_reply(
                format,
                "ambiguous",
                &format!("'{target}' matches more than one session; use a longer id."),
            );
            Some(1)
        }
    }
}

/// The token to match against daemon session names: a bare id as-is, this
/// channel's own `…://session/<id>` link stripped to the id the way the
/// app's `addressedID` does — case-insensitively, taking the component
/// after `session/` and stopping at `/` or `?`. A foreign channel's link
/// (and any other shape) stays with the app, which owns its error copy.
fn read_token(channel: &Channel, target: &str) -> Option<String> {
    let lowered = target.to_lowercase();
    let Some(scheme_end) = lowered.find("://") else {
        return Some(target.to_string());
    };
    if lowered[..scheme_end] != channel.url_scheme() {
        return None;
    }
    let rest = &lowered[scheme_end + 3..];
    let after = rest.find("session/").map(|index| &rest[index + 8..])?;
    let id: String = after
        .chars()
        .take_while(|character| *character != '/' && *character != '?')
        .collect();
    (!id.is_empty()).then_some(id)
}

/// The 8-4-4-4-12 shape of an app-created session's daemon name.
fn uuid_shaped(name: &str) -> bool {
    name.len() == 36
        && name.char_indices().all(|(index, character)| match index {
            8 | 13 | 18 | 23 => character == '-',
            _ => character.is_ascii_hexdigit(),
        })
}

async fn serve_daemon_read(
    channel: &Channel,
    info: &termiod::protocol::SessionInfo,
    lines: Option<u64>,
    format: &str,
) -> i32 {
    let mut rows =
        match termiod::client::observe_screen_rows(&info.name, info.rows, info.cols).await {
            Ok(rows) => rows,
            Err(error) => {
                control_error_reply(format, "daemon", &format!("{error:#}"));
                return 1;
            }
        };
    if let Some(cap) = lines.map(|cap| cap as usize).filter(|cap| *cap > 0) {
        if rows.len() > cap {
            rows = rows.split_off(rows.len() - cap);
        }
    }
    let screen = rows.join("\n");
    if format == "json" {
        let mut object = std::collections::BTreeMap::new();
        object.insert("ok", serde_json::Value::Bool(true));
        object.insert("schema_version", serde_json::Value::from(1));
        object.insert("screen", serde_json::Value::from(screen));
        object.insert(
            "target",
            serde_json::Value::from(format!(
                "{}://session/{}",
                channel.url_scheme(),
                info.name.to_lowercase()
            )),
        );
        object.insert("title", serde_json::Value::from(read_title(info)));
        match serde_json::to_string(&object) {
            Ok(reply) => println!("{reply}"),
            Err(error) => {
                control_error_reply(format, "daemon", &format!("{error}"));
                return 1;
            }
        }
    } else {
        println!("{}", if screen.is_empty() { "(blank screen)" } else { &screen });
    }
    0
}

/// The best name the daemon knows: the agent-reported title, else the live
/// foreground program, else the spawned command, else the placeholder every
/// bare shell gets. The app's own `read` answers with its richer display
/// title; the daemon plane reports what the roster carries.
fn read_title(info: &termiod::protocol::SessionInfo) -> String {
    if let Some(title) = info.title.as_deref().filter(|title| !title.is_empty()) {
        return title.to_string();
    }
    let program = info
        .foreground_argv
        .as_ref()
        .and_then(|argv| argv.first())
        .map(String::as_str)
        .or_else(|| info.command.split_whitespace().next())
        .unwrap_or("");
    let program = program.rsplit('/').next().unwrap_or(program);
    if program.is_empty() {
        "Terminal".to_string()
    } else {
        program.to_string()
    }
}

/// An error in the app's own reply shape, so both halves of the router speak
/// one contract to scripts.
fn control_error_reply(format: &str, code: &str, message: &str) {
    if format == "json" {
        let mut object = std::collections::BTreeMap::new();
        object.insert("error", serde_json::Value::from(code));
        object.insert("message", serde_json::Value::from(message));
        object.insert("ok", serde_json::Value::Bool(false));
        object.insert("schema_version", serde_json::Value::from(1));
        if let Ok(reply) = serde_json::to_string(&object) {
            println!("{reply}");
        }
    } else {
        println!("error: {message}");
    }
}
/// The public hook contract: the flags keep their names because users
/// hand-write hooks against them. Every one forwards to `termio agent report`,
/// which declares the same names and reads the same stdin blob, so the payload
/// is parsed once — by whichever binary the hook actually invoked.
#[derive(Args)]
struct ReportArgs {
    #[arg(value_enum)]
    state: AgentState,

    /// Read stdin as the host's JSON payload and forward its transcript path.
    #[arg(long)]
    transcript: bool,

    /// Forward this conversation id verbatim.
    #[arg(long, value_name = "ID")]
    conversation: Option<String>,

    /// Mine the conversation id from this stdin field.
    #[arg(long, value_name = "FIELD")]
    conversation_from: Option<String>,

    /// Mine the running tool's name from this stdin field.
    #[arg(long, value_name = "FIELD")]
    tool_from: Option<String>,

    /// Mine a first-prompt title candidate from this stdin field.
    #[arg(long, value_name = "FIELD")]
    prompt_title_from: Option<String>,

    /// Stay silent on stdout and print `{}` at the end, for agents (Cursor)
    /// that read a hook's stdout as its JSON reply.
    #[arg(long)]
    reply: bool,
}

/// Digits only: `parse` alone would also take a leading `+`, and
/// `allow_hyphen_values` lets `--timeout -5` reach this instead of being read
/// as a flag — both are the shell client's rejections, kept.
fn parse_timeout(raw: &str) -> Result<u64, String> {
    if raw.is_empty() || !raw.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("whole milliseconds, digits only".to_string());
    }
    raw.parse::<u64>()
        .map_err(|_| "whole milliseconds, digits only".to_string())
}

/// Strictly `0.<digits>` — anything else (".5", "0.", "50%") would land on the
/// wire as invalid JSON or a share the app rejects. Kept as the string the
/// caller typed, because that is what goes on the wire.
fn parse_ratio(raw: &str) -> Result<String, String> {
    let valid = raw
        .strip_prefix("0.")
        .is_some_and(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()));
    if valid {
        Ok(raw.to_string())
    } else {
        Err("a number between 0 and 1, e.g. 0.25".to_string())
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    // Rust ignores SIGPIPE and turns a closed pipe into a stdout panic; a CLI
    // whose output feeds `head` must die silently there, like the shell
    // client it replaces.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let (channel, provenance) = channel::resolve();

    // `--version` names the channel it drives, which is only known once
    // argv[0] has been read — so the version string is bound here rather than
    // in the derive.
    let version_line: &'static str = Box::leak(
        format!("{} ({})", lifecycle::BUILD_VERSION, channel.name).into_boxed_str(),
    );
    let command = Cli::command().version(version_line);
    let cli = Cli::from_arg_matches(&command.get_matches())?;

    match cli.verb {
        None => open_project(&channel, Path::new(".")).await,
        Some(Verb::Open { dir }) => {
            open_project(&channel, dir.as_deref().unwrap_or(Path::new("."))).await
        }
        Some(Verb::Directory(words)) => {
            let directory = words.first().map(String::as_str).unwrap_or(".");
            open_project(&channel, Path::new(directory)).await
        }
        Some(Verb::View { json }) => print_view(json).await,
        Some(Verb::Version { json }) => version::print_table(&channel, provenance, json).await,
        Some(Verb::Completion { shell }) => {
            let mut command = Cli::command();
            let name = command.get_name().to_string();
            clap_complete::generate(shell, &mut command, name, &mut std::io::stdout());
            Ok(())
        }
        Some(Verb::Pair(args)) => termiod::server::pair(args),
        Some(Verb::Server(args)) => termiod::server::run(args).await,
        Some(Verb::Stdio) => termiod::client::stdio().await,
        Some(Verb::Agent { verb }) => match verb {
            AgentVerb::Report(args) => agent_report(args).await,
            AgentVerb::Install(args) => termiod::server::install_agents(args).await,
            AgentVerb::Uninstall { json } => termiod::server::uninstall_agents(json).await,
        },
        Some(Verb::Notify(args)) => notify(&channel, args),
        Some(Verb::Sim { verb }) => simulator(&channel, verb),
        Some(Verb::Sessions { verb }) => {
            sessions(
                &channel,
                verb.unwrap_or(SessionVerb::List(ListArgs {
                    output: Output { json: false },
                })),
            )
            .await
        }
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

/// The words a verb collected, joined the way the shell client joined them:
/// one space between argv items, so `spawn fix the build` and
/// `spawn "fix the build"` put the same bytes on the wire.
fn join(words: &[String]) -> String {
    words.join(" ")
}

/// One request per verb. Everything that decides *what* goes on the wire lives
/// here; clap has already decided that the flags are spellable at all.
async fn sessions(channel: &Channel, verb: SessionVerb) -> Result<()> {
    // The app is contacted only once argv is fully diagnosed. clap has already
    // rejected what it can see; the checks below are the ones that need to
    // know which verb they are on, and they run before `require_socket` for
    // the same reason — a malformed command should say so, not report that the
    // app is down.
    let mut agent = String::new();
    let mut extra = String::new();
    let mut client_timeout = app_socket::client_timeout();

    let (operation, output, target, text) = match verb {
        SessionVerb::List(args) => {
            let format = args.output.format();
            app_socket::require_socket(channel);
            exit_outcome(app_socket::request_once(
                channel,
                client_timeout,
                "list",
                format,
                "",
                "",
                "",
                "",
            ));
        }

        SessionVerb::Watch(args) => {
            // Exit codes tell a supervising agent how the watch ended: Ctrl-C
            // is the normal end of supervision (0, via the handler); an
            // immediate error reply (control disabled, no scope) is 1; the
            // stream reaching EOF means the *app* closed it — 2, "termio
            // died", the case to escalate.
            unsafe {
                libc::signal(libc::SIGINT, watch_interrupted as usize);
            }
            app_socket::require_socket(channel);
            let snapshot = if args.no_snapshot {
                "\"snapshot\":false"
            } else {
                ""
            };
            let code = app_socket::watch(channel, args.output.format(), &args.state, snapshot);
            if code == 2 {
                eprintln!("termio: watch stream closed by the app (termio quit or died)");
            }
            std::process::exit(code);
        }

        SessionVerb::Close(args) => {
            // One request per tab; any failure fails the whole command, but
            // every target still gets its attempt and its own reply line. A
            // target carrying whitespace splits, the way the shell client's
            // unquoted expansion split it.
            let format = args.output.format();
            app_socket::require_socket(channel);
            let mut failed = 0;
            for target in args.sessions.iter().flat_map(|word| word.split_whitespace()) {
                if app_socket::request_once(
                    channel,
                    client_timeout,
                    "close",
                    format,
                    target,
                    "",
                    "",
                    "",
                ) != Outcome::Ok
                {
                    failed = 1;
                }
            }
            std::process::exit(failed);
        }

        SessionVerb::Focus(args) => ("focus", args.output, args.session, String::new()),

        SessionVerb::Read(args) => {
            // Device verb, daemon first (unify-server-plane Stage 10): a
            // session the local daemon hosts answers from its authoritative
            // VT — including sessions no window ever opened, and boxes with
            // no app at all. A target the daemon does not own (a session on
            // a remote device, an app-side title match, a foreign-channel
            // link) falls through to the app, which keeps its coverage.
            if let Some(code) =
                daemon_read(channel, &args.session, args.lines, args.output.format()).await
            {
                std::process::exit(code);
            }
            app_socket::require_socket(channel);
            if let Some(lines) = args.lines {
                extra = format!("\"lines\":{lines}");
            }
            ("read", args.output, args.session, String::new())
        }

        // `spawn` and the no-target `send` alias both start a fresh session:
        // the app spawns whenever a `send` request carries an empty target.
        SessionVerb::Spawn(args) => {
            // One job, one entry point: spawn creates agents, run creates
            // terminals. The wire cannot tell `spawn --agent terminal` from
            // `run` (both arrive as an empty-target send with the shell
            // pinned), so the split is enforced here, where the user's intent
            // is still visible.
            if let Some(named) = &args.agent {
                if named.eq_ignore_ascii_case("terminal") || named.eq_ignore_ascii_case("shell") {
                    fail("termio: spawn starts agents — for a plain terminal running a command, use `termio sessions run \"<command>\"`");
                }
                agent = named.clone();
            }
            placement(&mut extra, &args.placement);
            waiting(&mut extra, &args.wait, &mut client_timeout);
            ("send", args.output, String::new(), join(&args.words))
        }

        // `run` is the same spawn with the agent pinned to the plain shell —
        // the payload is a command line, not a prompt.
        SessionVerb::Run(args) => {
            agent = "terminal".to_string();
            placement(&mut extra, &args.placement);
            waiting(&mut extra, &args.wait, &mut client_timeout);
            ("send", args.output, String::new(), join(&args.words))
        }

        SessionVerb::Send(args) | SessionVerb::Answer(args) => {
            // A leading address targets an existing session. Without one,
            // `send` is a back-compat alias for `spawn`; the strict is_address
            // shape check keeps a prompt that merely opens with a word from
            // being mistaken for an address.
            let addressed = args
                .words
                .first()
                .is_some_and(|word| app_socket::is_address(word));
            let (target, words) = if addressed {
                (args.words[0].clone(), &args.words[1..])
            } else {
                (String::new(), &args.words[..])
            };

            // --no-enter and --key only read on a send to an existing session:
            // a spawn's prompt has to be submitted or the fresh agent just
            // sits on a filled composer, and a key is pressed against a TUI
            // that is already drawn, which a booting agent has none of.
            if args.no_enter {
                if target.is_empty() {
                    fail("termio: --no-enter needs a session to send to");
                }
                push(&mut extra, "\"enter\":false");
            }
            if !args.keys.is_empty() {
                if target.is_empty() {
                    fail("termio: --key needs a session to press it in");
                }
                // Order matters — the app presses them in the order named — so
                // they accumulate into a JSON array rather than a set. The
                // name itself is validated by the app, the one place that
                // knows the vocabulary.
                let names: Vec<String> = args
                    .keys
                    .iter()
                    .map(|key| format!("\"{}\"", app_socket::json_escape(key)))
                    .collect();
                push(&mut extra, &format!("\"keys\":[{}]", names.join(",")));
            }
            waiting(&mut extra, &args.wait, &mut client_timeout);
            ("send", args.output, target, join(words))
        }
    };

    app_socket::require_socket(channel);
    exit_outcome(app_socket::request_once(
        channel,
        client_timeout,
        operation,
        output.format(),
        &target,
        &agent,
        &text,
        &extra,
    ));
}

fn placement(extra: &mut String, placement: &Placement) {
    if let Some(direction) = placement.direction {
        push(extra, &format!("\"direction\":\"{}\"", direction.wire()));
    }
    if let Some(ratio) = &placement.ratio {
        push(extra, &format!("\"ratio\":{ratio}"));
    }
}

fn waiting(extra: &mut String, wait: &Wait, client_timeout: &mut u64) {
    if !wait.waiting() {
        return;
    }
    push(extra, "\"wait\":true");
    if let Some(milliseconds) = wait.timeout {
        push(extra, &format!("\"timeout_ms\":{milliseconds}"));
    }
    // The client read bound must outlive the server-side wait (which the app
    // clamps to 1s–600s), or the read would hang up mid-wait and report a
    // false timeout. An explicit TERMIO_CLI_TIMEOUT still wins — the escape
    // hatch.
    if !app_socket::explicit_client_timeout() {
        *client_timeout = wait.timeout.unwrap_or(300_000) / 1000 + 30;
    }
}

fn push(extra: &mut String, fragment: &str) {
    if !extra.is_empty() {
        extra.push(',');
    }
    extra.push_str(fragment);
}

extern "C" fn watch_interrupted(_: libc::c_int) {
    unsafe { libc::_exit(0) }
}

/// `termio agent report <state> …` — what every installed hook runs, on every
/// machine. The mining flags exist because a hook's host hands it a JSON blob
/// on stdin that nothing else sees, so mining here is what lets an agent carry
/// the transcript path, the conversation id, the running tool and a
/// first-prompt label.
async fn agent_report(args: ReportArgs) -> Result<()> {
    // A hook outside a termiod session has nothing to report to, and reporting
    // with an empty target is a call the daemon rejects. Silent, because hooks
    // fire constantly and a hook that talks is worse than one that does not.
    let session = std::env::var("TERMIOD_SESSION_ID").unwrap_or_default();
    let outcome = if session.is_empty() {
        Ok(())
    } else {
        let wants_stdin = args.transcript
            || args.conversation_from.is_some()
            || args.tool_from.is_some()
            || args.prompt_title_from.is_some();
        let payload = if wants_stdin { read_hook_payload() } else { None };
        let mined = |field: &Option<String>| -> Option<String> {
            mine_field(payload.as_ref()?, field.as_deref()?)
        };
        let details = termiod::protocol::StatusDetails {
            transcript_path: args
                .transcript
                .then(|| payload.as_ref().and_then(|p| mine_field(p, "transcript_path")))
                .flatten(),
            conversation_id: args.conversation.clone().or_else(|| mined(&args.conversation_from)),
            tool: mined(&args.tool_from),
            prompt_title: mined(&args.prompt_title_from),
        };
        termiod::client::set_status(&session, args.state.wire(), None, details).await
    };
    // Cursor reads a hook's stdout as its JSON reply, so the contract is an
    // empty object even when the report itself could not be delivered.
    if args.reply {
        print!("{{}}");
    }
    outcome
}

/// The host's JSON payload on stdin, or `None`. Never read from a tty: a hook
/// invoked without its payload piped in would wait on the terminal forever, and
/// a hook that hangs hangs the agent's turn with it.
fn read_hook_payload() -> Option<serde_json::Value> {
    use std::io::Read;
    if unsafe { libc::isatty(libc::STDIN_FILENO) } == 1 {
        return None;
    }
    let mut raw = String::new();
    std::io::stdin().read_to_string(&mut raw).ok()?;
    serde_json::from_str(&raw).ok()
}

/// One top-level string field of the hook payload.
///
/// Only a string, and only at the top level: a hook contract that quietly
/// started accepting nested paths would be a second dialect to keep in step.
fn mine_field(payload: &serde_json::Value, field: &str) -> Option<String> {
    payload
        .get(field)?
        .as_str()
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

/// `termio notify [--title T] "<message>"` — post a macOS notification on
/// demand, routed through the running app so the banner wears termio's
/// identity and a click focuses the calling session.
fn notify(channel: &Channel, args: NotifyArgs) -> Result<()> {
    let body = join(&args.words);
    if body.is_empty() {
        fail("termio: notify needs a message (e.g. `termio notify \"tests passed\"`)");
    }
    app_socket::require_socket(channel);
    let extra = match &args.title {
        Some(title) => format!("\"title\":\"{}\"", app_socket::json_escape(title)),
        None => String::new(),
    };
    exit_outcome(app_socket::request_once(
        channel,
        app_socket::client_timeout(),
        "notify",
        args.output.format(),
        "",
        "",
        &body,
        &extra,
    ));
}

/// `termio sim <action>` — one request per action: the action in `target`, its
/// parameters as strings in `arguments`, and the text to type in `text`.
fn simulator(channel: &Channel, verb: SimVerb) -> Result<()> {
    let number = |value: f64| value.to_string();
    let mut arguments: Vec<(&str, String)> = Vec::new();
    let mut text = String::new();
    let (action, device) = match verb {
        SimVerb::List(device) => ("list", device),
        SimVerb::Attach(device) => ("attach", device),
        SimVerb::Detach(device) => ("detach", device),
        SimVerb::Launch { app, bundle_id, device } => {
            arguments.push(("app", app.display().to_string()));
            if let Some(id) = bundle_id {
                arguments.push(("bundle-id", id));
            }
            ("launch", device)
        }
        SimVerb::OpenUrl { url, device } => {
            arguments.push(("url", url));
            ("open-url", device)
        }
        SimVerb::Screenshot { out, device } => {
            if let Some(out) = out {
                arguments.push(("out", out.display().to_string()));
            }
            ("screenshot", device)
        }
        SimVerb::Inspect { x, y, marker, r#match, device } => {
            if let (Some(x), Some(y)) = (x, y) {
                arguments.push(("x", number(x)));
                arguments.push(("y", number(y)));
            }
            if let Some(marker) = marker {
                arguments.push(("marker", marker));
            }
            if let Some(key) = r#match {
                arguments.push(("match", key));
            }
            ("inspect", device)
        }
        SimVerb::Tap { x, y, label, duration, device } => {
            match (x, y, label) {
                (_, _, Some(label)) => arguments.push(("label", label)),
                (Some(x), Some(y), None) => {
                    arguments.push(("x", number(x)));
                    arguments.push(("y", number(y)));
                }
                _ => fail("termio: tap needs X Y or --label (e.g. `termio sim tap 200 400`)"),
            }
            if let Some(duration) = duration {
                arguments.push(("duration", number(duration)));
            }
            ("tap", device)
        }
        SimVerb::Swipe { x, y, x2, y2, duration, device } => {
            arguments.push(("x", number(x)));
            arguments.push(("y", number(y)));
            arguments.push(("x2", number(x2)));
            arguments.push(("y2", number(y2)));
            if let Some(duration) = duration {
                arguments.push(("duration", number(duration)));
            }
            ("swipe", device)
        }
        SimVerb::TouchPath { points, device } => {
            arguments.push(("points", points));
            ("touch-path", device)
        }
        SimVerb::Touch2Path { points, device } => {
            arguments.push(("points", points));
            ("touch2-path", device)
        }
        SimVerb::Text { words, device } => {
            text = join(&words);
            ("text", device)
        }
        SimVerb::Key { name, count, device } => {
            arguments.push(("name", name));
            if let Some(count) = count {
                arguments.push(("count", count.to_string()));
            }
            ("key", device)
        }
        SimVerb::Button { name, device } => {
            arguments.push(("name", name));
            ("button", device)
        }
        SimVerb::Rotate { direction, orientation, device } => {
            if let Some(orientation) = orientation {
                arguments.push(("orientation", orientation));
            } else {
                arguments.push(("direction", direction.unwrap_or_else(|| "right".to_string())));
            }
            ("rotate", device)
        }
        SimVerb::Logs { bundle_id, tail, minutes, since, level, filter, device } => {
            let optional: [(&str, Option<String>); 6] = [
                ("bundle-id", bundle_id),
                ("tail", tail.map(|value| value.to_string())),
                ("minutes", minutes.map(|value| value.to_string())),
                ("since", since),
                ("level", level),
                ("filter", filter),
            ];
            for (key, value) in optional {
                if let Some(value) = value {
                    arguments.push((key, value));
                }
            }
            ("logs", device)
        }
        SimVerb::CrashReport { bundle_id, device } => {
            if let Some(id) = bundle_id {
                arguments.push(("bundle-id", id));
            }
            ("crash-report", device)
        }
        SimVerb::Keyboard { state, device } => {
            arguments.push(("state", state));
            ("keyboard", device)
        }
    };
    if let Some(name) = device.device {
        arguments.push(("device", name));
    }
    let fields = arguments
        .iter()
        .map(|(key, value)| format!("\"{key}\":\"{}\"", app_socket::json_escape(value)))
        .collect::<Vec<_>>()
        .join(",");
    // Any command may wait out a boot `attach` started — half a minute, a first
    // boot several — and installing a large app is slow too; the app answers
    // when it is done. An explicit TERMIO_CLI_TIMEOUT still wins.
    let timeout = if action != "list" && !app_socket::explicit_client_timeout() {
        app_socket::client_timeout().max(180)
    } else {
        app_socket::client_timeout()
    };
    app_socket::require_socket(channel);
    exit_outcome(app_socket::request_once(
        channel,
        timeout,
        "sim",
        device.output.format(),
        action,
        "",
        &text,
        &format!("\"arguments\":{{{fields}}}"),
    ));
}

/// Resolve to an absolute, symlink-free path so termio keys the project by
/// the same canonical path it stores, avoiding duplicate sidebar entries.
async fn open_project(channel: &Channel, directory: &Path) -> Result<()> {
    if !directory.is_dir() {
        eprintln!("termio: not a directory: {}", directory.display());
        std::process::exit(1);
    }
    let absolute = directory
        .canonicalize()
        .with_context(|| format!("resolving {}", directory.display()))?;
    if !cfg!(target_os = "macos") {
        return open_on_this_host(&absolute).await;
    }
    let error = Command::new("open")
        .arg("-b")
        .arg(&channel.bundle_id)
        .arg(&absolute)
        .exec();
    Err(error).context("running open")
}

/// Off a Mac there is no app to hand the directory to. The project goes into
/// this host's view instead, which every client connected here draws. A project
/// with no running session gets a shell, so it opens onto something live.
async fn open_on_this_host(directory: &Path) -> Result<()> {
    let path = directory.to_string_lossy().into_owned();
    let project = termiod::client::project_add(&path).await?;
    let view = termiod::client::view().await?;
    let Some(row) = view.projects.iter().find(|row| row.id == project) else {
        bail!("{path} was registered but is not in the view");
    };
    let live: Vec<String> = termiod::client::list()
        .await?
        .into_iter()
        .map(|info| info.id)
        .collect();
    let running = row.groups.iter().flat_map(|group| group.panes()).any(|pane| match &pane.kind {
        termiod::view::PaneKind::Terminal { session } => live.contains(session),
    });
    if !running {
        let (rows, cols) = termiod::client::term_size();
        let spec = termiod::protocol::CreateSpec {
            cwd: Some(path.clone()),
            rows,
            cols,
            place: Some(termiod::view::Place {
                project: Some(project.clone()),
            }),
            ..Default::default()
        };
        termiod::client::create(spec).await?;
    }
    println!("Opened {}. It shows in termio on every device connected to this machine.", row.label);
    Ok(())
}

/// `termio view`: the host's projects and how their sessions are grouped.
async fn print_view(json: bool) -> Result<()> {
    let view = termiod::client::view().await?;
    if json {
        println!("{}", serde_json::to_string_pretty(&view)?);
        return Ok(());
    }
    fn print_groups(groups: &[termiod::view::Group]) {
        for group in groups {
            let sessions: Vec<String> = group
                .panes()
                .iter()
                .map(|pane| match &pane.kind {
                    termiod::view::PaneKind::Terminal { session } => session.clone(),
                })
                .collect();
            println!("  {}  {}", group.id, sessions.join(" "));
        }
    }
    println!("revision {}", view.revision);
    for project in &view.projects {
        println!("{}  {}", project.label, project.path);
        print_groups(&project.groups);
    }
    if !view.loose.is_empty() {
        println!("(no project)");
        print_groups(&view.loose);
    }
    Ok(())
}

const NOTIFY_HELP: &str = "\
Post a macOS notification from the running app. The agent uses this to ping you
directly — \"build finished\", \"need a decision\" — regardless of whether termio is
frontmost (unlike the automatic completion banner). --title overrides the default
(the calling agent's name); the banner's subtitle is the project, and clicking it
focuses the session that posted it.";

const SIM_HELP: &str = "\
Drive the iOS Simulator shown in termio's Simulator pane, so an agent can run
and check an iOS app the way the person watching would. Coordinates are device
points from the top-left of the screen as it is shown — after a rotation too —
the unit `inspect` reports frames in, so tap the centre of a frame it printed.
Read the screen with `inspect` before tapping anything you have not located;
use `screenshot` for colour, images and layout.

Run `attach` FIRST, before you build: the person watches from the first
frame, and a shut-down device boots while xcodebuild compiles. It answers as
soon as the device is drawing — a few seconds — not once it has booted; the
next command waits for the boot to finish (half a minute, minutes on a first
boot), so start the build in between.

  termio sim attach --device \"iPhone 17\"
  xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 17' \\
    -derivedDataPath build build
  termio sim launch build/Build/Products/Debug-iphonesimulator/MyApp.app
  termio sim inspect
  termio sim tap --label \"Continue\"
  termio sim swipe 200 700 200 200
  termio sim text \"hello@example.com\" && termio sim key return
  termio sim screenshot --out /tmp/screen.png

With no --device, a command uses the first of these that is booted: the device
this session used last; the device the pane shows, unless another session is
driving it; a device no other session is driving; any device. When nothing is
booted, name one with `attach --device`. Build with xcodebuild in your shell;
`logs` reads the app's log and `crash-report` its last crash.
Needs a Mac with Apple silicon and macOS 15 or later.";

const SIM_INSPECT_HELP: &str = "\
Print the frontmost app's accessibility tree, one element per line:
type, label, value (or an empty field's placeholder), identifier, then the
frame as x,y width x height in device points. Elements that say nothing are
folded away, and elements wholly off the screen are counted, not printed.
With X Y, print the element drawn at that point, as a tap there would find
it — the read that resolves what covers what.
With --marker, print the first element, in tree order, whose label (or
--match value, role or id) contains the text; a title can match before the
button that shares it, so check the type. When the reply names a modal, stay
inside it. --json prints idb's full accessibility document instead.";

const LIST_HELP: &str = "\
List the sessions in this project with their live status (working / idle /
done / needs-you). `--json` adds each session's transcript path once its
agent has reported one.";

const WATCH_HELP: &str = "\
Block and stream one line per session status transition until interrupted.
On attach it first prints a snapshot line per session with its current
status (tagged \"snapshot\":true in --json); --no-snapshot skips that.
--state takes a comma-separated filter (working, idle, done, needs-you,
stalled); the default reports the two states a supervisor acts on: done,
needs-you.
In --json mode the app writes {\"heartbeat\":true} after 30s of silence so a
dead stream is distinguishable from a quiet one.

`stalled` is a watch-plane signal, not a real status: the session is still
working, but for 20+ minutes has made no repo change and next-to-no
transcript growth — the unattended-runaway pattern. Sustained output (a
long build streaming logs) suppresses it. The event carries the reasoning
in `evidence` (\"working 42m, no repo change, transcript +3 lines\"), fires
once per quiet stretch, and re-arms when progress resumes. Opt in with
--state stalled; it is not in the default filter.

exit codes: 0 after Ctrl-C (normal end of supervision), 2 when the stream
closes from the app side (termio quit or died).";

const SPAWN_HELP: &str = "\
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

exit codes: 0 settled, 1 error (including stalled/vanished), 3 timed out.";

const RUN_HELP: &str = "\
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

exit codes: 0 settled, 1 error (including stalled/vanished), 3 timed out.";

const READ_HELP: &str = "\
Print the session's current screen (its viewport, right-trimmed, trailing
blank rows dropped) without focusing it. The result channel for `run`
sessions, and a quick peek at any agent's live TUI. --lines keeps only
the last N rows. Scrollback is not included.";

const SEND_HELP: &str = "\
Type text into an existing session and submit it with a real Return
keypress — a prompt to drive it, or a menu choice (\"1\", \"yes\") to answer a
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

`answer` is a deprecated, agent-only alias; `send` without a target aliases `spawn`.";

const CLOSE_HELP: &str = "\
Close one or more session tabs. Each target gets its own attempt and reply
line; any failure fails the whole command.";

const FOCUS_HELP: &str = "\
Select the session in the app and bring termio to the front.";

#[cfg(test)]
mod tests {
    use super::*;

    fn release() -> Channel {
        Channel::from_program_name("termio")
    }

    #[test]
    fn links_resolve_the_way_the_apps_addressed_id_does() {
        let id = "8de0b387-485a-4016-8990-cbcbfff03199";
        let link = format!("termio://session/{id}");
        assert_eq!(read_token(&release(), &link).as_deref(), Some(id));
        // Case-insensitive scheme and id, trailing slash, query suffix.
        assert_eq!(
            read_token(&release(), &format!("TERMIO://session/{}", id.to_uppercase())).as_deref(),
            Some(id)
        );
        assert_eq!(read_token(&release(), &format!("{link}/")).as_deref(), Some(id));
        assert_eq!(read_token(&release(), &format!("{link}?focus=1")).as_deref(), Some(id));
        // A bare token passes through untouched.
        assert_eq!(read_token(&release(), "8de0b387").as_deref(), Some("8de0b387"));
    }

    #[test]
    fn foreign_and_malformed_links_stay_with_the_app() {
        assert_eq!(read_token(&release(), "termio-dev://session/8de0b387"), None);
        assert_eq!(read_token(&release(), "https://example.com/session/x"), None);
        assert_eq!(read_token(&release(), "termio://nothing-here"), None);
        assert_eq!(read_token(&release(), "termio://session/"), None);
    }

    #[test]
    fn only_uuid_shaped_names_belong_to_the_daemon_first_path() {
        assert!(uuid_shaped("8de0b387-485a-4016-8990-cbcbfff03199"));
        assert!(!uuid_shaped("8de0b387"));
        assert!(!uuid_shaped("deadbeef-server"));
        assert!(!uuid_shaped("8de0b387-485a-4016-8990-cbcbfff0319g"));
    }
}
