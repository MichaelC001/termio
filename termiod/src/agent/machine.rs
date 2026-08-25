//! What the daemon knows about its own box.
//!
//! Three bugs in the SSH arm existed only because the writer was on the wrong
//! machine, and none of them is ported here:
//!
//! - `$HOME` needed three escapings — raw, shell, and JavaScript — because the
//!   binary path was a shell *expression* the remote had to expand. A daemon
//!   knows its own executable's absolute path.
//! - `~/.config` had to be spelled `${XDG_CONFIG_HOME:-$HOME/.config}` so a
//!   remote shell would resolve it. Here it is one `std::env::var`.
//! - The CLI probe had to ask a login shell twice, because `ssh host cmd` gets a
//!   minimal `PATH`. A daemon *also* does not always inherit the user's `PATH`
//!   (it is auto-started from an SSH command or a launchd job, exactly as the Mac
//!   app is started from Finder), so the login-shell probe stays — but as the one
//!   mechanism it always was, asked once and cached, not as an SSH workaround.

use super::manifest::ConfigHome;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// The account's home directory. `$HOME` first, because that is what every
/// process on the box agrees the home is, then the password database for a
/// daemon started without an environment.
pub fn home_directory() -> Option<PathBuf> {
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        if !home.as_os_str().is_empty() {
            return Some(home);
        }
    }
    passwd_home()
}

fn passwd_home() -> Option<PathBuf> {
    // SAFETY: `getpwuid` returns a pointer into a static buffer owned by libc;
    // the strings are read and copied before anything else can call it.
    unsafe {
        let entry = libc::getpwuid(libc::getuid());
        if entry.is_null() {
            return None;
        }
        let dir = (*entry).pw_dir;
        if dir.is_null() {
            return None;
        }
        let dir = std::ffi::CStr::from_ptr(dir).to_string_lossy().into_owned();
        if dir.is_empty() {
            None
        } else {
            Some(PathBuf::from(dir))
        }
    }
}

/// The user's login shell, from the password database rather than the ambient
/// `SHELL` — a daemon started by launchd or by an SSH command may have neither,
/// or may have inherited someone else's.
pub fn login_shell() -> String {
    // SAFETY: same contract as `passwd_home`.
    let from_passwd = unsafe {
        let entry = libc::getpwuid(libc::getuid());
        if entry.is_null() || (*entry).pw_shell.is_null() {
            None
        } else {
            let shell = std::ffi::CStr::from_ptr((*entry).pw_shell)
                .to_string_lossy()
                .into_owned();
            if shell.is_empty() {
                None
            } else {
                Some(shell)
            }
        }
    };
    from_passwd
        .or_else(|| std::env::var("SHELL").ok())
        .unwrap_or_else(|| "/bin/sh".to_string())
}

/// The XDG bases, resolved against this box.
///
/// `~/.config` and `~/.local/share` are the spec's default *values*, not
/// directory names, and every agent termio files under them — OpenCode, Amp,
/// Crush — reads the variable. Writing to the literal default on a machine whose
/// owner moved their config puts a plugin where the agent never looks.
const XDG_BASES: [(&str, &str); 2] = [
    (".config", "XDG_CONFIG_HOME"),
    (".local/share", "XDG_DATA_HOME"),
];

/// Expand a manifest path (`~/.claude/settings.json`) against this box.
///
/// A manifest path always means the account the daemon runs as, so `~user` is
/// deliberately not honoured and a `~` anywhere but the front is an ordinary
/// character.
pub fn expand(path: &str) -> PathBuf {
    expand_with(path, home_directory(), &login_environment)
}

