import AppKit
import Carbon.HIToolbox
import GhosttyTerminal
import GhosttyVt
import QuartzCore
import TermioShared
import UniformTypeIdentifiers

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
    /// Writes input to the session — the link's `send`, which claims the
    /// write token as typing in the embedded surface does.
    var send: (Data) -> Void = { _ in }
    /// The session this pane shows, for app code that acts on the focused
    /// terminal (the paste interceptor).
    var sessionID: Session.ID?

    fileprivate let metalLayer = CAMetalLayer()
    fileprivate var renderer: TermiodStreamRenderer?
    private var displayLinkHandle: CADisplayLink?
    private var drawnTerminal: ObjectIdentifier?
    fileprivate var needsFullDraw = true
    private var lastViewport: TerminalGrid?
    private var focused = false {
        didSet {
            guard focused != oldValue else { return }
            needsFullDraw = true
            onFocusChange(focused)
            if let terminal = terminal() { deliver(terminal.encodeFocus(focused)) }
        }
    }

    /// Input-method state: the text being composed, and the strings a key
    /// event inserted while `interpretKeyEvents` ran.
    private var markedText = NSMutableAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    private var collectedText: [String]?
    private var interpretedCommand = false
    /// Ghostty's handshake for Control and Command keys the menu did not take
    /// (`performKeyEquivalent`).
    private var lastPerformKeyEvent: TimeInterval?
    /// Mouse buttons down that were reported to the program, so their
    /// releases are too, wherever the pointer is let go.
    private var reportedButtons: Set<GhosttyMouseButton.RawValue> = []
    private var scrollRemainder: CGFloat = 0
    private var trackingArea: NSTrackingArea?
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
    /// Metal or the shaders could not be set up, so this view can draw nothing.
    var hasRenderer: Bool { renderer != nil }

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
            try renderer.draw(
                terminal, into: metalLayer, focused: focused, force: needsFullDraw || replaced,
                preedit: markedText.length > 0 ? markedText.string : nil
            )
            needsFullDraw = false
        } catch {
            Log.termiod.error("stream frame failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Keyboard and input methods

extension TermiodStreamView: @preconcurrency NSTextInputClient {
    private func deliver(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        send(bytes)
    }

    /// Ghostty's AppKit `keyDown`: the event goes through the input method
    /// first, and what it inserted, if anything, rides the key event as text.
    override func keyDown(with event: NSEvent) {
        guard let terminal = terminal() else { return }
        if markedText.length == 0, let bytes = TermiodStreamKeyboard.naturalEditing(event) {
            terminal.scrollToBottom()
            deliver(bytes)
            return
        }
        let action = event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS
        let composingBefore = markedText.length > 0
        let layoutBefore = composingBefore ? nil : Self.keyboardLayoutID
        collectedText = []
        interpretedCommand = false
        interpretKeyEvents([event])
        let collected = collectedText ?? []
        collectedText = nil
        // A keystroke that switched the input source types nothing.
        if !composingBefore, layoutBefore != Self.keyboardLayoutID { return }
        if !collected.isEmpty {
            for text in collected {
                deliver(terminal.encode(TermiodStreamKeyboard.input(for: event, action: action, text: text)))
            }
            return
        }
        // A key the input method took while composing encodes as composing,
        // which sends nothing: Backspace edits the composition, not the line.
        let text = interpretedCommand ? nil : TermiodStreamKeyboard.typedText(of: event)
        deliver(terminal.encode(TermiodStreamKeyboard.input(
            for: event, action: action, text: text, composing: markedText.length > 0 || composingBefore
        )))
    }

    override func keyUp(with event: NSEvent) {
        guard let terminal = terminal() else { return }
        deliver(terminal.encode(TermiodStreamKeyboard.input(for: event, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil)))
    }

    /// A modifier pressed or released alone, which the Kitty protocol can
    /// report. Its side decides which key it was.
    override func flagsChanged(with event: NSEvent) {
        guard markedText.length == 0, let terminal = terminal() else { return }
        let held: Bool
        switch Int(event.keyCode) {
        case kVK_CapsLock: held = event.modifierFlags.contains(.capsLock)
        case kVK_Shift, kVK_RightShift: held = Self.sideHeld(event, .shift, right: NX_DEVICERSHIFTKEYMASK)
        case kVK_Control, kVK_RightControl: held = Self.sideHeld(event, .control, right: NX_DEVICERCTLKEYMASK)
        case kVK_Option, kVK_RightOption: held = Self.sideHeld(event, .option, right: NX_DEVICERALTKEYMASK)
        case kVK_Command, kVK_RightCommand: held = Self.sideHeld(event, .command, right: NX_DEVICERCMDKEYMASK)
        default: return
        }
        deliver(terminal.encode(TermiodStreamKeyboard.input(
            for: event, action: held ? GHOSTTY_KEY_ACTION_PRESS : GHOSTTY_KEY_ACTION_RELEASE, text: nil
        )))
    }

    /// Whether the modifier this event's key names is down: the flag alone
    /// cannot say for one side while the other is held.
    private static func sideHeld(_ event: NSEvent, _ flag: NSEvent.ModifierFlags, right mask: Int32) -> Bool {
        guard event.modifierFlags.contains(flag) else { return false }
        let rightDown = event.modifierFlags.rawValue & UInt(mask) != 0
        let isRight = [kVK_RightShift, kVK_RightControl, kVK_RightOption, kVK_RightCommand].contains(Int(event.keyCode))
        return isRight ? rightDown : true
    }

    /// Ghostty's: the editing keys it binds win over the menu; Control and
    /// Command keys go to the menu first, and come back here as a key the
    /// program receives when the menu has no item for them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, terminal() != nil else { return false }
        if TermiodStreamKeyboard.naturalEditing(event) != nil, markedText.length == 0 {
            keyDown(with: event)
            return true
        }
        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent, last == event.timestamp {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
                break
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }
        guard let translated = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode
        ) else { return false }
        keyDown(with: translated)
        return true
    }

    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
            return
        }
        // An editing command (Shift-Tab is `insertBacktab:`) still reaches the
        // program as the key that was pressed, without the text.
        interpretedCommand = true
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if collectedText != nil {
            collectedText?.append(text)
        } else if let terminal = terminal() {
            // Text an input method commits outside a keystroke, as from the
            // character viewer, is text, not a key.
            deliver(terminal.encodePaste(text))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else if let plain = string as? String {
            markedText = NSMutableAttributedString(string: plain)
        }
        markedSelection = selectedRange
    }

    func unmarkText() {
        markedText.mutableString.setString("")
        markedSelection = NSRange(location: 0, length: 0)
    }

    func selectedRange() -> NSRange {
        markedText.length > 0 ? markedSelection : NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard markedText.length > 0 else { return nil }
        let location = min(max(range.location, 0), markedText.length)
        let end = min(max(range.location + range.length, location), markedText.length)
        let clamped = NSRange(location: location, length: end - location)
        actualRange?.pointee = clamped
        return markedText.attributedSubstring(from: clamped)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// The cursor's cell on screen, where the candidate window goes.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let renderer, let cursor = terminal()?.cursorPosition else { return .zero }
        let cell = renderer.cellSize
        let viewRect = NSRect(
            x: renderer.appearance.paddingX + CGFloat(cursor.x) * cell.width,
            y: bounds.height - renderer.appearance.paddingY - CGFloat(cursor.y + 1) * cell.height,
            width: cell.width, height: cell.height
        )
        guard let window else { return viewRect }
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    private static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    // MARK: - Paste

    /// Edit ▸ Paste. A clipboard holding only an image goes to the program as
    /// Control-V, which agents answer by reading the image off the clipboard
    /// themselves — the embedded surface's rule. Text is pasted as the
    /// program's bracketed-paste mode asks.
    @objc func paste(_ sender: Any?) {
        guard let terminal = terminal() else { return }
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.terminalPasteText() {
            deliver(terminal.encodePaste(text))
        } else if pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier]) {
            let controlV = TermiodStreamTerminal.KeyInput(
                key: GHOSTTY_KEY_V, mods: GhosttyMods(GHOSTTY_MODS_CTRL), unshiftedCodepoint: 0x76
            )
            deliver(terminal.encode(controlV))
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private var pixelLayout: TermiodStreamTerminal.PixelLayout? {
        guard let renderer else { return nil }
        let scale = metalLayer.contentsScale
        return TermiodStreamTerminal.PixelLayout(
            cellWidth: UInt32(renderer.atlas.metrics.width), cellHeight: UInt32(renderer.atlas.metrics.height),
            paddingLeft: UInt32((renderer.appearance.paddingX * scale).rounded()),
            paddingTop: UInt32((renderer.appearance.paddingY * scale).rounded())
        )
    }

    private func mouseInput(
        _ event: NSEvent, action: GhosttyMouseAction, button: GhosttyMouseButton?
    ) -> TermiodStreamTerminal.MouseInput {
        let point = convert(event.locationInWindow, from: nil)
        let scale = metalLayer.contentsScale
        return TermiodStreamTerminal.MouseInput(
            action: action, button: button, mods: TermiodStreamKeyboard.mods(event.modifierFlags),
            x: Float(point.x * scale), y: Float((bounds.height - point.y) * scale),
            anyButtonPressed: !reportedButtons.isEmpty
        )
    }

    /// A press goes to a program tracking the mouse, unless Shift is held:
    /// Ghostty keeps Shift-click for the terminal's own selection.
    private func press(_ event: NSEvent, _ button: GhosttyMouseButton) {
        window?.makeFirstResponder(self)
        guard let terminal = terminal(), let layout = pixelLayout, terminal.tracksMouse,
              !event.modifierFlags.contains(.shift)
        else { return }
        reportedButtons.insert(button.rawValue)
        deliver(terminal.encode(mouseInput(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: button), layout: layout))
    }

    private func release(_ event: NSEvent, _ button: GhosttyMouseButton) {
        guard reportedButtons.remove(button.rawValue) != nil,
              let terminal = terminal(), let layout = pixelLayout
        else { return }
        deliver(terminal.encode(mouseInput(event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: button), layout: layout))
    }

    private func motion(_ event: NSEvent, _ button: GhosttyMouseButton?) {
        guard let terminal = terminal(), let layout = pixelLayout else { return }
        let held = button.flatMap { reportedButtons.contains($0.rawValue) ? $0 : nil }
        deliver(terminal.encode(mouseInput(event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: held), layout: layout))
    }

    override func mouseDown(with event: NSEvent) { press(event, GHOSTTY_MOUSE_BUTTON_LEFT) }
    override func mouseUp(with event: NSEvent) { release(event, GHOSTTY_MOUSE_BUTTON_LEFT) }
    override func rightMouseDown(with event: NSEvent) { press(event, GHOSTTY_MOUSE_BUTTON_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { release(event, GHOSTTY_MOUSE_BUTTON_RIGHT) }
    override func otherMouseDown(with event: NSEvent) { press(event, GHOSTTY_MOUSE_BUTTON_MIDDLE) }
    override func otherMouseUp(with event: NSEvent) { release(event, GHOSTTY_MOUSE_BUTTON_MIDDLE) }
    override func mouseMoved(with event: NSEvent) { motion(event, nil) }
    override func mouseDragged(with event: NSEvent) { motion(event, GHOSTTY_MOUSE_BUTTON_LEFT) }
    override func rightMouseDragged(with event: NSEvent) { motion(event, GHOSTTY_MOUSE_BUTTON_RIGHT) }
    override func otherMouseDragged(with event: NSEvent) { motion(event, GHOSTTY_MOUSE_BUTTON_MIDDLE) }

    /// Rows to scroll, as Ghostty counts them: a trackpad's points add up to
    /// whole cells, and a wheel's notch is three rows.
    override func scrollWheel(with event: NSEvent) {
        guard let terminal = terminal(), let layout = pixelLayout, let renderer else { return }
        let rows: Int
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += event.scrollingDeltaY
            let cell = max(1, renderer.cellSize.height)
            let whole = (scrollRemainder / cell).rounded(.towardZero)
            scrollRemainder -= whole * cell
            rows = -Int(whole)
        } else {
            rows = -Int((event.scrollingDeltaY * 3).rounded(.towardZero))
        }
        guard rows != 0 else { return }
        let at = mouseInput(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: nil)
        deliver(terminal.scroll(rows: rows, at: at, layout: layout))
        needsFullDraw = true
    }
}

import SwiftUI

/// Mounts a `TermiodStreamView` for a pane whose link is on the `vt_stream`
/// plane, in place of the embedded surface.
struct TermiodStreamPane: NSViewRepresentable {
    let link: TermiodSessionLink
    let sessionID: Session.ID
    let appearance: TermiodStreamRenderer.Appearance
    let colors: TermiodStreamTerminal.Theme?
    let isSelected: Bool
    let isVisible: Bool
    let onViewport: (TerminalGrid) -> Void
    let onVisibility: (Bool) -> Void
    let onFocused: () -> Void

    final class Coordinator {
        var themeApplied: TermiodStreamTerminal.Theme?
        var visible: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TermiodStreamView {
        let view = TermiodStreamView(appearance: appearance)
        // A pane that cannot draw this plane hands the session back to the
        // embedded surface rather than stay blank.
        if !view.hasRenderer { link.abandonStream() }
        return view
    }

    func updateNSView(_ view: TermiodStreamView, context: Context) {
        let link = link
        view.terminal = { link.streamTerminal }
        view.send = { link.send($0) }
        view.sessionID = sessionID
        view.onViewport = onViewport
        let onFocused = onFocused
        view.onFocusChange = { focused in if focused { onFocused() } }
        view.setAppearance(appearance)
        view.isShowing = isVisible
        if let colors, context.coordinator.themeApplied != colors {
            context.coordinator.themeApplied = colors
            link.setStreamTheme(colors)
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
