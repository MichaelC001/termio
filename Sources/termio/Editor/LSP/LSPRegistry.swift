import Foundation

/// One language server: how to launch it and which files it owns. The built-in table covers the
/// common toolchains; users extend or override it by dropping descriptors into
/// `~/.termio[-dev]/config/lsp.json` (an array of these, same shape — an entry with a built-in's
/// `id` replaces it wholesale, a new `id` appends).
struct LSPServerDescriptor: Codable, Identifiable {
    /// Stable name, also the merge key ("sourcekit-lsp", "gopls", …).
    var id: String
    /// The launch command; the first word is resolved on the login-shell PATH.
    var command: String
    /// File extension → LSP language id. These are the *LSP* ids (`typescriptreact`), not the
    /// highlight.js grammar names the editor's syntax coloring uses — the two vocabularies differ.
    var extensions: [String: String]
}

/// The language-server catalog behind the editor's go-to-definition/hover: which server owns a
/// file, and where its binary lives. Servers whose binary isn't installed simply don't resolve —
/// the feature is silently absent for that language, never a dialog.
enum LSPRegistry {
    static let builtin: [LSPServerDescriptor] = [
        // Ships with Xcode / the Command Line Tools — the one server that needs no install.
        LSPServerDescriptor(
            id: "sourcekit-lsp", command: "xcrun sourcekit-lsp",
            extensions: ["swift": "swift"]
        ),
        LSPServerDescriptor(
            id: "typescript-language-server", command: "typescript-language-server --stdio",
            extensions: [
                "ts": "typescript", "mts": "typescript", "cts": "typescript",
                "tsx": "typescriptreact",
                "js": "javascript", "mjs": "javascript", "cjs": "javascript",
                "jsx": "javascriptreact",
            ]
        ),
        LSPServerDescriptor(
            id: "pyright", command: "pyright-langserver --stdio",
            extensions: ["py": "python", "pyi": "python"]
        ),
        LSPServerDescriptor(
            id: "gopls", command: "gopls",
            extensions: ["go": "go"]
        ),
        LSPServerDescriptor(
            id: "rust-analyzer", command: "rust-analyzer",
            extensions: ["rs": "rust"]
        ),
        LSPServerDescriptor(
            id: "clangd", command: "clangd",
            extensions: [
                "c": "c", "h": "c",
                "cpp": "cpp", "cc": "cpp", "cxx": "cpp",
                "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
                "m": "objective-c", "mm": "objective-cpp",
            ]
        ),
    ]

    /// `~/.termio[-dev]/config/lsp.json`, beside the agent manifests.
    private static var configURL: URL {
        AppChannel.homeConfigDirectory
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("lsp.json")
    }

    /// Built-ins merged with the user's config file, computed once per app run — the same
    /// load-at-launch contract the agent manifests have.
    static let descriptors: [LSPServerDescriptor] = {
        var merged = builtin
        guard let data = try? Data(contentsOf: configURL) else { return merged }
        do {
            let custom = try JSONDecoder().decode([LSPServerDescriptor].self, from: data)
            for descriptor in custom {
                if let index = merged.firstIndex(where: { $0.id == descriptor.id }) {
                    merged[index] = descriptor
                } else {
                    merged.append(descriptor)
                }
            }
        } catch {
            Log.lsp.error("lsp.json invalid, using built-ins: \(String(describing: error), privacy: .public)")
        }
        return merged
    }()

    /// The server owning `url`'s extension, and the LSP language id it should be announced as.
    static func descriptor(for url: URL) -> (descriptor: LSPServerDescriptor, languageID: String)? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        for descriptor in descriptors {
            if let languageID = descriptor.extensions[ext] { return (descriptor, languageID) }
        }
        return nil
    }

    /// Splits a descriptor's command into an absolute binary path plus arguments, resolving the
    /// first word against the login-shell PATH (the same probe the Agents settings use — a
    /// Finder-launched app's own PATH has no homebrew). `nil` when the binary isn't installed.
    static func resolveLaunch(_ command: String) async -> (binary: String, arguments: [String])? {
        // Same trimming as `AgentAvailability.isCommandAvailable`, so the two PATH views agree.
        var words = command.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard let first = words.first, !first.isEmpty else { return nil }
        words.removeFirst()
        if first.hasPrefix("/") || first.hasPrefix("~") {
            let path = (first as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? (path, words) : nil
        }
        for directory in await AgentAvailability.pathDirectories() {
            let candidate = directory + "/" + first
            if FileManager.default.isExecutableFile(atPath: candidate) { return (candidate, words) }
        }
        return nil
    }
}