/// Resolve a manifest path against this box, honouring the agent's own
/// config-home variable when it declares one.
///
/// **Order: the agent's variable, then the XDG base, then `~`.** The two
/// overrides compose rather than race. An agent that documents its own variable
/// is saying "my whole tree is here", which is a more specific statement than
/// "my tree is under the config base", so it wins; the XDG base applies only
/// when the agent's variable is unset or empty. Nothing in the catalog needs
/// both today — no agent with a config-home variable keeps its tree under
/// `~/.config` — but the rule has to be decided somewhere rather than left to
/// whichever check happens to run first.
///
/// `Err` means *do not install*, with the sentence to show for it.
pub fn resolve(path: &str, home: Option<&ConfigHome>) -> std::result::Result<PathBuf, String> {
    resolve_with(path, home, &login_environment, home_directory())
}

fn resolve_with(
    path: &str,
    home: Option<&ConfigHome>,
    lookup: &dyn Fn(&str) -> Option<String>,
    home_directory: Option<PathBuf>,
) -> std::result::Result<PathBuf, String> {
    let Some(config_home) = home else {
        return Ok(expand_with(path, home_directory, lookup));
    };
    // An unset or empty variable is the default, not an error: it is what every
    // account that never moved its config has.
    let Some(moved) = lookup(&config_home.env).filter(|value| !value.trim().is_empty()) else {
        return Ok(expand_with(path, home_directory, lookup));
    };
    // A comma is ambiguous and this refuses rather than guesses — see
    // `AMBIGUOUS_CONFIG_HOME`.
    if moved.contains(',') {
        return Err(format!(
            "{} names more than one directory ({moved}); \
             set it to a single directory to install here",
            config_home.env
        ));
    }
    if !crate::agent::manifest::is_under(path, &config_home.path) {
        // The manifest validated this at load, so reaching it means a manifest
        // changed underneath a running daemon. Fall back rather than write
        // somewhere the prefix does not describe.
        return Ok(expand_with(path, home_directory, lookup));
    }
    let tail = path[config_home.path.len()..].trim_start_matches('/');
    let moved = expand_with(moved.trim(), home_directory, lookup);
    Ok(if tail.is_empty() {
        moved
    } else {
        moved.join(tail)
    })
}

fn expand_with(
    path: &str,
    home: Option<PathBuf>,
    lookup: &dyn Fn(&str) -> Option<String>,
) -> PathBuf {
    let home = match home {
        Some(home) => home,
        None => return PathBuf::from(path),
    };
    if path == "~" {
        return home;
    }
    let rest = match path.strip_prefix("~/") {
        Some(rest) => rest,
        None => return PathBuf::from(path),
    };
    for (prefix, variable) in XDG_BASES {
        let tail = if rest == prefix {
            Some("")
        } else {
            rest.strip_prefix(prefix)
                .and_then(|tail| tail.strip_prefix('/'))
        };
        let Some(tail) = tail else { continue };
        let Some(base) = lookup(variable) else { break };
        let base = PathBuf::from(base);
        return if tail.is_empty() { base } else { base.join(tail) };
    }
    home.join(rest)
}

/// A variable the daemon's own environment may be missing because of how it was
/// started. The daemon's own value wins where it has one — a user who exported
/// `XDG_CONFIG_HOME` for the process meant it — and the login shell answers for
/// the rest. Both XDG bases ride one probe because a second login shell would
/// pay for another rc that can take seconds.
pub fn login_environment(name: &str) -> Option<String> {
    if let Ok(value) = std::env::var(name) {
        if !value.is_empty() {
            return Some(value);
        }
    }
    probe().get(name).filter(|value| !value.is_empty()).cloned()
}

