import SwiftUI

// MARK: - Commit box

/// The staging half of the "ship it" footer: the commit-message box and the Commit
/// button. Only mounted when the working tree has changes — pushing lives in `RemoteBar`,
/// which persists once the tree is clean. Styled to sit under `InspectorTabsToolbar`:
/// Liquid Glass buttons on macOS 26 (flat `.bordered` fallback), the app's 8-pt radius.
struct CommitFooter: View {
    @ObservedObject var model: GitPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            messageField
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                commitButton
            }
        }
        .padding(10)
    }

    private var messageField: some View {
        TextField("Message (⌘↩ to commit)", text: $model.message, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1...4)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
    }

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
}

// MARK: - Remote bar (push)

/// The branch half of the "ship it" footer: the ahead/behind stat and the Push button.
/// Unlike `CommitFooter` this belongs to the *branch*, not the working-tree diff — so it
/// stays visible after a commit clears the tree, when the branch still has commits to
/// push. Renders nothing when the branch is level with origin. Opening a pull request is
/// deliberately left to the terminal (`gh` / a PR skill), where the user already lives.
struct RemoteBar: View {
    @ObservedObject var model: GitPanelModel

    var body: some View {
        if model.upstream.canPush {
            HStack(spacing: 8) {
                branchStatus
                Spacer(minLength: 6)
                pushButton
            }
            .padding(10)
        }
    }

    /// A one-line summary of where the branch sits versus its upstream — what Push will send.
    private var branchStatus: some View {
        let u = model.upstream
        let text: String
        if !u.hasUpstream {
            text = "Branch not published"
        } else if u.ahead > 0 && u.behind > 0 {
            text = "\(u.ahead) ahead · \(u.behind) behind"
        } else if u.ahead > 0 {
            text = "\(u.ahead) commit\(u.ahead == 1 ? "" : "s") to push"
        } else {
            text = "Up to date"
        }
        return HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
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
}

// MARK: - Button style

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
