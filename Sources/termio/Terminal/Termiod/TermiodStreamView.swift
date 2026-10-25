import AppKit
import QuartzCore
import TermioShared

/// The pane for a `vt_stream` session: it draws the link's client terminal and
/// says how much of a session it could show. It never sizes the terminal — the
/// session's grid comes only from the daemon's markers — so a pane larger than
/// the grid leaves room to the right and below, and a smaller one clips.
@MainActor
final class TermiodStreamView: NSView {
    /// The terminal to draw, read every frame: an attach replaces it with a
    /// fresh one, and the view follows without being told.
    var terminal: () -> TermiodStreamTerminal? = { nil }
    /// The grid this pane could hold, each time it changes. The link sends it
    /// as the viewport declaration the daemon's size policy reads.
    var onViewport: (TerminalGrid) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    private let metalLayer = CAMetalLayer()
    private var renderer: TermiodStreamRenderer?
    private var displayLinkHandle: CADisplayLink?
    private var drawnTerminal: ObjectIdentifier?
    private var needsFullDraw = true
    private var lastViewport: TerminalGrid?
    private var focused = false {
        didSet {
            guard focused != oldValue else { return }
            needsFullDraw = true
            onFocusChange(focused)
        }
    }
    /// Off while the pane is not on screen: a hidden pane draws nothing, as
    /// `setSurfaceVisible` arranges for the embedded surface.
    var isShowing = true {
        didSet {
            guard isShowing != oldValue else { return }
            displayLinkHandle?.isPaused = !isShowing
            needsFullDraw = true
        }
    }

    init(appearance: TermiodStreamRenderer.Appearance) {
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.pixelFormat = .bgra8Unorm
        // Theme colors are sRGB values, as the embedded surface treats them.
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = appearance.backgroundOpacity >= 1
        metalLayer.maximumDrawableCount = 3
        layer = metalLayer
        do {
            let renderer = try TermiodStreamRenderer(appearance: appearance, scale: currentScale)
            metalLayer.device = renderer.device
            self.renderer = renderer
        } catch {
            Log.termiod.error("stream renderer unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var cellSize: CGSize? { renderer?.cellSize }

    func setAppearance(_ appearance: TermiodStreamRenderer.Appearance) {
        guard let renderer else { return }
        do {
            metalLayer.isOpaque = appearance.backgroundOpacity >= 1
            if try renderer.update(appearance: appearance, scale: currentScale) {
                declareViewport()
            }
            needsFullDraw = true
        } catch {
            Log.termiod.error("stream renderer appearance: \(String(describing: error), privacy: .public)")
        }
    }

    private var currentScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        focused = window?.isKeyWindow ?? false
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = false
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            displayLinkHandle?.invalidate()
            displayLinkHandle = nil
            return
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyWindowChanged), name: name, object: window
            )
        }
        viewDidChangeBackingProperties()
        guard displayLinkHandle == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        link.isPaused = !isShowing
        displayLinkHandle = link
    }

    @objc private func keyWindowChanged() {
        focused = window?.isKeyWindow == true && window?.firstResponder === self
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = currentScale
        if let renderer, (try? renderer.update(appearance: renderer.appearance, scale: currentScale)) == true {
            declareViewport()
        }
        resizeDrawable()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeDrawable()
        declareViewport()
    }

    private func resizeDrawable() {
        let scale = metalLayer.contentsScale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        guard metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        needsFullDraw = true
    }

    private func declareViewport() {
        guard let renderer,
              let grid = TerminalGrid.fitting(
                  bounds.size, cell: renderer.cellSize,
                  paddingX: renderer.appearance.paddingX, paddingY: renderer.appearance.paddingY
              ),
              grid != lastViewport
        else { return }
        lastViewport = grid
        onViewport(grid)
    }

    @objc private func tick() {
        guard isShowing, let renderer, let terminal = terminal() else { return }
        let identity = ObjectIdentifier(terminal)
        let replaced = identity != drawnTerminal
        drawnTerminal = identity
        do {
            try renderer.draw(terminal, into: metalLayer, focused: focused, force: needsFullDraw || replaced)
            needsFullDraw = false
        } catch {
            Log.termiod.error("stream frame failed: \(String(describing: error), privacy: .public)")
        }
    }
}

import SwiftUI

/// Mounts a `TermiodStreamView` for a pane whose link is on the `vt_stream`
/// plane, in place of the embedded surface.
struct TermiodStreamPane: NSViewRepresentable {
    let link: TermiodSessionLink
    let appearance: TermiodStreamRenderer.Appearance
    let colors: TermiodStreamTerminal.Colors?
    let isSelected: Bool
    let isVisible: Bool
    let onViewport: (TerminalGrid) -> Void
    let onVisibility: (Bool) -> Void
    let onFocused: () -> Void

    final class Coordinator {
        var colorsApplied: TermiodStreamTerminal.Colors?
        var visible: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TermiodStreamView {
        let view = TermiodStreamView(appearance: appearance)
        let link = link
        view.terminal = { link.streamTerminal }
        return view
    }

    func updateNSView(_ view: TermiodStreamView, context: Context) {
        view.onViewport = onViewport
        let onFocused = onFocused
        view.onFocusChange = { focused in if focused { onFocused() } }
        view.setAppearance(appearance)
        view.isShowing = isVisible
        if let colors, context.coordinator.colorsApplied != colors {
            context.coordinator.colorsApplied = colors
            link.setStreamColors(colors)
        }
        if context.coordinator.visible != isVisible {
            context.coordinator.visible = isVisible
            onVisibility(isVisible)
        }
        if isSelected, isVisible, let window = view.window, window.firstResponder !== view {
            DispatchQueue.main.async { window.makeFirstResponder(view) }
        }
    }
}
