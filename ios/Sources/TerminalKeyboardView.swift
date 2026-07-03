import UIKit

/// One configurable control key: what Settings shows and what the key sends.
/// The catalog is curated from Claude Code's interactive-mode shortcuts — a
/// picker over known-good keys, not a raw byte-sequence builder.
struct TerminalControlKey {
    let id: String
    let title: String
    /// Settings subtitle — what the key does in Claude Code's TUI.
    let detail: String
    let payload: Data
}

enum TerminalKeyCatalog {
    /// Display order everywhere: on the keyboard and in Settings. Defaults
    /// lead, the long tail follows.
    static let all: [TerminalControlKey] = [
        TerminalControlKey(
            id: "shiftTab", title: "⇧⇥",
            detail: "Cycle permission modes — default, accept edits, plan",
            payload: Data("\u{1B}[Z".utf8)
        ),
        TerminalControlKey(
            id: "tab", title: "tab",
            detail: "Autocomplete, accept a suggestion",
            payload: Data([0x09])
        ),
        TerminalControlKey(
            id: "ctrlO", title: "^O",
            detail: "Toggle the transcript viewer (what the agent did)",
            payload: Data([0x0F])
        ),
        TerminalControlKey(
            id: "ctrlC", title: "^C",
            detail: "Interrupt — pressed twice while idle it exits the agent",
            payload: Data([0x03])
        ),
        TerminalControlKey(
            id: "ctrlL", title: "^L",
            detail: "Redraw a glitched screen",
            payload: Data([0x0C])
        ),
        TerminalControlKey(
            id: "ctrlB", title: "^B",
            detail: "Move the running task to the background",
            payload: Data([0x02])
        ),
        TerminalControlKey(
            id: "ctrlT", title: "^T",
            detail: "Toggle the task checklist",
            payload: Data([0x14])
        ),
        TerminalControlKey(
            id: "ctrlR", title: "^R",
            detail: "Search prompt history",
            payload: Data([0x12])
        ),
        TerminalControlKey(
            id: "ctrlZ", title: "^Z",
            detail: "Suspend the foreground process",
            payload: Data([0x1A])
        ),
        TerminalControlKey(
            id: "ctrlD", title: "^D",
            detail: "End of file — exits a shell or REPL",
            payload: Data([0x04])
        ),
        TerminalControlKey(
            id: "yes", title: "y",
            detail: "Answer yes to plain CLI prompts",
            payload: Data("y".utf8)
        ),
        TerminalControlKey(
            id: "no", title: "n",
            detail: "Answer no to plain CLI prompts",
            payload: Data("n".utf8)
        ),
    ]

    /// The research-backed hot set for driving Claude Code from a phone.
    /// Tab earns its default slot on ubiquity: 11 of 12 surveyed mobile
    /// terminals ship it on their bar (completion + field navigation).
    static let defaultIDs = ["shiftTab", "tab", "ctrlO", "ctrlC", "ctrlL"]

    static func keys(for ids: [String]) -> [TerminalControlKey] {
        all.filter { ids.contains($0.id) }
    }
}

/// A swap-in keyboard for driving the TUI directly — summoned the way iOS
/// switches to the number or handwriting keyboard (the composer's ⌨︎ button
/// sets it as the text view's `inputView`). While it is up every key is a raw
/// PTY byte, so there is no caret-vs-terminal ambiguity: the mode *is* the
/// keyboard. The 🌐 key hands back to the system keyboard, mirroring where
/// iOS puts its own globe.
///
/// The fixed core is the Claude Code hot set — esc (hold for esc-esc, the
/// rewind menu), menu numbers, arrows, return; Settings ▸ Terminal Keyboard
/// picks which control keys from the catalog join it. Vim-grade completeness
/// is a non-goal.
final class TerminalKeyboardView: UIInputView {
    /// Raw bytes for the PTY — the owner writes them to the terminal.
    var onKey: ((Data) -> Void)?
    /// The 🌐 key: restore the system keyboard.
    var onSwitchBack: (() -> Void)?

