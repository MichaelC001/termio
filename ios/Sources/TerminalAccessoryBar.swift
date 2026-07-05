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
    /// Display order everywhere: on the bar and in Settings. Defaults lead,
    /// the long tail follows.
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
    ]

    /// The research-backed hot set for driving Claude Code from a phone.
    /// Tab earns its default slot on ubiquity: 11 of 12 surveyed mobile
    /// terminals ship it on their bar (completion + field navigation).
    static let defaultIDs = ["shiftTab", "tab", "ctrlO", "ctrlC", "ctrlL"]

    static func keys(for ids: [String]) -> [TerminalControlKey] {
        all.filter { ids.contains($0.id) }
    }
}

/// The control-key strip docked above the system keyboard while the composer
/// is focused — the Blink/Termux pattern. The system keyboard keeps every
/// letter, digit, symbol, and language; this bar only carries what a terminal
/// needs and the keyboard lacks: esc, the configured control keys, and the
/// arrows. Keys write raw PTY bytes through `onKey`; the draft is untouched,
/// so typing still composes a prompt and the bar drives the TUI alongside it.
///
/// esc holds for esc-esc (Claude Code's rewind menu); arrows auto-repeat for
/// walking long menus. Which control keys appear comes from Settings ▸
/// Terminal Keyboard, so the bar rebuilds on `MobileSettings.didChange`.
final class TerminalAccessoryBar: UIInputView {
    /// Raw bytes for the PTY — the owner writes them to the terminal.
    var onKey: ((Data) -> Void)?

    /// One slim strip, not a second keyboard — a compact keycap centered in
    /// the bar so the terminal keeps as many rows as possible.
    static let barHeight: CGFloat = 44
    private static let keyHeight: CGFloat = 30
    private static let keySpacing: CGFloat = 6

    private let scroll = UIScrollView()
    private let row = UIStackView()
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var settingsObserver: NSObjectProtocol?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.barHeight),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = .flexibleWidth

        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.keyboardDismissMode = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        row.axis = .horizontal
        row.spacing = Self.keySpacing
        // Center the fixed-height keys in the taller bar — filling would fight
        // the height constraint and stretch the keys edge to edge.
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
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

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight)
    }

    // MARK: - Layout

    private func rebuild() {
        row.arrangedSubviews.forEach { view in
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // esc leads (its spot since the VT100), then the keys the user picked
        // in Settings. The arrows — the highest-frequency navigation keys —
        // ride right after tab so they stay in the always-visible zone instead
        // of scrolling off the end; if tab is off they lead, right after esc.
        // Everything the system keyboard already provides (letters, digits,
        // symbols, return, backspace) is left to it — no y/n or number keys.
        row.addArrangedSubview(makeEscButton())
        let configured = TerminalKeyCatalog.keys(for: MobileSettings.shared.terminalKeyIDs)
        if !configured.contains(where: { $0.id == "tab" }) { addArrows() }
        for key in configured {
            row.addArrangedSubview(makeKeyButton(title: key.title, payload: key.payload))
            if key.id == "tab" { addArrows() }
        }
    }

    private func addArrows() {
        for arrow in [
            (title: "←", bytes: "\u{1B}[D"),
            (title: "↓", bytes: "\u{1B}[B"),
            (title: "↑", bytes: "\u{1B}[A"),
            (title: "→", bytes: "\u{1B}[C"),
        ] {
            row.addArrangedSubview(
                makeKeyButton(title: arrow.title, payload: Data(arrow.bytes.utf8), repeats: true)
            )
        }
    }

    // MARK: - Keys

    private func makeKeyButton(title: String, payload: Data, repeats: Bool = false) -> UIButton {
        var config: UIButton.Configuration = if #available(iOS 26.0, *) {
            .glass()
        } else {
            .gray()
        }
        config.title = title
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
        config.titleTextAttributesTransformer = .init { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 15)
            return attributes
        }

        let fire: () -> Void = { [weak self] in
            self?.haptic.impactOccurred()
            self?.onKey?(payload)
        }
        let button: UIButton
        if repeats {
            let repeating = RepeatingKeyButton(configuration: config)
            repeating.onFire = fire
            button = repeating
        } else {
            button = UIButton(configuration: config)
            button.addAction(UIAction { _ in fire() }, for: .touchUpInside)
        }
        button.accessibilityLabel = title
        button.titleLabel?.numberOfLines = 1
        button.heightAnchor.constraint(equalToConstant: Self.keyHeight).isActive = true
        // Keep each key at its natural width so the row overflows and the strip
        // scrolls — without required resistance the scroll view compresses the
        // keys to fit and short titles like "tab" wrap character-by-character.
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    /// esc with a hold: tap interrupts, a long press sends esc-esc — Claude
    /// Code's rewind menu (or clear-draft), which has no single-key form.
    private func makeEscButton() -> UIButton {
        let button = makeKeyButton(title: "esc", payload: Data([0x1B]))
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
}

/// A button that behaves like a held key: a tap fires once, holding fires and
/// then repeats — long agent menus would otherwise cost one tap per row.
/// Used by the accessory bar's arrows.
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
