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
    /// Human-facing language name for the Languages settings pane ("TypeScript / JavaScript");
    /// the server id stands in when a user-config entry leaves it out.
    var name: String?
    /// The install command to surface when the binary is missing (`brew install gopls`).
    /// `nil` means the server ships with the system toolchain — nothing to install.
    var install: String?

    var displayName: String { name ?? id }
}

/// The language-server catalog behind the editor's go-to-definition/hover: which server owns a
/// file, and where its binary lives. Servers whose binary isn't installed simply don't resolve —
/// the feature is silently absent for that language, never a dialog.
enum LSPRegistry {
    static let builtin: [LSPServerDescriptor] = [
        // Ships with Xcode / the Command Line Tools — the one server that needs no install.
        LSPServerDescriptor(
            id: "sourcekit-lsp", command: "xcrun sourcekit-lsp",
            extensions: ["swift": "swift"],
            name: "Swift", install: nil
        ),
        LSPServerDescriptor(
            id: "typescript-language-server", command: "typescript-language-server --stdio",
            extensions: [
                "ts": "typescript", "mts": "typescript", "cts": "typescript",
                "tsx": "typescriptreact",
                "js": "javascript", "mjs": "javascript", "cjs": "javascript",
                "jsx": "javascriptreact",
            ],
            name: "TypeScript / JavaScript",
            install: "brew install typescript-language-server typescript"
        ),
        LSPServerDescriptor(
            id: "pyright", command: "pyright-langserver --stdio",
            extensions: ["py": "python", "pyi": "python"],
            name: "Python", install: "brew install pyright"
        ),
        LSPServerDescriptor(
            id: "gopls", command: "gopls",
            extensions: ["go": "go"],
            name: "Go", install: "brew install gopls"
        ),
        LSPServerDescriptor(
            id: "rust-analyzer", command: "rust-analyzer",
            extensions: ["rs": "rust"],
            name: "Rust", install: "brew install rust-analyzer"
        ),
        LSPServerDescriptor(
            id: "clangd", command: "clangd",
            extensions: [
                "c": "c", "h": "c",
                "cpp": "cpp", "cc": "cpp", "cxx": "cpp",
                "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
                "m": "objective-c", "mm": "objective-cpp",
            ],
            name: "C / C++ / Objective-C", install: nil
        ),
        LSPServerDescriptor(
            id: "jdtls", command: "jdtls",
            extensions: ["java": "java"],
            name: "Java", install: "brew install jdtls"
        ),
        LSPServerDescriptor(
            id: "kotlin-language-server", command: "kotlin-language-server",
            extensions: ["kt": "kotlin", "kts": "kotlin"],
            name: "Kotlin", install: "brew install kotlin-language-server"
        ),
        LSPServerDescriptor(
            id: "csharp-ls", command: "csharp-ls",
            extensions: ["cs": "csharp"],
            name: "C#", install: "dotnet tool install --global csharp-ls"
        ),
        LSPServerDescriptor(
            id: "ruby-lsp", command: "ruby-lsp",
            extensions: ["rb": "ruby"],
            name: "Ruby", install: "gem install ruby-lsp"
        ),
        LSPServerDescriptor(
            id: "intelephense", command: "intelephense --stdio",
            extensions: ["php": "php"],
            name: "PHP", install: "npm install -g intelephense"
        ),
        LSPServerDescriptor(
            id: "dart", command: "dart language-server",
            extensions: ["dart": "dart"],
            name: "Dart", install: "brew install dart-lang/dart/dart"
        ),
        LSPServerDescriptor(
            id: "metals", command: "metals",
            extensions: ["scala": "scala", "sc": "scala"],
            name: "Scala", install: "brew install metals"
        ),
        LSPServerDescriptor(
            id: "elixir-ls", command: "elixir-ls",
            extensions: ["ex": "elixir", "exs": "elixir"],
            name: "Elixir", install: "brew install elixir-ls"
        ),
        LSPServerDescriptor(
            id: "erlang_ls", command: "erlang_ls",
            extensions: ["erl": "erlang", "hrl": "erlang"],
            name: "Erlang", install: "brew install erlang_ls"
        ),
        LSPServerDescriptor(
            id: "haskell-language-server", command: "haskell-language-server-wrapper --lsp",
            extensions: ["hs": "haskell"],
            name: "Haskell", install: "brew install haskell-language-server"
        ),
        LSPServerDescriptor(
            id: "lua-language-server", command: "lua-language-server",
            extensions: ["lua": "lua"],
            name: "Lua", install: "brew install lua-language-server"
        ),
        LSPServerDescriptor(
            id: "clojure-lsp", command: "clojure-lsp",
            extensions: ["clj": "clojure", "cljs": "clojure", "cljc": "clojure", "edn": "clojure"],
            name: "Clojure", install: "brew install clojure-lsp"
        ),
        LSPServerDescriptor(
            id: "zls", command: "zls",
            extensions: ["zig": "zig"],
            name: "Zig", install: "brew install zls"
        ),
        LSPServerDescriptor(
            id: "ocamllsp", command: "ocamllsp",
            extensions: ["ml": "ocaml", "mli": "ocaml"],
            name: "OCaml", install: "opam install ocaml-lsp-server"
        ),
        LSPServerDescriptor(
            id: "bash-language-server", command: "bash-language-server start",
            extensions: ["sh": "shellscript", "bash": "shellscript", "zsh": "shellscript"],
            name: "Shell", install: "brew install bash-language-server"
        ),
        LSPServerDescriptor(
            id: "vscode-html-language-server", command: "vscode-html-language-server --stdio",
            extensions: ["html": "html", "htm": "html"],
            name: "HTML", install: "npm install -g vscode-langservers-extracted"
        ),
        LSPServerDescriptor(
            id: "vscode-css-language-server", command: "vscode-css-language-server --stdio",
            extensions: ["css": "css", "scss": "scss", "less": "less"],
            name: "CSS", install: "npm install -g vscode-langservers-extracted"
        ),
        LSPServerDescriptor(
            id: "vscode-json-language-server", command: "vscode-json-language-server --stdio",
            extensions: ["json": "json", "jsonc": "jsonc"],
            name: "JSON", install: "npm install -g vscode-langservers-extracted"
        ),
        LSPServerDescriptor(
            id: "yaml-language-server", command: "yaml-language-server --stdio",
            extensions: ["yml": "yaml", "yaml": "yaml"],
            name: "YAML", install: "brew install yaml-language-server"
        ),
        LSPServerDescriptor(
            id: "taplo", command: "taplo lsp stdio",
            extensions: ["toml": "toml"],
            name: "TOML", install: "brew install taplo"
        ),
        LSPServerDescriptor(
            id: "marksman", command: "marksman server",
            extensions: ["md": "markdown", "markdown": "markdown"],
            name: "Markdown", install: "brew install marksman"
        ),
        LSPServerDescriptor(
            id: "vue-language-server", command: "vue-language-server --stdio",
            extensions: ["vue": "vue"],
            name: "Vue", install: "npm install -g @vue/language-server"
        ),
        LSPServerDescriptor(
            id: "svelteserver", command: "svelteserver --stdio",
            extensions: ["svelte": "svelte"],
            name: "Svelte", install: "npm install -g svelte-language-server"
        ),
        LSPServerDescriptor(
            id: "terraform-ls", command: "terraform-ls serve",
            extensions: ["tf": "terraform", "tfvars": "terraform-vars"],
            name: "Terraform", install: "brew install hashicorp/tap/terraform-ls"
        ),
    ]

    /// `~/.termio[-dev]/config/lsp.json`, beside the agent manifests. Internal so the Languages
    /// settings pane can point users at it.
    static var configURL: URL {
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
