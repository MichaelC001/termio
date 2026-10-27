import GhosttyVt
import QuartzCore
import TermioShared
import TermioStream
import UIKit

/// The phone's view of a session on the `vt_stream` plane: the session's own
/// terminal (`TermiodSession.streamTerminal`) drawn by the shared renderer, in
/// place of the embedded surface, with input sent as events termiod encodes.
final class StreamTerminalView: UIView, UIKeyInput {
    /// The terminal to draw, read every frame: an attach replaces it.
    var terminal: () -> TermiodStreamTerminal? = { nil }
    /// The grid this screen could hold, each time it changes.
    var onViewport: (TerminalGrid) -> Void = { _ in }
    var sendInput: (Termiod.InputEvent) -> Void = { _ in }
    /// A pinch, as the scale it ended at, for the controller's font size.
    var onPinch: (CGFloat) -> Void = { _ in }
    /// The key bar, docked above the keyboard while this view has it.
    var inputAccessory: UIView?
    override var inputAccessoryView: UIView? { inputAccessory }
    /// Ctrl or Alt the key bar armed for the next typed key, and the call that
    /// says it was used, so the keycap lets go.
    var stickyMods: UInt16 = 0
    var onStickyConsumed: () -> Void = {}
    /// A long press, at its point, for the controller's Paste menu: pasting
    /// in is the one clipboard feature the phone's terminal has.
    var onPasteMenuRequested: (CGPoint) -> Void = { _ in }

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private var renderer: TermiodStreamRenderer?
    private var displayLink: CADisplayLink?
    private var drawnTerminal: ObjectIdentifier?
    private var needsFullDraw = true
    private var lastViewport: TerminalGrid?
    private var scrollRemainder: CGFloat = 0
    /// Hardware keys whose press the program saw, so each gets its release.
    private var heldKeys: [UIKeyboardHIDUsage: Termiod.InputEvent.Key] = [:]
    private var hasKeyboard = false {
        didSet {
            guard hasKeyboard != oldValue else { return }
            needsFullDraw = true
            sendInput(.focus(hasKeyboard))
        }
    }

    init(appearance: TermiodStreamRenderer.Appearance) {
        super.init(frame: .zero)
        accessibilityIdentifier = "terminal.stream"
        metalLayer.pixelFormat = .bgra8Unorm
        // Theme colors are sRGB values, as the embedded surface treats them.
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = appearance.backgroundOpacity >= 1
        do {
            let renderer = try TermiodStreamRenderer(appearance: appearance, scale: UIScreen.main.scale)
            metalLayer.device = renderer.device
            self.renderer = renderer
        } catch {
            Log.device.error("stream renderer unavailable: \(String(describing: error), privacy: .public)")
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Metal or the shaders could not be set up, so this view can draw nothing.
    var hasRenderer: Bool { renderer != nil }
    var cellSize: CGSize? { renderer?.cellSize }
    var appearance: TermiodStreamRenderer.Appearance? { renderer?.appearance }

    /// Where the cursor's cell is, in this view's coordinates: what the
    /// controller keeps above the keyboard.
    var cursorRect: CGRect? {
        guard let renderer, let screen = try? terminal()?.screen() else { return nil }
        let cell = renderer.cellSize
        return CGRect(
            x: renderer.appearance.paddingX + CGFloat(screen.cursorX) * cell.width,
            y: renderer.appearance.paddingY + CGFloat(screen.cursorY) * cell.height,
            width: cell.width, height: cell.height)
    }

    func setAppearance(_ appearance: TermiodStreamRenderer.Appearance) {
        guard let renderer else { return }
        do {
            metalLayer.isOpaque = appearance.backgroundOpacity >= 1
            if try renderer.update(appearance: appearance, scale: window?.screen.scale ?? UIScreen.main.scale) {
                declareViewport()
            }
            needsFullDraw = true
        } catch {
            Log.device.error("stream renderer appearance: \(String(describing: error), privacy: .public)")
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard let window else { return }
        metalLayer.contentsScale = window.screen.scale
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        needsFullDraw = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = metalLayer.contentsScale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            needsFullDraw = true
        }
        declareViewport()
    }

    private func declareViewport() {
        guard let renderer,
              let grid = TerminalGrid.fitting(
                  bounds.size, cell: renderer.cellSize,
                  paddingX: renderer.appearance.paddingX, paddingY: renderer.appearance.paddingY),
              grid != lastViewport
        else { return }
        lastViewport = grid
        onViewport(grid)
    }

    @objc private func tick() {
        guard let renderer, let terminal = terminal() else { return }
        let identity = ObjectIdentifier(terminal)
        let replaced = identity != drawnTerminal
        drawnTerminal = identity
        do {
            _ = try renderer.draw(terminal, into: metalLayer, focused: hasKeyboard, force: needsFullDraw || replaced)
            needsFullDraw = false
        } catch {
            Log.device.error("stream frame failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Gestures

    @objc private func tapped() {
        if !isFirstResponder { becomeFirstResponder() }
    }

    /// A drag scrolls by whole rows: to the program when it takes the wheel
    /// (mouse reporting, or the alternate screen's scroll mode), and through
    /// this screen's own scrollback otherwise, as the Mac's wheel does.
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let renderer, let terminal = terminal() else { return }
        if gesture.state == .began { scrollRemainder = 0 }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        scrollRemainder += translation.y
        let cell = max(1, renderer.cellSize.height)
        let rows = Int((scrollRemainder / cell).rounded(.towardZero))
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows) * cell
        let clamped = min(max(-rows, -500), 500)
        if terminal.wheelGoesToProgram {
            let location = gesture.location(in: self)
            sendInput(.wheel(.init(rows: Int32(clamped), columns: 0, mods: 0, at: pointer(location))))
        } else {
            terminal.scrollViewport(rows: clamped)
            needsFullDraw = true
        }
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, UIPasteboard.general.hasStrings else { return }
        onPasteMenuRequested(gesture.location(in: self))
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onPinch(gesture.scale)
    }

    private func pointer(_ location: CGPoint) -> Termiod.InputEvent.Pointer {
        let cell = renderer?.cellSize ?? CGSize(width: 8, height: 16)
        let paddingX = renderer?.appearance.paddingX ?? 0
        let paddingY = renderer?.appearance.paddingY ?? 0
        return .init(
            x: Float(location.x - paddingX), y: Float(location.y - paddingY),
            cellWidth: UInt32(max(1, cell.width.rounded())), cellHeight: UInt32(max(1, cell.height.rounded())))
    }

    // MARK: - Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { hasKeyboard = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            hasKeyboard = false
            releaseHeldKeys()
        }
        return resigned
    }

    var hasText: Bool { true }

    // A terminal takes keys as typed: no correction, capitals, or smart quotes.
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }

    /// The soft keyboard's text. A character a US keyboard has a key for goes
    /// as that key, so the program's keyboard modes apply to it; anything else
    /// (a composed character, an emoji) is text, as the Mac sends text an
    /// input method commits outside a keystroke.
    func insertText(_ text: String) {
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            sendInput(.paste(pending))
            pending = ""
        }
        for character in text {
            if let key = StreamKeyboard.key(typing: character) {
                flush()
                press(key)
            } else {
                pending.append(character)
            }
        }
        flush()
    }

    func deleteBackward() {
        press(.init(key: "backspace"))
    }

    private func press(_ key: Termiod.InputEvent.Key) {
        var key = key
        if stickyMods != 0 {
            key.mods |= stickyMods
            // A modifier the key bar holds makes a control code, not text.
            key.text = nil
            key.consumedMods = 0
            stickyMods = 0
            onStickyConsumed()
        }
        sendInput(.key(key))
        var release = key
        release.action = .release
        release.text = nil
        sendInput(.key(release))
    }

    /// A hardware keyboard's keys, by their physical position, with the
    /// modifiers held. A key this table does not name falls through to the
    /// soft keyboard's path as text.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let input = StreamKeyboard.key(for: key, action: .press) else {
                unhandled.insert(press)
                continue
            }
            heldKeys[key.keyCode] = input
            sendInput(.key(input))
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, var input = heldKeys.removeValue(forKey: key.keyCode) else {
                unhandled.insert(press)
                continue
            }
            input.action = .release
            input.text = nil
            sendInput(.key(input))
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    private func releaseHeldKeys() {
        for (_, held) in heldKeys {
            var release = held
            release.action = .release
            release.text = nil
            sendInput(.key(release))
        }
        heldKeys.removeAll()
    }
}

/// Keys as libghostty names them on the wire (`arrow_up`), which termiod's
/// encoder maps back: the same names the Mac sends.
enum StreamKeyboard {
    static let shift = UInt16(GHOSTTY_MODS_SHIFT)
    static let control = UInt16(GHOSTTY_MODS_CTRL)
    static let alt = UInt16(GHOSTTY_MODS_ALT)
    static let command = UInt16(GHOSTTY_MODS_SUPER)

    static func mods(_ flags: UIKeyModifierFlags) -> UInt16 {
        var mods: UInt16 = 0
        if flags.contains(.shift) { mods |= shift }
        if flags.contains(.control) { mods |= control }
        if flags.contains(.alternate) { mods |= alt }
        if flags.contains(.command) { mods |= command }
        if flags.contains(.alphaShift) { mods |= UInt16(GHOSTTY_MODS_CAPS_LOCK) }
        return mods
    }

