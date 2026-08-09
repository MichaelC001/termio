import UIKit

/// Slack's workspace rail, translated to Macs: swiping in from the left edge
/// of the Projects home slides a vertical rail of paired-Mac tiles over the
/// screen — one initials tile per Mac, the active one highlighted, tap
/// another to switch the whole app to it, and a ＋ tile at the end to pair a
/// new Mac. The reveal is interactive (the rail follows the finger); a tap
/// anywhere outside dismisses it.
@MainActor
final class MacSwitcherRail: NSObject {
    /// The ＋ tile was tapped — the host presents the QR scanner. Called
    /// after the rail has dismissed itself.
    var onAddMac: (() -> Void)?

    private static let width: CGFloat = 96
    private static let tileSize: CGFloat = 56

    private weak var hostView: UIView?
    private var overlay: UIView?
    private var dimView: UIView?
    private var railView: UIVisualEffectView?
    private var tileStack: UIStackView?
    private var macsObserver: NSObjectProtocol?

    func attach(to view: UIView) {
        hostView = view
        let edge = UIScreenEdgePanGestureRecognizer(
            target: self, action: #selector(handleEdgePan(_:))
        )
        edge.edges = .left
        view.addGestureRecognizer(edge)
    }

    deinit {
        if let macsObserver {
            NotificationCenter.default.removeObserver(macsObserver)
        }
    }

    // MARK: - Gesture

    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        // Installed in the window so the rail covers the tab bar too,
        // Slack-style, while the gesture stays scoped to the Projects home.
        guard let container = hostView?.window else { return }
        let translation = gesture.translation(in: container).x
        switch gesture.state {
        case .began:
            install(in: container)
            update(progress: translation / Self.width)
        case .changed:
            update(progress: translation / Self.width)
        case .ended:
            let velocity = gesture.velocity(in: container).x
            let shouldOpen = translation / Self.width > 0.5 || velocity > 300
            settle(open: shouldOpen)
        case .cancelled, .failed:
            settle(open: false)
        default:
            break
        }
    }

    private func update(progress rawProgress: CGFloat) {
        let progress = max(0, min(1, rawProgress))
        railView?.frame.origin.x = (progress - 1) * Self.width
        dimView?.alpha = progress
    }

    private func settle(open: Bool) {
        guard let railView, let dimView else { return }
        UIView.animate(
            withDuration: 0.3, delay: 0,
            usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
            options: .curveEaseOut
        ) {
            railView.frame.origin.x = open ? 0 : -Self.width
            dimView.alpha = open ? 1 : 0
        } completion: { _ in
            if !open { self.tearDown() }
        }
    }

    @objc private func dimTapped() {
        settle(open: false)
    }

    // MARK: - Views

    private func install(in container: UIView) {
        tearDown()

        let overlay = UIView(frame: container.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let dim = UIView(frame: overlay.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dim.alpha = 0
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTapped)))
        overlay.addSubview(dim)

        let rail = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        rail.frame = CGRect(x: -Self.width, y: 0, width: Self.width, height: overlay.bounds.height)
        rail.autoresizingMask = [.flexibleHeight]
        overlay.addSubview(rail)

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rail.contentView.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: rail.contentView.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: rail.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: rail.contentView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: rail.contentView.safeAreaLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -16),
        ])

        container.addSubview(overlay)
        self.overlay = overlay
        self.dimView = dim
        self.railView = rail
        self.tileStack = stack
        rebuildTiles()

        // A switch or an identity adoption moves the highlight while open.
        macsObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.macsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildTiles() }
        }
    }

    private func tearDown() {
        if let macsObserver {
            NotificationCenter.default.removeObserver(macsObserver)
            self.macsObserver = nil
        }
        overlay?.removeFromSuperview()
        overlay = nil
        dimView = nil
        railView = nil
        tileStack = nil
    }

    private func rebuildTiles() {
        guard let stack = tileStack else { return }
        for view in stack.arrangedSubviews {
            view.removeFromSuperview()
        }
        let activeID = CompanionLink.activeMac?.id
        for mac in CompanionLink.pairedMacs {
            stack.addArrangedSubview(makeTile(
                boxText: Self.initials(of: mac.name),
                name: mac.name,
                isActive: mac.id == activeID
            ) { [weak self] in
                CompanionLink.switchTo(mac.id)
                self?.settle(open: false)
            })
        }
        stack.addArrangedSubview(makeTile(boxText: "+", name: "Add a Mac", isActive: false) { [weak self] in
            guard let self else { return }
            settle(open: false)
            onAddMac?()
        })
    }

    private func makeTile(
        boxText: String, name: String, isActive: Bool, action: @escaping () -> Void
    ) -> UIView {
        let box = UILabel()
        box.text = boxText
        box.font = .systemFont(ofSize: boxText == "+" ? 26 : 20, weight: .semibold)
        box.textAlignment = .center
        box.textColor = boxText == "+" ? .secondaryLabel : .label
        box.backgroundColor = .secondarySystemFill
        box.layer.cornerRadius = 16
        box.layer.cornerCurve = .continuous
        box.layer.masksToBounds = true
        if isActive {
            box.layer.borderWidth = 2
            box.layer.borderColor = UIColor.label.cgColor
        }
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: Self.tileSize),
            box.heightAnchor.constraint(equalToConstant: Self.tileSize),
        ])

        let label = UILabel()
        label.text = name
        label.font = .systemFont(ofSize: 11, weight: isActive ? .semibold : .regular)
        label.textColor = isActive ? .label : .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2

        let column = UIStackView(arrangedSubviews: [box, label])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 5
        // Touches land on the wrapping control, not the labels.
        column.isUserInteractionEnabled = false

        let control = TileControl()
        control.onTap = action
        column.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: control.topAnchor),
            column.bottomAnchor.constraint(equalTo: control.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: control.trailingAnchor),
        ])
        return control
    }

    /// "Jiwei's MacBook Pro" → "JM": first letters of the first two words.
    private static func initials(of name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        guard !letters.isEmpty else { return "?" }
        return String(letters).uppercased()
    }
}

/// A tap target wrapping one tile — UIControl so the touch dims and commits
/// like a button without hand-rolled gesture state.
private final class TileControl: UIControl {
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    @objc private func tapped() {
        onTap?()
    }
}