    private struct Key {
        let title: String
        let payload: Data
        var symbolName: String?
        var repeats = false
    }

    // System-keyboard metrics, pixel-measured off iOS 26 (iPhone 16 Pro,
    // 402pt): 43pt keycaps on a 54pt row pitch (11pt between rows), keys
    // 7pt apart and 7pt from the screen edges. The keycap height only
    // decides the self-sized fallback — under a matched system-keyboard
    // height the rows keep their pitch and the slack pools on top.
    private static let rowHeight: CGFloat = 43
    private static let rowSpacing: CGFloat = 11
    private static let keySpacing: CGFloat = 7
    private static let edgeInset: CGFloat = 7
    /// Above this a control row splits, evenly, so keys stay thumb-sized
    /// (the system fits 10 per row; 7 keeps ~49pt caps).
    private static let maxKeysPerRow = 7
    /// The strip under the key plane where the system parks its bare globe
    /// key (measured: the plane ends ~44pt above the safe-area bottom).
    private static let globeBandHeight: CGFloat = 44
    /// System return key: 92pt of the 388pt usable row.
    private static let returnWidthFraction: CGFloat = 92.0 / 388.0

    private let column = UIStackView()
    private var globe: UIButton!
    private var matchedHeight: NSLayoutConstraint?
    private var preferredHeight: NSLayoutConstraint?
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var settingsObserver: NSObjectProtocol?