    /// A hardware key, or nil when it has no name here.
    static func key(for key: UIKey, action: Termiod.InputEvent.Action) -> Termiod.InputEvent.Key? {
        guard let name = names[key.keyCode] else { return nil }
        let mods = mods(key.modifierFlags)
        // Text only for what types: never a control code or a function key.
        let typed = key.characters
        let text = typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) && !typed.isEmpty
            && mods & (control | command) == 0 ? typed : nil
        let unshifted = key.charactersIgnoringModifiers.unicodeScalars.first.map(\.value) ?? 0
        return .init(action: action, key: name, mods: mods, consumedMods: text == nil ? 0 : mods & shift,
                     text: text, unshifted: unshifted)
    }

    /// A character the soft keyboard typed, as the US-layout key for it, or
    /// nil when no key types it.
    static func key(typing character: Character) -> Termiod.InputEvent.Key? {
        switch character {
        case "\n", "\r": return .init(key: "enter")
        case "\t": return .init(key: "tab")
        default: break
        }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              let (name, shifted) = typing[scalar]
        else { return nil }
        let base = shifted ? (unshiftedCharacter[name] ?? scalar) : scalar
        return .init(action: .press, key: name, mods: shifted ? shift : 0, consumedMods: shifted ? shift : 0,
                     text: String(character), unshifted: base.value)
    }

    private static let typing: [Unicode.Scalar: (String, Bool)] = {
        var table: [Unicode.Scalar: (String, Bool)] = [" ": ("space", false)]
        for scalar in "abcdefghijklmnopqrstuvwxyz".unicodeScalars {
            table[scalar] = (String(scalar), false)
            table[Unicode.Scalar(scalar.value - 32)!] = (String(scalar), true)
        }
        for (index, digit) in "0123456789".unicodeScalars.enumerated() {
            table[digit] = ("digit_\(index)", false)
        }
        for (shifted, index) in zip(")!@#$%^&*(".unicodeScalars, 0...) {
            table[shifted] = ("digit_\(index)", true)
        }
        let punctuation: [(Character, Character, String)] = [
            ("-", "_", "minus"), ("=", "+", "equal"), ("[", "{", "bracket_left"), ("]", "}", "bracket_right"),
            ("\\", "|", "backslash"), (";", ":", "semicolon"), ("'", "\"", "quote"), (",", "<", "comma"),
            (".", ">", "period"), ("/", "?", "slash"), ("`", "~", "backquote"),
        ]
        for (plain, shifted, name) in punctuation {
            table[plain.unicodeScalars.first!] = (name, false)
            table[shifted.unicodeScalars.first!] = (name, true)
        }
        return table
    }()

    private static let unshiftedCharacter: [String: Unicode.Scalar] = {
        var table: [String: Unicode.Scalar] = [:]
        for (scalar, (name, shifted)) in typing where !shifted { table[name] = scalar }
        return table
    }()

    private static let names: [UIKeyboardHIDUsage: String] = {
        var table: [UIKeyboardHIDUsage: String] = [
            .keyboardReturnOrEnter: "enter", .keyboardEscape: "escape", .keyboardDeleteOrBackspace: "backspace",
            .keyboardTab: "tab", .keyboardSpacebar: "space", .keyboardHyphen: "minus", .keyboardEqualSign: "equal",
            .keyboardOpenBracket: "bracket_left", .keyboardCloseBracket: "bracket_right",
            .keyboardBackslash: "backslash", .keyboardSemicolon: "semicolon", .keyboardQuote: "quote",
            .keyboardGraveAccentAndTilde: "backquote", .keyboardComma: "comma", .keyboardPeriod: "period",
            .keyboardSlash: "slash", .keyboardCapsLock: "caps_lock",
            .keyboardRightArrow: "arrow_right", .keyboardLeftArrow: "arrow_left",
            .keyboardDownArrow: "arrow_down", .keyboardUpArrow: "arrow_up",
            .keyboardHome: "home", .keyboardEnd: "end", .keyboardPageUp: "page_up", .keyboardPageDown: "page_down",
            .keyboardDeleteForward: "delete", .keyboardInsert: "insert",
        ]
        let letters: [UIKeyboardHIDUsage] = [
            .keyboardA, .keyboardB, .keyboardC, .keyboardD, .keyboardE, .keyboardF, .keyboardG, .keyboardH,
            .keyboardI, .keyboardJ, .keyboardK, .keyboardL, .keyboardM, .keyboardN, .keyboardO, .keyboardP,
            .keyboardQ, .keyboardR, .keyboardS, .keyboardT, .keyboardU, .keyboardV, .keyboardW, .keyboardX,
            .keyboardY, .keyboardZ,
        ]
        for (usage, letter) in zip(letters, "abcdefghijklmnopqrstuvwxyz") { table[usage] = String(letter) }
        let digits: [UIKeyboardHIDUsage] = [
            .keyboard0, .keyboard1, .keyboard2, .keyboard3, .keyboard4,
            .keyboard5, .keyboard6, .keyboard7, .keyboard8, .keyboard9,
        ]
        for (index, usage) in digits.enumerated() { table[usage] = "digit_\(index)" }
        let functions: [UIKeyboardHIDUsage] = [
            .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
            .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12,
        ]
        for (index, usage) in functions.enumerated() { table[usage] = "f\(index + 1)" }
        return table
    }()
}
