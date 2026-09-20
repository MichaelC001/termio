import AppKit
import CoreGraphics
import CryptoKit
import PDFKit
import Foundation
import SwiftUI

/// One highlighted passage: the per-line rectangles it covers on a single page, plus the
/// text it quotes so the sidebar can list it (and "Add to Chat" can send it) without
/// re-extracting anything from the document.
///
/// Rectangles are in PDF page space — origin bottom-left, unrotated — which is the space
/// `PDFSelection.bounds(for:)` returns and `PDFAnnotation(bounds:)` expects, so a mark
/// survives zooming, window resizes, and reopening.
struct PDFHighlight: Codable, Identifiable, Hashable {
    var id: UUID
    /// Zero-based page index in the document.
    var page: Int
    /// One rect per typeset line the selection covered. Separate rects rather than one
    /// union: a selection that starts mid-line would otherwise paint over the words
    /// before it.
    var rects: [Rect]
    /// The quoted text, already unwrapped by `PDFSelectionText`.
    var text: String
    /// The marker's color. Absent in sidecars written before colors existed, which read
    /// back as the default.
    var color: PDFHighlightColor?

    var ink: PDFHighlightColor { color ?? .yellow }

    /// What makes two marks the same mark when they come from different places — the
    /// sidecar and the file's own annotations. Ids don't survive a round trip through a
    /// PDF written by anything but us (Preview's highlights have no id at all), so a mark
    /// is identified by where it sits on the page, rounded to half a point.
    var placement: Placement {
        Placement(page: page, rects: rects.map {
            [($0.x * 2).rounded(), ($0.y * 2).rounded(),
             ($0.width * 2).rounded(), ($0.height * 2).rounded()]
        })
    }

    struct Placement: Hashable {
        let page: Int
        let rects: [[Double]]
    }

    init(id: UUID = UUID(), page: Int, rects: [Rect], text: String, color: PDFHighlightColor = .yellow) {
        self.id = id
        self.page = page
        self.rects = rects
        self.text = text
        self.color = color
    }

    /// `CGRect` isn't `Codable` in a shape that reads well on disk, so the file carries
    /// four numbers per line.
    private enum CodingKeys: String, CodingKey { case id, page, rects, text, color }

    struct Rect: Codable, Hashable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.size.width
            height = rect.size.height
        }

        var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
}

/// The marker colors, Apple Books' set. A highlight is content the reader puts *into*
/// someone else's document — unlike the app's own chrome, which stays monochrome — so the
/// familiar five are what people reach for. PDFKit composites highlight annotations
/// multiplicatively, so each is a saturated ink laid down at low alpha: the band shows,
/// the words underneath stay black.
enum PDFHighlightColor: String, Codable, CaseIterable, Hashable {
    case yellow, green, blue, pink, purple

    /// sRGB, not calibrated RGB: a PDF stores raw components, so a calibrated color would
    /// be written as different numbers than the ones the screen was showing and the mark
    /// would change shade the moment it was saved into the book.
    ///
    /// Opaque, and deliberately so. A PDF highlight annotation carries only its color —
    /// PDFKit's writer drops the constant-alpha entry — so a translucent ink would look
    /// one way on screen and another once the mark is saved into the book. Viewers
    /// composite highlights multiplicatively, which is what keeps the words legible under
    /// a solid pastel, and is why Preview's own yellow behaves the same way.
    var annotationColor: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 1.00, green: 0.89, blue: 0.42, alpha: 1)
        case .green: return NSColor(srgbRed: 0.68, green: 0.90, blue: 0.62, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.62, green: 0.81, blue: 1.00, alpha: 1)
        case .pink: return NSColor(srgbRed: 1.00, green: 0.70, blue: 0.78, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.81, green: 0.74, blue: 1.00, alpha: 1)
        }
    }

    /// The swatch in the selection popover and the dot in the highlights rail: the same
    /// ink the page gets, so the palette and the mark can't drift apart.
    var swatchColor: Color { Color(nsColor: annotationColor) }

    var label: String {
        switch self {
        case .yellow: return localized("Yellow")
        case .green: return localized("Green")
        case .blue: return localized("Blue")
        case .pink: return localized("Pink")
        case .purple: return localized("Purple")
        }
    }
}

