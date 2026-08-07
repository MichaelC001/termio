import Highlightr
import TermioShared
import UIKit

/// Full-screen unified diff, phone rules. The desktop pane renders the same model in
/// AppKit; what changes here is what a 390pt screen can carry:
///
/// - **Never scroll horizontally.** Lines soft-wrap, and a hanging indent keeps a
///   wrapped continuation visually inside its line.
/// - **A saturated edge bar, not a full-line fill.** A heavy green behind a whole line
///   drowns the syntax colors at this size, so the strong ink is a 3pt bar at the
///   leading edge and the line itself takes a very light wash.
/// - **One line-number column.** Two would cost a tenth of the width; a deletion shows
///   its old number, everything else the new one, which is what a reviewer quotes.
/// - **Fold bands are rows, not gutter buttons.** The whole band is the tap target, so
///   it clears 44pt.
/// - **The file walker is in the view.** ‹ 3 of 12 › moves between changed files without
///   a trip back to the list, and the floating button jumps to the next hunk.
/// - **Selection feeds the agent.** Long-press → "Send to Agent" bracketed-pastes the
///   selected code into the session's PTY: the thing a phone diff is *for*.
final class DiffViewController: UIViewController {
    private var files: [WireChange]
    private var index: Int

    /// Ask the owner (which holds the companion socket) for one file's diff; the reply
    /// arrives back through `receive(_:)`.
    var onRequestDiff: ((String) -> Void)?
    /// Bracketed-paste selected code into the session's terminal. nil hides the action —
    /// a plain shell has no prompt to feed.
    var onSendToAgent: ((String) -> Void)?

    private var rows: [DiffLine] = []
    private var expanded: Set<Int> = []
    private var document: DiffDocument?
    /// The path a `readDiff` is in flight for, so a late reply for the previous file
    /// can't paint over the current one.
    private var pendingPath: String?

    private let storage = NSTextStorage()
    private var textView: DiffTextView!
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let walkerLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let hunkButton = UIButton(type: .system)
    private var walkerBar: UIStackView!

    /// A `readDiff` is outstanding, so a failure belongs to this screen.
    var isAwaitingDiff: Bool { pendingPath != nil }

    private var change: WireChange? {
        files.indices.contains(index) ? files[index] : nil
    }

    init(files: [WireChange], index: Int) {
        self.files = files
        self.index = min(max(index, 0), max(files.count - 1, 0))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let header = configureHeader()
        let walker = configureWalker()
        configureText(below: header, above: walker)
        configureHunkButton(above: walker)
        configureStatus()
        reloadFile()
    }

    // MARK: - Chrome

