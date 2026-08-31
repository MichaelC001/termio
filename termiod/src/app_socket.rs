//! The Mac app's session-control socket, spoken the way `scripts/termio`
//! speaks it: one-line JSON requests over
//! `~/Library/Application Support/<channel dir>/session-control.sock`, with
//! the shell client's exact request shape, error taxonomy, and exit-code
//! semantics. This module exists so the Rust client can replace the script
//! wholesale at parity; verbs migrate off this socket onto the daemon's
//! framed protocol one at a time (unify-server-plane Stage 10), and each
//! migrated verb stops calling into here.

use crate::channel::Channel;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// How a one-shot request ended. `Timeout` is `--wait`'s "still running"
/// outcome, exit code 3 — distinct from success and from hard errors so
/// scripts can branch without parsing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Ok,
    Error,
    Timeout,
}

pub fn socket_path(channel: &Channel) -> PathBuf {
    let home = std::env::var_os("HOME").unwrap_or_default();
    PathBuf::from(home)
        .join("Library/Application Support")
        .join(&channel.support_dir_name)
        .join("session-control.sock")
}

/// The one-shot read bound in seconds: `TERMIO_CLI_TIMEOUT`, default 15.
pub fn client_timeout() -> u64 {
    std::env::var("TERMIO_CLI_TIMEOUT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(15)
}

/// Whether the caller set an explicit `TERMIO_CLI_TIMEOUT` — the escape
/// hatch that wins over the widened `--wait` read bound.
pub fn explicit_client_timeout() -> bool {
    std::env::var_os("TERMIO_CLI_TIMEOUT").is_some_and(|value| !value.is_empty())
}

/// JSON-escape a string for embedding in a request, byte-for-byte the shell
/// client's `json_escape`: backslashes, double quotes, tabs, and newlines.
/// ESC survives as a JSON `\u001b` escape — an escape sequence is exactly the kind of
/// keypress `send --no-enter` exists to deliver. Every other C0 byte
/// (carriage returns included) is stripped outright: they are never
/// intentional in a prompt, and one raw byte would make the whole request
/// undecodable.
pub fn json_escape(input: &str) -> String {
    let mut escaped = String::with_capacity(input.len());
    for character in input.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\t' => escaped.push_str("\\t"),
            '\u{1b}' => escaped.push_str("\\u001b"),
            '\n' => escaped.push_str("\\n"),
            '\u{00}'..='\u{1f}' => {}
            _ => escaped.push(character),
        }
    }
    escaped
}

/// Whether a token addresses a session rather than prompt text: a
/// `termio://` deep link, or a bare id (full UUID or an 8+ char hex
/// prefix). Deliberately permissive — an unknown address fails loudly as
/// `not_found` on the server, whereas an unrecognized one would silently
/// become the first words of a prompt to a freshly spawned agent.
pub fn is_address(token: &str) -> bool {
    if let Some(scheme_end) = token.find("://") {
        let scheme = &token[..scheme_end];
        let rest = &token[scheme_end + 3..];
        return scheme.starts_with("termio")
            && scheme[6..].chars().all(|c| c.is_ascii_lowercase() || c == '-')
            && !rest.is_empty()
            && !rest.contains(' ');
    }
    let bytes = token.as_bytes();
    if bytes.len() < 8 || bytes.len() > 36 {
        return false;
    }
    bytes[..8].iter().all(|byte| byte.is_ascii_hexdigit())
        && bytes[8..]
            .iter()
            .all(|byte| byte.is_ascii_hexdigit() || *byte == b'-')
}

/// The one-line JSON control request shared by the one-shot and streaming
/// paths, in the shell client's exact field order. `extra` is raw JSON
/// (`"key":value`) appended verbatim, for the rare per-verb field that
/// doesn't earn a slot in every request.
pub fn build_request(op: &str, format: &str, target: &str, agent: &str, text: &str, extra: &str) -> String {
    let caller_session = std::env::var("TERMIO_SESSION").unwrap_or_default();
    // $PWD the way a shell provides it: the inherited logical path when it
    // still names the current directory (sh validates this at startup), the
    // physical path otherwise.
    let physical = std::env::current_dir().ok();
    let caller_cwd = std::env::var("PWD")
        .ok()
        .filter(|value| !value.is_empty())
        .filter(|value| std::fs::canonicalize(value).ok() == physical)
        .or_else(|| physical.map(|directory| directory.display().to_string()))
        .unwrap_or_default();
    let mut request = format!(
        "{{\"op\":\"{op}\",\"format\":\"{format}\",\"caller_session\":\"{}\",\"caller_cwd\":\"{}\",\"target\":\"{}\",\"agent\":\"{}\",\"text\":\"{}\"",
        json_escape(&caller_session),
        json_escape(&caller_cwd),
        json_escape(target),
        json_escape(agent),
        json_escape(text),
    );
    if !extra.is_empty() {
        request.push(',');
        request.push_str(extra);
    }
    request.push('}');
    request
}