/// Where a document's marks live: a JSON sidecar, never the PDF.
///
/// The PDF is left alone on purpose. Writing marks into it means a new multi-megabyte
/// binary in the repo on every highlight — a diff nobody can review and a blob the history
/// carries forever. A sidecar is one line per mark, so a review shows what was marked, and
/// `git status` stays about the work.
///
/// Inside a repo the sidecar goes **with the repo** (`.termio/pdf/<path to the file>.json`),
/// so marks can be committed, reviewed, and read by an agent working in that checkout — and
/// they survive the document being re-exported, because the key is the path, not the bytes.
/// A document outside any repo has nowhere to file that, so it falls back to the app's own
/// storage, keyed by content hash.
enum PDFHighlightStore {
    /// What a sidecar records about the document it belongs to. Two independent ways back
    /// to that document, because either one alone has a case it loses:
    ///
    /// - `document` — the path, repo-relative inside a checkout (an absolute path in a file
    ///   meant to be committed is somebody else's machine). Survives the PDF being
    ///   re-exported in place; lost when the file is renamed.
    /// - `contentHash` — the file's bytes. Survives a rename or a move; lost when the file
    ///   is regenerated.
    ///
    /// Together they cover every case but "renamed *and* re-exported", which nothing short
    /// of asking the user could resolve.
    private struct Sidecar: Codable {
        var document: String
        var highlights: [PDFHighlight]
        var fingerprint: String?
        /// A whole-file hash, written by earlier versions. Only ever read, so a sidecar
        /// made before identifiers were used still matches its document.
        var contentHash: String?
        /// The document's page count when the marks were made — the guard against adopting
        /// a genuinely different document that happens to sit at the same path.
        var pageCount: Int?

        private enum CodingKeys: String, CodingKey {
            case document, highlights, fingerprint, contentHash, pageCount
            /// Sidecars written before the field was renamed.
            case path
        }

        init(document: String, highlights: [PDFHighlight], fingerprint: String?, pageCount: Int?) {
            self.document = document
            self.highlights = highlights
            self.fingerprint = fingerprint
            self.pageCount = pageCount
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(document, forKey: .document)
            try values.encode(highlights, forKey: .highlights)
            try values.encodeIfPresent(fingerprint, forKey: .fingerprint)
            try values.encodeIfPresent(pageCount, forKey: .pageCount)
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            document = try values.decodeIfPresent(String.self, forKey: .document)
                ?? values.decodeIfPresent(String.self, forKey: .path) ?? ""
            highlights = try values.decode([PDFHighlight].self, forKey: .highlights)
            fingerprint = try values.decodeIfPresent(String.self, forKey: .fingerprint)
            contentHash = try values.decodeIfPresent(String.self, forKey: .contentHash)
            pageCount = try values.decodeIfPresent(Int.self, forKey: .pageCount)
        }
    }

    /// The two homes a document's marks can have.
    enum Store: Equatable {
        /// `<repo>/.termio/pdf/<path relative to the repo>.json`, mirroring the repo's own
        /// tree so a marked-up paper's sidecar sits where you'd look for it.
        case project(URL)
        /// The app's storage, keyed by the file's content hash — for documents that belong
        /// to no repo.
        case support(key: String)
    }

    static func store(for url: URL) -> Store? {
        if let root = GitRoot.find(for: url) {
            let relative = url.standardizedFileURL.path
                .replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
            return .project(root
                .appendingPathComponent(".termio/pdf", isDirectory: true)
                .appendingPathComponent(relative + ".json"))
        }
        return fingerprint(for: url).map { .support(key: $0) }
    }

    static var directory: URL {
        AppChannel.supportDirectory.appendingPathComponent("PDFHighlights", isDirectory: true)
    }

