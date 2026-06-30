import SwiftUI

/// The coding-plan usage limits for the agents termio runs, reusing the OAuth
/// credentials the `claude` and `codex` CLIs already leave on disk — the same
/// approach as steipete's CodexBar, scoped to the two agents with a clean
/// local-cred endpoint. A reference view, not an ambient one: it pulls fresh on
/// open and on Refresh, so a glance here tells you whether to start that long run.
struct UsageSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: UsageMonitor
    /// The agent whose statistics are shown. Held loosely (optional) so a disabled
    /// agent falling out of the list resolves back to the first available one
    /// rather than stranding on an empty pane.
    @State private var selected: AgentPreset?

    /// The supported agents the user has left enabled — one sub-tab each.
    private var agents: [AgentPreset] {
        UsageMonitor.supportedAgents.filter(settings.isAgentEnabled)
    }

    /// The resolved selection: the held one if still enabled, else the first agent.
    private var current: AgentPreset {
        if let selected, agents.contains(selected) { return selected }
        return agents.first ?? .claudeCode
    }

    var body: some View {
        Group {
            if agents.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    UsageAgentPicker(
                        agents: agents,
                        selection: Binding(get: { current }, set: { selected = $0 })
                    )
                    Divider()
                    UsageAgentDetail(agent: current, usage: usage)
                }
            }
        }
        .onAppear(perform: usage.refresh)
    }

    private var emptyState: some View {
        Form {
            Section {
                Text("Enable Claude Code or Codex in the Agents tab to see their usage here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeaderLabel(title: "Usage")
            }
        }
        .formStyle(.grouped)
    }
}

/// The Usage pane's secondary tab strip: one selectable pill per agent (brand mark
/// + name), CodexBar's provider-switcher pattern. The selected pill tints accent
/// over a soft capsule; the rest stay flat with a hover lift.
private struct UsageAgentPicker: View {
    let agents: [AgentPreset]
    @Binding var selection: AgentPreset

    var body: some View {
        HStack(spacing: 6) {
            ForEach(agents) { agent in
                pill(for: agent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func pill(for agent: AgentPreset) -> some View {
        let isSelected = agent == selection
        return Button {
            selection = agent
        } label: {
            HStack(spacing: 6) {
                AgentIconView(agent: agent, size: 14)
                Text(agent.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.accentColor.opacity(isSelected ? 0.14 : 0))
            )
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}

/// One agent's statistics: the local token totals (today / week / month, with the
/// API-rate cost estimate where termio can price it) and the live plan-limit lanes.
private struct UsageAgentDetail: View {
    let agent: AgentPreset
    @ObservedObject var usage: UsageMonitor

    var body: some View {
        Form {
            Section {
                if let tokens = usage.tokenUsage[agent] {
                    TokenUsageRow(label: "Today", stats: tokens.today, hasCost: tokens.hasCost)
                    TokenUsageRow(label: "This week", stats: tokens.week, hasCost: tokens.hasCost)
                    TokenUsageRow(label: "This month", stats: tokens.month, hasCost: tokens.hasCost)
                } else {
                    Text("No local usage yet — run `\(agent.command ?? agent.rawValue)` once, then Refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                SectionHeaderLabel(title: "Token usage")
            } footer: {
                Text("Tallied from \(agent.displayName)'s own local session logs across every terminal and editor on this Mac — your actual usage, regardless of how the plan bills.\(usage.tokenUsage[agent]?.hasCost == true ? " Cost is estimated at API rates." : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let reading = usage.usage[agent], !reading.windows.isEmpty {
                Section {
                    ForEach(reading.windows) { window in
                        UsageWindowRow(window: window)
                    }
                } header: {
                    SectionHeaderLabel(title: "Plan limits")
                }
            }

            Section {
                Button("Refresh", action: usage.forceRefresh)
            } footer: {
                Text("Plan limits come from \(agent.displayName)'s OAuth login (no passwords stored); reading Claude's may prompt once for Keychain access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One token-usage window: the period, the token throughput, and (for agents
/// termio can price) the API-rate dollar estimate. This is the "what did I
/// actually burn" line — independent of plan billing.
private struct TokenUsageRow: View {
    let label: String
    let stats: TokenWindowStats
    let hasCost: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            Text("\(stats.tokenSummary) tokens")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if hasCost, !stats.costSummary.isEmpty {
                Text("· \(stats.costSummary)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
    }
}

/// One quota lane: its period and a filled bar with the percent and reset time.
/// The bar tints amber past 75% and red past 90%, so a near-exhausted window
/// reads at a glance without a number-by-number scan.
private struct UsageWindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label)
                    .font(.callout)
                Spacer()
                Text("\(window.usedPercent)%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !window.resetSummary.isEmpty {
                    Text("· resets \(window.resetSummary)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(fill)
                        .frame(width: max(0, min(1, Double(window.usedPercent) / 100)) * geometry.size.width)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
    }

    private var fill: Color {
        switch window.usedPercent {
        case 90...: return .red
        case 75...: return .orange
        default: return .accentColor
        }
    }
}
