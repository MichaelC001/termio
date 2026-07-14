import AppKit
import SwiftUI
import WebKit

/// The live state behind one browser pane: the WKWebView itself plus the header
/// chrome's bindings. Cached in `TermioStore.browserPanes` by session id — the
/// same lifetime the terminal surface cache gives shells — so flipping between
/// sessions or rearranging splits never reloads the page.
///
/// This is deliberately a *preview pane*, not a browser: one URL field, reload,
/// and open-in-Safari. No tabs, no history UI, no omnibox — back/forward ride
/// the trackpad swipe (`allowsBackForwardNavigationGestures`), and Web Inspector
/// comes free via `isInspectable`, which is the cheap version of what
/// Cursor/Codex ship as "read the dev server's console".
@MainActor
final class BrowserPaneModel: NSObject, ObservableObject {
    let webView: WKWebView
    /// The header field's text. Follows navigation, but the user's in-progress
    /// edit is theirs until they submit or navigate away.
    @Published var addressText: String
    @Published private(set) var isLoading = false

    /// Fired on every committed navigation with the new URL — the store writes
    /// it back into `Session.browserURL` so the pane restores where it left off.
    var onNavigate: ((URL) -> Void)?
    /// Fired on any click in the web content, so the pane takes the selection
    /// the way clicking a terminal surface does (WKWebView swallows the mouse
    /// events SwiftUI gestures would otherwise see).
    var onActivate: (() -> Void)?

    /// Coalesces the flood of `setFrameSize` calls a divider drag produces into
    /// one re-fit after the drag settles.
    private var refitDebounce: DispatchWorkItem?

    init(initialURL: URL?) {
        let clickReporting = ClickReportingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView = clickReporting
        addressText = initialURL?.absoluteString ?? ""
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        // Transparent until the page paints, so a dark terminal theme doesn't get
        // a white flash while a dev server compiles (same trick as `FilePreview`).
        webView.setValue(false, forKey: "drawsBackground")
        clickReporting.onMouseDown = { [weak self] in self?.onActivate?() }
        clickReporting.onResize = { [weak self] in self?.scheduleFit() }
        if let initialURL { webView.load(URLRequest(url: initialURL)) }
    }

    /// Shrinks the page to fit the pane's width — the iPad-Safari "shrink to fit"
    /// so a fixed-width desktop site (baidu, apple.com: ~980px) shows whole in a
    /// narrow split instead of a clipped left strip. Only ever scales *down*: a
    /// page that already fits keeps its natural size. Reset to 1 before measuring
    /// so a responsive page (whose layout width follows the zoom) converges in one
    /// pass instead of oscillating.
    func fitToWidth() {
        let available = webView.bounds.width
        guard available > 0 else { return }
        webView.pageZoom = 1
        let js = "Math.ceil(Math.max(document.documentElement.scrollWidth, (document.body||{}).scrollWidth||0))"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let contentWidth = (result as? NSNumber)?.doubleValue,
                  contentWidth > available else { return }
            // A floor keeps a very wide page legible rather than shrinking to a
            // thumbnail; below it the pane scrolls horizontally as before.
            self.webView.pageZoom = max(0.4, available / contentWidth)
        }
    }

    private func scheduleFit() {
        refitDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fitToWidth() }
        }
        refitDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Loads whatever is in the address field. A schemeless entry gets `http://`
    /// for loopback hosts (dev servers don't serve TLS) and `https://` otherwise.
    func submitAddress() {
        let text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let hasScheme = text.contains("://")
        let loopback = text.hasPrefix("localhost") || text.hasPrefix("127.")
            || text.hasPrefix("0.0.0.0") || text.hasPrefix("[::1]")
        let candidate = hasScheme ? text : (loopback ? "http://" : "https://") + text
        guard let url = URL(string: candidate), url.host != nil else { return }
        webView.load(URLRequest(url: url))
    }

    func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
            isLoading = false
        } else if webView.url != nil {
            webView.reload()
        } else {
            submitAddress()
        }
    }

    func openInDefaultBrowser() {
        guard let url = webView.url ?? URL(string: addressText) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension BrowserPaneModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        addressText = url.absoluteString
        onNavigate?(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        fitToWidth()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        isLoading = false
    }
}

