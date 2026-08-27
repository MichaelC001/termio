//! The generated plugin sources.
//!
//! OpenCode, Pi and Amp have no hook config to merge: each loads a single
//! dropped-in file and runs it in-process inside the PTY. So unlike every other
//! dialect the hook here is generated **source**, not a command string, and the
//! machine it is for reaches further into it than a swapped binary path.
//!
//! Two traps live here, and both fail *silently*, because every hook form ends
//! in `2>/dev/null || true` or `.quiet().nothrow()`. See
//! `docs/design/20260824-agent-integration-on-a-device.md`:
//!
//! 1. **Bun's `$` escapes each hole into one argv token**, so a path containing
//!    `$HOME` reaches the kernel as a directory literally named `$HOME`. This
//!    daemon runs on the box, so it interpolates its own resolved path and the
//!    question does not arise. See [`cli_declaration`].
//! 2. **The session id comes from `TERMIOD_SESSION_ID`**, which
//!    `session::daemon_owned_env` exports after the client's `env` so a client
//!    cannot spoof it. A plugin loaded outside a termiod session has no id and
//!    must report nothing rather than send an empty one.
//!
//! Pi needs no branch of its own: it shells out through `pi.exec("sh", …)`, so
//! it emits the same command the other dialects get.

use super::apple_json;
use super::install::{InstallRequest, StdinMining, SOCKET_MARKER};
use super::manifest::{HookDialect, HookEvent};

/// A JavaScript string literal, with `/` escaped as `\/`. Legal JavaScript, and
/// what Swift's `JSONSerialization` put on disk in every plugin termio already
/// installed — reproduced rather than tidied so the files do not churn now that
/// the writer has changed hands.
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

/// The `const session = …` line every plugin needs.
///
/// Not a machine branch any more. Both used to exist: a Mac plugin left this out
/// and let the `termio` CLI read `TERMIO_SESSION` for itself, a device plugin
/// read `TERMIOD_SESSION_ID`. One report path means one id, and it is the
/// daemon's — exported by `session::daemon_owned_env` after the client's `env`,
/// so a client cannot spoof it.
fn session_declaration() -> &'static str {
    "\n  const session = process.env.TERMIOD_SESSION_ID;"
}