    private func configureHeader() -> UIView {
        let close = UIButton(type: .system)
        close.applyGlassSymbol("xmark")
        close.tintColor = .label
        close.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        }, for: .touchUpInside)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingMiddle

        subtitleLabel.font = .preferredFont(forTextStyle: .caption2)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingHead

        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.alignment = .center

        spinner.hidesWhenStopped = true

        let bar = UIStackView(arrangedSubviews: [close, titles, spinner])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 4
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            close.widthAnchor.constraint(equalToConstant: 40),
            close.heightAnchor.constraint(equalToConstant: 40),
            spinner.widthAnchor.constraint(equalToConstant: 40),
        ])
        return bar
    }

    /// ‹ 3 of 12 › — walking the changed files without going back to the list. Absent
    /// for a single file, where it would only take height away from the code.
    private func configureWalker() -> UIView {
        previousButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        previousButton.addAction(UIAction { [weak self] _ in self?.walk(-1) }, for: .touchUpInside)
        nextButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        nextButton.addAction(UIAction { [weak self] _ in self?.walk(1) }, for: .touchUpInside)

        walkerLabel.font = .roundedCounter(size: 13, weight: .medium)
        walkerLabel.textColor = .secondaryLabel
        walkerLabel.textAlignment = .center

        let bar = UIStackView(arrangedSubviews: [previousButton, walkerLabel, nextButton])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.distribution = .fill
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = .init(top: 6, leading: 12, bottom: 6, trailing: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = files.count < 2
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 44),
            previousButton.heightAnchor.constraint(equalToConstant: 44),
            nextButton.widthAnchor.constraint(equalToConstant: 44),
            nextButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        walkerBar = bar
        return bar
    }

    private func configureText(below header: UIView, above walker: UIView) {
        let layoutManager = DiffWashLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // Breathing room between the edge bar and the first glyph lives in the
        // container's padding, so the wash the layout manager paints still reaches the
        // full width instead of stopping at an inset.
        container.lineFragmentPadding = 8
        layoutManager.addTextContainer(container)

        textView = DiffTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.delegate = self
        // The left inset is the line-number column the text view paints into.
        textView.textContainerInset = UIEdgeInsets(top: 10, left: DiffTextView.gutterWidth, bottom: 24, right: 8)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: walker.topAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        textView.addGestureRecognizer(tap)
    }

    /// Jump to the next change in a long diff — the one navigation a scrolling reader
    /// actually needs. Floats over the code, out of the text's way.
    private func configureHunkButton(above walker: UIView) {
        hunkButton.applyGlassSymbol("chevron.down")
        hunkButton.tintColor = .label
        hunkButton.isHidden = true
        hunkButton.addAction(UIAction { [weak self] _ in self?.scrollToNextChange() }, for: .touchUpInside)
        hunkButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hunkButton)
        NSLayoutConstraint.activate([
            hunkButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            hunkButton.bottomAnchor.constraint(equalTo: walker.topAnchor, constant: -14),
            hunkButton.widthAnchor.constraint(equalToConstant: 44),
            hunkButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configureStatus() {
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    // MARK: - Files

    private func walk(_ delta: Int) {
        let target = index + delta
        guard files.indices.contains(target) else { return }
        index = target
        reloadFile()
    }

    private func reloadFile() {
        guard let change else { return }
        rows = []
        expanded = []
        document = nil
        storage.setAttributedString(NSAttributedString())
        titleLabel.text = (change.path as NSString).lastPathComponent
        subtitleLabel.text = summary(for: change)
        walkerLabel.text = "\(index + 1) of \(files.count)"
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index < files.count - 1
        hunkButton.isHidden = true
        statusLabel.isHidden = true
        pendingPath = change.path
        spinner.startAnimating()
        onRequestDiff?(change.path)
    }

    private func summary(for change: WireChange) -> String {
        let directory = (change.path as NSString).deletingLastPathComponent
        var parts: [String] = []
        if !directory.isEmpty { parts.append(directory) }
        if change.isBinary {
            parts.append("binary")
        } else {
            parts.append("+\(change.additions) −\(change.deletions)")
        }
        if change.isStaged { parts.append("staged") }
        return parts.joined(separator: " · ")
    }

    /// A `readDiff` reply arrived (routed in by the owner).
    func receive(_ diff: WireDiff) {
        guard diff.path == pendingPath else { return }
        pendingPath = nil
        spinner.stopAnimating()
        guard !diff.binary else {
            show(status: "Binary file — no text diff to show.")
            return
        }
        rows = DiffParser.lines(from: diff.text)
        guard !rows.isEmpty else {
            show(status: "No textual changes in this file.")
            return
        }
        statusLabel.isHidden = true
        rebuild(preservingScroll: false)
        highlightSyntax()
    }

    /// The Mac refused the request (routed in by the owner).
    func failed(_ message: String) {
        pendingPath = nil
        spinner.stopAnimating()
        show(status: message)
    }

    private func show(status: String) {
        storage.setAttributedString(NSAttributedString())
        document = nil
        textView.document = nil
        hunkButton.isHidden = true
        statusLabel.text = status
        statusLabel.isHidden = false
    }

    // MARK: - Rendering

    private func rebuild(preservingScroll: Bool, anchorRowId: Int? = nil, anchorY: CGFloat = 0) {
        let items = DiffParser.displayItems(lines: rows, expanded: expanded)
        let built = DiffDocument.build(items: items, font: MobileSettings.shared.codeFont())
        document = built
        textView.document = built
        storage.setAttributedString(built.attributed)
        hunkButton.isHidden = built.changeAnchors.count < 2
        guard preservingScroll, let anchorRowId,
              let line = built.lines.first(where: { $0.rowId == anchorRowId }) else { return }
        // Keep the tapped band's first revealed line where the band was, so expanding
        // never teleports the reader.
        let rect = textView.rect(forParagraph: line)
        let offset = max(rect.minY - anchorY, -textView.adjustedContentInset.top)
        textView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    }

    /// Colors the diff the way the desktop does: each side is highlighted as one text so
    /// multi-line constructs (block comments, raw strings) keep their real state, then
    /// the per-line results are dropped onto the built document. Context lines take the
    /// new side's colors; the old side contributes only its deletions.
    private func highlightSyntax() {
        guard let change,
              let language = CodeHighlighter.language(forFileNamed: (change.path as NSString).lastPathComponent)
        else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        let font = MobileSettings.shared.codeFont()
        let newSide = rows.filter { $0.kind == .context || $0.kind == .addition }
        let oldSide = rows.filter { $0.kind == .deletion }
        let path = change.path
        DiffSyntaxHighlighter.shared.styledLines(
            newSide: newSide, oldSide: oldSide, language: language,
            theme: dark ? "xcode-dark" : "xcode", font: font
        ) { [weak self] styled in
            guard let self, !styled.isEmpty, self.change?.path == path else { return }
            apply(styled: styled)
        }
    }

    private func apply(styled: [Int: NSAttributedString]) {
        guard let document else { return }
        storage.beginEditing()
        for line in document.lines {
            guard case .code = line.role, let colored = styled[line.rowId],
                  colored.length == line.range.length - 1 else { continue }
            colored.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: colored.length)) {
                value, range, _ in
                guard let color = value as? UIColor else { return }
                storage.addAttribute(
                    .foregroundColor, value: color,
                    range: NSRange(location: line.range.location + range.location, length: range.length)
                )
            }
        }
        storage.endEditing()
    }

    // MARK: - Interaction

    /// A tap on a fold band reveals its lines. Everything else is the text view's own
    /// business (a tap in code just dismisses any selection).
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: textView)
        guard let line = textView.line(at: point), case .band(let expandable) = line.role else { return }
        guard expandable else {
            // A fixed band's lines were never fetched — say so instead of no-oping.
            let alert = UIAlertController(
                title: "Not available",
                message: "This diff was fetched without full context because the file is large, so the skipped lines aren't on the phone.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let anchorY = textView.rect(forParagraph: line).minY - textView.contentOffset.y
        expanded.insert(line.rowId)
        rebuild(preservingScroll: true, anchorRowId: line.rowId, anchorY: anchorY)
    }

    private func scrollToNextChange() {
        guard let document, !document.changeAnchors.isEmpty else { return }
        let current = textView.contentOffset.y + textView.adjustedContentInset.top
        let next = document.changeAnchors.first {
            textView.rect(forParagraph: document.lines[$0]).minY > current + 8
        } ?? document.changeAnchors[0]
        let target = textView.rect(forParagraph: document.lines[next]).minY - 12
        textView.setContentOffset(CGPoint(x: 0, y: max(target, -textView.adjustedContentInset.top)), animated: true)
    }

    /// The selected text as pure code: band labels are chrome, so a selection that
    /// spans one hands the agent the code around it, not "⋯ 24 unchanged lines".
    private func selectedCode() -> String? {
        guard let document, let range = textView.selectedTextRange, !range.isEmpty else { return nil }
        let selection = textView.selectedRange
        var parts: [String] = []
        for line in document.lines {
            guard NSIntersectionRange(line.range, selection).length > 0 else { continue }
            if case .band = line.role { continue }
            let clipped = NSIntersectionRange(line.range, selection)
            parts.append((storage.string as NSString).substring(with: clipped))
        }
        let text = parts.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

extension DiffViewController: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard onSendToAgent != nil, range.length > 0 else { return nil }
        let send = UIAction(title: "Send to Agent", image: UIImage(systemName: "arrow.up.message")) {
            [weak self] _ in
            guard let self, let code = selectedCode() else { return }
            onSendToAgent?(code)
            self.textView.selectedTextRange = nil
            dismiss(animated: true)
        }
        return UIMenu(children: [send] + suggestedActions)
    }
}

