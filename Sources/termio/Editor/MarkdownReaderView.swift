import AppKit
import SwiftUI
import WebKit

/// The Preview side of `FileEditorView` for Markdown: renders the file as a themed,
/// document-grade reading view (the Apple-docs / iA-Writer register — narrow measure,
/// generous rhythm), reusing the same `TraceMarkdown` parser the session trace uses but
/// with its own reader stylesheet rather than the trace's dense dashboard skin.
///
/// It renders the *live* editor buffer (`source`), not the file on disk, so flipping over
/// from Edit shows unsaved keystrokes immediately. The page's colors come from termio's
/// active chrome theme via `TraceTheme`, so Preview always matches the app.
struct MarkdownReaderView: View {
    let source: String
    let fileURL: URL
    @ObservedObject var settings: AppSettings
    let colorScheme: ColorScheme

    var body: some View {
        let theme = TraceTheme.resolve(settings: settings, colorScheme: colorScheme)
        // Relative image paths (`![](./shot.png)`) resolve against the file's own folder.
        MarkdownReaderWebView(
            html: MarkdownReaderRenderer.document(source, theme: theme),
            baseURL: fileURL.deletingLastPathComponent(),
            background: settings.terminalBackgroundColor
        )
    }
}

/// A `WKWebView` host that renders the reader HTML, preserves scroll position across
/// re-renders (theme flip, live edit), and opens web links in the browser rather than
/// navigating the page away. Its own background is cleared so the terminal background
/// shows through until the themed page paints (no white flash).
private struct MarkdownReaderWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    let background: NSColor

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: baseURL)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        // Restore the reader's scroll offset after the new content lays out, so re-rendering
        // (e.g. a theme change, or editing then flipping back) doesn't jump to the top.
        context.coordinator.restoreScroll = true
        view.evaluateJavaScript("window.scrollY") { value, _ in
            context.coordinator.savedScrollY = (value as? CGFloat) ?? 0
            view.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(lastHTML: html) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String
        var savedScrollY: CGFloat = 0
        var restoreScroll = false
        init(lastHTML: String) { self.lastHTML = lastHTML }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard restoreScroll else { return }
            restoreScroll = false
            webView.evaluateJavaScript("window.scrollTo(0, \(savedScrollY))")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                // In-page anchors scroll within the doc; external links open in the browser.
                if url.fragment != nil, url.path == webView.url?.path {
                    decisionHandler(.allow)
                } else {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                }
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