/// The body of a plugin's `report`. A plugin loaded outside a termiod session
/// reports nothing rather than invoking `set-status` with an empty id the daemon
/// would reject.
///
/// `conversation`, when the manifest declared a locator, rides along — on both
/// machines now. Bun's `$` escapes each interpolation into one argv token, so
/// the id needs no quoting of its own.
fn daemon_report_body(shell: &str, carries_conversation: bool) -> String {
    let mut body = String::from("    if (!session) return;\n");
    if carries_conversation {
        body.push_str(&format!(
            "    if (conversation && roots.has(conversation)) {{\n      \
             return {shell}`${{cli}} set-status ${{session}} ${{state}} --conversation ${{conversation}}`.quiet().nothrow();\n    }}\n"
        ));
    }
    body.push_str(&format!(
        "    return {shell}`${{cli}} set-status ${{session}} ${{state}}`.quiet().nothrow();"
    ));
    body
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

    let report_body = daemon_report_body("$", conversation_expression.is_some());
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
        session_declaration()
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
         const session = process.env.TERMIOD_SESSION_ID;\n  \
         const report = (state, context) => {{\n    \
         if (!session) return;\n    \
         const id = context?.sessionManager?.getSessionId?.();\n    \
         const conversation = id && /^[A-Za-z0-9._-]+$/.test(id) ? ` --conversation ${{id}}` : \"\";\n    \
         pi.exec(\"sh\", [\"-c\", `${{cli}} set-status \"$TERMIOD_SESSION_ID\" ${{state}}${{conversation}} 2>/dev/null || true`]);\n  \
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
    let report_body = daemon_report_body("amp.$", false);
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
        session_declaration()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::install::tests::{device_request, local_request, spec_of};

    fn opencode_spec() -> crate::agent::manifest::HookSpec {
        spec_of(
            r#"{"id":"opencode","name":"OpenCode","hooks":{"type":"plugin",
                "dir":"~/.config/opencode/plugin","dialect":"opencode",
                "conversation":"properties.sessionID","events":[
                  {"on":"session.status","state":"working","matcher":"busy"},
                  {"on":"session.idle","state":"done"},
                  {"on":"permission.updated","state":"attention"}]}}"#,
        )
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

    fn amp_spec() -> crate::agent::manifest::HookSpec {
        spec_of(
            r#"{"id":"amp","name":"Amp","hooks":{"type":"plugin","dir":"~/.config/amp/plugins",
                "dialect":"amp","events":[{"on":"agent.start","state":"working"},
                {"on":"agent.end","state":"done"}]}}"#,
        )
    }

    fn rendered(
        dialect: HookDialect,
        spec: &crate::agent::manifest::HookSpec,
        request: &InstallRequest,
    ) -> String {
        source(dialect, &spec.events, spec.conversation.as_deref(), request)
            .expect("a plugin dialect")
    }

    /// **The property this stage exists for.** There used to be two templates per
    /// dialect — a Mac one reporting through the app's CLI, a device one through
    /// the daemon — and every divergence between them was a bug waiting: the
    /// ownership fingerprint drifted exactly that way, and a reinstall doubled
    /// every device hook for it. One template each now, and this is what says so.
    #[test]
    fn one_template_serves_both_machines() {
        for (dialect, spec) in [
            (HookDialect::OpenCodePlugin, opencode_spec()),
            (HookDialect::PiPlugin, pi_spec()),
            (HookDialect::AmpPlugin, amp_spec()),
        ] {
            assert_eq!(
                rendered(dialect, &spec, &local_request("/opt/termiod")),
                rendered(dialect, &spec, &device_request("/opt/termiod")),
                "{dialect:?} still renders differently per machine"
            );
        }
    }

    /// The conversation plumbing used to be dropped on a device, because
    /// `SetStatus` had no field for an id. It has one now, so a device agent
    /// follows an in-process `/new` rotation exactly as a local one does.
    #[test]
    fn a_device_plugin_now_carries_the_conversation_too() {
        let device = rendered(
            HookDialect::OpenCodePlugin,
            &opencode_spec(),
            &device_request("/opt/termiod"),
        );
        assert!(device.contains("--conversation ${conversation}"), "{device}");
        assert!(device.contains("roots.has(conversation)"), "{device}");
    }

    #[test]
    fn the_opencode_plugin_renders_exactly() {
        assert_eq!(
            rendered(
                HookDialect::OpenCodePlugin,
                &opencode_spec(),
                &device_request("/opt/termiod")
            ),
            r#"// termio agent status — reports OpenCode session lifecycle to termio.
// Socket marker: agent-status.sock
export const TermioStatus = async ({ $ }) => {
  const cli = "\/opt\/termiod";
  const session = process.env.TERMIOD_SESSION_ID;
  const roots = new Set();
  const note = (info) => {
    if (!info?.id) return;
    if (info.parentID) roots.delete(info.id); else roots.add(info.id);
  };
  const report = (state, conversation) => {
    if (!session) return;
    if (conversation && roots.has(conversation)) {
      return $`${cli} set-status ${session} ${state} --conversation ${conversation}`.quiet().nothrow();
    }
    return $`${cli} set-status ${session} ${state}`.quiet().nothrow();
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

    #[test]
    fn the_pi_plugin_renders_exactly() {
        assert_eq!(
            rendered(HookDialect::PiPlugin, &pi_spec(), &device_request("/opt/termiod")),
            r#"// termio agent status — reports Pi turn lifecycle to termio.
// Socket marker: agent-status.sock
export default (pi) => {
  const cli = "'\/opt\/termiod'";
  const session = process.env.TERMIOD_SESSION_ID;
  const report = (state, context) => {
    if (!session) return;
    const id = context?.sessionManager?.getSessionId?.();
    const conversation = id && /^[A-Za-z0-9._-]+$/.test(id) ? ` --conversation ${id}` : "";
    pi.exec("sh", ["-c", `${cli} set-status "$TERMIOD_SESSION_ID" ${state}${conversation} 2>/dev/null || true`]);
  };
  pi.on("session_start", (_event, context) => report("idle", context));
  pi.on("agent_start", (_event, context) => report("working", context));
  pi.on("agent_end", (_event, context) => report("done", context));
};"#
        );
    }

    #[test]
    fn the_amp_plugin_renders_exactly() {
        assert_eq!(
            rendered(HookDialect::AmpPlugin, &amp_spec(), &device_request("/opt/termiod")),
            r#"// termio agent status — reports Amp turn lifecycle to termio.
// Socket marker: agent-status.sock
export default (amp) => {
  const cli = "\/opt\/termiod";
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

    /// A plugin loaded outside a termiod session has no id, and reporting an
    /// empty one is a call the daemon rejects — silently, because the whole form
    /// is `.quiet().nothrow()`.
    #[test]
    fn a_plugin_outside_a_session_reports_nothing() {
        for (dialect, spec) in [
            (HookDialect::OpenCodePlugin, opencode_spec()),
            (HookDialect::PiPlugin, pi_spec()),
            (HookDialect::AmpPlugin, amp_spec()),
        ] {
            let source = rendered(dialect, &spec, &device_request("/opt/termiod"));
            assert!(source.contains("const session = process.env.TERMIOD_SESSION_ID;"), "{dialect:?}");
            assert!(source.contains("if (!session) return;"), "{dialect:?}");
        }
    }

    /// Every generated plugin carries the comment the installer recognizes it
    /// by. Without it an install cannot tell its own file from a user's, so it
    /// would either refuse to replace its own work or claim someone else's.
    #[test]
    fn every_generated_plugin_is_recognizable_as_ours() {
        for (dialect, spec) in [
            (HookDialect::OpenCodePlugin, opencode_spec()),
            (HookDialect::PiPlugin, pi_spec()),
            (HookDialect::AmpPlugin, amp_spec()),
        ] {
            let source = rendered(dialect, &spec, &device_request("/opt/termiod"));
            assert!(
                source.contains(&format!("// Socket marker: {SOCKET_MARKER}")),
                "{dialect:?} lost its ownership marker"
            );
        }
    }
}