// MARK: - Document

/// The folded diff laid down as one attributed string plus per-paragraph metadata the
/// text view reads at draw time. One document means one scroll and one continuous
/// selection, which is what lets a selection cross lines and reach the agent intact.
final class DiffDocument {
    enum Role {
        case code(DiffLine.Kind)
        case band(expandable: Bool)
    }

    struct Line {
        let role: Role
        /// The paragraph's range, including its trailing newline.
        let range: NSRange
        /// `DiffLine.id` for code (keys the syntax pass), the first hidden line's id for
        /// a band (keys the expand).
        let rowId: Int
        /// The number drawn in the gutter: a deletion's old line, else the new one.
        let number: Int?
    }

    let attributed: NSAttributedString
    let lines: [Line]
    /// Indices into `lines` where a run of additions/deletions starts — the stops the
    /// next-hunk button walks.
    let changeAnchors: [Int]

    private init(attributed: NSAttributedString, lines: [Line], changeAnchors: [Int]) {
        self.attributed = attributed
        self.lines = lines
        self.changeAnchors = changeAnchors
    }

    /// Extra height around a band's text, so the whole row clears a 44pt tap target.
    static let bandPadding: CGFloat = 13

    static func build(items: [DiffItem], font: UIFont) -> DiffDocument {
        var text = String()
        var lines: [Line] = []
        var changeAnchors: [Int] = []
        var previousWasChange = false

        for item in items {
            let location = (text as NSString).length
            switch item {
            case .line(let row):
                text += row.text
                text += "\n"
                let isChange = row.kind == .addition || row.kind == .deletion
                if isChange, !previousWasChange { changeAnchors.append(lines.count) }
                previousWasChange = isChange
                lines.append(Line(
                    role: .code(row.kind),
                    range: NSRange(location: location, length: (row.text as NSString).length + 1),
                    rowId: row.id,
                    number: row.kind == .deletion ? row.oldLine : row.newLine
                ))
            case .band(let id, let count, let expandable):
                let label = "⋯ \(count) unchanged \(count == 1 ? "line" : "lines")"
                text += label
                text += "\n"
                previousWasChange = false
                lines.append(Line(
                    role: .band(expandable: expandable),
                    range: NSRange(location: location, length: (label as NSString).length + 1),
                    rowId: id,
                    number: nil
                ))
            }
        }

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
        ])
        // A wrapped continuation hangs off the line's *own* indentation, not off the
        // margin: on a 390pt screen most lines wrap, and a continuation that jumps back
        // to column 0 reads as a new statement. One style per distinct indent, cached —
        // a 5000-line diff has a handful.
        var styles: [String: NSParagraphStyle] = [:]
        for (item, line) in zip(items, lines) {
            guard case .line(let row) = item else { continue }
            let indent = String(row.text.prefix { $0 == " " || $0 == "\t" })
            let style = styles[indent] ?? {
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 2
                let width = (indent as NSString).size(withAttributes: [.font: font]).width
                style.headIndent = width + 16
                styles[indent] = style
                return style
            }()
            attributed.addAttribute(.paragraphStyle, value: style, range: line.range)
        }

        let band = NSMutableParagraphStyle()
        band.alignment = .center
        band.lineSpacing = 2
        band.paragraphSpacingBefore = bandPadding
        band.paragraphSpacing = bandPadding
        for (item, line) in zip(items, lines) {
            switch item {
            case .band:
                attributed.addAttributes([
                    .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: UIColor.tertiaryLabel,
                    .paragraphStyle: band,
                ], range: line.range)
            case .line(let row):
                guard let emphasis = row.emphasis, !emphasis.isEmpty,
                      let range = utf16Range(of: emphasis, in: row.text) else { continue }
                let color: UIColor = row.kind == .addition
                    ? UIColor.systemGreen.withAlphaComponent(0.3)
                    : UIColor.systemRed.withAlphaComponent(0.3)
                attributed.addAttribute(
                    .backgroundColor, value: color,
                    range: NSRange(location: line.range.location + range.location, length: range.length)
                )
            }
        }

        return DiffDocument(attributed: attributed, lines: lines, changeAnchors: changeAnchors)
    }

    /// The index of the first line whose paragraph ends past `location`.
    func lineIndex(at location: Int) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(lines[mid].range) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func line(at location: Int) -> Line? {
        let index = lineIndex(at: location)
        guard index < lines.count, NSLocationInRange(location, lines[index].range) else { return nil }
        return lines[index]
    }

    /// `DiffLine.emphasis` counts `Character`s (the intraline pass is CJK-aware);
    /// attributed ranges are UTF-16. Bail rather than misplace the span.
    private static func utf16Range(of emphasis: Range<Int>, in text: String) -> NSRange? {
        guard let lower = text.index(text.startIndex, offsetBy: emphasis.lowerBound, limitedBy: text.endIndex),
              let upper = text.index(text.startIndex, offsetBy: emphasis.upperBound, limitedBy: text.endIndex),
              lower < upper else { return nil }
        return NSRange(lower..<upper, in: text)
    }
}

