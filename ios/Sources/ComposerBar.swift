import UIKit

/// One tappable chip above the composer — since the slash commands moved
/// into the type-"/" suggestion panel this row only carries answer keys
/// while the agent is blocked on a prompt. Styled like keyboard keys, not
/// accent pills: the row only existing during a prompt is already the
/// urgency signal, and the system keyboard sits right below.
struct ComposerChip {
    let title: String
    let payload: Data
    /// Holding the chip repeats its payload (arrow keys walking a long menu).
    var repeats = false
}

/// One entry of the "/" autocomplete catalog (name without the slash).
struct SlashCommand {
    let name: String
    let detail: String
}

/// Moshi/ChatGPT-style prompt composer: draft the whole message in a native
/// text view — autocorrect, dictation, and CJK input all work, everything a
/// raw keystroke stream loses — then deliver it to the PTY as one atomic
/// write. Return adds a newline; only the send button submits, so dictation
/// can never fire a half-formed prompt.
///
/// Typing "/" as the first character opens a Telegram-style command panel
/// (prefix-filtered live, tap = send now, arrow = insert to add arguments) —
/// the bot-command interaction from Telegram's ChatInterfaceInputContexts,
/// where the query dies on the first whitespace.
final class ComposerBar: UIView {
    var onSend: ((String) -> Void)?
    var onChip: ((ComposerChip) -> Void)?
    var onAttach: (() -> Void)?
    /// Raw bytes a hardware keyboard aimed at the TUI (arrows, Esc, Return
    /// while the draft is empty) — the owner writes them to the PTY.
    var onTerminalKey: ((Data) -> Void)?

    /// The agent's command catalog; empty disables the "/" panel.
    var slashCommands: [SlashCommand] = []

