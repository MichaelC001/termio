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