/// Where a command could be found from this box, login shell first.
///
/// `PATH` is the one variable whose *inherited* value must not win. A daemon
/// auto-started from `ssh host termiod stdio` inherits ssh's minimal `PATH`, and
/// a Mac one started by launchd inherits almost nothing — while the agents worth
/// finding are exactly the ones outside a default `PATH`. On a stock Ubuntu box
/// `claude` installs to `~/.local/bin`, which only `~/.profile` adds; trusting
/// the inherited value answers "not installed" for an agent sitting right there,
/// and then no skill is installed anywhere. That failure is silent, and it was
/// the blocker in front of everything else in the device arm.
///
/// The inherited value is kept as a second source rather than dropped: it is
/// still a real place this daemon can exec from, and a union can only ever find
/// more.
pub fn login_path() -> Vec<String> {
    let mut directories = Vec::new();
    let from_login = probe().get("PATH").cloned().unwrap_or_default();
    let inherited = std::env::var("PATH").unwrap_or_default();
    for source in [from_login, inherited] {
        for directory in source.split(':').filter(|d| !d.is_empty()) {
            if !directories.iter().any(|seen| seen == directory) {
                directories.push(directory.to_string());
            }
        }
    }
    directories
}

/// Whether `command`'s binary can be run on this box.
///
/// Answers `true` when it could not look, so a probe that fails never reads as
/// "not installed" — the don't-cry-wolf rule the app follows locally, and the
/// one that stops a broken environment from quietly uninstalling everything.
pub fn is_command_installed(command: &str) -> bool {
    let trimmed = command.trim();
    let Some(binary) = trimmed.split(' ').next().filter(|b| !b.is_empty()) else {
        return true;
    };
    if binary.starts_with('/') || binary.starts_with('~') {
        return is_executable(&expand(binary));
    }
    let directories = login_path();
    if directories.is_empty() {
        return true;
    }
    directories
        .iter()
        .any(|directory| is_executable(&Path::new(directory).join(binary)))
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    match std::fs::metadata(path) {
        Ok(metadata) => metadata.is_file() && metadata.permissions().mode() & 0o111 != 0,
        Err(_) => false,
    }
}

/// One login-shell spawn answers for everything the daemon's own environment
/// cannot see. Bounded and cached for the process: an rc that blocks must not
/// wedge an install, and a shell that never returns must not be asked twice.
fn probe() -> &'static HashMap<String, String> {
    static PROBED: OnceLock<HashMap<String, String>> = OnceLock::new();
    PROBED.get_or_init(probe_login_shell)
}

fn probe_login_shell() -> HashMap<String, String> {
    let names = ["PATH", "XDG_CONFIG_HOME", "XDG_DATA_HOME"];
    // `${VAR-}` rather than `$VAR`, so an unset variable is an empty line and
    // the lines stay positional under `set -u`.
    let script = format!(
        "printf '%s\\n' {}",
        names
            .iter()
            .map(|name| format!("\"${{{name}-}}\""))
            .collect::<Vec<_>>()
            .join(" ")
    );
    let mut child = match std::process::Command::new(login_shell())
        .args(["-lc", &script])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            crate::agent::manifest::log(&format!("could not probe the login shell: {error}"));
            return HashMap::new();
        }
    };

    // Bound the probe. `wait_timeout` is not in std, so poll `try_wait` — the
    // shell either answers in well under a second or it is an rc that hangs,
    // and either way the install must not stop here.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                crate::agent::manifest::log("the login shell did not answer in time");
                return HashMap::new();
            }
            Err(_) => return HashMap::new(),
        }
    }

    let mut output = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        use std::io::Read;
        let _ = stdout.read_to_string(&mut output);
    }
    let mut resolved = HashMap::new();
    for (index, name) in names.iter().enumerate() {
        if let Some(value) = output.lines().nth(index) {
            if !value.is_empty() {
                resolved.insert(name.to_string(), value.to_string());
            }
        }
    }
    resolved
}

