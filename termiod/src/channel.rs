//! Which channel the `termio` client drives, resolved from its own name.
//!
//! The shell client carried three build-time rewritten variables
//! (`SUPPORT_DIR_NAME`, `BUNDLE_ID`, `VERSION`); this derives the same
//! bindings from argv[0] instead: the dev bundle installs the binary as
//! `termio-dev`, which selects the `.dev` bundle id, the `termio-dev`
//! support directory, and the dev daemon socket. One binary, no sed.
//!
//! An inherited `TERMIO_CHANNEL` is deliberately not consulted: the shell
//! client pinned `TERMIO_CHANNEL="$CHANNEL"` on every daemon exec so a stale
//! value could not cross channels, and this keeps that rule. The one runtime
//! override is `TERMIOD_SOCK`, which pins the daemon socket outright
//! (`paths::socket_path` honors it first) — that is how a hook firing inside
//! a channel-pinned session reaches the daemon that owns it. `termio
//! version` prints which of the two answered, so a surprising socket names
//! its own cause.

/// The bindings the shell client's three rewritten variables carried.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Channel {
    /// `release`, `dev`, or a custom probe channel name.
    pub name: String,
    /// The Mac app this client drives (`open -b`, `lsappinfo`).
    pub bundle_id: String,
    /// Directory name under `~/Library/Application Support` holding the
    /// app's control socket, support copies, and device registry.
    pub support_dir_name: String,
}

/// Which rung decided where the daemon socket is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provenance {
    /// `TERMIOD_SOCK` names the socket directly.
    ExplicitSocket,
    /// Derived from the binary's own name (`termio` / `termio-<channel>`).
    ProgramName,
}

impl Channel {
    fn release() -> Channel {
        Channel {
            name: "release".to_string(),
            bundle_id: "sh.termio.app".to_string(),
            support_dir_name: "termio".to_string(),
        }
    }

    /// Same validation rule as `paths::channel_suffix`: a channel name is a
    /// path component, so anything that isn't lowercase alphanumeric-or-dash
    /// falls back to the release channel instead of opening a stray
    /// directory.
    fn named(candidate: &str) -> Channel {
        let name = candidate.trim().to_lowercase();
        if name.is_empty() || name == "release" {
            return Channel::release();
        }
        if !name
            .chars()
            .all(|character| character.is_alphanumeric() || character == '-')
        {
            return Channel::release();
        }
        Channel {
            bundle_id: format!("sh.termio.app.{name}"),
            support_dir_name: format!("termio-{name}"),
            name,
        }
    }

    /// `termio` → release; `termio-dev` → dev; `termio-<name>` → `<name>`;
    /// anything else → release. Takes the bare program name, not a path.
    pub fn from_program_name(program: &str) -> Channel {
        match program.strip_prefix("termio-") {
            Some(rest) => Channel::named(rest),
            None => Channel::release(),
        }
    }
}

fn program_name() -> String {
    std::env::args()
        .next()
        .as_deref()
        .map(std::path::Path::new)
        .and_then(|path| path.file_name())
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "termio".to_string())
}

fn explicit_socket() -> bool {
    std::env::var_os("TERMIOD_SOCK").is_some_and(|value| !value.is_empty())
}

/// Resolve the channel and pin it for everything downstream: sets
/// `TERMIO_CHANNEL` in this process's environment so `paths::*` and every
/// exec'd daemon derive the same socket, overwriting any inherited value —
/// the same pin the shell client applied on every daemon exec.
pub fn resolve() -> (Channel, Provenance) {
    let channel = Channel::from_program_name(&program_name());
    std::env::set_var("TERMIO_CHANNEL", &channel.name);
    let provenance = if explicit_socket() {
        Provenance::ExplicitSocket
    } else {
        Provenance::ProgramName
    };
    (channel, provenance)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plain_name_is_the_release_channel() {
        let channel = Channel::from_program_name("termio");
        assert_eq!(channel.name, "release");
        assert_eq!(channel.bundle_id, "sh.termio.app");
        assert_eq!(channel.support_dir_name, "termio");
    }

    #[test]
    fn a_dev_suffix_selects_the_dev_bundle_and_support_dir() {
        let channel = Channel::from_program_name("termio-dev");
        assert_eq!(channel.name, "dev");
        assert_eq!(channel.bundle_id, "sh.termio.app.dev");
        assert_eq!(channel.support_dir_name, "termio-dev");
    }

    #[test]
    fn a_custom_suffix_is_its_own_probe_channel() {
        let channel = Channel::from_program_name("termio-smoke2");
        assert_eq!(channel.name, "smoke2");
        assert_eq!(channel.support_dir_name, "termio-smoke2");
    }

    #[test]
    fn an_explicit_release_suffix_collapses_to_release() {
        assert_eq!(Channel::from_program_name("termio-release"), Channel::release());
    }

    #[test]
    fn an_invalid_suffix_falls_back_to_release_like_paths_does() {
        assert_eq!(Channel::from_program_name("termio-../evil"), Channel::release());
        assert_eq!(Channel::from_program_name("termio-a_b"), Channel::release());
    }

    #[test]
    fn an_unrelated_program_name_is_release() {
        assert_eq!(Channel::from_program_name("termiofoo"), Channel::release());
        assert_eq!(Channel::from_program_name("cargo"), Channel::release());
    }
}