    /// How a document identifies itself to its sidecar: where it sits, what it contains,
    /// and how many pages it has. Computed once when the document opens — the hash reads
    /// the whole file, which is not something to redo on every highlight.
    struct Identity {
        /// The path the sidecar records: repo-relative inside a checkout (an absolute path
        /// in a file meant to be committed is somebody else's machine), absolute otherwise.
        let document: String
        /// The document's own identifier — see `fingerprint(for:)`.
        let fingerprint: String?
        let pageCount: Int?

        static func of(_ url: URL, pageCount: Int?) -> Identity {
            let path = url.standardizedFileURL.path
            let relative = GitRoot.find(for: url)
                .map { path.replacingOccurrences(of: $0.standardizedFileURL.path + "/", with: "") }
            return Identity(document: relative ?? path,
                            fingerprint: PDFHighlightStore.fingerprint(for: url),
                            pageCount: pageCount)
        }
    }

    static func load(for url: URL) -> [PDFHighlight] {
        guard let store = store(for: url) else { return [] }
        return load(from: store, identity: .of(url, pageCount: nil))
    }

    /// The marks for a document — including ones filed before it was renamed or rewritten.
    ///
    /// Resolution runs strongest signal first:
    ///
    /// 1. A sidecar exactly where this document's would be written.
    /// 2. One whose `contentHash` matches these bytes — the same document under a new name,
    ///    so the marks move with it.
    /// 3. One written for this same path with the same page count — the document was
    ///    re-exported in place, so the pages didn't move and the rectangles still hold.
    ///
    /// An adopted sidecar is re-filed under the current identity and the old one deleted,
    /// so a rename or a re-export is paid for once.
    static func load(from store: Store, identity: Identity) -> [PDFHighlight] {
        if let own = sidecar(at: fileURL(for: store)) { return own.highlights }
        guard let (origin, adopted) = orphan(matching: identity, near: store) else { return [] }
        write(adopted.highlights, to: store, identity: identity)
        try? FileManager.default.removeItem(at: origin)
        Log.files.info("pdf highlights: adopted \(adopted.highlights.count, privacy: .public) marks from \(origin.lastPathComponent, privacy: .public)")
        return adopted.highlights
    }

    /// Best-effort, atomic. A failed save loses marks, which is recoverable; trapping is
    /// not, and neither is refusing to show the document because its sidecar won't write.
    static func save(_ highlights: [PDFHighlight], to store: Store, identity: Identity) {
        write(highlights, to: store, identity: identity)
    }

