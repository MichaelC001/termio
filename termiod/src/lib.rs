//! Internal library for the `termiod` and `termio` binaries.
//!
//! This is not a public API: every module is exported so the two binaries in
//! `src/bin/` can share one implementation, and nothing here carries a
//! stability promise. Downstream code lives in this repository only.
//!
//! Dependency discipline (docker-lessons RFC §6): the runtime core — PTY
//! host, session lifecycle, framed protocol — must not import from the
//! planes (`files`, `git`, `resource`, `agent`). Planes may depend on the
//! core; the core compiles without them. If this ever needs teeth it becomes
//! a `termiod-core` crate boundary, the same move as `termiod-vt`.

pub mod agent;
pub mod client;
pub mod daemon;
pub mod files;
pub mod git;
pub mod handoff;
pub mod id;
pub mod keep_awake;
pub mod lifecycle;
pub mod log;
pub mod paths;
pub mod proc;
pub mod protocol;
pub mod pty;
pub mod remote;
pub mod resource;
pub mod service;
pub mod session;
pub mod tombstone;
pub mod wss;
