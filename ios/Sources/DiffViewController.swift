import UIKit

/// Unified diff, mobile rules: soft-wrap, no horizontal scroll, colored edge
/// bars instead of full-line backgrounds.
final class DiffViewController: UIViewController {
    private let change: MockChange

    init(change: MockChange) {
        self.change = change
        super.init(nibName: nil, bundle: nil)
        title = (change.path as NSString).lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let summary = UILabel()
        summary.font = MobileSettings.shared.codeFont()
        summary.textColor = .secondaryLabel
        summary.text = "+\(change.additions) −\(change.deletions)"
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: summary)

        let textView = UITextView()
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.attributedText = Self.render(diff: MockChange.sampleDiff)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(textView)
    }

    private static func render(diff: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = MobileSettings.shared.codeFont()
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 14 // hanging indent keeps wrapped lines aligned
        for line in diff.components(separatedBy: "\n") {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: UIColor.label,
            ]
            if line.hasPrefix("@@") {
                attrs[.foregroundColor] = UIColor.systemPurple
                attrs[.font] = MobileSettings.shared.codeFont(weight: .semibold)
            } else if line.hasPrefix("+") {
                attrs[.foregroundColor] = UIColor.systemGreen
            } else if line.hasPrefix("-") {
                attrs[.foregroundColor] = UIColor.systemRed
            } else {
                attrs[.foregroundColor] = UIColor.secondaryLabel
            }
            result.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }
        return result
    }
}