// MARK: - Text view

/// The diff's text view: TextKit 1 so the wash layout manager can paint underneath the
/// glyphs, plus the line-number column drawn into the container's left inset.
final class DiffTextView: UITextView {
    static let gutterWidth: CGFloat = 34

    var document: DiffDocument? {
        didSet {
            (layoutManager as? DiffWashLayoutManager)?.document = document
            setNeedsDisplay()
        }
    }

    /// The paragraph's rect in content coordinates.
    func rect(forParagraph line: DiffDocument.Line) -> CGRect {
        let glyphs = layoutManager.glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerInset.left
        rect.origin.y += textContainerInset.top
        return rect
    }

    /// The line under a point in view coordinates, if any.
    func line(at point: CGPoint) -> DiffDocument.Line? {
        guard let document else { return nil }
        let inContainer = CGPoint(
            x: point.x - textContainerInset.left,
            y: point.y - textContainerInset.top
        )
        let index = layoutManager.characterIndex(
            for: inContainer, in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        // `characterIndex` snaps to the nearest character, so a tap in the empty space
        // past the end would "hit" the last line. Take the hit only if the point is
        // actually inside that paragraph.
        guard let line = document.line(at: index),
              rect(forParagraph: line).insetBy(dx: 0, dy: -DiffDocument.bandPadding).contains(point)
        else { return nil }
        return line
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        (layoutManager as? DiffWashLayoutManager)?.contentWidth = bounds.width
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        drawLineNumbers(in: rect)
    }

    /// Numbers ride in the container's left inset, outside the selectable text — so a
    /// selection copies pure code, never "214 let x = 1". Only the visible paragraphs
    /// are measured.
    private func drawLineNumbers(in rect: CGRect) {
        guard let document, let context = UIGraphicsGetCurrentContext() else { return }
        let size = max(9, MobileSettings.shared.codeFont().pointSize - 2)
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.tertiaryLabel,
        ]
        // Start at the first paragraph the dirty rect touches — a 5000-line diff must
        // not measure every line on every scroll tick.
        let visible = rect.offsetBy(dx: -textContainerInset.left, dy: -textContainerInset.top)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        context.saveGState()
        var index = document.lineIndex(at: characters.location)
        while index < document.lines.count {
            let line = document.lines[index]
            index += 1
            if line.range.location >= NSMaxRange(characters) { break }
            guard let number = line.number else { continue }
            let paragraph = self.rect(forParagraph: line)
            let text = NSAttributedString(string: "\(number)", attributes: attributes)
            // Right-aligned against the code's leading edge, drawn on the paragraph's
            // first line so a wrapped line is numbered once.
            text.draw(at: CGPoint(
                x: Self.gutterWidth - text.size().width - 8,
                y: paragraph.minY + font.lineHeight * 0.1
            ))
        }
        context.restoreGState()
    }
}

