import XCTest
@testable import termio

/// The document-mode HTML whitelist: the boundary where README markup becomes real
/// layout while script vectors must die. Each case pins one edge of that boundary.
final class HTMLSanitizerTests: XCTestCase {
    func testWhitelistedLayoutTablePassesThrough() {
        let html = #"<table><tr><td width="50%" valign="middle"><img src="web/shot.png" alt="a" width="100%" /></td></tr></table>"#
        let out = HTMLSanitizer.sanitize(html)
        XCTAssertEqual(
            out,
            #"<table><tr><td width="50%" valign="middle"><img src="web/shot.png" alt="a" width="100%"></td></tr></table>"#
        )
    }

    func testScriptAndHandlersDie() {
        XCTAssertEqual(
            HTMLSanitizer.sanitize("<script>alert(1)</script>"),
            "&lt;script&gt;alert(1)&lt;/script&gt;"
        )
        // The tag survives; the handler, style, and class do not.
        XCTAssertEqual(
            HTMLSanitizer.sanitize(#"<img src="x.png" onerror="alert(1)" style="x" class="y">"#),
            #"<img src="x.png">"#
        )
    }

    func testJavascriptURLsDropped() {
        XCTAssertEqual(HTMLSanitizer.sanitize(#"<a href="javascript:alert(1)">x</a>"#), "<a>x</a>")
        XCTAssertEqual(HTMLSanitizer.sanitize(#"<img src="data:text/html,x">"#), "<img>")
    }

    func testCommentsDropAndDetailsKeepOpen() {
        XCTAssertEqual(
            HTMLSanitizer.sanitize("<!-- hidden -->\n<details open><summary>t</summary></details>"),
            "\n<details open><summary>t</summary></details>"
        )
    }

    func testSafeURL() {
        XCTAssertTrue(HTMLSanitizer.safeURL("https://x.y/z", allowRelative: false))
        XCTAssertTrue(HTMLSanitizer.safeURL("docs/a.png", allowRelative: true))
        XCTAssertTrue(HTMLSanitizer.safeURL("#anchor", allowRelative: true))
        XCTAssertFalse(HTMLSanitizer.safeURL("docs/a.png", allowRelative: false))
        XCTAssertFalse(HTMLSanitizer.safeURL("javascript:x", allowRelative: true))
        XCTAssertFalse(HTMLSanitizer.safeURL("JAVASCRIPT:x", allowRelative: true))
    }

    func testDocumentModeImageAndTranscriptPlaceholder() {
        let md = "![shot](web/shot.png)"
        XCTAssertTrue(
            MarkdownHTML.html(md, documentMode: true).contains(#"<img src="web/shot.png" alt="shot">"#))
        XCTAssertTrue(MarkdownHTML.html(md).contains("🖼 shot"))
    }

    func testTranscriptModeStillEscapesRawHTML() {
        XCTAssertFalse(MarkdownHTML.html("<table><tr><td>x</td></tr></table>").contains("<table>"))
    }
}

/// The GitHub-flavored constructs cmark-gfm doesn't give us: anchors, autolinks, alerts,
/// emoji, footnotes, math and highlighted fences. Each case pins the behavior a document
/// written for GitHub expects to see in the reader.
final class MarkdownGitHubFeatureTests: XCTestCase {
    // MARK: Heading anchors

    func testHeadingsGetSlugIDsAndDeduplicate() {
        let html = MarkdownHTML.html("# Design Notes\n\n## Design Notes\n", documentMode: true)
        XCTAssertTrue(html.contains(#"<h1 id="design-notes">"#))
        XCTAssertTrue(html.contains(#"<h2 id="design-notes-1">"#))
    }

    func testHeadingSlugDropsPunctuationAndKeepsCase() {
        let html = MarkdownHTML.html("### What's *new* in v0.34?\n", documentMode: true)
        XCTAssertTrue(html.contains(#"id="whats-new-in-v034""#), html)
    }

    // MARK: Autolinks

    func testBareURLBecomesALink() {
        let html = MarkdownHTML.html("See https://termio.sh/docs for more.")
        XCTAssertTrue(html.contains(#"<a href="https://termio.sh/docs">https://termio.sh/docs</a>"#), html)
    }

    func testTrailingSentencePunctuationStaysOutsideTheLink() {
        let html = MarkdownHTML.html("Read https://termio.sh/docs.")
        XCTAssertTrue(html.contains(#"<a href="https://termio.sh/docs">"#), html)
        XCTAssertTrue(html.hasSuffix(".</p>"), html)
    }

    func testWWWLinksGetAScheme() {
        XCTAssertTrue(MarkdownHTML.html("www.termio.sh").contains(#"<a href="http://www.termio.sh">"#))
    }

    func testAutolinkNeverNestsInsideAMarkdownLink() {
        let html = MarkdownHTML.html("[https://a.example](https://b.example)")
        XCTAssertEqual(html, #"<p><a href="https://b.example">https://a.example</a></p>"#)
    }

    func testEmailsAndBareWordsAreNotLinked() {
        XCTAssertFalse(MarkdownHTML.html("write to hi@termio.sh").contains("<a "))
        XCTAssertFalse(MarkdownHTML.html("the whole thing").contains("<a "))
    }

    // MARK: Alerts

    func testAlertRendersAsATitledBlock() {
        let html = MarkdownHTML.html("> [!WARNING]\n> Do not ship this.\n", documentMode: true)
        XCTAssertTrue(html.contains(#"<div class="alert alert-warning">"#), html)
        XCTAssertTrue(html.contains(#"<p class="alert-title">Warning</p>"#), html)
        XCTAssertTrue(html.contains("<p>Do not ship this.</p>"), html)
        XCTAssertFalse(html.contains("[!WARNING]"), html)
    }

    func testAlertKeepsLaterBlocksAndPlainQuotesAreUntouched() {
        let alert = MarkdownHTML.html("> [!NOTE]\n> First.\n>\n> - second\n", documentMode: true)
        // The blank line makes it a loose list, so the item keeps its paragraph.
        XCTAssertTrue(alert.contains("<ul><li><p>second</p></li></ul>"), alert)
        let quote = MarkdownHTML.html("> just a quote\n", documentMode: true)
        XCTAssertTrue(quote.contains("<blockquote><p>just a quote</p></blockquote>"), quote)
    }

    // MARK: Emoji

    func testEmojiShortcodesSubstitute() {
        XCTAssertTrue(MarkdownHTML.html("ship it :rocket:").contains("🚀"))
        XCTAssertTrue(MarkdownHTML.html("meet at 10:30 tomorrow").contains("10:30"))
        XCTAssertTrue(MarkdownHTML.html("`:rocket:` stays").contains("<code>:rocket:</code>"))
    }

    // MARK: Footnotes

    func testFootnotesNumberByReferenceOrder() {
        let source = """
        Second claim.[^b] First claim.[^a]

        [^a]: The A note.
        [^b]: The B note.
        """
        let html = MarkdownHTML.html(source, documentMode: true)
        XCTAssertTrue(html.contains(##"<sup class="footnote-ref" id="fnref-b"><a href="#fn-b">1</a></sup>"##), html)
        XCTAssertTrue(html.contains(##"<sup class="footnote-ref" id="fnref-a"><a href="#fn-a">2</a></sup>"##), html)
        XCTAssertTrue(html.contains(#"<section class="footnotes">"#), html)
        XCTAssertTrue(html.contains(#"<li id="fn-b">"#), html)
        // The definitions never reach the prose, either as text or as cmark link
        // reference definitions.
        XCTAssertFalse(html.contains("[^a]"), html)
        XCTAssertFalse(html.contains("]: The A note."), html)
    }

    func testUnreferencedFootnoteIsDropped() {
        let html = MarkdownHTML.html("Nothing here.\n\n[^x]: orphan\n", documentMode: true)
        XCTAssertFalse(html.contains("footnotes"), html)
        XCTAssertFalse(html.contains("orphan"), html)
    }

    // MARK: Math

    func testInlineAndDisplayMathRenderAsMathML() {
        let inline = MarkdownHTML.html("The identity $E = mc^2$ holds.", documentMode: true)
        XCTAssertTrue(inline.contains("<math"), inline)
        XCTAssertFalse(inline.contains("$"), inline)

        let display = MarkdownHTML.html("$$\\sum_{i=1}^{n} i$$", documentMode: true)
        XCTAssertTrue(display.contains(#"<div class="math math-display">"#), display)
        // Display math owns its line; it is never wrapped in a paragraph.
        XCTAssertFalse(display.hasPrefix("<p>"), display)
    }

    func testMathFenceRenders() {
        let html = MarkdownHTML.html("```math\n\\frac{a}{b}\n```", documentMode: true)
        XCTAssertTrue(html.contains(#"<div class="math math-display">"#), html)
    }

    func testDollarsInProseAndCodeAreNotMath() {
        let prose = MarkdownHTML.html("It costs $5 and $6 total.", documentMode: true)
        XCTAssertTrue(prose.contains("$5 and $6"), prose)
        let code = MarkdownHTML.html("run `echo $PATH` first", documentMode: true)
        XCTAssertTrue(code.contains("<code>echo $PATH</code>"), code)
        let fence = MarkdownHTML.html("```sh\necho $HOME $USER\n```", documentMode: true)
        XCTAssertTrue(fence.contains("$HOME"), fence)
    }

    // MARK: Code fences

    func testKnownLanguageIsHighlightedAndUnknownIsNot() {
        let swift = MarkdownHTML.html("```swift\nlet x = 1\n```", documentMode: true)
        XCTAssertTrue(swift.contains("hljs-keyword"), swift)
        XCTAssertTrue(swift.contains(#"class="language-swift hljs""#), swift)

        let unknown = MarkdownHTML.html("```notalanguage\nlet x = 1\n```", documentMode: true)
        XCTAssertFalse(unknown.contains("hljs-"), unknown)
        XCTAssertTrue(unknown.contains("let x = 1"), unknown)
    }

    func testHighlightedCodeStillEscapes() {
        let html = MarkdownHTML.html("```html\n<script>x</script>\n```", documentMode: true)
        XCTAssertFalse(html.contains("<script>"), html)
    }
}

/// End-to-end pass over `Fixtures/markdown-features.md`, the sheet used to judge the
/// reader by eye. The unit cases above pin each construct; this one pins that a real
/// document exercising all of them at once leaks no source markers.
final class MarkdownFeatureSheetTests: XCTestCase {
    private func featureSheet() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "markdown-features", withExtension: "md",
                              subdirectory: "Fixtures"),
            "the feature sheet is missing from the test bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testFeatureSheetLeavesNoSourceMarkers() throws {
        let html = MarkdownHTML.html(try featureSheet(), softBreaksAsBreaks: false, documentMode: true)
        for marker in ["[!NOTE]", "[!WARNING]", "$$", "[^anti100x]", "[^boundaries]:"] {
            XCTAssertFalse(html.contains(marker), "\(marker) survived into the output")
        }
        // The sheet's one surviving `:rocket:` is the deliberate one inside a code span.
        XCTAssertTrue(html.contains("<code>:rocket:</code>"))
        XCTAssertFalse(
            html.replacingOccurrences(of: "<code>:rocket:</code>", with: "").contains(":rocket:"),
            "an emoji shortcode outside code survived into the output")
    }

    func testFeatureSheetRendersEveryConstruct() throws {
        let html = MarkdownHTML.html(try featureSheet(), softBreaksAsBreaks: false, documentMode: true)
        for fragment in [
            #"<h2 id="alerts">"#,          // heading anchors
            #"id="duplicate-1""#,          // slug de-duplication
            "alert alert-caution",         // all five alert kinds present
            "🚀",                          // emoji shortcodes
            "hljs-keyword",                // fenced-code highlighting
            "<math",                       // KaTeX MathML
            #"<div class="math math-display">"#,
            #"<section class="footnotes">"#,
            #"<a href="https://github.com/termio-sh/termio">"#,  // bare-URL autolink
            #"<a href="http://www.termio.sh">"#,
        ] {
            XCTAssertTrue(html.contains(fragment), "\(fragment) is missing from the output")
        }
        // Prose that merely looks like markup stays prose.
        XCTAssertTrue(html.contains("costs $5 and $6"), "prose dollars were eaten by math")
        XCTAssertTrue(html.contains("10:30"), "a clock time was eaten by emoji substitution")
    }
}