/// This daemon's own executable, as an absolute path, for stamping into a hook
/// command. The SSH arm had to emit `$HOME/.local/bin/termiod` and escape it
/// three ways; the process that will be exec'd knows where it lives.
pub fn daemon_binary() -> String {
    if let Ok(path) = std::env::current_exe() {
        // A daemon started through a symlink still reports the link's path here,
        // which is the path the user's own `PATH` resolves — the right one to
        // stamp. Canonicalizing would replace it with a build artefact's path
        // that a later upgrade renames out from under every hook.
        if let Some(path) = path.to_str() {
            return path.to_string();
        }
    }
    match home_directory() {
        Some(home) => home.join(".local/bin/termiod").display().to_string(),
        None => "termiod".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expand_resolves_a_leading_tilde_against_this_home() {
        let home = home_directory().expect("a home");
        assert_eq!(expand("~/.claude/settings.json"), home.join(".claude/settings.json"));
        assert_eq!(expand("~"), home);
    }

    #[test]
    fn expand_leaves_an_absolute_path_alone() {
        assert_eq!(expand("/etc/hosts"), PathBuf::from("/etc/hosts"));
        // A tilde that is not the first segment is an ordinary character.
        assert_eq!(
            expand("/tmp/~/x"),
            PathBuf::from("/tmp/~/x")
        );
    }

    #[test]
    fn xdg_config_home_is_a_variable_not_a_directory_name() {
        let home = Some(PathBuf::from("/home/u"));
        let moved = |name: &str| (name == "XDG_CONFIG_HOME").then(|| "/home/u/cfg".to_string());
        assert_eq!(
            expand_with("~/.config/opencode/plugin", home.clone(), &moved),
            PathBuf::from("/home/u/cfg/opencode/plugin")
        );
        assert_eq!(
            expand_with("~/.config", home.clone(), &moved),
            PathBuf::from("/home/u/cfg")
        );
        // Unset: the spec's own default, which is what every default account has.
        let unset = |_: &str| None;
        assert_eq!(
            expand_with("~/.config/amp/plugins", home.clone(), &unset),
            PathBuf::from("/home/u/.config/amp/plugins")
        );
        // `.claude` is not an XDG base and must never be rerouted by one.
        assert_eq!(
            expand_with("~/.claude/settings.json", home, &moved),
            PathBuf::from("/home/u/.claude/settings.json")
        );
    }

    #[test]
    fn an_absent_binary_is_not_installed_and_a_present_one_is() {
        assert!(is_command_installed("/bin/sh"));
        assert!(!is_command_installed("/nonexistent/agent-cli"));
        // The empty command is the plain login shell, which is always available.
        assert!(is_command_installed(""));
    }

    fn home(env: &str, path: &str) -> ConfigHome {
        ConfigHome {
            env: env.to_string(),
            path: path.to_string(),
        }
    }

    /// Resolution with a stated environment, so these assert the rule rather
    /// than whatever this machine happens to export.
    fn at(path: &str, home: Option<&ConfigHome>, env: &[(&str, &str)]) -> Result<String, String> {
        let env: Vec<(String, String)> = env
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let lookup = move |name: &str| {
            env.iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.clone())
        };
        resolve_with(path, home, &lookup, Some(PathBuf::from("/home/u")))
            .map(|path| path.display().to_string())
    }

    /// The four states the field has to survive, and the reason it exists: an
    /// agent whose owner moved its config gets the install where the agent
    /// actually reads, and one who did not is unaffected.
    #[test]
    fn a_config_home_variable_moves_the_install() {
        let claude = home("CLAUDE_CONFIG_DIR", "~/.claude");

        // Unset: the documented default, which is every account that never
        // touched it.
        assert_eq!(
            at("~/.claude/settings.json", Some(&claude), &[]),
            Ok("/home/u/.claude/settings.json".into())
        );
        // Set: the whole tree moves, prefix replaced and tail kept.
        assert_eq!(
            at("~/.claude/settings.json", Some(&claude), &[("CLAUDE_CONFIG_DIR", "/srv/work")]),
            Ok("/srv/work/settings.json".into())
        );
        assert_eq!(
            at("~/.claude/skills/termio/SKILL.md", Some(&claude), &[("CLAUDE_CONFIG_DIR", "/srv/work")]),
            Ok("/srv/work/skills/termio/SKILL.md".into())
        );
        // Empty: not a directory named "", the default.
        assert_eq!(
            at("~/.claude/settings.json", Some(&claude), &[("CLAUDE_CONFIG_DIR", "   ")]),
            Ok("/home/u/.claude/settings.json".into())
        );
        // The variable may itself be `~`-relative.
        assert_eq!(
            at("~/.claude/settings.json", Some(&claude), &[("CLAUDE_CONFIG_DIR", "~/work")]),
            Ok("/home/u/work/settings.json".into())
        );
    }

    /// A comma is ambiguous. Claude Code's own entry describes one directory;
    /// the comma-separated form is ccusage's convention for *reading* across
    /// profiles. Installing into the first would wire up one profile and leave
    /// the others silent, which reads as an agent that reports sometimes.
    #[test]
    fn more_than_one_directory_is_refused_rather_than_guessed() {
        let claude = home("CLAUDE_CONFIG_DIR", "~/.claude");
        let outcome = at(
            "~/.claude/settings.json",
            Some(&claude),
            &[("CLAUDE_CONFIG_DIR", "~/.claude-work,~/.claude-personal")],
        );
        let error = outcome.expect_err("must refuse");
        assert!(error.contains("CLAUDE_CONFIG_DIR"), "{error}");
        assert!(error.contains("more than one directory"), "{error}");
    }

    /// The two overrides compose in a stated order rather than racing. Nothing
    /// in the catalog needs both today, but the rule has to be decided
    /// somewhere.
    #[test]
    fn an_agents_own_variable_outranks_the_xdg_base() {
        let under_xdg = home("SOME_AGENT_HOME", "~/.config/some-agent");
        let env = [
            ("XDG_CONFIG_HOME", "/xdg"),
            ("SOME_AGENT_HOME", "/agent-home"),
        ];
        assert_eq!(
            at("~/.config/some-agent/hooks.json", Some(&under_xdg), &env),
            Ok("/agent-home/hooks.json".into())
        );
        // With only the XDG base set, the XDG base applies.
        assert_eq!(
            at("~/.config/some-agent/hooks.json", Some(&under_xdg), &env[..1]),
            Ok("/xdg/some-agent/hooks.json".into())
        );
        // And an agent that declares no variable is untouched by this at all.
        assert_eq!(
            at("~/.config/some-agent/hooks.json", None, &env),
            Ok("/xdg/some-agent/hooks.json".into())
        );
    }

    /// A prefix that is a text prefix but not a path prefix must not match, or
    /// `~/.pi/agent` would claim `~/.pi/agentic`.
    #[test]
    fn the_prefix_is_matched_by_path_component() {
        let pi = home("PI_DIR", "~/.pi/agent");
        assert_eq!(
            at("~/.pi/agent/extensions", Some(&pi), &[("PI_DIR", "/elsewhere")]),
            Ok("/elsewhere/extensions".into())
        );
        // Outside the declared prefix: fall back rather than write somewhere
        // the prefix does not describe.
        assert_eq!(
            at("~/.pi/agentic/x", Some(&pi), &[("PI_DIR", "/elsewhere")]),
            Ok("/home/u/.pi/agentic/x".into())
        );
        // The home itself resolves to the moved directory, with no stray slash.
        assert_eq!(
            at("~/.pi/agent", Some(&pi), &[("PI_DIR", "/elsewhere")]),
            Ok("/elsewhere".into())
        );
    }

    /// The probe has to look past the `PATH` this process inherited. A daemon
    /// auto-started over SSH gets a minimal one, and the agents worth finding
    /// live outside it.
    #[test]
    fn the_login_shell_path_is_consulted_even_when_one_was_inherited() {
        assert!(
            !std::env::var("PATH").unwrap_or_default().is_empty(),
            "this test is meaningless without an inherited PATH"
        );
        let login = probe().get("PATH").cloned().unwrap_or_default();
        for directory in login.split(':').filter(|d| !d.is_empty()) {
            assert!(
                login_path().iter().any(|seen| seen == directory),
                "{directory} came from the login shell and must be searched"
            );
        }
    }
}
