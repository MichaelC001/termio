//! `termio version` — every version in one table: this client, the running
//! app, the local termiod, and one row per known remote from the device
//! registry the app writes at each handshake (`devices.json`). A remote row
//! is what the last connect observed, stamped so a stale row announces its
//! staleness instead of posing as live state; a host this Mac has never
//! spoken to is absent, and nothing here touches the network.
//!
//! Ported from the shell client's `version_table()`, with two deliberate
//! deviations: the local daemon rows come from `lifecycle::status()`
//! in-process instead of awk over pretty-printed JSON, and a final line
//! names the resolved socket and which rung chose it (`TERMIOD_SOCK` or the
//! program name), so a surprising socket names its own cause.

use crate::channel::{Channel, Provenance};
use crate::{lifecycle, paths};
use anyhow::Result;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn row(name: &str, version: &str, proto: &str, note: &str) {
    let line = format!("{name:<14} {version:<22} {proto:<9} {note}");
    println!("{}", line.trim_end());
}

pub async fn print_table(channel: &Channel, provenance: Provenance) -> Result<()> {
    row(
        "termio",
        lifecycle::BUILD_VERSION,
        "",
        &format!("(client, {} channel)", channel.name),
    );

    match running_app_version(&channel.bundle_id) {
        Some(version) => row("termio.app", &version, "", "(running)"),
        None => row("termio.app", "-", "", "(not running)"),
    }

    match lifecycle::status().await {
        Ok(status) if status.daemon.running => {
            let version = status.daemon.version.unwrap_or(status.binary.version);
            let proto = status
                .daemon
                .proto
                .map(|proto| format!("proto {proto}"))
                .unwrap_or_default();
            row("termiod local", &version, &proto, "");
        }
        // This binary and the daemon build from one crate, so its own stamp
        // is the installed daemon's version — the shell client had to locate
        // and exec the daemon binary to learn the same thing.
        Ok(status) => row(
            "termiod local",
            &status.binary.version,
            "",
            "(binary; daemon not running)",
        ),
        Err(_) => row("termiod local", "-", "", "(no answer)"),
    }

    for remote in remote_rows(&channel.support_dir_name) {
        row(&remote.alias, &remote.version, &remote.proto, &remote.stamp);
    }

    if let Ok(socket) = paths::socket_path() {
        let why = match provenance {
            Provenance::ExplicitSocket => "via TERMIOD_SOCK",
            Provenance::ProgramName => "via program name",
        };
        println!();
        println!("socket {} ({why})", socket.display());
    }
    Ok(())
}

/// The running app's `CFBundleShortVersionString+CFBundleVersion`, through
/// `lsappinfo` so only a live process answers — a stale bundle on disk never
/// poses as running. macOS only; anywhere else there is no app.
fn running_app_version(bundle_id: &str) -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let info = Command::new("lsappinfo")
        .args(["info", "-only", "bundlepath", bundle_id])
        .output()
        .ok()?;
    let stdout = String::from_utf8_lossy(&info.stdout);
    let bundle = stdout
        .lines()
        .find_map(|line| line.strip_prefix("\"LSBundlePath\"=\""))
        .and_then(|rest| rest.strip_suffix('"'))?;
    let plist = format!("{bundle}/Contents/Info.plist");
    let read = |key: &str| -> Option<String> {
        let output = Command::new("/usr/libexec/PlistBuddy")
            .args(["-c", &format!("Print :{key}"), &plist])
            .output()
            .ok()?;
        output
            .status
            .success()
            .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
            .filter(|value| !value.is_empty())
    };
    let version = read("CFBundleShortVersionString").unwrap_or_else(|| "?".to_string());
    match read("CFBundleVersion") {
        Some(build) => Some(format!("{version}+{build}")),
        None => Some(version),
    }
}

struct RemoteRow {
    alias: String,
    version: String,
    proto: String,
    stamp: String,
}

