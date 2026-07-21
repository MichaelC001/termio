import AppKit
import SwiftUI

/// Settings ▸ Languages: the language servers behind the editor's ⌘-click navigation and hover,
/// with a live installed/missing status per server. Status and guidance only — termio never runs
/// an installer; a missing server shows the command to copy, the same "an installed CLI *is* the
/// on switch" philosophy as the Agents tab. Custom servers plug in through `lsp.json`.
struct LanguagesSettingsTab: View {
    var body: some View {
        Form {
            Section {
                ForEach(LSPRegistry.descriptors) { LanguageServerRow(descriptor: $0) }
            } header: {
                SectionHeaderLabel(title: "Language Servers")
            } footer: {
                Text("Powers ⌘-click jump-to-definition, ⌃⌘J, and hover documentation in the file editor. termio finds each server on your login-shell PATH — install one and it just starts working; nothing to enable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                customConfigRow
            } header: {
                SectionHeaderLabel(title: "Custom Servers")
            }
        }
        .formStyle(.grouped)
    }

    private var customConfigRow: some View {
        HStack(spacing: 10) {
            SettingsLabel(
                symbol: "square.and.pencil",
                title: "lsp.json",
                subtext: "Add or override servers in \(LSPRegistry.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")): an array of { id, command, extensions } entries. A matching id replaces the built-in; a new id adds a language."
            )
            Spacer(minLength: 8)
            Button("Reveal in Finder") { reveal() }
                .controlSize(.small)
        }
    }

    /// Shows the config file in Finder, pointing at its (created-if-needed) folder when the
    /// file itself hasn't been written yet.
    private func reveal() {
        let url = LSPRegistry.configURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
    }
}

/// One server's status row: language name, launch command, and either the resolved binary path
/// (installed) or the copyable install command (missing). The probe reuses the registry's own
/// PATH resolution, so this row and the editor always agree.
private struct LanguageServerRow: View {
    let descriptor: LSPServerDescriptor

    private enum Status { case probing, missing, found(String) }
    @State private var status: Status = .probing

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName).font(.headline)
                Text(descriptor.command)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help("Handles: " + descriptor.extensions.keys.sorted().map { ".\($0)" }.joined(separator: " "))
            Spacer(minLength: 8)
            trailing
        }
        .task {
            if let launch = await LSPRegistry.resolveLaunch(descriptor.command) {
                status = .found(launch.binary)
            } else {
                status = .missing
            }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
    }

    private var dotColor: Color {
        switch status {
        case .probing: return .clear
        case .missing: return Color.secondary.opacity(0.35)
        case .found: return .green
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .probing:
            EmptyView()
        case .found(let path):
            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 260, alignment: .trailing)
        case .missing:
            if let install = descriptor.install {
                HStack(spacing: 5) {
                    Text(install)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(install, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Copy install command")
                }
            } else {
                // sourcekit-lsp / clangd: part of the Xcode toolchain — absence means the
                // Command Line Tools are missing, not a package to brew.
                Text("Ships with Xcode")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
