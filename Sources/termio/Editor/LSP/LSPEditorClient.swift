import Foundation
import LanguageClient
import LanguageServerProtocol

/// The LSP side of one open editor buffer: announces the document (`didOpen`), keeps the server's
/// copy fresh with debounced whole-document `didChange`s, and answers the two questions the editor
/// asks — where is this symbol defined, and what is it (`hover`). Created only when a registered
/// server owns the file; the editor treats a `nil` client as "feature absent".
@MainActor
final class LSPEditorClient {
    private let server: InitializingServer
    private let uri: DocumentUri
    private let fileURL: URL
    private var version = 1
    /// The buffer text the server hasn't seen yet, and the debounce that will send it. Requests
    /// flush first, so a jump right after typing still resolves against the current text.
    private var unsentText: String?
    private var changeTask: Task<Void, Never>?

    /// Opens `url` against its project's server. `nil` when no server owns the file — the caller
    /// leaves every LSP hook dormant.
    static func attach(url: URL, text: String) async -> LSPEditorClient? {
        guard let connection = await LSPManager.shared.server(for: url) else { return nil }
        let client = LSPEditorClient(server: connection.server, url: url)
        await client.didOpen(text: text, languageID: connection.languageID)
        return client
    }

    private init(server: InitializingServer, url: URL) {
        self.server = server
        self.fileURL = url.standardizedFileURL
        self.uri = url.standardizedFileURL.absoluteString
    }

    private func didOpen(text: String, languageID: String) async {
        let item = TextDocumentItem(uri: uri, languageId: languageID, version: version, text: text)
        do {
            try await server.textDocumentDidOpen(DidOpenTextDocumentParams(textDocument: item))
        } catch {
            Log.lsp.error("didOpen failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Notes an edit; a short quiet period later the whole buffer is sent as one full-sync change
    /// (a rangeless change event is a full replace — every mainstream server accepts it, and it
    /// sidesteps incremental-diff bookkeeping entirely).
    func noteChange(fullText: String) {
        unsentText = fullText
        changeTask?.cancel()
        changeTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            await self.flushPendingChange()
        }
    }

    private func flushPendingChange() async {
        guard let text = unsentText else { return }
        unsentText = nil
        changeTask?.cancel()
        changeTask = nil
        version += 1
        let change = TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: text)
        do {
            try await server.textDocumentDidChange(
                DidChangeTextDocumentParams(uri: uri, version: version, contentChange: change)
            )
        } catch {
            Log.lsp.error("didChange failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Where the symbol at `utf16Offset` is defined: the target file plus 1-based line, or `nil`
    /// when the server has no answer. Multiple candidates collapse to the first — good enough for
    /// a jump, and menus can come later if it ever matters.
    func definition(at utf16Offset: Int, in text: String) async -> (url: URL, line: Int)? {
        await flushPendingChange()
        let position = LSPPositions.position(utf16Offset: utf16Offset, in: text as NSString)
        let response: DefinitionResponse
        do {
            response = try await server.definition(TextDocumentPositionParams(uri: uri, position: position))
        } catch {
            Log.lsp.error("definition failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let hit = Self.firstTarget(in: response) else { return nil }
        guard let url = URL(string: hit.uri), url.isFileURL else { return nil }
        return (url.standardizedFileURL, hit.range.start.line + 1)
    }

    private static func firstTarget(in response: DefinitionResponse) -> (uri: DocumentUri, range: LSPRange)? {
        switch response {
        case .optionA(let location):
            return (location.uri, location.range)
        case .optionB(let locations):
            return locations.first.map { ($0.uri, $0.range) }
        case .optionC(let links):
            return links.first.map { ($0.targetUri, $0.targetSelectionRange) }
        case nil:
            return nil
        }
    }

    /// The hover text for the symbol at `utf16Offset`, flattened to one markdown string
    /// (fenced when the server sent language-tagged code). `nil` when there's nothing to show.
    func hover(at utf16Offset: Int, in text: String) async -> String? {
        await flushPendingChange()
        let position = LSPPositions.position(utf16Offset: utf16Offset, in: text as NSString)
        let response: HoverResponse
        do {
            response = try await server.hover(TextDocumentPositionParams(uri: uri, position: position))
        } catch {
            Log.lsp.error("hover failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let hover = response else { return nil }
        let markdown: String
        switch hover.contents {
        case .optionA(let marked):
            markdown = Self.flatten(marked)
        case .optionB(let markedList):
            markdown = markedList.map(Self.flatten).joined(separator: "\n\n")
        case .optionC(let content):
            markdown = content.value
        }
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func flatten(_ marked: MarkedString) -> String {
        switch marked {
        case .optionA(let plain):
            return plain
        case .optionB(let code):
            return "```\(code.language)\n\(code.value)\n```"
        }
    }

    /// Tells the server the buffer is gone. Any still-pending edit is moot — the document is
    /// closing, and the file on disk is the auto-save's business, not the server's.
    func close() {
        changeTask?.cancel()
        unsentText = nil
        let uri = uri
        let server = server
        Task {
            try? await server.textDocumentDidClose(DidCloseTextDocumentParams(uri: uri))
        }
    }
}
