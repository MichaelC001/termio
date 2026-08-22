//! Keeping the daemon alive across logins and crashes (§6).
//!
//! Making `termiod` the only PTY owner makes it a single point of failure. An
//! in-process PTY at least died *with* the app; a daemon that is not supervised
//! dies on its own and takes every session with it — and "the session lives on
//! the box, not in the connection" stops being true the first time the user
//! logs out.
//!
//! macOS answers this with a **launchd user agent**: `RunAtLoad` starts it at
//! login, `KeepAlive` restarts it if it dies. Linux's answer is a systemd
//! `--user` unit plus `loginctl enable-linger` — without linger a user daemon is
//! killed at logout, so sessions would vanish silently between SSH connections.
//! Only macOS is implemented here; Linux boxes are reached over SSH, which
//! autostarts the daemon on contact, so the gap is a durability limit rather
//! than an outage.
//!
//! Installing is never automatic. It writes into the user's `LaunchAgents` and
//! makes the daemon outlive every termio process, which is the user's decision
//! to make, not a side effect of running a command.

use anyhow::{bail, Context, Result};
use std::path::PathBuf;

use crate::paths;

const LABEL_BASE: &str = "sh.termio.termiod";

/// The launchd label, scoped by channel: `sh.termio.termiod` for a release
/// build, `sh.termio.termiod.dev` for the dev build beside it.
///
/// The label is also the plist filename and the `gui/$UID/…` target, so one
/// label for two channels is one job for two apps to fight over: each
/// `install()` boots the other's out, repoints the plist at its own binary, and
/// `KeepAlive` respawns whichever wrote last. Scoping the socket alone would
/// not have fixed that — it is a second axis.
pub fn label() -> String {
    match paths::channel_suffix().strip_prefix('-') {
        Some(channel) => format!("{LABEL_BASE}.{channel}"),
        None => LABEL_BASE.to_string(),
    }
}

#[derive(clap::Subcommand)]
pub enum ServiceCmd {
    /// Install and start the launchd user agent (macOS).
    Install,
    /// Stop and remove the launchd user agent.
    Uninstall,
    /// Report whether the agent is installed and loaded.
    Status,
}

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set, so the user's LaunchAgents directory can't be found")
}

fn plist_path() -> Result<PathBuf> {
    Ok(home()?
        .join("Library/LaunchAgents")
        .join(format!("{}.plist", label())))
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The agent definition.
///
/// `TERMIOD_SOCK` is forwarded **only if the caller had it set**. Both sides
/// derive the socket path the same way from the same environment, so pinning it
/// here when the user has not pinned it would make the daemon and the app
/// rendezvous at different sockets the moment either one's `TMPDIR` differs.
/// If the user has pinned it, they meant it, and the agent must honour it.
///
/// `TERMIO_CHANNEL` is the opposite case and is pinned whenever it is not the
/// release channel. There is nothing for the agent to inherit it *from*:
/// launchd starts the daemon from its own environment, and the channel is not
/// in it — the app reads its own off its bundle identifier. An unpinned agent
/// would therefore serve the release socket no matter which build installed it,
/// which is the collision this scoping exists to end.
pub fn plist(
    binary: &str,
    socket_override: Option<&str>,
    label: &str,
    channel: Option<&str>,
) -> String {
    let mut variables: Vec<(&str, &str)> = Vec::new();
    if let Some(channel) = channel {
        variables.push(("TERMIO_CHANNEL", channel));
    }
    if let Some(socket) = socket_override {
        variables.push(("TERMIOD_SOCK", socket));
    }
    let environment = if variables.is_empty() {
        String::new()
    } else {
        let body: String = variables
            .iter()
            .map(|(key, value)| {
                format!(
                    "        <key>{key}</key>\n        <string>{}</string>\n",
                    escape(value)
                )
            })
            .collect();
        format!("    <key>EnvironmentVariables</key>\n    <dict>\n{body}    </dict>\n")
    };
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{binary}</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
{environment}</dict>
</plist>
"#,
        label = escape(label),
        binary = escape(binary),
        environment = environment,
    )
}

/// The binary launchd should run. Resolved to an absolute path at install time
/// so the agent does not depend on a `PATH` it will not inherit.
fn resolved_binary() -> Result<String> {
    let binary = std::env::current_exe().context("resolving this binary's path")?;
    let binary = binary.canonicalize().unwrap_or(binary);
    Ok(binary.to_string_lossy().into_owned())
}

fn launchctl(args: &[&str]) -> Result<std::process::Output> {
    std::process::Command::new("launchctl")
        .args(args)
        .output()
        .context("running launchctl")
}

fn domain_target() -> String {
    format!("gui/{}", unsafe { libc::getuid() })
}

pub fn run(cmd: ServiceCmd) -> Result<()> {
    if !cfg!(target_os = "macos") {
        bail!(
            "`termiod service` manages a launchd agent and is macOS-only. \
             On Linux use a systemd --user unit with `loginctl enable-linger` \
             (without linger the daemon is killed at logout)."
        );
    }
    match cmd {
        ServiceCmd::Install => install(),
        ServiceCmd::Uninstall => uninstall(),
        ServiceCmd::Status => status(),
    }
}

