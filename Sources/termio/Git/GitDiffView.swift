import AppKit
import SwiftUI

// MARK: - Diff overlay

/// A read-only unified diff that covers the terminal pane — the git counterpart of
/// `FilePreviewView`/`FileEditorView`, driven by `store.openDiff`. Rendered as native
/// SwiftUI rows (the Xcode / CodeEdit / gitdiff pattern — parse the diff, draw line
/// rows with a line-number gutter and per-line green/red backgrounds) rather than a
/// web view, so it needs no syntax-highlighting dependency. Escape or the close
/// button dismisses it back to the terminal.
struct GitDiffView: View {
    let request: GitDiffRequest
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void

    @State private var rows: [DiffRow] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        .onExitCommand(perform: onClose)
        .task(id: request) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(request.change.status.letter)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(request.change.status.tint)
                .frame(width: 16)
            Text(request.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            let directory = (request.change.path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                Text(directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if request.change.additions > 0 {
                Text("+\(request.change.additions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.green)
            }
            if request.change.deletions > 0 {
                Text("−\(request.change.deletions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.red)
            }
            // Close lives in the toolbar now (a bordered, Liquid Glass button hugging the
            // terminal|inspector divider) — see `setCloseOverlayVisible` in App.swift.
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: settings.terminalBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView(
                "No Diff",
                systemImage: "doc",
                description: Text("No textual changes to show.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        DiffLineRow(row: row, font: diffFont,
                                    showOldGutter: hasOldLines, showNewGutter: hasNewLines)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    /// Whether any row carries an old/new line number. A pure-addition file (new file)
    /// has no old numbers, so we collapse that empty gutter rather than show a blank band;
    /// likewise a pure deletion collapses the new gutter.
    private var hasOldLines: Bool { rows.contains { $0.oldLine != nil } }
    private var hasNewLines: Bool { rows.contains { $0.newLine != nil } }

    /// The terminal font, so the diff reads in the same face as the agent's output.
    private var diffFont: Font {
        let size = max(11, settings.fontSize)
        return settings.fontFamily.isEmpty
            ? .system(size: size, design: .monospaced)
            : .custom(settings.fontFamily, size: size)
    }

    private func load() async {
        let parsed = await GitService.diffRows(for: request.change, in: request.repoRoot)
        rows = parsed
        isLoading = false
    }
}

/// One line of the diff: a hunk header on a faint accent band, or a code line with an
/// old/new line-number gutter, a `+`/`−`/space sign, and a green/red/clear background.
/// Long lines soft-wrap (the panel is fixed-width) rather than scroll horizontally,
/// which keeps each line's background spanning the full width.
private struct DiffLineRow: View {
    let row: DiffRow
    let font: Font
    var showOldGutter = true
    var showNewGutter = true

    var body: some View {
        if row.kind == .hunk {
            Text(row.text)
                .font(font)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 10)
                .background(Color.accentColor.opacity(0.10))
        } else {
            HStack(alignment: .top, spacing: 0) {
                if showOldGutter { gutter(row.oldLine) }
                if showNewGutter { gutter(row.newLine) }
                Text(sign)
                    .font(font)
                    .foregroundStyle(signColor)
                    .frame(width: 16)
                Text(row.text.isEmpty ? " " : row.text)
                    .font(font)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 10)
            }
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
        }
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 36, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var sign: String {
        switch row.kind {
        case .addition: return "+"
        case .deletion: return "-"
        default: return " "
        }
    }

    private var signColor: Color {
        switch row.kind {
        case .addition: return .green
        case .deletion: return .red
        default: return .secondary
        }
    }

    private var background: Color {
        switch row.kind {
        case .addition: return Color.green.opacity(0.13)
        case .deletion: return Color.red.opacity(0.13)
        default: return .clear
        }
    }
}