    private let textView = ComposerTextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let keyboardButton = UIButton(type: .system)
    /// Built on first use; staying set across focus cycles means the user's
    /// keyboard choice survives dismiss/reopen, like any system keyboard.
    private lazy var terminalKeyboard: TerminalKeyboardView = {
        let keyboard = TerminalKeyboardView()
        keyboard.onKey = { [weak self] payload in self?.onTerminalKey?(payload) }
        keyboard.onSwitchBack = { [weak self] in self?.setTerminalKeyboardActive(false) }
        return keyboard
    }()
    private let attachButton = UIButton(type: .system)
    private let attachSpinner = UIActivityIndicatorView(style: .medium)
    private let chipsScroll = UIScrollView()
    private let chipsStack = UIStackView()
    private let suggestionsPanel = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemUltraThinMaterial)
    )
    private let suggestionsStack = UIStackView()
    private var suggestionsHeight: NSLayoutConstraint!
    private var textHeight: NSLayoutConstraint!
    private var textLeadingWithAttach: NSLayoutConstraint!
    private var textLeadingFlush: NSLayoutConstraint!

    private static let minTextHeight: CGFloat = 36
    private static let maxTextHeight: CGFloat = 120
    private static let suggestionRowHeight: CGFloat = 44
    /// 4.5 rows: the half row signals there is more to scroll (Telegram's trick).
    private static let maxSuggestionsHeight: CGFloat = 198

    init() {
        super.init(frame: .zero)

        configureSuggestionsPanel()

        chipsStack.axis = .horizontal
        chipsStack.spacing = 6
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        chipsScroll.showsHorizontalScrollIndicator = false
        chipsScroll.addSubview(chipsStack)
        chipsScroll.isHidden = true

        let pillWrapper = UIView()
        let pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        pill.clipsToBounds = true
        pill.layer.cornerRadius = 22
        pill.layer.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false
        pillWrapper.addSubview(pill)

        let suggestionsWrapper = UIView()
        suggestionsWrapper.isHidden = true
        suggestionsPanel.translatesAutoresizingMaskIntoConstraints = false
        suggestionsWrapper.addSubview(suggestionsPanel)
        NSLayoutConstraint.activate([
            suggestionsPanel.leadingAnchor.constraint(equalTo: suggestionsWrapper.leadingAnchor, constant: 8),
            suggestionsPanel.trailingAnchor.constraint(equalTo: suggestionsWrapper.trailingAnchor, constant: -8),
            suggestionsPanel.topAnchor.constraint(equalTo: suggestionsWrapper.topAnchor),
            suggestionsPanel.bottomAnchor.constraint(equalTo: suggestionsWrapper.bottomAnchor),
        ])

        let column = UIStackView(arrangedSubviews: [suggestionsWrapper, chipsScroll, pillWrapper])
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // Attachments: photos/files land on the Mac, their path lands in the
        // draft (hidden until the session can actually receive uploads).
        attachButton.setImage(UIImage(systemName: "plus.circle"), for: .normal)
        attachButton.setPreferredSymbolConfiguration(.init(pointSize: 26), forImageIn: .normal)
        attachButton.accessibilityLabel = "Attach"
        attachButton.tintColor = .secondaryLabel
        attachButton.isHidden = true
        attachButton.addAction(UIAction { [weak self] _ in
            self?.onAttach?()
        }, for: .touchUpInside)
        attachSpinner.hidesWhenStopped = true

        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.delegate = self
        textView.onTerminalKey = { [weak self] payload in self?.onTerminalKey?(payload) }

        placeholder.text = "Prompt"
        placeholder.font = textView.font
        placeholder.textColor = .tertiaryLabel

        // Telegram-scale controls: the send circle fills most of the pill's
        // height, the companions follow proportionally.
        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        sendButton.setPreferredSymbolConfiguration(.init(pointSize: 32), forImageIn: .normal)
        sendButton.accessibilityLabel = "Send"
        sendButton.addAction(UIAction { [weak self] _ in
            self?.submit()
        }, for: .touchUpInside)

        // Swap to the terminal keyboard the way iOS swaps to the number or
        // handwriting keyboard — by replacing the text view's inputView.
        keyboardButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
        keyboardButton.setPreferredSymbolConfiguration(.init(pointSize: 21), forImageIn: .normal)
        keyboardButton.accessibilityLabel = "Terminal keyboard"
        keyboardButton.tintColor = .secondaryLabel
        keyboardButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setTerminalKeyboardActive(textView.inputView == nil)
        }, for: .touchUpInside)

        for subview in [attachButton, attachSpinner, textView, placeholder, keyboardButton, sendButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            pill.contentView.addSubview(subview)
        }

        textHeight = textView.heightAnchor.constraint(equalToConstant: Self.minTextHeight)
        // The draft hugs the pill's edge until the attach button earns its
        // place (companion sessions only).
        textLeadingWithAttach = textView.leadingAnchor.constraint(
            equalTo: attachButton.trailingAnchor, constant: 6
        )
        textLeadingFlush = textView.leadingAnchor.constraint(
            equalTo: pill.contentView.leadingAnchor, constant: 14
        )
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            chipsScroll.heightAnchor.constraint(equalToConstant: 32),
            chipsStack.leadingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.leadingAnchor, constant: 10),
            chipsStack.trailingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.trailingAnchor, constant: -10),
            chipsStack.topAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.topAnchor),
            chipsStack.bottomAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.bottomAnchor),
            chipsStack.heightAnchor.constraint(equalTo: chipsScroll.frameLayoutGuide.heightAnchor),
            pill.leadingAnchor.constraint(equalTo: pillWrapper.leadingAnchor, constant: 8),
            pill.trailingAnchor.constraint(equalTo: pillWrapper.trailingAnchor, constant: -8),
            pill.topAnchor.constraint(equalTo: pillWrapper.topAnchor),
            pill.bottomAnchor.constraint(equalTo: pillWrapper.bottomAnchor),
            attachButton.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 8),
            attachButton.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -8),
            attachButton.widthAnchor.constraint(equalToConstant: 32),
            attachButton.heightAnchor.constraint(equalToConstant: 32),
            attachSpinner.centerXAnchor.constraint(equalTo: attachButton.centerXAnchor),
            attachSpinner.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
            textLeadingFlush,
            textView.trailingAnchor.constraint(equalTo: keyboardButton.leadingAnchor, constant: -4),
            keyboardButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -4),
            keyboardButton.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -6),
            keyboardButton.widthAnchor.constraint(equalToConstant: 34),
            keyboardButton.heightAnchor.constraint(equalToConstant: 34),
            textView.topAnchor.constraint(equalTo: pill.contentView.topAnchor, constant: 4),
            textView.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -4),
            textHeight,
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
            placeholder.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
            sendButton.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -6),
            sendButton.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -4),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        refreshControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        textView.becomeFirstResponder()
    }

    func unfocus() {
        textView.resignFirstResponder()
    }

    /// Swaps between the system keyboard and the terminal keyboard in place
    /// (reloadInputViews animates it like a 🌐 switch). While the terminal
    /// keyboard is up nothing can land in the draft, so the placeholder
    /// says where the keys are going instead of inviting a prompt.
    private func setTerminalKeyboardActive(_ active: Bool) {
        textView.inputView = active ? terminalKeyboard : nil
        keyboardButton.setImage(
            UIImage(systemName: active ? "keyboard.fill" : "keyboard"), for: .normal
        )
        keyboardButton.tintColor = active ? .label : .secondaryLabel
        placeholder.text = active ? "Keys go to the terminal" : "Prompt"
        if textView.isFirstResponder {
            textView.reloadInputViews()
        } else {
            textView.becomeFirstResponder()
        }
    }

    /// Shows the attach (+) button — only sessions with a Mac behind them
    /// can receive uploads. The draft's leading edge follows.
    func setAttachAvailable(_ available: Bool) {
        attachButton.isHidden = !available
        if available {
            textLeadingFlush.isActive = false
            textLeadingWithAttach.isActive = true
        } else {
            textLeadingWithAttach.isActive = false
            textLeadingFlush.isActive = true
        }
    }

    /// Spins the attach slot while an upload is in flight.
    func setAttachBusy(_ busy: Bool) {
        attachButton.alpha = busy ? 0 : 1
        attachButton.isEnabled = !busy
        if busy { attachSpinner.startAnimating() } else { attachSpinner.stopAnimating() }
    }

    /// Appends text to the draft (an uploaded file's path), space-separated.
    func insertDraft(_ text: String) {
        let current = textView.text ?? ""
        if current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") {
            textView.text = current + text
        } else {
            textView.text = current + " " + text
        }
        refreshControls()
        refreshSuggestions()
    }

    /// Replaces the chip row. Empty hides the row entirely.
    func setChips(_ chips: [ComposerChip]) {
        chipsStack.arrangedSubviews.forEach { view in
            chipsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for chip in chips {
            // Floating over the terminal: glass capsules on iOS 26 (iMessage's
            // floating-control look). No accent tint — the row only existing
            // while the agent is blocked is the signal, and neutral keys match
            // the keyboard right below.
            var config: UIButton.Configuration = if #available(iOS 26.0, *) {
                .glass()
            } else {
                .gray()
            }
            config.title = chip.title
            config.cornerStyle = .capsule
            config.contentInsets = .init(top: 6, leading: 12, bottom: 6, trailing: 12)
            config.titleTextAttributesTransformer = .init { attributes in
                var attributes = attributes
                attributes.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                return attributes
            }
            let button: UIButton
            if chip.repeats {
                let repeating = RepeatingKeyButton(configuration: config)
                repeating.onFire = { [weak self] in self?.onChip?(chip) }
                button = repeating
            } else {
                button = UIButton(configuration: config)
                button.addAction(UIAction { [weak self] _ in
                    self?.onChip?(chip)
                }, for: .touchUpInside)
            }
            chipsStack.addArrangedSubview(button)
        }
        chipsScroll.isHidden = chips.isEmpty
    }

    private func submit() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textView.text = ""
        refreshControls()
        refreshSuggestions()
        onSend?(text)
    }

    private func refreshControls() {
        let empty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !textView.text.isEmpty
        sendButton.isEnabled = !empty
        sendButton.alpha = empty ? 0.35 : 1

        let fitting = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        textHeight.constant = min(max(fitting, Self.minTextHeight), Self.maxTextHeight)
        textView.isScrollEnabled = fitting > Self.maxTextHeight
    }

    // MARK: - Slash suggestions

    private func configureSuggestionsPanel() {
        suggestionsPanel.clipsToBounds = true
        suggestionsPanel.layer.cornerRadius = 16
        suggestionsPanel.layer.cornerCurve = .continuous
        // Visibility is the WRAPPER's job (the stack collapses it); hiding
        // the panel itself here would stick — nothing ever unhides it.

        // Rows sit directly in the effect view's content — matches are
        // capped instead of scrolled, so no scroll layer is needed.
        suggestionsStack.axis = .vertical
        suggestionsStack.translatesAutoresizingMaskIntoConstraints = false
        suggestionsPanel.contentView.addSubview(suggestionsStack)

        suggestionsHeight = suggestionsPanel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            suggestionsHeight,
            suggestionsStack.leadingAnchor.constraint(equalTo: suggestionsPanel.contentView.leadingAnchor),
            suggestionsStack.trailingAnchor.constraint(equalTo: suggestionsPanel.contentView.trailingAnchor),
            suggestionsStack.topAnchor.constraint(equalTo: suggestionsPanel.contentView.topAnchor),
        ])

        // The panel hugs the pill's width, not the screen edge.
        suggestionsPanel.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Telegram's trigger rule: the query lives while the draft starts with
    /// "/" and contains no whitespace yet; it filters by prefix and dies the
    /// moment a space lands (arguments are free text).
    private func refreshSuggestions() {
        let text = textView.text ?? ""
        guard !slashCommands.isEmpty, text.hasPrefix("/"),
              !text.contains(where: \.isWhitespace) else {
            setSuggestions([])
            return
        }
        let query = text.dropFirst().lowercased()
        // Capped, not scrolled: typing another letter narrows the rest away
        // (Telegram shows a handful and relies on the query, not scrolling).
        let matches = slashCommands.filter { $0.name.lowercased().hasPrefix(query) }
        setSuggestions(Array(matches.prefix(4)))
    }

    private func setSuggestions(_ commands: [SlashCommand]) {
        suggestionsStack.arrangedSubviews.forEach { view in
            suggestionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for command in commands {
            suggestionsStack.addArrangedSubview(makeSuggestionRow(command))
        }
        // The wrapper (the stack's arranged view) is what collapses.
        suggestionsPanel.superview?.isHidden = commands.isEmpty
        suggestionsHeight.constant = min(
            CGFloat(commands.count) * Self.suggestionRowHeight,
            Self.maxSuggestionsHeight
        )
    }

    /// One row: tap sends the command now (Telegram sends bot commands on
    /// tap); the trailing arrow only inserts it, for commands taking
    /// arguments — Telegram's arrowButtonPressed. Plain labels + an overlay
    /// button: UIButton.Configuration text refused to render inside this
    /// effect-view stack, labels never fail.
    private func makeSuggestionRow(_ command: SlashCommand) -> UIView {
        let row = UIView()

        let name = UILabel()
        name.text = "/" + command.name
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = .label

        let detail = UILabel()
        detail.text = command.detail
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.textColor = .secondaryLabel

        let labels = UIStackView(arrangedSubviews: [name, detail])
        labels.axis = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.isUserInteractionEnabled = false

        let main = UIButton(type: .custom)
        main.accessibilityLabel = "Send /\(command.name)"
        main.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            textView.text = ""
            refreshControls()
            setSuggestions([])
            onSend?("/" + command.name)
        }, for: .touchUpInside)

        let insert = UIButton(type: .system)
        insert.setImage(UIImage(systemName: "arrow.up.left"), for: .normal)
        insert.tintColor = .tertiaryLabel
        insert.accessibilityLabel = "Insert /\(command.name)"
        insert.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            textView.text = "/" + command.name + " "
            refreshControls()
            refreshSuggestions()
        }, for: .touchUpInside)

        let hairline = UIView()
        hairline.backgroundColor = .separator.withAlphaComponent(0.4)

        for subview in [main, labels, insert, hairline] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: Self.suggestionRowHeight),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: insert.leadingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            main.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: insert.leadingAnchor),
            main.topAnchor.constraint(equalTo: row.topAnchor),
            main.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            insert.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            insert.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            insert.widthAnchor.constraint(equalToConstant: 36),
            insert.heightAnchor.constraint(equalToConstant: 36),
            hairline.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            hairline.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
        return row
    }
}

