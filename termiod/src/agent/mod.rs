//! Agent integration — the manifest schema, and the installers that write it
//! into the agent config files on this box.
//!
//! The machine that owns the files decides what goes in them. Before this the
//! plan lived in Swift and the filesystem lived here, so a twelve-agent install
//! was forty to sixty sequential `ssh` round trips and neither the phone nor a
//! browser could install at all. See
//! `docs/design/20260825-agent-integration-moves-to-termiod.md`.
//!
//! - [`manifest`] is the schema: the same JSON the Mac app reads, from the same
//!   bundled files plus the user's own `~/.termio/config/agents`. A fixture test
//!   parses every manifest in both languages and asserts the same values, because
//!   a manifest the two disagree about is a bug the user experiences as "my agent
//!   shows up in the list but never gets hooks", and it is silent.
//! - [`machine`] is what the daemon knows about its own box that a remote writer
//!   had to ask for: `$HOME`, the XDG bases, the login-shell `PATH`.

#[cfg(test)]
mod fixture;
pub mod machine;
pub mod manifest;
