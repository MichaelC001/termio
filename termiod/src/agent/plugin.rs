//! The generated plugin sources.
//!
//! OpenCode, Pi and Amp have no hook config to merge: each loads a single
//! dropped-in file and runs it in-process inside the PTY. So unlike every other
//! dialect the hook here is generated **source**, not a command string, and the
//! machine it is for reaches further into it than a swapped binary path.
//!
//! Three traps live in this file, and all three fail *silently*, because every
//! hook form ends in `2>/dev/null || true` or `.quiet().nothrow()`. They are
//! recorded in `docs/design/20260824-agent-integration-on-a-device.md`:
//!
//! 1. **The binary is interpolated by Bun's `$`, which escapes each hole into
//!    one argv token.** Handing it `$HOME/.local/bin/termiod` reaches the kernel
//!    as a directory literally named `$HOME`, exactly the way an over-quoted
//!    shell path does. The SSH arm worked around it by joining the path in
//!    JavaScript — `(process.env.HOME ?? "") + "/.local/bin/termiod"` — because
//!    the writer could not see the box. This daemon *is* on the box, so it
//!    interpolates its own resolved path and the question does not arise. See
//!    [`cli_declaration`].
//! 2. **The session id comes from the environment**, `TERMIOD_SESSION_ID`, which
//!    `session::daemon_owned_env` exports after the client's `env` so a client
//!    cannot spoof it. A plugin loaded *outside* a termiod session has no id, and
//!    must report nothing rather than call `set-status` with an empty one the
//!    daemon would reject.
//! 3. **A device drops the conversation plumbing.** `SetStatus` carries a state
//!    and a title and nothing else. That is one fact about the daemon, not three
//!    facts about three plugin APIs, so it is applied once, in
//!    [`super::install`], where the reporter is chosen.
//!
//! Pi needs no device branch of its own: it already shells out through
//! `pi.exec("sh", …)`, so its device form is whatever the shared report command
//! emits — the same string the JSON-manifest and script-directory dialects get.

use super::apple_json;
use super::install::{InstallRequest, StdinMining, SOCKET_MARKER};
use super::manifest::{HookDialect, HookEvent};

/// A JavaScript string literal.
///
/// Swift builds these with a plain `JSONSerialization.data(withJSONObject:)` and
/// no `withoutEscapingSlashes`, so a `/` comes out as `\/`. That is legal
/// JavaScript and means the same thing, and it is also what is on disk in every
/// plugin termio has already installed — so it is reproduced rather than
/// tidied, and the files do not churn when the writer changes hands.
fn js(value: &str) -> String {
    apple_json::string_literal(value, true)
}

/// Which file a dialect owns inside its plugin directory, and the name an
/// earlier build used. Publishing the new one and then sweeping the old is what
/// keeps a rename from leaving the agent loading two copies.
pub fn filenames(dialect: HookDialect) -> Option<(&'static str, &'static str)> {
    match dialect {
        HookDialect::OpenCodePlugin | HookDialect::PiPlugin => {
            Some(("termio.js", "termio-status.js"))
        }
        HookDialect::AmpPlugin => Some(("termio.ts", "termio-status.ts")),
        _ => None,
    }
}

/// The plugin source for a dialect, or `None` if it is not a plugin dialect.
pub fn source(
    dialect: HookDialect,
    events: &[HookEvent],
    conversation: Option<&str>,
    request: &InstallRequest,
) -> Option<String> {
    match dialect {
        HookDialect::OpenCodePlugin => Some(open_code_source(events, conversation, request)),
        HookDialect::PiPlugin => Some(pi_source(events, conversation, request)),
        HookDialect::AmpPlugin => Some(amp_source(events, request)),
        _ => None,
    }
}

/// `const cli = …`.
///
/// One spelling for both machines, because the daemon knows where its own
/// binary is on either. The SSH arm needed two — a JavaScript expression that
/// rebuilt `$HOME` at load time for a device, a literal for the Mac — and the
/// device half of that is a guess: `$HOME/.local/bin/termiod` is where the Mac
/// *assumes* the daemon was deployed. A box that keeps it anywhere else got a
/// plugin that exec'd a path with nothing at it, and said nothing.
fn cli_declaration(request: &InstallRequest) -> String {
    format!("const cli = {};", js(request.binary()))
}

