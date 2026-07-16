import SwiftUI

struct AgentSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.agentHooksEnabled) {
                    SettingsLabel(
                        symbol: "dot.radiowaves.left.and.right",
                        title: "Live agent status",
                        subtext: "Installs hooks for Claude Code, Codex, OpenCode, and Pi so termio can tell when an agent is working or waiting on you — shown as the spinning sidebar icon and the menu-bar pulse. Adds termio's own entries to each agent's config; turning this off removes them. (Codex needs a one-time /hooks trust.)"
                    )
                }
                .toggleStyle(.switch)
                if settings.agentHooksEnabled {
                    // For re-applying after the user (or another tool) has edited
                    // ~/.claude/settings.json; install is idempotent.
                    Button("Reinstall hooks") { AgentStatusHooks.sync(enabled: true) }
                }
            } header: {
                SectionHeaderLabel(title: "Status")
            }
            Section {
                CommandLineToolRow()
                Toggle(isOn: $settings.sessionControlEnabled) {
                    SettingsLabel(
                        symbol: "arrow.triangle.branch",
                        title: "Session control",
                        subtext: "Lets an agent see and drive its sibling sessions in the same project with the `termio sessions` command (list, send a prompt, answer a menu, start, stop). Scoped to the current project. Adds a short awareness note to the agents' instruction files; turning this off removes it."
                    )
                }
                .toggleStyle(.switch)
                if settings.sessionControlEnabled {
                    Button("Reinstall note") { SessionSkillInstaller.sync(enabled: true) }
                }
            } header: {
                SectionHeaderLabel(title: "Orchestration")
            }
            ForEach(AgentPreset.allCases) { preset in
                Section {
                    AgentRow(settings: settings, preset: preset)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One agent's settings block: enable switch, command/path override, an install
/// link when its CLI can't be resolved, and the permission-bypass toggle.
private struct AgentRow: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset

    /// `nil` while the PATH probe is still running (show nothing rather than a
    /// premature warning); `false` once we've confirmed the command isn't resolvable.
    @State private var available: Bool?

    var body: some View {
        // `Group` is transparent inside a Form (its children each become a row), so it
        // just gives the several rows one place to hang the availability probe.
        Group {
            // The Dia "Sync row": a badge + title + subtitle on the left, its switch on
            // the right. The switch controls whether the agent appears in the sidebar's
            // new-session quick-add row.
            Toggle(isOn: Binding(
                get: { settings.isAgentEnabled(preset) },
                set: { settings.setAgent(preset, enabled: $0) }
            )) {
                SettingsLabel(
                    preset.icon,
                    title: preset.displayName,
                    subtext: settings.command(for: preset) ?? "Login shell"
                )
            }
            .toggleStyle(.switch)

            // The plain terminal launches the login shell — there is no command to
            // override, so only agent presets get a field.
            if preset != .terminal {
                TextField(
                    "Command",
                    text: Binding(
                        get: { settings.agentCommandOverrides[preset.rawValue] ?? "" },
                        set: { settings.agentCommandOverrides[preset.rawValue] = $0 }
                    ),
                    prompt: Text(preset.command ?? "")
                )

                // When the CLI can't be resolved on PATH, quietly offer a jump to its
                // install page — no alarm. Not every agent is meant to be installed, so
                // this only appears for agents that carry an install link.
                if available == false, let url = preset.installURL {
                    Link(destination: url) {
                        Label("Install \(preset.displayName)", systemImage: "arrow.down.circle")
                    }
                }
            }

            // One-click bypass for the agent's permission/approval prompts, for agents
            // that have a stable flag for it. Appends the flag to the command above
            // rather than replacing it, so it composes with a custom override.
            if let flag = preset.permissionBypassFlag {
                Toggle(isOn: Binding(
                    get: { settings.bypassesPermissions(preset) },
                    set: { settings.setBypassPermissions(preset, enabled: $0) }
                )) {
                    SettingsLabel(
                        title: "Skip permission prompts",
                        subtext: "Runs with `\(flag)`. The agent won't ask before editing files or running commands."
                    )
                }
                .toggleStyle(.switch)
            }
        }
        // Re-checks whenever the effective command changes, so typing a valid path
        // clears the warning. The PATH probe runs once (cached); each row does an
        // in-memory lookup. SwiftUI cancels and restarts this on every id change, so
        // the leading sleep debounces per-keystroke edits into one probe once the
        // user pauses. The plain terminal has no command to resolve, so it never probes.
        .task(id: effectiveCommand) {
            guard preset != .terminal else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            available = await AgentAvailability.isCommandAvailable(effectiveCommand)
        }
    }

    /// The effective command whose binary availability we probe (override + bypass
    /// flag folded in), matching what a session actually launches.
    private var effectiveCommand: String { settings.command(for: preset) ?? "" }
}

/// Installs and reports the `termio` command-line tool. It audits on appear so the
/// row always reflects reality (a moved app shows "Update"), and re-audits after
/// the install action so the button and caption update in place.
private struct CommandLineToolRow: View {
    @State private var status: CommandLineTool.Status = .notInstalled

    var body: some View {
        HStack(spacing: 10) {
            SettingsLabel(symbol: "terminal", title: "Command-line tool", subtext: description)
            Spacer()
            if let title = buttonTitle {
                Button(title) { status = CommandLineTool.install() }
            }
        }
        .onAppear { status = CommandLineTool.audit() }
    }

    private var description: String {
        let tool = CommandLineTool.toolName
        switch status {
        case .installed:
            return "`\(tool)` is on your PATH. Run `\(tool) sessions …` to drive sibling sessions, or `\(tool) .` to open a folder."
        case .stale(let path):
            return "An older install points at \(path). Update it to this version of termio."
        case .notInstalled:
            return "Install `\(tool)` so you (and agents) can run `\(tool) sessions …` from any shell. Links to /usr/local/bin."
        case .conflict:
            return "A different `\(tool)` already exists at \(CommandLineTool.installURL.path). Remove it first — termio won't overwrite a file it didn't create."
        case .unavailable:
            return "Available when termio runs from the built app bundle."
        }
    }

    private var buttonTitle: String? {
        switch status {
        case .installed: return "Reinstall"
        case .stale: return "Update"
        case .notInstalled: return "Install"
        case .conflict, .unavailable: return nil
        }
    }
}