/// One record per device that has been reached over SSH, labeled by its most
/// recently used alias. Devices only ever seen locally are the local row.
fn remote_rows(support_dir_name: &str) -> Vec<RemoteRow> {
    let Some(home) = std::env::var_os("HOME") else {
        return Vec::new();
    };
    let path = std::path::Path::new(&home)
        .join("Library/Application Support")
        .join(support_dir_name)
        .join("devices.json");
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let Ok(devices) = serde_json::from_str::<Vec<serde_json::Value>>(&raw) else {
        return Vec::new();
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or(0);
    devices
        .iter()
        .filter_map(|device| {
            let alias = device
                .get("routes")?
                .as_array()?
                .iter()
                .filter_map(|route| route.as_str())
                .find_map(|route| route.strip_prefix("ssh:"))?;
            let version = device
                .get("daemonVersion")
                .and_then(|value| value.as_str())
                .unwrap_or("-");
            let proto = device
                .get("proto")
                .and_then(|value| value.as_u64())
                .map(|proto| format!("proto {proto}"))
                .unwrap_or_default();
            let stamp = device
                .get("observedAt")
                .and_then(|value| value.as_str())
                .and_then(parse_utc_timestamp)
                .map(|observed| {
                    format!("(as of last connect, {})", age(now.saturating_sub(observed)))
                })
                .unwrap_or_else(|| "(as of an earlier connect)".to_string());
            Some(RemoteRow {
                alias: alias.to_string(),
                version: version.to_string(),
                proto,
                stamp,
            })
        })
        .collect()
}

fn age(seconds: i64) -> String {
    let seconds = seconds.max(0);
    if seconds < 60 {
        "just now".to_string()
    } else if seconds < 3600 {
        format!("{}m ago", seconds / 60)
    } else if seconds < 86400 {
        format!("{}h ago", seconds / 3600)
    } else {
        format!("{}d ago", seconds / 86400)
    }
}

/// `2026-08-31T12:34:56Z` → Unix seconds. The registry writes exactly this
/// shape; anything else reads as "an earlier connect" rather than guessing.
fn parse_utc_timestamp(stamp: &str) -> Option<i64> {
    let bytes = stamp.as_bytes();
    if bytes.len() != 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' {
        return None;
    }
    if bytes[13] != b':' || bytes[16] != b':' || bytes[19] != b'Z' {
        return None;
    }
    let number = |range: std::ops::Range<usize>| stamp.get(range)?.parse::<i64>().ok();
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    if !(0..24).contains(&hour) || !(0..60).contains(&minute) || !(0..60).contains(&second) {
        return None;
    }
    // Days-from-civil (Howard Hinnant's algorithm), avoiding a time crate for
    // one fixed-format field.
    let year_adjusted = if month <= 2 { year - 1 } else { year };
    let era = year_adjusted.div_euclid(400);
    let year_of_era = year_adjusted - era * 400;
    let month_shifted = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * month_shifted + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_registry_timestamp_shape_parses_to_unix_seconds() {
        assert_eq!(parse_utc_timestamp("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_utc_timestamp("2026-08-31T00:00:00Z"), Some(1_788_134_400));
    }

    #[test]
    fn anything_else_reads_as_an_earlier_connect() {
        assert_eq!(parse_utc_timestamp(""), None);
        assert_eq!(parse_utc_timestamp("2026-08-31 00:00:00"), None);
        assert_eq!(parse_utc_timestamp("2026-08-31T00:00:00.123Z"), None);
        assert_eq!(parse_utc_timestamp("2026-13-01T00:00:00Z"), None);
    }

    #[test]
    fn ages_bucket_like_the_shell_client() {
        assert_eq!(age(0), "just now");
        assert_eq!(age(59), "just now");
        assert_eq!(age(60), "1m ago");
        assert_eq!(age(3_599), "59m ago");
        assert_eq!(age(3_600), "1h ago");
        assert_eq!(age(86_400 * 3 + 5), "3d ago");
        assert_eq!(age(-5), "just now");
    }
}
