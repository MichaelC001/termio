import SwiftUI

// MARK: - Commit / push / PR footer

/// The "ship it" footer pinned below the changes list: a commit-message box, the
/// commit + push buttons, and the pull-request row. Turns a reviewed diff into a
/// commit/push/PR without leaving the pane. Purely `git`/`gh` shell-outs behind
/// `GitPanelModel` — no GitHub dependency when `gh` is absent (the PR row just hides).
///
/// Styled to sit under `InspectorTabsToolbar`: the same Liquid Glass button treatment on
/// macOS 26 (with a flat `.bordered` fallback), theme-aware tints from `ChromeTheme`, and
/// the app's 5/7/8-pt corner-radius + hover-fill vocabulary.
struct CommitFooter: View {
    @ObservedObject var model: GitPanelModel
    @Binding var showPRSheet: Bool
    let chrome: ChromeTheme?
    /// Opens a URL in the browser (an existing PR when its row is clicked).
    let openURL: (String) -> Void

    @State private var generateHovering = false
    @State private var prRowHovering = false

    /// The active accent for interactive glyphs — the terminal theme's accent when a theme
    /// is set, otherwise the system accent.
    private var accent: Color { chrome?.accent ?? .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)

            messageField

            if let banner = model.banner {
                Text(banner.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(banner.kind == .error ? Color.red : Color.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text("\(model.selectedCount) of \(model.changes.count) selected")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 6)
                pushButton
                commitButton
            }

            if model.ghAvailable {
                Divider().opacity(0.4)
                pullRequestRow
            }
        }
        .padding(10)
    }

    // MARK: Message box

    private var messageField: some View {
        // The prompt doubles as the generating-state label: a bare corner spinner over an
        // empty field reads as "the panel is loading", so the words carry the meaning while
        // the agent writes the message.
        TextField(model.isGenerating ? "Writing commit message…" : "Message (⌘↩ to commit)",
                  text: $model.message, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1...4)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            // Leave room for the ✨ button so a long first line doesn't run under it.
            .padding(.trailing, model.aiAvailable ? 24 : 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
            .overlay(alignment: .topTrailing) {
                if model.aiAvailable { generateButton }
            }
    }

    /// Writes a Conventional Commit message from the checked files' diffs via the agent CLI
    /// (claude/codex). Plain button with the app's 5-pt hover-fill (as `TreeHeaderButton`),
    /// tinted with the theme accent when it can act.
    private var generateButton: some View {
        Button {
            Task { await model.generateMessage() }
        } label: {
            Group {
                if model.isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(generateHovering ? 0.08 : 0))
            )
            .foregroundStyle(model.selectedCount == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(accent))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.selectedCount == 0 || model.isGenerating)
        .onHover { generateHovering = $0 }
        .padding(2)
        .help("Generate commit message from the checked files")
    }

    // MARK: Commit / push

    private var commitButton: some View {
        Button {
            Task { await model.commit() }
        } label: {
            // Overlay the spinner on a zero-opacity label rather than swapping content, so
            // the button keeps its "Commit" width instead of jumping when work starts.
            Text("Commit")
                .opacity(model.isCommitting ? 0 : 1)
                .overlay { if model.isCommitting { ProgressView().controlSize(.small) } }
        }
        .controlSize(.small)
        .disabled(!model.canCommit)
        .keyboardShortcut(.return, modifiers: .command)
        .footerButtonStyle(prominent: true)
    }

    private var pushButton: some View {
        Button {
            Task { await model.push() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up")
                Text(model.upstream.ahead > 0 ? "Push \(model.upstream.ahead)" : "Push")
            }
            .opacity(model.isPushing ? 0 : 1)
            .overlay { if model.isPushing { ProgressView().controlSize(.small) } }
        }
        .controlSize(.small)
        .disabled(model.isPushing || !model.upstream.canPush)
        .footerButtonStyle(prominent: false)
        .help(model.upstream.hasUpstream ? "Push to the tracking branch" : "Publish this branch to origin")
    }

    // MARK: Pull request

    /// Shows the branch's existing PR (clickable, with rolled-up check state) or an
    /// affordance to open one — a hoverable row in the sidebar's 7-pt radius, tinted with
    /// the theme accent. Only mounted when `gh` is available.
    @ViewBuilder private var pullRequestRow: some View {
        if let pr = model.pullRequest {
            prRow(action: { openURL(pr.url) }, help: pr.title) {
                Image(systemName: "arrow.triangle.pull")
                Text("PR #\(pr.number)").foregroundStyle(.primary)
                checksBadge(pr.checks)
                Spacer(minLength: 4)
                Text(pr.state.capitalized).foregroundStyle(.secondary)
            }
        } else {
            prRow(action: { showPRSheet = true }, help: "Open a pull request for this branch") {
                Image(systemName: "arrow.triangle.pull")
                Text("Create Pull Request")
                Spacer()
            }
        }
    }

    private func prRow<Content: View>(
        action: @escaping () -> Void,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { content() }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(prRowHovering ? 0.12 : 0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { prRowHovering = $0 }
        .help(help)
    }

    @ViewBuilder private func checksBadge(_ checks: PRChecks) -> some View {
        switch checks {
        case .passing: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending: Image(systemName: "clock.fill").foregroundStyle(.yellow)
        case .none: EmptyView()
        }
    }
}

/// The footer's primary/secondary buttons in the app's Liquid Glass idiom on macOS 26,
/// falling back to the standard bordered styles on older systems — the same availability
/// split `InspectorTabsToolbar` uses for its glass pill.
private extension View {
    @ViewBuilder func footerButtonStyle(prominent: Bool) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

// MARK: - Create-PR sheet

/// A compact sheet for `gh pr create`: title (prefilled from the commit message), base
/// branch (the repo default), and an optional description. On success it opens the new
/// PR in the browser and refreshes the footer so the row flips to showing it.
struct CreatePRSheet: View {
    @ObservedObject var model: GitPanelModel
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var prBody = ""
    @State private var base = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Pull Request")
                .font(.headline)

            field(label: "Title") {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            field(label: "Base branch") {
                TextField("base", text: $base)
                    .textFieldStyle(.roundedBorder)
            }

            field(label: "Description") {
                TextField("Optional", text: $prBody, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...10)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || base.isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 470)
        .onAppear {
            base = model.defaultBranch
            // Seed the title from the first line of the commit message, if any.
            if title.isEmpty {
                title = model.message.split(separator: "\n").first.map(String.init) ?? ""
            }
        }
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func create() {
        isCreating = true
        error = nil
        Task {
            let result = await GHService.createPR(
                title: title.trimmingCharacters(in: .whitespaces),
                body: prBody,
                base: base,
                in: model.repoRoot
            )
            isCreating = false
            switch result {
            case .success(let url):
                await model.refreshRemoteState()
                onCreated(url)
                dismiss()
            case .failure(let message):
                error = message
            }
        }
    }
}