/// The shell client's pre-flight: `sessions` and `notify` refuse before
/// building a request when there is no control socket at all.
pub fn require_socket(channel: &Channel) -> PathBuf {
    let socket = socket_path(channel);
    let is_socket = std::fs::metadata(&socket)
        .map(|metadata| std::os::unix::fs::FileTypeExt::is_socket(&metadata.file_type()))
        .unwrap_or(false);
    if !is_socket {
        eprintln!(
            "termio: app is not running (no control socket at {})",
            socket.display()
        );
        std::process::exit(1);
    }
    socket
}

/// One request/response round-trip: prints the app's reply and reports the
/// outcome through the return value so callers surface it as an exit code —
/// agents check `$?`, not prose. An empty reply is a hard error, never a
/// silent success: a control CLI must fail loud.
pub fn request_once(
    channel: &Channel,
    timeout_seconds: u64,
    op: &str,
    format: &str,
    target: &str,
    agent: &str,
    text: &str,
    extra: &str,
) -> Outcome {
    let socket = socket_path(channel);
    let request = build_request(op, format, target, agent, text, extra);
    let response = exchange(&socket, &request, timeout_seconds);
    let response = match response {
        Ok(bytes) => bytes,
        Err(error) => {
            // A refused connect and a live-but-silent app are different
            // failures with different fixes: EPERM is a sandbox denying this
            // process, not a stale socket, and "restart termio" sends that
            // reader the wrong way.
            match error.kind() {
                std::io::ErrorKind::PermissionDenied => eprintln!(
                    "termio: the OS denied the connection to {} — this process is likely sandboxed (Codex workspace-write blocks unix sockets); termio itself is fine and restarting it will not help — run the command outside the sandbox",
                    socket.display()
                ),
                std::io::ErrorKind::NotFound => eprintln!(
                    "termio: no socket at {} — termio isn't running; start it first",
                    socket.display()
                ),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => eprintln!(
                    "termio: no reply from the app within {timeout_seconds}s — it may be busy or wedged; check the app, or raise TERMIO_CLI_TIMEOUT"
                ),
                _ => eprintln!(
                    "termio: nothing is listening at {} (connection refused) — the socket file outlived the app that made it; restart termio",
                    socket.display()
                ),
            }
            return Outcome::Error;
        }
    };
    let response = String::from_utf8_lossy(&response);
    let response = response.trim_end_matches('\n');
    if response.is_empty() {
        eprintln!(
            "termio: no reply from the app within {timeout_seconds}s — it may be busy or wedged; check the app, or raise TERMIO_CLI_TIMEOUT"
        );
        return Outcome::Error;
    }
    println!("{response}");
    if response.starts_with("error:") || response.contains("\"ok\":false") {
        return Outcome::Error;
    }
    // A --wait that expired is its own outcome, on its own exit code (3).
    // JSON mode keys off the contract field, text mode off the headline;
    // both checks are scoped to wait requests (never `read`, whose payload
    // is an arbitrary screen) so no other reply can trip them.
    if extra.contains("\"wait\":true") {
        if format == "json" {
            if response.contains("\"timed_out\":true") {
                return Outcome::Timeout;
            }
        } else if response.lines().next().unwrap_or("").contains("— timed out") {
            return Outcome::Timeout;
        }
    }
    Outcome::Ok
}