    /// Pins the whole view to the system keyboard's measured height. Swapping
    /// an inputView keeps the keyboard container at its current height, so a
    /// shorter self-sized view leaves dead glass below the last row — match
    /// the container instead and let the rows stretch into it.
    func matchSystemKeyboardHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        if let matchedHeight {
            matchedHeight.constant = height
            return
        }
        let constraint = heightAnchor.constraint(equalToConstant: height)
        // Just below required: the system's own placement constraints win if
        // they ever disagree.
        constraint.priority = .required - 1
        constraint.isActive = true
        matchedHeight = constraint
    }

    init() {
        super.init(frame: .zero, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false

        column.axis = .vertical
        column.spacing = Self.rowSpacing
        column.distribution = .fillEqually
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // The keyboard's height comes from these constraints
        // (allowsSelfSizing) — the matched system height when known, the
        // preferred keycap rows otherwise; the safe-area bottom keeps the
        // last row above the home indicator. Rows pin to the BOTTOM at their
        // natural keycap height: under a taller matched height the slack
        // pools at the top (where the system parks QuickType), so keycaps
        // stay 42pt and sit exactly where the system's own keys sit —
        // stretching the rows to fill instead reads as a 63pt-key bug.
        let hugTop = column.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        hugTop.priority = .defaultHigh
        // The key plane stops a globe-band above the safe area, and the
        // globe sits below it as a bare icon — where the system keyboard
        // puts its own (center 43pt from the left edge).
        globe = makeGlobeButton()
        addSubview(globe)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.edgeInset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.edgeInset),
            column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            hugTop,
            column.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Self.globeBandHeight
            ),
            globe.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 43),
            globe.centerYAnchor.constraint(
                equalTo: column.bottomAnchor, constant: Self.globeBandHeight / 2
            ),
            globe.widthAnchor.constraint(equalToConstant: 44),
            globe.heightAnchor.constraint(equalToConstant: 44),
        ])

        rebuild()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: MobileSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuild()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // UIInputView's built-in `.keyboard` material still renders as the
        // legacy flat grey slab, layered over the much lighter Liquid Glass
        // backdrop the real keyboard sits on — hide it so the keycaps float
        // on the same glass as the system keys. (UIKit inserts the material
        // as a sibling subview of `column`, sometimes after init.)
        for view in subviews where view !== column && view !== globe {
            view.isHidden = true
        }
    }

    // MARK: - Layout

    private func rebuild() {
        column.arrangedSubviews.forEach { view in
            column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // The top row keeps the physical keyboard's corners (Fitts: corners
        // are the fastest targets): esc top-left, its spot since the VT100,
        // and ⌫ top-right, where every layout since the typewriter has put
        // it. ⌫ sends DEL 0x7F — the byte every surveyed terminal sends —
        // and auto-repeats; without it a typo at a raw prompt would force a
        // switch back to the system keyboard, which this keyboard replaces.
        // Configurable keys fill the row between the corners; overflow
        // drops to rows below.
        let bksp = makeKeyButton(Key(
            title: "⌫", payload: Data([0x7F]), symbolName: "delete.left", repeats: true
        ))
        let configurable = TerminalKeyCatalog
            .keys(for: MobileSettings.shared.terminalKeyIDs)
            .map { makeKeyButton(Key(title: $0.title, payload: $0.payload)) }
        let betweenCorners = Self.maxKeysPerRow - 2
        column.addArrangedSubview(makeRow(
            [makeEscButton()] + Array(configurable.prefix(betweenCorners)) + [bksp]
        ))
        let overflow = Array(configurable.dropFirst(betweenCorners))
        if !overflow.isEmpty {
            for chunk in Self.split(overflow, limit: Self.maxKeysPerRow) {
                column.addArrangedSubview(makeRow(chunk))
            }
        }

        // Digits answer the agent's option menus.
        column.addArrangedSubview(makeRow(["1", "2", "3", "4"].map { digit in
            makeKeyButton(Key(title: digit, payload: Data(digit.utf8)))
        }))
        // Bottom plane row mirrors the system's: return anchors the right
        // corner at the system return key's width, arrows share the rest.
        let arrows = [
            Key(title: "←", payload: Data("\u{1B}[D".utf8), symbolName: "arrow.left", repeats: true),
            Key(title: "↓", payload: Data("\u{1B}[B".utf8), symbolName: "arrow.down", repeats: true),
            Key(title: "↑", payload: Data("\u{1B}[A".utf8), symbolName: "arrow.up", repeats: true),
            Key(title: "→", payload: Data("\u{1B}[C".utf8), symbolName: "arrow.right", repeats: true),
        ].map(makeKeyButton)
        let enter = makeKeyButton(Key(
            title: "return", payload: Data("\r".utf8), symbolName: "return"
        ))
        let lastRow = UIStackView(arrangedSubviews: arrows + [enter])
        lastRow.axis = .horizontal
        lastRow.spacing = Self.keySpacing
        for arrow in arrows.dropFirst() {
            arrow.widthAnchor.constraint(equalTo: arrows[0].widthAnchor).isActive = true
        }
        enter.widthAnchor.constraint(
            equalTo: lastRow.widthAnchor, multiplier: Self.returnWidthFraction
        ).isActive = true
        column.addArrangedSubview(lastRow)

        // Native 42pt keycaps. Outranks hugTop (750) so a taller matched
        // height breaks the top hug — slack above, not inside the rows — but
        // still breakable itself, so a SHORTER container (landscape) evenly
        // compresses the rows instead of clipping them.
        preferredHeight?.isActive = false
        let rows = column.arrangedSubviews.count
        let height = column.heightAnchor.constraint(
            equalToConstant: CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * Self.rowSpacing
        )
        height.priority = UILayoutPriority(900)
        height.isActive = true
        preferredHeight = height
    }

    /// Splits an overfull control zone into evenly sized rows (7 keys → 4+3,
    /// never 5+2).
    private static func split(_ buttons: [UIButton], limit: Int) -> [[UIButton]] {
        let rowCount = max(1, Int(ceil(Double(buttons.count) / Double(limit))))
        var rows: [[UIButton]] = []
        var index = 0
        for row in 0..<rowCount {
            let take = Int(ceil(Double(buttons.count - index) / Double(rowCount - row)))
            rows.append(Array(buttons[index ..< index + take]))
            index += take
        }
        return rows
    }

    private func makeRow(_ buttons: [UIButton]) -> UIView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.spacing = Self.keySpacing
        row.distribution = .fillEqually
        return row
    }

    /// The system's globe, replicated: a bare icon below the key plane, no
    /// keycap behind it.
    private func makeGlobeButton() -> UIButton {
        var config = UIButton.Configuration.plain()
        // iOS 26's plain configuration ships a glass background with its own
        // soft shadow — strip it so only the icon shows.
        config.background = .clear()
        config.image = UIImage(systemName: "globe")
        config.preferredSymbolConfigurationForImage = .init(pointSize: 21, weight: .regular)
        config.baseForegroundColor = KeyCapButton.keyForeground
        let globe = UIButton(configuration: config)
        globe.translatesAutoresizingMaskIntoConstraints = false
        globe.accessibilityLabel = "Switch to system keyboard"
        globe.addAction(UIAction { [weak self] _ in
            self?.haptic.impactOccurred()
            self?.onSwitchBack?()
        }, for: .touchUpInside)
        return globe
    }

    // MARK: - Keys

    /// esc with a hold: tap interrupts, a long press sends esc-esc — Claude
    /// Code's rewind menu (or clear-draft), which has no single-key form.
    private func makeEscButton() -> UIButton {
        let button = makeKeyButton(Key(title: "esc", payload: Data([0x1B])))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(escHeld(_:)))
        hold.cancelsTouchesInView = true
        button.addGestureRecognizer(hold)
        return button
    }

    @objc private func escHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        haptic.impactOccurred()
        onKey?(Data([0x1B]))
        // Two distinct presses, not one write: back-to-back 0x1B bytes read
        // as a single Alt-prefixed key to a terminal parser.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.onKey?(Data([0x1B]))
        }
    }

    private func makeKeyButton(_ key: Key) -> UIButton {
        // A single character means the key types that character — those get
        // the white keycap and the big letter-key font; everything else
        // (esc, ^C, arrows, return) is a gray function key with a 16pt label.
        let typesACharacter = key.symbolName == nil && key.title.count == 1

        var config = UIButton.Configuration.plain()
        // Same glass-background strip as the globe key (see makeBottomRow).
        config.background = .clear()
        config.contentInsets = .zero
        config.baseForegroundColor = KeyCapButton.keyForeground
        if let symbolName = key.symbolName {
            config.image = UIImage(systemName: symbolName)
            config.preferredSymbolConfigurationForImage = .init(pointSize: 18, weight: .regular)
        } else {
            config.title = key.title
            let font = UIFont.systemFont(ofSize: typesACharacter ? 25 : 16)
            config.titleTextAttributesTransformer = .init { attributes in
                var attributes = attributes
                attributes.font = font
                return attributes
            }
        }

        let fire: () -> Void = { [weak self] in
            self?.haptic.impactOccurred()
            self?.onKey?(key.payload)
        }
        let button: KeyCapButton
        if key.repeats {
            let repeating = RepeatingKeyButton(configuration: config)
            repeating.onFire = fire
            button = repeating
        } else {
            button = KeyCapButton(configuration: config)
            button.addAction(UIAction { _ in fire() }, for: .touchUpInside)
        }
        button.keyCapRole = typesACharacter ? .character : .function
        button.accessibilityLabel = key.title
        return button
    }
}