    private static func write(_ highlights: [PDFHighlight], to store: Store, identity: Identity) {
        let target = fileURL(for: store)
        do {
            if highlights.isEmpty {
                try? FileManager.default.removeItem(at: target)
                return
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let sidecar = Sidecar(document: identity.document, highlights: highlights,
                                  fingerprint: identity.fingerprint, pageCount: identity.pageCount)
            try encoder.encode(sidecar).write(to: target, options: .atomic)
        } catch {
            Log.files.error("pdf highlights: save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func fileURL(for store: Store) -> URL {
        switch store {
        case let .project(url): return url
        case let .support(key): return directory.appendingPathComponent("\(key).json")
        }
    }

    /// A sidecar for this same document filed under an earlier name or an earlier version.
    /// Searched only where this document's own sidecar would live — a project's
    /// `.termio/pdf` tree, or the app's storage. A repo's marks are the repo's.
    private static func orphan(matching identity: Identity, near store: Store) -> (URL, Sidecar)? {
        var byPath: (URL, Sidecar)?
        for entry in sidecarFiles(near: store) {
            guard let sidecar = sidecar(at: entry) else { continue }
            // The document's own identifier is the strong signal: the same book, renamed,
            // moved, or re-saved with something added to it.
            if let fingerprint = identity.fingerprint, sidecar.fingerprint == fingerprint {
                return (entry, sidecar)
            }
            // The path is the weak one: same place, different bytes — a re-export. Taken
            // only if nothing matches by content, and only if the pages didn't move.
            if byPath == nil, sidecar.document == identity.document,
               identity.pageCount == nil || sidecar.pageCount == nil
                || sidecar.pageCount == identity.pageCount {
                byPath = (entry, sidecar)
            }
        }
        return byPath
    }

    private static func sidecarFiles(near store: Store) -> [URL] {
        let base: URL
        switch store {
        case let .project(url):
            // Walk back up to the `.termio/pdf` root: the sidecar tree mirrors the repo's,
            // so a file renamed into another folder is still found.
            var directory = url.deletingLastPathComponent()
            while directory.path != "/", directory.lastPathComponent != "pdf" {
                directory = directory.deletingLastPathComponent()
            }
            base = directory
        case .support:
            base = directory
        }
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
    }

    private static func sidecar(at url: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    /// What identifies a PDF as *this* document, whatever it is called and however it has
    /// been updated since.
    ///
    /// The PDF specification puts a file identifier in the trailer — `/ID [permanent,
    /// changing]` — whose first string is fixed when the file is created and, per spec,
    /// must not change when the file is updated. That is exactly the question a sidecar
    /// asks, so it is the key: a book that is renamed, moved, or re-saved with a table of
    /// contents added keeps its marks with no further work. It is also nearly free to read,
    /// where hashing a 200 MB scan is not.
    ///
    /// Roughly 5% of PDFs carry no identifier, so those fall back to a hash of the first
    /// kilobyte — the same rule PDF.js and Hypothesis use, and the reason the two forms are
    /// prefixed: an `id-` key and an `h-` key can never be confused for one another.
    ///
    /// Not a guarantee, and it doesn't pretend to be: identifiers are not unique by
    /// construction, and a writer that ignores the spec will mint a new one (PDFKit's own
    /// `write(to:)` does — verified against this book). The sidecar keeps the path and the
    /// page count as weaker signals for exactly those cases.
    static func fingerprint(for url: URL) -> String? {
        if let identifier = permanentIdentifier(of: url) { return "id-" + identifier }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1024), !head.isEmpty else { return nil }
        return "h-" + SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
    }

    private static func permanentIdentifier(of url: URL) -> String? {
        guard let document = CGPDFDocument(url as CFURL),
              let identifiers = document.fileIdentifier else { return nil }
        var string: CGPDFStringRef?
        guard CGPDFArrayGetString(identifiers, 0, &string), let string,
              let bytes = CGPDFStringGetBytePtr(string) else { return nil }
        let length = CGPDFStringGetLength(string)
        guard length > 0 else { return nil }
        return (0..<length).map { String(format: "%02x", bytes[$0]) }.joined()
    }


    /// The marks the document itself carries    /// The marks the document itself carries — ours from a previous save, and anyone
    /// else's: a book highlighted in Preview or Books lists its marks here too. Without
    /// this the rail could only ever show what termio had written, which made a marked-up
    /// book look untouched.
    ///
    /// Our own marks are one annotation per typeset line sharing a `userName`, so they are
    /// regrouped by it. A foreign highlight is one annotation carrying several quads, and
    /// stands on its own.
    static func marksInDocument(_ document: PDFDocument) -> [PDFHighlight] {
        var marks: [PDFHighlight] = []
        var grouped: [String: (page: Int, rects: [PDFHighlight.Rect], text: String)] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Highlight" {
                let rect = PDFHighlight.Rect(annotation.bounds)
                let quoted = quotedText(of: annotation, on: page)
                guard let name = annotation.userName, UUID(uuidString: name) != nil else {
                    marks.append(PDFHighlight(page: index, rects: [rect], text: quoted,
                                              color: nearestColor(annotation.color)))
                    continue
                }
                var entry = grouped[name] ?? (index, [], "")
                entry.rects.append(rect)
                entry.text = entry.text.isEmpty ? quoted : entry.text
                grouped[name] = entry
            }
        }
        for (name, entry) in grouped {
            marks.append(PDFHighlight(id: UUID(uuidString: name) ?? UUID(), page: entry.page,
                                      rects: entry.rects, text: entry.text,
                                      color: colorOfGroup(named: name, in: document) ?? .yellow))
        }
        return marks
    }

    /// An annotation's own note if it carries one, otherwise the words underneath it.
    private static func quotedText(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        if let contents = annotation.contents, !contents.isEmpty {
            return PDFSelectionText.unwrapped(contents)
        }
        guard let text = page.selection(for: annotation.bounds)?.string else { return "" }
        return PDFSelectionText.unwrapped(text)
    }

    private static func colorOfGroup(named name: String, in document: PDFDocument) -> PDFHighlightColor? {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let match = page.annotations.first(where: { $0.userName == name }) {
                return nearestColor(match.color)
            }
        }
        return nil
    }