extension ComposerBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        refreshControls()
        refreshSuggestions()
    }
}

/// With an empty draft the hardware keyboard belongs to the TUI: arrows walk
/// the agent's menus, Esc cancels, Return confirms. The moment a draft exists
/// the keys revert to text editing, so caret movement and the
/// return-inserts-newline contract stay untouched.
private final class ComposerTextView: UITextView {
    var onTerminalKey: ((Data) -> Void)?

    private static let terminalKeyPayloads: [String: Data] = [
        UIKeyCommand.inputUpArrow: Data("\u{1B}[A".utf8),
        UIKeyCommand.inputDownArrow: Data("\u{1B}[B".utf8),
        UIKeyCommand.inputEscape: Data([0x1B]),
        "\r": Data("\r".utf8),
    ]

    override var keyCommands: [UIKeyCommand]? {
        guard (text ?? "").isEmpty else { return super.keyCommands }
        let forwarded = Self.terminalKeyPayloads.keys.map { input in
            let command = UIKeyCommand(
                input: input,
                modifierFlags: [],
                action: #selector(forwardTerminalKey(_:))
            )
            // Without priority the text view swallows arrows for caret moves
            // (and Return for a newline) before the command can fire.
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return (super.keyCommands ?? []) + forwarded
    }

    @objc private func forwardTerminalKey(_ command: UIKeyCommand) {
        guard let input = command.input,
              let payload = Self.terminalKeyPayloads[input] else { return }
        onTerminalKey?(payload)
    }
}