/// The `const session = …` line a device plugin needs, or nothing on this Mac,
/// where the id rides in on `TERMIO_SESSION` and the CLI reads it itself.
fn session_declaration(request: &InstallRequest) -> &'static str {
    if request.is_local() {
        ""
    } else {
        "\n  const session = process.env.TERMIOD_SESSION_ID;"
    }
}

/// The body of a device plugin's `report`. A plugin loaded outside a termiod
/// session reports nothing rather than invoking `set-status` with an empty id.
fn daemon_report_body(shell: &str) -> String {
    format!(
        "    if (!session) return;\n    return {shell}`${{cli}} set-status ${{session}} ${{state}}`.quiet().nothrow();"
    )
}

/// OpenCode plugin: a session is `busy` while working and emits `session.idle`
/// when the turn ends; `permission.updated` means it is waiting on the user.
///
/// `conversation` (the manifest's `hooks.conversation`) is the dot key path in
/// the event object naming OpenCode's own conversation id; when set, each report
/// carries it so termio can follow an in-process new-session rotation. Subagent
/// child sessions share this event bus and adopting a child's id would mis-pin
/// the tab, so the plugin learns which ids are top-level from
/// `session.created`/`session.updated` — child sessions carry `parentID` — and
/// forwards only those.
fn open_code_source(
    events: &[HookEvent],
    conversation: Option<&str>,
    request: &InstallRequest,
) -> String {
    let conversation_expression = conversation.map(|path| {
        let mut expression = String::from("event");
        for component in path.split('.') {
            expression.push_str(&format!("?.{component}"));
        }
        expression
    });

    let branches = events
        .iter()
        .map(|event| {
            let arguments = match &conversation_expression {
                Some(expression) => format!("{}, {expression}", js(&event.state)),
                None => js(&event.state),
            };
            match &event.matcher {
                Some(matcher) => format!(
                    "      if (event.type === {} && event.properties?.status?.type === {}) return report({arguments});",
                    js(&event.name),
                    js(matcher)
                ),
                None => format!(
                    "      if (event.type === {}) return report({arguments});",
                    js(&event.name)
                ),
            }
        })
        .collect::<Vec<_>>()
        .join("\n");

    let identity = if conversation_expression.is_none() {
        String::new()
    } else {
        "\n  const roots = new Set();\n  const note = (info) => {\n    if (!info?.id) return;\n    \
         if (info.parentID) roots.delete(info.id); else roots.add(info.id);\n  };"
            .to_string()
    };
    let identity_branches = if conversation_expression.is_none() {
        String::new()
    } else {
        "      if (event.type === \"session.created\" || event.type === \"session.updated\") \
         return note(event.properties?.info);\n      if (event.type === \"session.deleted\") \
         return roots.delete(event.properties?.info?.id);\n"
            .to_string()
    };

    let report_body = if request.is_local() {
        if conversation_expression.is_none() {
            "    return $`${cli} agent report ${state}`.quiet().nothrow();".to_string()
        } else {
            "    if (conversation && roots.has(conversation)) {\n      \
             return $`${cli} agent report ${state} --conversation ${conversation}`.quiet().nothrow();\n    }\n    \
             return $`${cli} agent report ${state}`.quiet().nothrow();"
                .to_string()
        }
    } else {
        daemon_report_body("$")
    };
    let report_parameters = if conversation_expression.is_none() {
        "(state)"
    } else {
        "(state, conversation)"
    };

    format!(
        "// termio agent status — reports OpenCode session lifecycle to termio.\n\
         // Socket marker: {SOCKET_MARKER}\n\
         export const TermioStatus = async ({{ $ }}) => {{\n  \
         {}{}{identity}\n  \
         const report = {report_parameters} => {{\n\
         {report_body}\n  \
         }};\n  \
         return {{\n    \
         event: async ({{ event }}) => {{\n\
         {identity_branches}{branches}\n    \
         }},\n  \
         }};\n\
         }};",
        cli_declaration(request),
        session_declaration(request)
    )
}