fn exchange(socket: &std::path::Path, request: &str, timeout_seconds: u64) -> std::io::Result<Vec<u8>> {
    let mut stream = UnixStream::connect(socket)?;
    let timeout = Duration::from_secs(timeout_seconds);
    // Both timeouts are armed before the request goes out, and never again:
    // once the app has replied and closed its end, macOS refuses setsockopt
    // on the socket (EINVAL) even though the reply is still readable — so a
    // per-read re-arm would turn every fast reply into a phantom failure.
    stream.set_write_timeout(Some(timeout))?;
    stream.set_read_timeout(Some(timeout))?;
    stream.write_all(request.as_bytes())?;
    let deadline = Instant::now() + timeout;
    let mut response = Vec::new();
    let mut buffer = [0u8; 16 * 1024];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                response.extend_from_slice(&buffer[..count]);
                if Instant::now() >= deadline {
                    break;
                }
            }
            Err(error)
                if error.kind() == std::io::ErrorKind::WouldBlock
                    || error.kind() == std::io::ErrorKind::TimedOut =>
            {
                if response.is_empty() {
                    return Err(std::io::ErrorKind::TimedOut.into());
                }
                break;
            }
            Err(error) => return Err(error),
        }
    }
    Ok(response)
}

/// Streaming: the app holds the connection open and pushes one line per
/// scoped status transition until interrupted. No read bound here — watch
/// is *supposed* to sit open, and its liveness signal is the app's 30s
/// heartbeat line in `--json` mode. Returns the exit code: an immediate
/// error reply is 1; the stream reaching EOF means the *app* closed it —
/// 2, "termio died", the case to escalate. Ctrl-C is handled by the caller
/// installing a handler that exits 0 (the normal end of supervision).
pub fn watch(channel: &Channel, format: &str, states: &str, extra: &str) -> i32 {
    let socket = socket_path(channel);
    let request = build_request("watch", format, "", "", states, extra);
    let mut stream = match UnixStream::connect(&socket) {
        Ok(stream) => stream,
        Err(_) => return 2,
    };
    if stream.write_all(request.as_bytes()).is_err() {
        return 2;
    }
    let reader = std::io::BufReader::new(stream);
    let mut first = true;
    use std::io::BufRead;
    for line in reader.lines() {
        let Ok(line) = line else { break };
        println!("{line}");
        use std::io::Write as _;
        let _ = std::io::stdout().flush();
        if first {
            first = false;
            if line.starts_with("error:") || line.contains("\"ok\":false") {
                return 1;
            }
        }
    }
    if first {
        // EOF before any line: still the app closing the stream.
        return 2;
    }
    2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escaping_matches_the_shell_clients_rules() {
        assert_eq!(json_escape(r#"a\b"c"#), r#"a\\b\"c"#);
        assert_eq!(json_escape("a\tb"), r"a\tb");
        assert_eq!(json_escape("a\nb"), r"a\nb");
        assert_eq!(json_escape("a\u{1b}[A"), r"a\u001b[A");
        // Other C0 bytes — carriage returns included — are stripped outright.
        assert_eq!(json_escape("a\rb\u{07}c"), "abc");
    }

    #[test]
    fn addresses_are_links_or_hex_ids() {
        assert!(is_address("termio://session/8de0b387-485a-4016-8990-cbcbfff03199"));
        assert!(is_address("termio-dev://session/x"));
        assert!(is_address("8de0b387"));
        assert!(is_address("8de0b387-485a-4016-8990-cbcbfff03199"));
        assert!(is_address("DEADBEEF"));
        assert!(!is_address("fix the build"));
        assert!(!is_address("deadbee"));
        assert!(!is_address("termio://has space"));
        assert!(!is_address("https://example.com"));
        assert!(!is_address("8de0b387-485a-4016-8990-cbcbfff03199-and-more-tail"));
    }

    #[test]
    fn requests_carry_the_shell_clients_field_order() {
        std::env::remove_var("TERMIO_SESSION");
        // A PWD that does not name the actual cwd is distrusted, sh-style,
        // so the physical directory is what lands in caller_cwd.
        std::env::set_var("PWD", "/tmp/not-the-cwd");
        let physical = std::env::current_dir().unwrap().display().to_string();
        let request = build_request("send", "json", "8de0b387", "", "hi", "\"enter\":false");
        assert_eq!(
            request,
            format!(
                "{{\"op\":\"send\",\"format\":\"json\",\"caller_session\":\"\",\"caller_cwd\":\"{}\",\"target\":\"8de0b387\",\"agent\":\"\",\"text\":\"hi\",\"enter\":false}}",
                json_escape(&physical)
            )
        );
    }
}
