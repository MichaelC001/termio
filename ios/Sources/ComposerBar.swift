import UIKit

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
    /// Hold-to-talk: the terminal keyboard's space bar drives this when
    /// push-to-talk is on. Recording lives here — the composer owns the draft
    /// the transcript lands in and the pill the HUD sits over; the space key
    /// only forwards its hold gesture. The transcript is inserted, never
    /// auto-sent (the same contract as the send button).
    private let dictation = VoiceDictation()
    private let recordingHUD = VoiceRecordingHUD()
    private var dictationHeld = false
    private var dictationCancelZone = false
    /// Built on first use; staying set across focus cycles means the user's
    /// keyboard choice survives dismiss/reopen, like any system keyboard.
    private lazy var terminalKeyboard: TerminalKeyboardView = {
        let keyboard = TerminalKeyboardView()
        keyboard.onKey = { [weak self] payload in self?.onTerminalKey?(payload) }
        keyboard.onSwitchBack = { [weak self] in self?.setTerminalKeyboardActive(false) }
        keyboard.onDictationBegan = { [weak self] in self?.startDictation() }
        keyboard.onDictationChanged = { [weak self] cancelling in
            self?.updateDictationCancelZone(cancelling)
        }
        keyboard.onDictationEnded = { [weak self] in self?.finishDictation() }
        keyboard.onDictationCancelled = { [weak self] in self?.cancelDictation() }
        return keyboard
    }()
    private let attachButton = UIButton(type: .system)
    private let attachSpinner = UIActivityIndicatorView(style: .medium)
    private let attachProgressLabel = UILabel()
    private let suggestionsPanel = UIVisualEffectView(effect: ComposerBar.fieldEffect())
    private let suggestionsStack = UIStackView()
    private let pill = UIVisualEffectView(effect: ComposerBar.fieldEffect())

    /// iMessage's compose field is Liquid Glass, not a frosted material —
    /// the ultra-thin blur reads as a flat grey film over the keyboard.
    private static func fieldEffect() -> UIVisualEffect {
        if #available(iOS 26, *) {
            return UIGlassEffect(style: .regular)
        }
        return UIBlurEffect(style: .systemUltraThinMaterial)
    }
    private var suggestionsHeight: NSLayoutConstraint!
    private var textHeight: NSLayoutConstraint!
    private var pillLeadingWithAttach: NSLayoutConstraint!
    private var pillLeadingFlush: NSLayoutConstraint!
    /// The system keyboard's height, recorded on every show while it (not
    /// the terminal keyboard) is up. The swap hands this to the terminal
    /// keyboard so it fills the container the system keeps at that height.
    private var systemKeyboardHeight: CGFloat = 0
    private var keyboardObserver: NSObjectProtocol?

    private static let minTextHeight: CGFloat = 36
    private static let maxTextHeight: CGFloat = 120
    /// The pill's rest height — one line of the body font plus the text
    /// insets, MEASURED in init (the body style's line fragment is 22pt,
    /// taller than font.lineHeight, so a hardcoded constant sits every
    /// trailing control visibly below center).
    private var restTextHeight: CGFloat = ComposerBar.minTextHeight
    private static let suggestionRowHeight: CGFloat = 44
    /// 4.5 rows: the half row signals there is more to scroll (Telegram's trick).
    private static let maxSuggestionsHeight: CGFloat = 198

    init() {
        super.init(frame: .zero)

        configureSuggestionsPanel()

        // iMessage's field: a slim hairline-bordered capsule, not a chunky
        // blur slab. The border tracks appearance changes below.
        let pillWrapper = UIView()
        pill.clipsToBounds = true
        pill.layer.cornerCurve = .continuous
        pill.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pillWrapper.addSubview(pill)
        updatePillBorder()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ComposerBar, _) in
            self.updatePillBorder()
        }

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

        let column = UIStackView(arrangedSubviews: [suggestionsWrapper, pillWrapper])
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // Attachments: photos/files land on the Mac, their path lands in the
        // draft (hidden until the session can actually receive uploads).
        // A standalone circle to the LEFT of the field, where iMessage puts
        // its "+" — not a glyph inside the pill.
        var attachConfig: UIButton.Configuration = if #available(iOS 26.0, *) {
            .glass()
        } else {
            .gray()
        }
        attachConfig.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        )
        attachConfig.cornerStyle = .capsule
        attachButton.configuration = attachConfig
        attachButton.accessibilityLabel = "Attach"
        attachButton.tintColor = .secondaryLabel
        attachButton.isHidden = true
        attachButton.addAction(UIAction { [weak self] _ in
            self?.onAttach?()
        }, for: .touchUpInside)
        attachSpinner.hidesWhenStopped = true
        attachProgressLabel.font = .roundedCounter(size: 12, weight: .medium)
        attachProgressLabel.textColor = .secondaryLabel
        attachProgressLabel.isHidden = true

        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.delegate = self
        textView.onTerminalKey = { [weak self] payload in self?.onTerminalKey?(payload) }

        restTextHeight = max(Self.minTextHeight, ceil(textView.sizeThatFits(
            CGSize(width: 1000, height: CGFloat.greatestFiniteMagnitude)
        ).height))
        pill.layer.cornerRadius = restTextHeight / 2

        placeholder.text = "Prompt"
        placeholder.font = textView.font
        placeholder.textColor = .tertiaryLabel

        // The pill's right slot is send's alone (iMessage puts its send arrow
        // inside the field): empty while there is nothing to send, the circle
        // springing in the moment a draft exists.
        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        sendButton.setPreferredSymbolConfiguration(.init(pointSize: 30), forImageIn: .normal)
        sendButton.accessibilityLabel = "Send"
        sendButton.addAction(UIAction { [weak self] _ in
            self?.submit()
        }, for: .touchUpInside)

        // A persistent toggle OUTSIDE the pill on the right, mirroring the
        // attach "+" on the left, that swaps to the terminal keyboard the way
        // iOS swaps to the number or handwriting keyboard (replacing the text
        // view's inputView). Unlike send it never leaves: driving the TUI is a
        // core loop here, so the switch stays one reachable thumb-tap away,
        // draft or not.
        var keyboardConfig: UIButton.Configuration = if #available(iOS 26.0, *) {
            .glass()
        } else {
            .gray()
        }
        keyboardConfig.image = UIImage(
            systemName: "keyboard",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        )
        keyboardConfig.cornerStyle = .capsule
        // Color the glyph through the configuration, NOT tintColor: on a glass
        // capsule tintColor washes the whole background, so toggling active
        // would flip the capsule's fill — baseForegroundColor keeps the tint on
        // the icon and the glass steady.
        keyboardConfig.baseForegroundColor = .secondaryLabel
        keyboardButton.configuration = keyboardConfig
        keyboardButton.accessibilityLabel = "Terminal keyboard"
        keyboardButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setTerminalKeyboardActive(textView.inputView == nil)
        }, for: .touchUpInside)

        // The recording HUD is purely presentational; the space bar's gesture
        // already owns the touch while it's up.
        recordingHUD.isUserInteractionEnabled = false

        for subview in [attachButton, keyboardButton, attachSpinner, attachProgressLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            pillWrapper.addSubview(subview)
        }
        for subview in [textView, placeholder, sendButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            pill.contentView.addSubview(subview)
        }
        // The recording HUD covers the pill while the mic button is held.
        recordingHUD.translatesAutoresizingMaskIntoConstraints = false
        pillWrapper.addSubview(recordingHUD)

        textHeight = textView.heightAnchor.constraint(equalToConstant: restTextHeight)
        // Trailing controls center on the rest-height strip at the pill's
        // bottom: dead-center while the field is one line, hugging the last
        // line as it grows (iMessage's send-button behavior).
        let controlCenter = -restTextHeight / 2
        let controlGap = -(restTextHeight - 30) / 2
        // The field hugs the leading edge until the attach button earns its
        // place (companion sessions only).
        pillLeadingWithAttach = pill.leadingAnchor.constraint(
            equalTo: attachButton.trailingAnchor, constant: 8
        )
        pillLeadingFlush = pill.leadingAnchor.constraint(
            equalTo: pillWrapper.leadingAnchor, constant: 8
        )
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            attachButton.leadingAnchor.constraint(equalTo: pillWrapper.leadingAnchor, constant: 8),
            attachButton.centerYAnchor.constraint(equalTo: pill.bottomAnchor, constant: controlCenter),
            attachButton.widthAnchor.constraint(equalToConstant: 34),
            attachButton.heightAnchor.constraint(equalToConstant: 34),
            attachSpinner.centerXAnchor.constraint(equalTo: attachButton.centerXAnchor),
            attachSpinner.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
            attachProgressLabel.centerXAnchor.constraint(equalTo: attachButton.centerXAnchor),
            attachProgressLabel.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor),
            pillLeadingFlush,
            pill.trailingAnchor.constraint(equalTo: keyboardButton.leadingAnchor, constant: -8),
            pill.topAnchor.constraint(equalTo: pillWrapper.topAnchor),
            pill.bottomAnchor.constraint(equalTo: pillWrapper.bottomAnchor),
            keyboardButton.trailingAnchor.constraint(equalTo: pillWrapper.trailingAnchor, constant: -8),
            keyboardButton.centerYAnchor.constraint(equalTo: pill.bottomAnchor, constant: controlCenter),
            // Sized to the pill's rest height so it reads as a peer capsule,
            // not a dot; bottom-anchored, so it hugs the last line as the pill
            // grows (like send and attach).
            keyboardButton.widthAnchor.constraint(equalToConstant: restTextHeight),
            keyboardButton.heightAnchor.constraint(equalToConstant: restTextHeight),
            textView.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -36),
            textView.topAnchor.constraint(equalTo: pill.contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor),
            textHeight,
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
            placeholder.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
            sendButton.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: controlGap),
            sendButton.centerYAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: controlCenter),
            sendButton.widthAnchor.constraint(equalToConstant: 30),
            sendButton.heightAnchor.constraint(equalToConstant: 30),
            recordingHUD.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            recordingHUD.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            recordingHUD.topAnchor.constraint(equalTo: pill.topAnchor),
            recordingHUD.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])

        refreshControls()

        // Every system-keyboard show refreshes the height the terminal
        // keyboard must fill on swap (device rotations included). Shows of
        // the terminal keyboard itself are skipped — its (possibly shorter)
        // fallback height must never become the measurement.
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, textView.inputView == nil,
                  let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
            else { return }
            systemKeyboardHeight = frame.cgRectValue.height
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
        }
    }

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
        if active {
            terminalKeyboard.matchSystemKeyboardHeight(systemKeyboardHeight)
        }
        textView.inputView = active ? terminalKeyboard : nil
        // Only the glyph changes on toggle — outline→filled, dim→full — so the
        // capsule's glass background stays put (see baseForegroundColor above).
        keyboardButton.configuration?.image = UIImage(
            systemName: active ? "keyboard.fill" : "keyboard",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        )
        keyboardButton.configuration?.baseForegroundColor = active ? .label : .secondaryLabel
        placeholder.text = active ? "Keys go to the terminal" : "Prompt"
        if textView.isFirstResponder {
            textView.reloadInputViews()
        } else {
            textView.becomeFirstResponder()
        }
    }

    /// Shows the attach (+) button — only sessions with a Mac behind them
    /// can receive uploads. The field's leading edge follows.
    func setAttachAvailable(_ available: Bool) {
        attachButton.isHidden = !available
        if available {
            pillLeadingFlush.isActive = false
            pillLeadingWithAttach.isActive = true
        } else {
            pillLeadingWithAttach.isActive = false
            pillLeadingFlush.isActive = true
        }
    }

    /// CGColor doesn't follow appearance changes on its own.
    private func updatePillBorder() {
        pill.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    /// Spins the attach slot while an upload is in flight; a batch shows its
    /// "n/m" position instead of the spinner. The slot crossfades between
    /// faces instead of blinking (Telegram's panel-swap timing).
    func setAttachBusy(_ busy: Bool, progress: (done: Int, total: Int)? = nil) {
        attachButton.isEnabled = !busy
        if busy, let progress, progress.total > 1 {
            attachSpinner.stopAnimating()
            attachProgressLabel.text = "\(progress.done + 1)/\(progress.total)"
            attachProgressLabel.isHidden = false
        } else {
            attachProgressLabel.isHidden = true
            if busy { attachSpinner.startAnimating() } else { attachSpinner.stopAnimating() }
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut]) {
            self.attachButton.alpha = busy ? 0 : 1
        }
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

    private func submit() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        PromptHistory.shared.record(text)
        textView.text = ""
        refreshControls()
        refreshSuggestions()
        onSend?(text)
    }

    // MARK: - Hold-to-talk

    /// Driven by the terminal keyboard's space bar when push-to-talk is on.
    private func startDictation() {
        dictationHeld = true
        dictationCancelZone = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dictation.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Released during the permission prompt: don't leave a mic hot.
                guard dictationHeld else {
                    dictation.cancel()
                    return
                }
                recordingHUD.beginRecording { [weak self] in self?.dictation.currentLevel() ?? 0 }
            case .failure(let failure):
                recordingHUD.showError(failure.hudMessage)
            }
        }
    }

    private func updateDictationCancelZone(_ cancelling: Bool) {
        guard dictation.isRecording, cancelling != dictationCancelZone else { return }
        dictationCancelZone = cancelling
        recordingHUD.setCancelZone(cancelling)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    private func finishDictation() {
        dictationHeld = false
        guard dictation.isRecording else {
            // Too fast to have started, or still awaiting permission — tidy up.
            dictation.cancel()
            recordingHUD.dismiss()
            return
        }
        if dictationCancelZone {
            cancelDictation()
            return
        }
        recordingHUD.showTranscribing()
        dictation.stopAndTranscribe { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let transcript):
                recordingHUD.dismiss()
                insertDraft(transcript)
                if !textView.isFirstResponder { textView.becomeFirstResponder() }
            case .failure(.empty):
                // A stray tap or silence — don't scold, just clear the HUD.
                recordingHUD.dismiss()
            case .failure(let failure):
                recordingHUD.showError(failure.hudMessage)
            }
        }
    }

    private func cancelDictation() {
        dictationHeld = false
        dictationCancelZone = false
        dictation.cancel()
        recordingHUD.dismiss()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func refreshControls() {
        let empty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !textView.text.isEmpty
        // The keyboard toggle lives outside the pill and never leaves; only
        // send comes and goes. It springs into the pill's right slot the
        // moment there is something to send (Telegram's check-appearance
        // curve) rather than blinking on — but only on the empty⇄draft
        // transition, not on every keystroke.
        if sendButton.isHidden != empty {
            sendButton.isHidden = empty
            if !empty {
                sendButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                sendButton.alpha = 0
                UIView.animate(
                    withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.6,
                    initialSpringVelocity: 0, options: [.allowUserInteraction]
                ) {
                    self.sendButton.transform = .identity
                    self.sendButton.alpha = 1
                }
            }
        }
        sendButton.isEnabled = !empty

        let fitting = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        textHeight.constant = min(max(fitting, restTextHeight), Self.maxTextHeight)
        textView.isScrollEnabled = fitting > Self.maxTextHeight
    }

    // MARK: - Suggestions

    /// What the panel above the pill can offer: the "/" command catalog, or
    /// a previously sent prompt recalled from history.
    private enum Suggestion {
        case slash(SlashCommand)
        case history(String)
    }

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

    /// Telegram's trigger rule for "/": the query lives while the draft
    /// starts with "/" and contains no whitespace yet; it filters by prefix
    /// and dies the moment a space lands (arguments are free text). Any other
    /// single-line draft of 2+ characters recalls prompt history instead —
    /// the highest-hit-rate source on mobile (people re-send yesterday's
    /// prompts), and fully local so typing never waits on a lookup.
    private func refreshSuggestions() {
        let text = textView.text ?? ""
        if !slashCommands.isEmpty, text.hasPrefix("/"),
           !text.contains(where: \.isWhitespace) {
            let query = text.dropFirst().lowercased()
            // Capped, not scrolled: typing another letter narrows the rest
            // away (Telegram shows a handful and relies on the query).
            let matches = slashCommands.filter { $0.name.lowercased().hasPrefix(query) }
            setSuggestions(matches.prefix(4).map(Suggestion.slash))
        } else if text.count >= 2, !text.contains("\n") {
            // A newline means they're composing something new, not recalling.
            setSuggestions(
                PromptHistory.shared.matches(for: text, limit: 3).map(Suggestion.history)
            )
        } else {
            setSuggestions([])
        }
    }

    private func setSuggestions(_ suggestions: [Suggestion]) {
        suggestionsStack.arrangedSubviews.forEach { view in
            suggestionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, suggestion) in suggestions.enumerated() {
            // Hairlines separate rows; the last row ends at the panel's own
            // edge, so a line there would just underline the panel.
            let separated = index < suggestions.count - 1
            switch suggestion {
            case .slash(let command):
                suggestionsStack.addArrangedSubview(
                    makeSuggestionRow(command, showsHairline: separated)
                )
            case .history(let text):
                suggestionsStack.addArrangedSubview(
                    makeHistoryRow(text, showsHairline: separated)
                )
            }
        }
        // The wrapper (the stack's arranged view) is what collapses.
        suggestionsPanel.superview?.isHidden = suggestions.isEmpty
        suggestionsHeight.constant = min(
            CGFloat(suggestions.count) * Self.suggestionRowHeight,
            Self.maxSuggestionsHeight
        )
    }

    /// One row: tap sends the command now (Telegram sends bot commands on
    /// tap); the trailing arrow only inserts it, for commands taking
    /// arguments — Telegram's arrowButtonPressed. Plain labels + an overlay
    /// button: UIButton.Configuration text refused to render inside this
    /// effect-view stack, labels never fail.
    private func makeSuggestionRow(_ command: SlashCommand, showsHairline: Bool) -> UIView {
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
        hairline.isHidden = !showsHairline

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

    /// One history row: a recall glyph and the past prompt on a single line.
    /// Tap fills the draft — never sends; recall shouldn't fire a prompt —
    /// and long-press forgets the entry.
    private func makeHistoryRow(_ text: String, showsHairline: Bool) -> UIView {
        let row = UIView()

        // The plain clock — Apple's own "recents" glyph (Spotlight, App
        // Store searches), quieter than the arrowed variant.
        let icon = UIImageView(image: UIImage(systemName: "clock"))
        icon.tintColor = .tertiaryLabel
        icon.preferredSymbolConfiguration = .init(pointSize: 13)

        let label = UILabel()
        label.text = text.replacingOccurrences(of: "\n", with: " ")
        label.font = .systemFont(ofSize: 15)
        label.textColor = .label
        label.lineBreakMode = .byTruncatingTail

        let main = UIButton(type: .custom)
        main.accessibilityLabel = "Fill draft with \(text)"
        main.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            textView.text = text
            refreshControls()
            // Not refreshSuggestions(): re-matching the filled draft would
            // only re-open the panel with the row that was just tapped.
            setSuggestions([])
        }, for: .touchUpInside)
        // Recognition cancels the button's touch, so a forget never fills.
        main.addGestureRecognizer(ClosureLongPress { [weak self] in
            PromptHistory.shared.remove(text)
            self?.refreshSuggestions()
        })

        let hairline = UIView()
        hairline.backgroundColor = .separator.withAlphaComponent(0.4)
        hairline.isHidden = !showsHairline

        for subview in [main, icon, label, hairline] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: Self.suggestionRowHeight),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            main.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            main.topAnchor.constraint(equalTo: row.topAnchor),
            main.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            hairline.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
        return row
    }
}

/// A long-press recognizer carrying a closure — target/action can't capture
/// the row's text.
private final class ClosureLongPress: UILongPressGestureRecognizer {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(fire))
    }

    @objc private func fire() {
        if state == .began { handler() }
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
