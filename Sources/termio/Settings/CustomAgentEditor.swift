import AppKit
import SwiftUI

/// Reads and writes user agent manifests (`~/.termio[-dev]/config/agents/<id>.json`)
/// on behalf of the Settings form. The form covers the everyday fields (name,
/// command, icon symbol, bypass flag, skills directory); a hand-written manifest's
/// other keys (status, hooks, resume, …) are preserved verbatim on rewrite.
enum UserAgentStore {
    struct Draft {
        var name = ""
        var command = ""
        /// SF Symbol name; empty means the default terminal glyph.
        var symbol = ""
        var permissionBypassFlag = ""
        /// The agent's user-level skills directory (`~/.config/my-agent/skills`),
        /// where termio installs the session-control skill; empty declares none.
        var skillsDir = ""

        init() {}

        /// Prefills the form from an existing definition for edit mode.
        init(_ definition: AgentDefinition) {
            name = definition.displayName
            command = definition.command ?? ""
            if case .symbol(let name) = definition.icon { symbol = name }
            permissionBypassFlag = definition.permissionBypassFlag ?? ""
            skillsDir = definition.skillDir ?? ""
        }

        var isValid: Bool {
            !name.trimmingCharacters(in: .whitespaces).isEmpty
                && !command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Writes the draft as a manifest and returns its id — the existing id when
    /// editing, else a fresh slug derived from the name. Editing loads the current
    /// JSON first and only replaces the form's keys, so hand-authored extras
    /// survive a rename.
    static func save(_ draft: Draft, existingID: String?) throws -> String {
        let id = existingID ?? uniqueID(for: draft.name)
        let directory = AgentCatalog.userAgentsDirectory
        let file = directory.appendingPathComponent("\(id).json")

        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        object["id"] = id
        object["name"] = draft.name.trimmingCharacters(in: .whitespaces)
        object["command"] = draft.command.trimmingCharacters(in: .whitespaces)

        let flag = draft.permissionBypassFlag.trimmingCharacters(in: .whitespaces)
        object["permissionBypassFlag"] = flag.isEmpty ? nil : flag

        let symbol = draft.symbol.trimmingCharacters(in: .whitespaces)
        if !symbol.isEmpty {
            object["icon"] = ["symbol": symbol]
        } else if let icon = object["icon"] as? [String: Any], icon["symbol"] != nil {
            // Clearing the field removes a symbol icon (back to the default glyph),
            // but never touches a hand-authored path/vector/asset icon.
            object["icon"] = nil
        }

        let skillsDir = draft.skillsDir.trimmingCharacters(in: .whitespaces)
        if skillsDir.isEmpty {
            object["skills"] = nil
        } else {
            object["skills"] = ["dir": skillsDir]
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
        return id
    }

    static func delete(id: String) throws {
        let file = AgentCatalog.userAgentsDirectory.appendingPathComponent("\(id).json")
        try FileManager.default.removeItem(at: file)
    }

    /// A filename-safe slug from the display name, suffixed until it collides with
    /// no known agent id (bundled or user).
    private static func uniqueID(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var slug = name.lowercased()
            .map { character -> Character in
                character.unicodeScalars.allSatisfy(allowed.contains) ? character : "-"
            }
            .reduce(into: "") { partial, character in
                // Collapse runs of separators so "My  Agent!" → "my-agent".
                if character == "-" && partial.hasSuffix("-") { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "agent" }
        let taken = Set(AgentDefinition.allCases.map(\.id))
        if !taken.contains(slug) { return slug }
        for counter in 2... where !taken.contains("\(slug)-\(counter)") {
            return "\(slug)-\(counter)"
        }
        fatalError("unreachable: the counter loop always returns")
    }
}

/// The create/edit form for a user agent — the everyday subset of the manifest.
/// Anything richer (status regexes, hooks, resume) stays a hand-written JSON
/// affair; this form round-trips those keys untouched.
struct CustomAgentEditorSheet: View {
    /// `nil` creates a new agent; a definition edits its manifest in place.
    let existing: AgentDefinition?
    /// Called with the saved agent's id after the manifest is written.
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: UserAgentStore.Draft
    @State private var saveError: String?

    init(existing: AgentDefinition?, onSave: @escaping (String) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _draft = State(initialValue: existing.map(UserAgentStore.Draft.init) ?? UserAgentStore.Draft())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(localized("Name"), text: $draft.name, prompt: Text(localized("My Agent")))
                    LabeledContent(localized("Command")) {
                        TextField(
                            "", text: $draft.command,
                            prompt: Text("my-agent --flag"))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .fontDesign(.monospaced)
                        .labelsHidden()
                    }
                } header: {
                    SectionHeaderLabel(title: existing == nil ? localized("New Agent") : localized("Edit Agent"))
                } footer: {
                    Text(localized("The command is run in a login shell, so anything on your PATH works."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent(localized("Icon")) {
                        HStack(spacing: 8) {
                            TextField("", text: $draft.symbol, prompt: Text(localized("SF Symbol name")))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .labelsHidden()
                            IconBadge(iconPreview)
                        }
                    }
                    LabeledContent(localized("Skip-permissions flag")) {
                        TextField("", text: $draft.permissionBypassFlag, prompt: Text("--yolo"))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .fontDesign(.monospaced)
                            .labelsHidden()
                    }
                    LabeledContent("Skills directory") {
                        TextField("", text: $draft.skillsDir, prompt: Text("~/.config/my-agent/skills"))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .fontDesign(.monospaced)
                            .labelsHidden()
                    }
                } footer: {
                    Text(localized("Both optional. The flag powers the agent’s “Skip permission prompts” switch; leave it empty if the CLI has none. The directory receives termio’s session-control skill (as `<dir>/termio`); leave it empty to skip installing one."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(localized("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? localized("Add") : localized("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
            .padding(12)
        }
        .frame(width: 440, height: 430)
    }

    /// The badge the agent will actually get: the typed symbol when the system
    /// resolves it, else the default terminal glyph — so the preview never lies.
    private var iconPreview: AgentIcon {
        let symbol = draft.symbol.trimmingCharacters(in: .whitespaces)
        guard !symbol.isEmpty,
              NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        else { return .terminalGlyph }
        return .symbol(symbol)
    }

    private func save() {
        do {
            let id = try UserAgentStore.save(draft, existingID: existing?.id)
            dismiss()
            onSave(id)
        } catch {
            saveError = error.localizedDescription
        }
    }
}
