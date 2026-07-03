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
            id: "tab", title: "tab",
            detail: "Autocomplete, accept a suggestion",
            payload: Data([0x09])
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
    static let defaultIDs = ["shiftTab", "ctrlO", "ctrlC", "ctrlL"]

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

    private static let rowHeight: CGFloat = 46
    private static let spacing: CGFloat = 7
    /// Above this a control row splits, evenly, so keys stay thumb-sized.
    private static let maxKeysPerRow = 5

    private let column = UIStackView()
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var settingsObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false

        column.axis = .vertical
        column.spacing = Self.spacing
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // The keyboard's height comes purely from these constraints
        // (allowsSelfSizing); the safe-area bottom keeps the last row above
        // the home indicator.
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
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

    // MARK: - Layout

    private func rebuild() {
        column.arrangedSubviews.forEach { view in
            column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // esc leads the control zone; the rest comes from Settings.
        let controls = [makeEscButton()] + TerminalKeyCatalog
            .keys(for: MobileSettings.shared.terminalKeyIDs)
            .map { makeKeyButton(Key(title: $0.title, payload: $0.payload)) }
        for chunk in Self.split(controls, limit: Self.maxKeysPerRow) {
            column.addArrangedSubview(makeRow(chunk))
        }

        column.addArrangedSubview(makeRow(["1", "2", "3", "4"].map { digit in
            makeKeyButton(Key(title: digit, payload: Data(digit.utf8)))
        }))
        column.addArrangedSubview(makeRow([
            Key(title: "←", payload: Data("\u{1B}[D".utf8), symbolName: "arrow.left", repeats: true),
            Key(title: "↓", payload: Data("\u{1B}[B".utf8), symbolName: "arrow.down", repeats: true),
            Key(title: "↑", payload: Data("\u{1B}[A".utf8), symbolName: "arrow.up", repeats: true),
            Key(title: "→", payload: Data("\u{1B}[C".utf8), symbolName: "arrow.right", repeats: true),
        ].map(makeKeyButton)))
        column.addArrangedSubview(makeBottomRow())

        for row in column.arrangedSubviews {
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        }
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
        row.spacing = Self.spacing
        row.distribution = .fillEqually
        return row
    }

    /// System-keyboard bottom row: globe on the left, a wide Return filling
    /// the rest.
    private func makeBottomRow() -> UIView {
        var globeConfig = UIButton.Configuration.gray()
        globeConfig.image = UIImage(systemName: "globe")
        globeConfig.cornerStyle = .medium
        let globe = UIButton(configuration: globeConfig)
        globe.accessibilityLabel = "Switch to system keyboard"
        globe.addAction(UIAction { [weak self] _ in
            self?.haptic.impactOccurred()
            self?.onSwitchBack?()
        }, for: .touchUpInside)

        let enter = makeKeyButton(Key(title: "return", payload: Data("\r".utf8)))

        let row = UIStackView(arrangedSubviews: [globe, enter])
        row.axis = .horizontal
        row.spacing = Self.spacing
        globe.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.22).isActive = true
        return row
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
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .medium
        if let symbolName = key.symbolName {
            config.image = UIImage(systemName: symbolName)
            config.preferredSymbolConfigurationForImage = .init(pointSize: 16, weight: .medium)
        } else {
            config.title = key.title
            config.titleTextAttributesTransformer = .init { attributes in
                var attributes = attributes
                attributes.font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
                return attributes
            }
        }

        let fire: () -> Void = { [weak self] in
            self?.haptic.impactOccurred()
            self?.onKey?(key.payload)
        }
        let button: UIButton
        if key.repeats {
            let repeating = RepeatingKeyButton(configuration: config)
            repeating.onFire = fire
            button = repeating
        } else {
            button = UIButton(configuration: config)
            button.addAction(UIAction { _ in fire() }, for: .touchUpInside)
        }
        button.accessibilityLabel = key.title
        return button
    }
}

/// A button that behaves like a held key: a tap fires once, holding fires and
/// then repeats — long agent menus would otherwise cost one tap per row.
/// Shared by the composer's answer chips and the terminal keyboard's arrows.
final class RepeatingKeyButton: UIButton {
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