    /// The palette entry a foreign highlight's color is closest to, so the rail can show a
    /// dot for a mark made in another app. The page keeps the color it was written with.
    static func nearestColor(_ color: NSColor?) -> PDFHighlightColor {
        guard let sample = color?.usingColorSpace(.sRGB) else { return .yellow }
        return PDFHighlightColor.allCases.min { lhs, rhs in
            distance(sample, lhs) < distance(sample, rhs)
        } ?? .yellow
    }

    private static func distance(_ color: NSColor, _ candidate: PDFHighlightColor) -> CGFloat {
        guard let other = candidate.annotationColor.usingColorSpace(.sRGB) else { return .greatestFiniteMagnitude }
        let red = color.redComponent - other.redComponent
        let green = color.greenComponent - other.greenComponent
        let blue = color.blueComponent - other.blueComponent
        return red * red + green * green + blue * blue
    }

    /// Writes the marks into the PDF itself, as annotations another reader can see.
    ///
    /// A reconcile, not an append: the file is made to match the mark list, so a mark
    /// removed or re-inked on screen is removed or re-inked in the book too. Marks already
    /// in place are left alone, which is what makes a second save a no-op rather than a
    /// second coat of ink.
    ///
    /// The document is opened fresh here rather than handed in: this runs off the main
    /// thread, and PDFKit objects belong to whoever opened them. The result is written
    /// beside the original and swapped in atomically, so an interrupted save leaves the
    /// book as it was.
    ///
    /// Returns false, having changed nothing, if the document can't be opened or written.
    static func reconcile(_ marks: [PDFHighlight], into url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }
        let wanted = Dictionary(marks.map { ($0.placement, $0) }, uniquingKeysWith: { first, _ in first })
        var present: Set<PDFHighlight.Placement> = []
        var changed = false

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Highlight" {
                // Our own marks are one annotation per line, so a line belongs to whichever
                // wanted mark covers it; a foreign mark stands alone.
                let single = PDFHighlight(page: index, rects: [PDFHighlight.Rect(annotation.bounds)],
                                          text: "").placement
                let owner = wanted.keys.first { key in
                    key.page == index && key.rects.contains(single.rects[0])
                }
                guard let owner else {
                    page.removeAnnotation(annotation)
                    changed = true
                    continue
                }
                present.insert(owner)
                if let mark = wanted[owner], annotation.color != mark.ink.annotationColor {
                    annotation.color = mark.ink.annotationColor
                    changed = true
                }
            }
        }

        for mark in marks where !present.contains(mark.placement) {
            guard let page = document.page(at: mark.page) else { continue }
            for rect in mark.rects {
                let annotation = PDFAnnotation(bounds: rect.cgRect, forType: .highlight,
                                               withProperties: nil)
                annotation.color = mark.ink.annotationColor
                annotation.userName = mark.id.uuidString
                annotation.contents = mark.text
                page.addAnnotation(annotation)
            }
            changed = true
        }

        guard changed else { return true }
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).termio-marks")
        guard document.write(to: staged) else {
            try? FileManager.default.removeItem(at: staged)
            Log.files.error("pdf highlights: could not write the marked copy")
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staged)
            Log.files.error("pdf highlights: could not replace the document: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

}
