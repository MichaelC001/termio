import Foundation
import Markdown

/// Markdown → HTML, shared by the session trace (agent messages) and the file-preview
/// Markdown reader. Built on Apple's swift-markdown (cmark-gfm underneath, so GFM tables /
/// strikethrough / task lists parse correctly). We walk the AST and emit HTML ourselves
/// instead of using a stock formatter so every piece of source text is escaped (transcripts
/// carry untrusted tool output, so raw HTML in the markdown renders as text, never as
/// markup). Soft-break handling differs per caller — see `softBreaksAsBreaks`.
enum MarkdownHTML {
    /// `softBreaksAsBreaks`: agent messages use single newlines for line-based content, so
    /// the trace renders each as `<br>`. A *document* (README, design doc) hard-wraps its
    /// source at ~80 columns and expects those newlines to collapse to spaces and reflow to
    /// the viewport — pass `false` there, or every source line break becomes a literal break
    /// (ragged short lines, big right-hand gap, and no reflow on resize).
    static func html(_ source: String, softBreaksAsBreaks: Bool = true) -> String {
        var visitor = HTMLVisitor(softBreaksAsBreaks: softBreaksAsBreaks)
        return visitor.visit(Document(parsing: source))
    }
}

private struct HTMLVisitor: MarkupVisitor {
    typealias Result = String
    let softBreaksAsBreaks: Bool

    mutating func defaultVisit(_ markup: Markup) -> String {
        children(markup)
    }

    private mutating func children(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    // MARK: Blocks

    mutating func visitParagraph(_ p: Paragraph) -> String {
        "<p>\(children(p))</p>"
    }

    mutating func visitHeading(_ h: Heading) -> String {
        "<h\(h.level)>\(children(h))</h\(h.level)>"
    }

    mutating func visitCodeBlock(_ c: CodeBlock) -> String {
        let lang = (c.language?.isEmpty == false)
            ? " class=\"language-\(escape(c.language!))\"" : ""
        let code = c.code.hasSuffix("\n") ? String(c.code.dropLast()) : c.code
        return "<pre><code\(lang)>\(escape(code))</code></pre>"
    }

    mutating func visitBlockQuote(_ q: BlockQuote) -> String {
        "<blockquote>\(children(q))</blockquote>"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        "<ul>\(children(list))</ul>"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        "<ol>\(children(list))</ol>"
    }

    mutating func visitListItem(_ item: ListItem) -> String {
        let box: String
        switch item.checkbox {
        case .checked: box = "☑ "
        case .unchecked: box = "☐ "
        case nil: box = ""
        }
        return "<li>\(box)\(children(item))</li>"
    }

    mutating func visitThematicBreak(_ hr: ThematicBreak) -> String {
        "<hr>"
    }

    /// Raw HTML in the source is untrusted transcript content — show it, don't run it.
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        "<p>\(escape(html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)))</p>"
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) -> String {
        "<table>\(children(table))</table>"
    }

    mutating func visitTableHead(_ head: Table.Head) -> String {
        let cells = head.children.map { "<th>\(children($0))</th>" }.joined()
        return "<thead><tr>\(cells)</tr></thead>"
    }

    mutating func visitTableBody(_ body: Table.Body) -> String {
        "<tbody>\(children(body))</tbody>"
    }

    mutating func visitTableRow(_ row: Table.Row) -> String {
        let cells = row.children.map { "<td>\(children($0))</td>" }.joined()
        return "<tr>\(cells)</tr>"
    }

    // MARK: Inline

    mutating func visitText(_ text: Markdown.Text) -> String {
        escape(text.string)
    }

    mutating func visitInlineCode(_ code: InlineCode) -> String {
        "<code>\(escape(code.code))</code>"
    }

    mutating func visitEmphasis(_ em: Emphasis) -> String {
        "<em>\(children(em))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(children(strong))</strong>"
    }

    mutating func visitStrikethrough(_ s: Strikethrough) -> String {
        "<del>\(children(s))</del>"
    }

    /// Only web links become anchors; anything else (`javascript:`, `file:`, relative
    /// paths) renders as its label text.
    mutating func visitLink(_ link: Link) -> String {
        guard let dest = link.destination,
              dest.hasPrefix("https://") || dest.hasPrefix("http://") else {
            return children(link)
        }
        return "<a href=\"\(escape(dest))\">\(children(link))</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let alt = children(image)
        return "<span class=\"image\">🖼 \(alt.isEmpty ? "image" : alt)</span>"
    }

    mutating func visitInlineHTML(_ html: InlineHTML) -> String {
        escape(html.rawHTML)
    }

    mutating func visitSoftBreak(_ br: SoftBreak) -> String {
        // A document collapses source line breaks to spaces (normal Markdown) so text
        // reflows; the trace keeps them as `<br>` for line-based agent output.
        softBreaksAsBreaks ? "<br>" : " "
    }

    mutating func visitLineBreak(_ br: LineBreak) -> String {
        "<br>"
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