/// The system keyboard's keycap, replicated. Pixel-measured off iOS 26's
/// light keyboard: EVERY key face is white there — the classic #ABB1BA
/// function-key gray is gone — so in light mode the roles share a white cap
/// and presses flash gray. Dark mode keeps the two-tone scheme (#6B6B6B
/// letters, #474747 functions) with the native pressed palette swap. A 1pt
/// crisp bottom shadow under every cap.
///
/// Styling is opt-in via `keyCapRole` so `RepeatingKeyButton` subclasses can
/// live elsewhere unstyled.
class KeyCapButton: UIButton {
    enum Role {
        /// Types a character — the white letter-key cap.
        case character
        /// Modifier or action — the gray cap of shift, return, 123.
        case function
    }

    var keyCapRole: Role? {
        didSet {
            guard keyCapRole != nil else { return }
            if !observesTraits {
                observesTraits = true
                registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                    (button: KeyCapButton, _) in button.applyKeyCap()
                }
            }
            applyKeyCap()
        }
    }

    override var isHighlighted: Bool {
        didSet { if keyCapRole != nil { applyKeyCap() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard keyCapRole != nil else { return }
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds, cornerRadius: Self.cornerRadius
        ).cgPath
    }

    /// Measured: a 99px key reads 56px wide at its top scanline, so the
    /// corner arc is ~21.5px ≈ 7pt on a 43pt cap.
    private static let cornerRadius: CGFloat = 7

    static let keyForeground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : .black
    }
    private static let characterBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0x6B / 255.0, alpha: 1) : .white
    }
    private static let functionBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0x47 / 255.0, alpha: 1) : .white
    }
    /// Light mode's pressed flash — both roles are white at rest there, so
    /// the dark-mode palette swap would be invisible; dim toward the
    /// backdrop (#E0E1E5) instead.
    private static let lightPressed = UIColor(
        red: 0xD1 / 255.0, green: 0xD4 / 255.0, blue: 0xDA / 255.0, alpha: 1
    )
    private static let keyShadow = UIColor { traits in
        UIColor(white: 0, alpha: traits.userInterfaceStyle == .dark ? 0.7 : 0.3)
    }

    private var observesTraits = false

    private func applyKeyCap() {
        guard let role = keyCapRole else { return }
        let background: UIColor
        if isHighlighted, traitCollection.userInterfaceStyle != .dark {
            background = Self.lightPressed
        } else {
            // Dark mode (and rest state): the native palette — pressed keys
            // swap tones, which in light mode is a white-on-white no-op.
            let swapped = (role == .character) != isHighlighted
            background = swapped ? Self.characterBackground : Self.functionBackground
        }
        // Paint the cap through the configuration's background — fighting it
        // with a raw `layer.backgroundColor`/`cornerRadius` loses on iOS 26,
        // where the configuration render pass rewrites the layer (and its
        // stock glass background drew a second, offset "cap" behind ours).
        var cap = UIBackgroundConfiguration.clear()
        cap.backgroundColor = background.resolvedColor(with: traitCollection)
        cap.cornerRadius = Self.cornerRadius
        configuration?.background = cap
        layer.shadowColor = Self.keyShadow.resolvedColor(with: traitCollection).cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }
}

/// A button that behaves like a held key: a tap fires once, holding fires and
/// then repeats — long agent menus would otherwise cost one tap per row.
/// Used by the terminal keyboard's arrows; keycap styling only kicks in when
/// a `keyCapRole` is set.
final class RepeatingKeyButton: KeyCapButton {
    var onFire: (() -> Void)?

    private static let initialDelay: TimeInterval = 0.4
    private static let repeatInterval: TimeInterval = 0.12

    private var repeatTimer: Timer?
    private var heldLongEnoughToRepeat = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(pressBegan), for: .touchDown)
        addTarget(
            self, action: #selector(pressEnded),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        repeatTimer?.invalidate()
    }

    @objc private func pressBegan() {
        heldLongEnoughToRepeat = false
        let timer = Timer(timeInterval: Self.initialDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginRepeating() }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func beginRepeating() {
        heldLongEnoughToRepeat = true
        onFire?()
        let timer = Timer(timeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFire?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    @objc private func pressEnded() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        // A quick tap never reached the repeat threshold — fire it once here;
        // a held press already delivered its keys.
        if !heldLongEnoughToRepeat {
            onFire?()
        }
        heldLongEnoughToRepeat = false
    }
}