/// Paints each line's meaning behind its glyphs: a saturated 3pt bar at the leading
/// edge and a light wash across the row for additions and deletions, a flat fill for
/// fold bands. The bar is what carries at phone size — the wash stays light enough that
/// syntax colors on top stay readable, which a full-strength green does not.
final class DiffWashLayoutManager: NSLayoutManager {
    var document: DiffDocument?
    /// The hosting view's width — washes span the whole row, including the line-number
    /// column, not just the laid-out text.
    var contentWidth: CGFloat = 0

    static let barWidth: CGFloat = 3

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        if let document, let container = textContainers.first {
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            let width = max(usedRect(for: container).width + origin.x, contentWidth)
            var index = document.lineIndex(at: charRange.location)
            while index < document.lines.count {
                let line = document.lines[index]
                index += 1
                if line.range.location >= NSMaxRange(charRange) { break }
                guard let (wash, bar) = Self.fills(for: line.role) else { continue }
                let glyphs = glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
                var rect = boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.x = 0
                rect.size.width = width
                rect.origin.y += origin.y
                if case .band = line.role {
                    rect = rect.insetBy(dx: 0, dy: -DiffDocument.bandPadding)
                }
                wash.setFill()
                UIRectFill(rect)
                if let bar {
                    bar.setFill()
                    UIRectFill(CGRect(x: 0, y: rect.minY, width: Self.barWidth, height: rect.height))
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// (row wash, leading bar). The wash is deliberately faint; the bar is full strength.
    static func fills(for role: DiffDocument.Role) -> (UIColor, UIColor?)? {
        switch role {
        case .code(.addition):
            return (UIColor.systemGreen.withAlphaComponent(0.09), UIColor.systemGreen)
        case .code(.deletion):
            return (UIColor.systemRed.withAlphaComponent(0.09), UIColor.systemRed)
        case .band:
            return (UIColor.label.withAlphaComponent(0.05), nil)
        case .code:
            return nil
        }
    }
}

// MARK: - Syntax

/// One reusable Highlightr on a serial queue. Building its JavaScriptCore context costs
/// on the order of 100 ms — too much to pay per file — and the context is not safe to
/// share across threads, so every request is funnelled through the same queue. The
/// desktop keeps the same arrangement behind an actor.
final class DiffSyntaxHighlighter {
    static let shared = DiffSyntaxHighlighter()

    /// Past this, highlighting a whole file's diff costs more than it returns on a
    /// phone; the reader stays readable in plain ink.
    private static let maxCharacters = 200_000

    private let queue = DispatchQueue(label: "sh.termio.diff-syntax", qos: .userInitiated)
    private var highlightr: Highlightr?
    private var appliedTheme: String?
    private var appliedFont: UIFont?

    func styledLines(
        newSide: [DiffLine], oldSide: [DiffLine], language: String,
        theme: String, font: UIFont,
        completion: @escaping ([Int: NSAttributedString]) -> Void
    ) {
        let total = newSide.reduce(0) { $0 + $1.text.count } + oldSide.reduce(0) { $0 + $1.text.count }
        guard total <= Self.maxCharacters else { return }
        queue.async { [weak self] in
            guard let self, let highlightr = prepared(theme: theme, font: font) else { return }
            var result: [Int: NSAttributedString] = [:]
            Self.apply(newSide, keeping: [.context, .addition], highlightr, language, into: &result)
            Self.apply(oldSide, keeping: [.deletion], highlightr, language, into: &result)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func prepared(theme: String, font: UIFont) -> Highlightr? {
        if highlightr == nil { highlightr = Highlightr() }
        guard let highlightr else { return nil }
        if appliedTheme != theme {
            guard highlightr.setTheme(to: theme) else { return nil }
            appliedTheme = theme
            appliedFont = nil
        }
        if appliedFont != font {
            highlightr.theme.setCodeFont(font)
            appliedFont = font
        }
        return highlightr
    }

    private static func apply(
        _ side: [DiffLine], keeping kinds: Set<DiffLine.Kind>,
        _ highlightr: Highlightr, _ language: String,
        into result: inout [Int: NSAttributedString]
    ) {
        let joined = side.map(\.text).joined(separator: "\n")
        // The colored text must round-trip exactly, or the per-line offsets below would
        // attribute the wrong spans — bail to plain rendering instead.
        guard let colored = highlightr.highlight(joined, as: language, fastRender: true),
              colored.string == joined else { return }
        var location = 0
        for row in side {
            let length = (row.text as NSString).length
            defer { location += length + 1 }
            guard kinds.contains(row.kind), length > 0 else { continue }
            result[row.id] = colored.attributedSubstring(from: NSRange(location: location, length: length))
        }
    }
}
