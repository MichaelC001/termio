import SwiftUI

struct AgentSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.agentHooksEnabled) {
                    HStack(spacing: 10) {
                        IconBadge(symbol: "dot.radiowaves.left.and.right")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live agent status")
                                .font(.headline)
                            Text("Installs hooks for Claude Code, Codex, OpenCode, and Pi so termio can tell when an agent is working or waiting on you — shown as the spinning sidebar icon and the menu-bar pulse. Adds termio's own entries to each agent's config; turning this off removes them. (Codex needs a one-time /hooks trust.)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
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
                    HStack(spacing: 10) {
                        IconBadge(symbol: "arrow.triangle.branch")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Session control")
                                .font(.headline)
                            Text("Lets an agent see and drive its sibling sessions in the same project with the `termio sessions` command (list, send a prompt, answer a menu, start, stop). Scoped to the current project. Adds a short awareness note to the agents' instruction files; turning this off removes it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
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
                    // The Dia "Sync row": a badge + title + subtitle on the left,
                    // its switch on the right. The switch controls whether the
                    // agent appears in the sidebar's new-session quick-add row.
                    Toggle(isOn: Binding(
                        get: { settings.isAgentEnabled(preset) },
                        set: { settings.setAgent(preset, enabled: $0) }
                    )) {
                        HStack(spacing: 10) {
                            IconBadge(preset.icon)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.displayName)
                                    .font(.headline)
                                Text(subtitle(for: preset))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)

                    // The plain terminal launches the login shell — there is no
                    // command to override, so only agent presets get a field.
                    if preset != .terminal {
                        TextField(
                            "Command",
                            text: Binding(
                                get: { settings.agentCommandOverrides[preset.rawValue] ?? "" },
                                set: { settings.agentCommandOverrides[preset.rawValue] = $0 }
                            ),
                            prompt: Text(preset.command ?? "")
                        )
                    }

                    // One-click bypass for the agent's permission/approval prompts,
                    // for agents that have a stable flag for it. Appends the flag to
                    // the command above rather than replacing it, so it composes with
                    // a custom override.
                    if let flag = preset.permissionBypassFlag {
                        Toggle(isOn: Binding(
                            get: { settings.bypassesPermissions(preset) },
                            set: { settings.setBypassPermissions(preset, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Skip permission prompts")
                                Text("Runs with `\(flag)`. The agent won't ask before editing files or running commands.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Subtitle under each agent name: the effective command it runs (override and
    /// bypass flag included), so the row stays self-describing without reading the
    /// fields below it.
    private func subtitle(for preset: AgentPreset) -> String {
        settings.command(for: preset) ?? "Login shell"
    }
}

/// Installs and reports the `termio` command-line tool. It audits on appear so the
/// row always reflects reality (a moved app shows "Update"), and re-audits after
/// the install action so the button and caption update in place.
private struct CommandLineToolRow: View {
    @State private var status: CommandLineTool.Status = .notInstalled

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: "terminal")
            VStack(alignment: .leading, spacing: 2) {
                Text("Command-line tool")
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let title = buttonTitle {
                Button(title) { status = CommandLineTool.install() }
            }
        }
        .onAppear { status = CommandLineTool.audit() }
    }

    private var description: String {
        switch status {
        case .installed:
            return "`termio` is on your PATH. Run `termio sessions …` to drive sibling sessions, or `termio .` to open a folder."
        case .stale(let path):
            return "An older install points at \(path). Update it to this version of termio."
        case .notInstalled:
            return "Install `termio` so you (and agents) can run `termio sessions …` from any shell. Links to /usr/local/bin."
        case .conflict:
            return "A different `termio` already exists at \(CommandLineTool.installURL.path). Remove it first — termio won't overwrite a file it didn't create."
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