/// WKWebView that reports raw clicks upward before handling them — the only
/// reliable way to make "click the web content" move the pane selection, since
/// the web view consumes mouse events before any SwiftUI gesture sees them.
private final class ClickReportingWebView: WKWebView {
    var onMouseDown: (() -> Void)?
    /// Fired whenever the pane resizes the view (divider drag, window resize,
    /// sidebar toggle) so the page can be re-fit to the new width.
    var onResize: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { onResize?() }
    }
}

/// One browser pane: a thin header (reload / URL / open-in-Safari) over the web
/// view. Mounted by `TerminalPane` in the same flat ZStack as the terminal
/// surfaces, at the frame the split tree computes.
struct BrowserPaneView: View {
    @ObservedObject var model: BrowserPaneModel
    @EnvironmentObject var settings: AppSettings
    /// Closes this browser pane (its session). Inline on the header rather than
    /// only in the sidebar because a browser is the kind of pane you expect to
    /// dismiss in one click — the terminal panes lean on the sidebar close, but a
    /// preview you opened to glance at should close where you're looking.
    let onClose: () -> Void
    @FocusState private var addressFocused: Bool
    /// Whether the main window is in macOS fullscreen. In fullscreen the pane's
    /// top no longer meets the window title bar, so the seam-covering hairline
    /// (below) would just be a stray line — hidden there.
    @State private var isFullScreen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            WebViewRepresentable(webView: model.webView)
        }
        .background(Color(nsColor: settings.terminalBackgroundColor))
        // A hairline along the pane's top edge so the address bar reads as a
        // browser toolbar sitting under the window chrome, rather than floating
        // loose against the title bar (the terminal panes have no such bar, so
        // without the line the browser's top looks unfinished). Dropped in
        // fullscreen, where there is no title bar for it to seam against.
        .overlay(alignment: .top) {
            if !isFullScreen {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if isMainWindow(note.object) { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if isMainWindow(note.object) { isFullScreen = false }
        }
        .onAppear {
            // The pane can mount while already fullscreen (opened from a
            // fullscreen window), so seed the state instead of waiting for a toggle.
            isFullScreen = mainWindow()?.styleMask.contains(.fullScreen) ?? false
        }
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName }
    }

    private func isMainWindow(_ object: Any?) -> Bool {
        (object as? NSWindow)?.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: model.reloadOrStop) {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(model.isLoading ? "Stop loading" : "Reload")
            TextField("localhost:3000", text: $model.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .focused($addressFocused)
                .onSubmit {
                    model.submitAddress()
                    addressFocused = false
                }
                // A pane opened blank (plain "Browser Right/Down", no link under
                // the pointer) is waiting for an address — put the cursor there.
                .onAppear { if model.addressText.isEmpty { addressFocused = true } }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .quaternarySystemFill))
                )
            Button(action: model.openInDefaultBrowser) {
                Image(systemName: "safari")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Open in default browser")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Close browser")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

private struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Store cache

extension TermioStore {
    /// The live model behind a browser session, created on first mount — the
    /// browser counterpart of `surface(for:in:)`. Torn down by `closeSession` /
    /// `removeProject` like the surface cache.
    func browserPane(for session: Session) -> BrowserPaneModel {
        if let existing = browserPanes[session.id] { return existing }
        let model = BrowserPaneModel(initialURL: session.browserURL.flatMap(URL.init(string:)))
        let id = session.id
        model.onNavigate = { [weak self] url in
            guard let self,
                  let projectIndex = projects.firstIndex(where: { $0.sessions.contains { $0.id == id } }),
                  let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == id })
            else { return }
            projects[projectIndex].sessions[sessionIndex].browserURL = url.absoluteString
        }
        model.onActivate = { [weak self] in
            guard let self, selectedSessionID != id else { return }
            selectedSessionID = id
        }
        browserPanes[id] = model
        return model
    }
}