/// Pi extension: `agent_start` fires when a turn begins, `agent_end` when it
/// returns to the user. Pi has no shell-hook config, so the extension itself
/// shells out via `pi.exec`.
///
/// `conversation == "context"` means Pi's own conversation id is read from the
/// extension context's session manager and forwarded with each report, so termio
/// can follow an in-process `/new` rotation. The id is embedded in a shell
/// command, so it is forwarded only when it looks like a bare token — Pi's
/// uuidv7 ids always do.
fn pi_source(events: &[HookEvent], conversation: Option<&str>, request: &InstallRequest) -> String {
    let header = format!(
        "// termio agent status — reports Pi turn lifecycle to termio.\n// Socket marker: {SOCKET_MARKER}\nexport default (pi) => {{\n"
    );
    if conversation.is_none() {
        // The one template that needs no device branch: it already goes through
        // a shell, so it takes the same command string every other dialect gets.
        let listeners = events
            .iter()
            .map(|event| {
                let command = super::install::report_command(
                    &event.state,
                    &StdinMining::default(),
                    HookDialect::ClaudeNested,
                    request,
                );
                format!(
                    "  pi.on({}, () => pi.exec(\"sh\", [\"-c\", {}]));",
                    js(&event.name),
                    js(&command)
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        return format!("{header}{listeners}\n}};");
    }

    let listeners = events
        .iter()
        .map(|event| {
            format!(
                "  pi.on({}, (_event, context) => report({}, context));",
                js(&event.name),
                js(&event.state)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "{header}  const cli = {};\n  \
         const report = (state, context) => {{\n    \
         const id = context?.sessionManager?.getSessionId?.();\n    \
         const conversation = id && /^[A-Za-z0-9._-]+$/.test(id) ? ` --conversation ${{id}}` : \"\";\n    \
         pi.exec(\"sh\", [\"-c\", `${{cli}} agent report ${{state}}${{conversation}} 2>/dev/null || true`]);\n  \
         }};\n{listeners}\n}};",
        js(&super::install::shell_quote_path(request.binary()))
    )
}

/// Amp plugin: `agent.start` fires when the user submits a prompt, `agent.end`
/// when the agent finishes handling it. Amp auto-loads any plugin under its
/// plugins directory, runs on Bun, and exposes Bun's `$` as `amp.$`.
fn amp_source(events: &[HookEvent], request: &InstallRequest) -> String {
    let listeners = events
        .iter()
        .map(|event| {
            format!(
                "  amp.on({}, () => report({}));",
                js(&event.name),
                js(&event.state)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let report_body = if request.is_local() {
        "    return amp.$`${cli} agent report ${state}`.quiet().nothrow();".to_string()
    } else {
        daemon_report_body("amp.$")
    };
    format!(
        "// termio agent status — reports Amp turn lifecycle to termio.\n\
         // Socket marker: {SOCKET_MARKER}\n\
         export default (amp) => {{\n  \
         {}{}\n  \
         const report = (state) => {{\n\
         {report_body}\n  \
         }};\n\
         {listeners}\n\
         }};",
        cli_declaration(request),
        session_declaration(request)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::install::tests::{device_request, local_request, spec_of};

    fn opencode() -> (Vec<HookEvent>, Option<String>) {
        let spec = spec_of(
            r#"{"id":"opencode","name":"OpenCode","hooks":{"type":"plugin",
                "dir":"~/.config/opencode/plugin","dialect":"opencode",
                "conversation":"properties.sessionID","events":[
                  {"on":"session.status","state":"working","matcher":"busy"},
                  {"on":"session.idle","state":"done"},
                  {"on":"permission.updated","state":"attention"}]}}"#,
        );
        (spec.events.clone(), spec.conversation.clone())
    }

    /// The exact bytes the Swift SSH arm wrote to `ukvps`, with only the binary
    /// resolved — the deliberate correction, recorded in the module docs. If
    /// this drifts, so does every OpenCode plugin already on a user's box.
    #[test]
    fn the_opencode_device_plugin_matches_the_swift_arm() {
        let (events, _) = opencode();
        // A device drops the conversation plumbing: `set-status` has no field
        // for it.
        let source = source(
            HookDialect::OpenCodePlugin,
            &events,
            None,
            &device_request("/home/ubuntu/.local/bin/termiod"),
        )
        .expect("a plugin dialect");
        assert_eq!(
            source,
            r#"// termio agent status — reports OpenCode session lifecycle to termio.
// Socket marker: agent-status.sock
export const TermioStatus = async ({ $ }) => {
  const cli = "\/home\/ubuntu\/.local\/bin\/termiod";
  const session = process.env.TERMIOD_SESSION_ID;
  const report = (state) => {
    if (!session) return;
    return $`${cli} set-status ${session} ${state}`.quiet().nothrow();
  };
  return {
    event: async ({ event }) => {
      if (event.type === "session.status" && event.properties?.status?.type === "busy") return report("working");
      if (event.type === "session.idle") return report("done");
      if (event.type === "permission.updated") return report("attention");
    },
  };
};"#
        );
    }

    /// Captured the same way as the device form: by pointing the Swift SSH arm
    /// at a box with the *local* reporter. Hand-deriving this one is what put a
    /// stray blank line in the first cut of the generator, with a test that
    /// agreed with it.
    #[test]
    fn the_opencode_mac_plugin_keeps_the_conversation_plumbing() {
        let (events, conversation) = opencode();
        let source = source(
            HookDialect::OpenCodePlugin,
            &events,
            conversation.as_deref(),
            &local_request("/Users/x/termio"),
        )
        .expect("a plugin dialect");
        assert_eq!(
            source,
            r#"// termio agent status — reports OpenCode session lifecycle to termio.
// Socket marker: agent-status.sock
export const TermioStatus = async ({ $ }) => {
  const cli = "\/Users\/x\/termio";
  const roots = new Set();
  const note = (info) => {
    if (!info?.id) return;
    if (info.parentID) roots.delete(info.id); else roots.add(info.id);
  };
  const report = (state, conversation) => {
    if (conversation && roots.has(conversation)) {
      return $`${cli} agent report ${state} --conversation ${conversation}`.quiet().nothrow();
    }
    return $`${cli} agent report ${state}`.quiet().nothrow();
  };
  return {
    event: async ({ event }) => {
      if (event.type === "session.created" || event.type === "session.updated") return note(event.properties?.info);
      if (event.type === "session.deleted") return roots.delete(event.properties?.info?.id);
      if (event.type === "session.status" && event.properties?.status?.type === "busy") return report("working", event?.properties?.sessionID);
      if (event.type === "session.idle") return report("done", event?.properties?.sessionID);
      if (event.type === "permission.updated") return report("attention", event?.properties?.sessionID);
    },
  };
};"#
        );
    }

    /// A plugin loaded outside a termiod session has no id, and reporting an
    /// empty one is a call the daemon rejects — silently, because the whole form
    /// is `.quiet().nothrow()`.
    #[test]
    fn a_device_plugin_outside_a_session_reports_nothing() {
        for dialect in [HookDialect::OpenCodePlugin, HookDialect::AmpPlugin] {
            let (events, _) = opencode();
            let source = source(dialect, &events, None, &device_request("/x/termiod"))
                .expect("a plugin dialect");
            assert!(source.contains("const session = process.env.TERMIOD_SESSION_ID;"));
            assert!(source.contains("if (!session) return;"));
        }
    }

    #[test]
    fn the_amp_device_plugin_matches_the_swift_arm() {
        let spec = spec_of(
            r#"{"id":"amp","name":"Amp","hooks":{"type":"plugin","dir":"~/.config/amp/plugins",
                "dialect":"amp","events":[{"on":"agent.start","state":"working"},
                {"on":"agent.end","state":"done"}]}}"#,
        );
        let source = source(
            HookDialect::AmpPlugin,
            &spec.events,
            None,
            &device_request("/home/ubuntu/.local/bin/termiod"),
        )
        .expect("a plugin dialect");
        assert_eq!(
            source,
            r#"// termio agent status — reports Amp turn lifecycle to termio.
// Socket marker: agent-status.sock
export default (amp) => {
  const cli = "\/home\/ubuntu\/.local\/bin\/termiod";
  const session = process.env.TERMIOD_SESSION_ID;
  const report = (state) => {
    if (!session) return;
    return amp.$`${cli} set-status ${session} ${state}`.quiet().nothrow();
  };
  amp.on("agent.start", () => report("working"));
  amp.on("agent.end", () => report("done"));
};"#
        );
    }

    #[test]
    fn the_amp_mac_plugin_reports_through_the_cli() {
        let spec = spec_of(
            r#"{"id":"amp","name":"Amp","hooks":{"type":"plugin","dir":"~/.config/amp/plugins",
                "dialect":"amp","events":[{"on":"agent.start","state":"working"},
                {"on":"agent.end","state":"done"}]}}"#,
        );
        let source = source(
            HookDialect::AmpPlugin,
            &spec.events,
            None,
            &local_request("/Users/x/termio"),
        )
        .expect("a plugin dialect");
        assert_eq!(
            source,
            r#"// termio agent status — reports Amp turn lifecycle to termio.
// Socket marker: agent-status.sock
export default (amp) => {
  const cli = "\/Users\/x\/termio";
  const report = (state) => {
    return amp.$`${cli} agent report ${state}`.quiet().nothrow();
  };
  amp.on("agent.start", () => report("working"));
  amp.on("agent.end", () => report("done"));
};"#
        );
    }

    fn pi_spec() -> crate::agent::manifest::HookSpec {
        spec_of(
            r#"{"id":"pi","name":"Pi","hooks":{"type":"plugin","dir":"~/.pi/agent/extensions",
                "dialect":"pi","conversation":"context","events":[
                  {"on":"session_start","state":"idle"},
                  {"on":"agent_start","state":"working"},
                  {"on":"agent_end","state":"done"}]}}"#,
        )
    }

    /// Pi takes the shared command string on a device, so its device form has no
    /// template of its own to keep in step.
    #[test]
    fn the_pi_device_plugin_matches_the_swift_arm() {
        let mut request = device_request("/home/ubuntu/.local/bin/termiod");
        request.hook_version = "16.0".into();
        let source = source(HookDialect::PiPlugin, &pi_spec().events, None, &request)
            .expect("a plugin dialect");
        assert_eq!(
            source,
            r#"// termio agent status — reports Pi turn lifecycle to termio.
// Socket marker: agent-status.sock
export default (pi) => {
  pi.on("session_start", () => pi.exec("sh", ["-c", "'\/home\/ubuntu\/.local\/bin\/termiod' set-status \"$TERMIOD_SESSION_ID\" idle 2>\/dev\/null || true # termio-hooks v16.0"]));
  pi.on("agent_start", () => pi.exec("sh", ["-c", "'\/home\/ubuntu\/.local\/bin\/termiod' set-status \"$TERMIOD_SESSION_ID\" working 2>\/dev\/null || true # termio-hooks v16.0"]));
  pi.on("agent_end", () => pi.exec("sh", ["-c", "'\/home\/ubuntu\/.local\/bin\/termiod' set-status \"$TERMIOD_SESSION_ID\" done 2>\/dev\/null || true # termio-hooks v16.0"]));
};"#
        );
    }

    #[test]
    fn the_pi_mac_plugin_reads_its_id_from_the_extension_context() {
        let spec = pi_spec();
        let source = source(
            HookDialect::PiPlugin,
            &spec.events,
            spec.conversation.as_deref(),
            &local_request("/Users/x/termio"),
        )
        .expect("a plugin dialect");
        assert_eq!(
            source,
            r#"// termio agent status — reports Pi turn lifecycle to termio.
// Socket marker: agent-status.sock
export default (pi) => {
  const cli = "'\/Users\/x\/termio'";
  const report = (state, context) => {
    const id = context?.sessionManager?.getSessionId?.();
    const conversation = id && /^[A-Za-z0-9._-]+$/.test(id) ? ` --conversation ${id}` : "";
    pi.exec("sh", ["-c", `${cli} agent report ${state}${conversation} 2>/dev/null || true`]);
  };
  pi.on("session_start", (_event, context) => report("idle", context));
  pi.on("agent_start", (_event, context) => report("working", context));
  pi.on("agent_end", (_event, context) => report("done", context));
};"#
        );
    }

    /// Every generated plugin carries the comment the installer recognizes it
    /// by. Without it an install cannot tell its own file from a user's, so it
    /// would either refuse to replace its own work or claim someone else's.
    #[test]
    fn every_generated_plugin_is_recognizable_as_ours() {
        let (events, conversation) = opencode();
        for dialect in [
            HookDialect::OpenCodePlugin,
            HookDialect::PiPlugin,
            HookDialect::AmpPlugin,
        ] {
            for request in [local_request("/x/termio"), device_request("/x/termiod")] {
                let source = source(dialect, &events, conversation.as_deref(), &request)
                    .expect("a plugin dialect");
                assert!(
                    source.contains(&format!("// Socket marker: {SOCKET_MARKER}")),
                    "{dialect:?} lost its ownership marker"
                );
            }
        }
    }
}
