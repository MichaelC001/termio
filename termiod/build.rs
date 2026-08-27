//! Stamps the build version into the binary as `TERMIOD_VERSION`.
//!
//! The crate version in `Cargo.toml` never moves with the app's releases, so
//! comparing it would call every daemon current. The app is stamped from
//! `TERMIO_VERSION` and `TERMIO_BUILD` (`scripts/build-app.sh`, set by the
//! release workflow from the tag), and the daemon takes the same two so the
//! version a daemon reports is the version of the app that shipped it:
//! `0.44.0+1533`. The build number is what orders two dev builds of one
//! version, and it is also the fallback when there is no tag — a checkout
//! reports `0.0.0+<commit count>`, which compares older than any release
//! (a dev build never stages itself over a released daemon) but still
//! advances between two dev builds.

use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=TERMIO_VERSION");
    println!("cargo:rerun-if-env-changed=TERMIO_BUILD");

    let version = std::env::var("TERMIO_VERSION")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "0.0.0".to_string());
    let build = std::env::var("TERMIO_BUILD")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(commit_count)
        .unwrap_or_else(|| "0".to_string());
    println!("cargo:rustc-env=TERMIOD_VERSION={version}+{build}");
}

/// `git rev-list --count HEAD`, the same number the release workflow stamps as
/// the app's build number. `None` outside a checkout, or without git.
fn commit_count() -> Option<String> {
    let output = Command::new("git")
        .args(["rev-list", "--count", "HEAD"])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let count = String::from_utf8(output.stdout).ok()?;
    let count = count.trim();
    count.parse::<u64>().ok().map(|_| count.to_string())
}