fn install() -> Result<()> {
    let path = plist_path()?;
    std::fs::create_dir_all(path.parent().expect("plist path always has a parent"))
        .context("creating ~/Library/LaunchAgents")?;
    let socket_override = std::env::var("TERMIOD_SOCK").ok();
    let label = label();
    let suffix = paths::channel_suffix();
    let contents = plist(
        &resolved_binary()?,
        socket_override.as_deref(),
        &label,
        suffix.strip_prefix('-'),
    );
    std::fs::write(&path, contents).with_context(|| format!("writing {}", path.display()))?;

    // Replacing an existing agent: boot it out first, or `bootstrap` fails with
    // "service already loaded" and the user is left running the old binary while
    // the new plist sits on disk claiming otherwise.
    let target = format!("{}/{label}", domain_target());
    let _ = launchctl(&["bootout", &target]);
    let output = launchctl(&["bootstrap", &domain_target(), &path.to_string_lossy()])?;
    if !output.status.success() {
        bail!(
            "launchctl bootstrap failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    println!("installed {label} → {}", path.display());
    println!("termiod now starts at login and restarts if it crashes.");
    Ok(())
}

fn uninstall() -> Result<()> {
    let path = plist_path()?;
    let label = label();
    let booted_out = launchctl(&["bootout", &format!("{}/{label}", domain_target())])
        .map(|output| output.status.success())
        .unwrap_or(false);
    match std::fs::remove_file(&path) {
        Ok(()) => println!("removed {}", path.display()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            println!("{label} was not installed");
        }
        Err(error) => return Err(error).with_context(|| format!("removing {}", path.display())),
    }
    // Booting out the job stops the daemon launchd owns, which ends its
    // sessions — the old message claimed the opposite. But a daemon some client
    // autostarted is not launchd's to stop, and it keeps running, so the claim
    // is only true when there was a loaded job to boot out.
    if booted_out {
        println!("the daemon and its running sessions were stopped; it will not restart.");
    } else {
        println!("no supervised daemon was loaded; anything already running is untouched.");
    }
    Ok(())
}

fn status() -> Result<()> {
    let path = plist_path()?;
    println!(
        "plist:  {} ({})",
        path.display(),
        if path.exists() { "present" } else { "absent" }
    );
    println!("socket: {}", paths::socket_path()?.display());
    let output = launchctl(&["print", &format!("{}/{}", domain_target(), label())])?;
    if output.status.success() {
        let text = String::from_utf8_lossy(&output.stdout);
        let pid = text
            .lines()
            .find_map(|line| line.trim().strip_prefix("pid = "))
            .unwrap_or("not running");
        println!("agent:  loaded (pid {})", pid.trim());
    } else {
        println!("agent:  not loaded");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{plist, LABEL_BASE};

    /// The two keys that make this a *supervised* daemon rather than a one-shot
    /// launch: start at login, and come back after a crash.
    #[test]
    fn the_agent_starts_at_login_and_restarts_after_a_crash() {
        let text = plist("/usr/local/bin/termiod", None, LABEL_BASE, None);
        assert!(text.contains("<key>RunAtLoad</key>\n    <true/>"), "{text}");
        assert!(text.contains("<key>KeepAlive</key>\n    <true/>"), "{text}");
        assert!(text.contains(&format!("<string>{LABEL_BASE}</string>")));
        assert!(text.contains("<string>serve</string>"));
    }

    /// Pinning a socket the user never pinned would send the daemon and the app
    /// to different rendezvous points, so the key is simply absent.
    #[test]
    fn no_socket_is_pinned_unless_the_user_pinned_one() {
        assert!(!plist("/usr/local/bin/termiod", None, LABEL_BASE, None).contains("TERMIOD_SOCK"));

        let pinned = plist(
            "/usr/local/bin/termiod",
            Some("/tmp/custom/termiod.sock"),
            LABEL_BASE,
            None,
        );
        assert!(pinned.contains("<key>TERMIOD_SOCK</key>"), "{pinned}");
        assert!(pinned.contains("<string>/tmp/custom/termiod.sock</string>"));
    }

    /// The release channel is the absence of a channel, so its agent carries no
    /// `TERMIO_CHANNEL` and stays byte-identical to the one shipped before this
    /// scoping existed. A dev build's agent must differ on both axes at once —
    /// a distinct label, or the two jobs overwrite each other, *and* a pinned
    /// channel, or the job launchd starts serves the release socket.
    #[test]
    fn a_dev_agent_is_a_different_job_pinned_to_its_own_channel() {
        let release = plist("/usr/local/bin/termiod", None, LABEL_BASE, None);
        assert!(!release.contains("TERMIO_CHANNEL"), "{release}");

        let dev = plist(
            "/usr/local/bin/termiod",
            None,
            &format!("{LABEL_BASE}.dev"),
            Some("dev"),
        );
        assert!(dev.contains(&format!("<string>{LABEL_BASE}.dev</string>")), "{dev}");
        assert!(dev.contains("<key>TERMIO_CHANNEL</key>"), "{dev}");
        assert!(dev.contains("<string>dev</string>"), "{dev}");
    }

    /// Both environment keys land in one dict. Emitting a second
    /// `EnvironmentVariables` would make launchd read only the last.
    #[test]
    fn a_pinned_socket_and_channel_share_one_dict() {
        let text = plist(
            "/usr/local/bin/termiod",
            Some("/tmp/custom/termiod.sock"),
            &format!("{LABEL_BASE}.dev"),
            Some("dev"),
        );
        assert_eq!(text.matches("<key>EnvironmentVariables</key>").count(), 1, "{text}");
        assert!(text.contains("<key>TERMIO_CHANNEL</key>"), "{text}");
        assert!(text.contains("<key>TERMIOD_SOCK</key>"), "{text}");
    }

    /// A path with XML metacharacters must not be able to break the document —
    /// the plist is generated, and a malformed one fails to load with a message
    /// that explains nothing.
    #[test]
    fn paths_with_xml_metacharacters_stay_inside_their_element() {
        let text = plist("/opt/a&b/<termiod>", None, LABEL_BASE, None);
        assert!(text.contains("<string>/opt/a&amp;b/&lt;termiod&gt;</string>"), "{text}");
    }
}
