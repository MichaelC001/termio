import Photos
import UIKit

/// Telegram-style attachment sheet, faithful to their gallery tab's anatomy:
/// a circled ✕ and a centered "Recents ⌄" header, an edge-to-edge recents
/// grid whose first cell is the camera tile, selection rings on every photo,
/// and a bottom tab bar (Gallery · File) that swaps to a blue Add button once
/// something is selected. Underneath it's still the cheap version — a
/// detented system sheet, none of Telegram's hand-rolled pan/snap physics.
final class AttachmentSheetViewController: UIViewController {
    /// Ordered selection confirmed with the Add button.
    var onPickAssets: (([PHAsset]) -> Void)?
    var onCamera: (() -> Void)?
    /// System PHPicker — full library browsing and the no-permission fallback.
    var onPhotoLibrary: (() -> Void)?
    var onFiles: (() -> Void)?

    private static let selectionCap = 10

    private var fetchResult: PHFetchResult<PHAsset>?
    private let imageManager = PHCachingImageManager()
    private var selected: [PHAsset] = []
    private var hasCameraTile: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    private var grid: UICollectionView!
    private let deniedLabel = UILabel()
    private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let tabs = UIStackView()
    private let addButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildHeader()
        buildGrid()
        buildBottomBar()
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
                DispatchQueue.main.async { self?.reloadLibrary() }
            }
        default:
            reloadLibrary()
        }
    }

    // MARK: - Header (✕ + "Recents ⌄")

    private func buildHeader() {
        let close = UIButton(type: .system)
        // Same material as the composer's (+) so the two circles read as one
        // family.
        var closeConfig: UIButton.Configuration = if #available(iOS 26.0, *) {
            .glass()
        } else {
            .gray()
        }
        closeConfig.cornerStyle = .capsule
        closeConfig.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        close.configuration = closeConfig
        close.tintColor = .label
        close.accessibilityLabel = "Close"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        // Telegram's "Recents ⌄" opens the album browser; ours opens the full
        // system picker — same promise, the whole library behind the recents.
        let title = UIButton(type: .system)
        var titleConfig = UIButton.Configuration.plain()
        titleConfig.title = "Recents"
        titleConfig.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
        titleConfig.imagePlacement = .trailing
        titleConfig.imagePadding = 4
        titleConfig.baseForegroundColor = .label
        title.configuration = titleConfig
        title.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        title.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true) { self?.onPhotoLibrary?() }
        }, for: .touchUpInside)

        for subview in [close, title] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // Telegram's sheet chrome: 44pt circle, 16pt side inset, 44pt nav row.
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            close.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: close.centerYAnchor),
        ])
    }

    // MARK: - Grid

    private func buildGrid() {
        let columns = 3
        let fraction = 1.0 / CGFloat(columns)
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(fraction),
            heightDimension: .fractionalHeight(1)
        ))
        item.contentInsets = .init(top: 0.5, leading: 0.5, bottom: 0.5, trailing: 0.5)
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1),
                              heightDimension: .fractionalWidth(fraction)),
            repeatingSubitem: item, count: columns
        )
        let layout = UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group))
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        grid.accessibilityIdentifier = "attach.grid"
        grid.register(AttachmentPhotoCell.self, forCellWithReuseIdentifier: "photo")
        grid.register(AttachmentCameraCell.self, forCellWithReuseIdentifier: "camera")
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        // Keep the tail of the grid reachable above the floating bottom bar.
        grid.contentInset.bottom = 76

        deniedLabel.text = "Allow photo access to pick from your library here, or use the buttons below."
        deniedLabel.font = .preferredFont(forTextStyle: .footnote)
        deniedLabel.textColor = .secondaryLabel
        deniedLabel.textAlignment = .center
        deniedLabel.numberOfLines = 0
        deniedLabel.isHidden = true

        for subview in [grid!, deniedLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 64),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            deniedLabel.centerYAnchor.constraint(equalTo: grid.centerYAnchor),
            deniedLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            deniedLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    // MARK: - Bottom bar (tabs ⇄ Add)

    private func buildBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        tabs.axis = .horizontal
        tabs.distribution = .fillEqually
        tabs.translatesAutoresizingMaskIntoConstraints = false
        // Gallery marks the pane we're on (Telegram highlights the active
        // tab); File is the hop to the document picker.
        tabs.addArrangedSubview(tabItem("photo.on.rectangle.fill", "Gallery", tint: .systemBlue, action: nil))
        tabs.addArrangedSubview(tabItem("folder", "File", tint: .secondaryLabel) { [weak self] in
            self?.dismiss(animated: true) { self?.onFiles?() }
        })
        bottomBar.contentView.addSubview(tabs)

        var addConfig = UIButton.Configuration.filled()
        addConfig.cornerStyle = .capsule
        addConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = UIFont.roundedCounter(size: 17, weight: .semibold)
            return attrs
        }
        addButton.configuration = addConfig
        addButton.isHidden = true
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.addAction(UIAction { [weak self] _ in
            guard let self, !selected.isEmpty else { return }
            let assets = selected
            dismiss(animated: true) { self.onPickAssets?(assets) }
        }, for: .touchUpInside)
        bottomBar.contentView.addSubview(addButton)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // Telegram's glass tab panel: 62pt tall, 20pt side insets, 30pt
            // icons; the Add face copies SolidRoundedButtonNode (48pt / r24).
            bottomBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -66),
            tabs.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor, constant: -20),
            tabs.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor, constant: 4),
            tabs.heightAnchor.constraint(equalToConstant: 58),
            addButton.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor, constant: 16),
            addButton.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor, constant: -16),
            addButton.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor, constant: 8),
            addButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func tabItem(_ symbol: String, _ title: String, tint: UIColor,
                         action: (() -> Void)?) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        )
        config.title = title
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = tint
        // Telegram's attachment tabs sit at 10pt medium (system tab bars too).
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = UIFont.systemFont(ofSize: 10, weight: .medium)
            return attrs
        }
        let button = UIButton(configuration: config)
        if let action {
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
        return button
    }

    private func refreshBottomBar() {
        let hasSelection = !selected.isEmpty
        let previousTitle = addButton.configuration?.title
        addButton.configuration?.title = "Add \(selected.count)"
        guard hasSelection == addButton.isHidden else {
            // Already showing the right face; a count change gets Telegram's
            // little acknowledgment pop instead of a silent relabel.
            if hasSelection, previousTitle != addButton.configuration?.title {
                UIView.animate(withDuration: 0.1, animations: {
                    self.addButton.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
                }) { _ in
                    UIView.animate(withDuration: 0.15) { self.addButton.transform = .identity }
                }
            }
            return
        }
        // Telegram's tabs⇄sendbar swap: 0.25s ease, slide + fade, no hard cut.
        let incoming: UIView = hasSelection ? addButton : tabs
        let outgoing: UIView = hasSelection ? tabs : addButton
        incoming.isHidden = false
        incoming.alpha = 0
        incoming.transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            incoming.alpha = 1
            incoming.transform = .identity
            outgoing.alpha = 0
        } completion: { _ in
            outgoing.isHidden = true
            outgoing.alpha = 1
        }
    }

    // MARK: - Library

    private func reloadLibrary() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            deniedLabel.isHidden = false
            grid.isHidden = true
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 120
        fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        deniedLabel.isHidden = true
        grid.isHidden = false
        grid.reloadData()
    }

    private func asset(at indexPath: IndexPath) -> PHAsset? {
        let index = indexPath.item - (hasCameraTile ? 1 : 0)
        guard index >= 0, let fetchResult, index < fetchResult.count else { return nil }
        return fetchResult.object(at: index)
    }
}

extension AttachmentSheetViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int {
        (fetchResult?.count ?? 0) + (hasCameraTile ? 1 : 0)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if hasCameraTile, indexPath.item == 0 {
            return collectionView.dequeueReusableCell(withReuseIdentifier: "camera", for: indexPath)
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath) as! AttachmentPhotoCell
        guard let asset = asset(at: indexPath) else { return cell }
        cell.configure(asset: asset, manager: imageManager,
                       selectionIndex: selected.firstIndex(of: asset).map { $0 + 1 })
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if hasCameraTile, indexPath.item == 0 {
            dismiss(animated: true) { [weak self] in self?.onCamera?() }
            return
        }
        guard let tapped = asset(at: indexPath) else { return }
        if let index = selected.firstIndex(of: tapped) {
            selected.remove(at: index)
        } else if selected.count < Self.selectionCap {
            selected.append(tapped)
        } else {
            // Telegram's only picker haptic: the limit breach. Selection
            // itself stays silent — no tactile fatigue on rapid picking.
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        refreshBottomBar()
        // Renumber every visible badge; only the tapped cell gets the bounce —
        // deselection shifts later ordinals, but those just relabel.
        for visiblePath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: visiblePath) as? AttachmentPhotoCell,
                  let visibleAsset = asset(at: visiblePath) else { continue }
            cell.setSelectionIndex(
                selected.firstIndex(of: visibleAsset).map { $0 + 1 },
                animated: visiblePath == indexPath
            )
        }
    }
}

/// Square thumbnail with Telegram's selection language: a ring on every
/// photo's top-right corner, numbered and filled blue once selected.
private final class AttachmentPhotoCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let ring = UIView()
    private let badge = UILabel()
    private var requestID: PHImageRequestID?
    private weak var manager: PHCachingImageManager?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        ring.layer.borderColor = UIColor.white.cgColor
        ring.layer.borderWidth = 1.5
        ring.layer.cornerRadius = 14.5
        ring.layer.shadowColor = UIColor.black.cgColor
        ring.layer.shadowOpacity = 0.25
        ring.layer.shadowRadius = 2
        ring.layer.shadowOffset = .zero
        ring.isUserInteractionEnabled = false
        ring.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(ring)

        // Telegram sizes the ordinal by digit count (16/15pt); our cap is 10,
        // so two digits max — 15pt covers both.
        badge.font = .roundedCounter(size: 15, weight: .semibold)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        ring.addSubview(badge)

        // Telegram's check circle: 29pt, 3pt off the cell corner.
        NSLayoutConstraint.activate([
            ring.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            ring.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -3),
            ring.widthAnchor.constraint(equalToConstant: 29),
            ring.heightAnchor.constraint(equalToConstant: 29),
            badge.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func configure(asset: PHAsset, manager: PHCachingImageManager, selectionIndex: Int?) {
        self.manager = manager
        if let requestID { manager.cancelImageRequest(requestID) }
        imageView.image = nil
        let scale = UIScreen.main.scale
        let side = bounds.width * scale
        requestID = manager.requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            options: nil
        ) { [weak self] image, _ in
            self?.imageView.image = image
        }
        setSelectionIndex(selectionIndex)
    }

    func setSelectionIndex(_ index: Int?, animated: Bool = false) {
        let selecting = index != nil && badge.isHidden
        badge.isHidden = index == nil
        badge.text = index.map(String.init)
        ring.backgroundColor = index == nil ? .clear : .systemBlue
        imageView.alpha = index == nil ? 1 : 0.75
        guard animated else { return }
        // Telegram's CheckNode bounce: dip, overshoot, settle on select
        // (0.08/0.13/0.10s); just dip-and-return on deselect.
        if selecting {
            UIView.animateKeyframes(withDuration: 0.31, delay: 0) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.26) {
                    self.ring.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.26, relativeDuration: 0.42) {
                    self.ring.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.68, relativeDuration: 0.32) {
                    self.ring.transform = .identity
                }
            }
        } else {
            UIView.animateKeyframes(withDuration: 0.21, delay: 0) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.38) {
                    self.ring.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.38, relativeDuration: 0.62) {
                    self.ring.transform = .identity
                }
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let requestID { manager?.cancelImageRequest(requestID) }
        requestID = nil
        imageView.image = nil
        setSelectionIndex(nil)
    }
}

/// The grid's first cell — Telegram puts its live camera feed here; ours is
/// a quiet tile that opens the full camera (the live AVCaptureSession tile
/// stays deferred).
private final class AttachmentCameraCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        let icon = UIImageView(image: UIImage(
            systemName: "camera.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .medium)
        ))
        icon.tintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Camera"
    }

    /// Telegram's button feedback: dim instantly on touch-down, ease back
    /// on release — opacity only, no scaling.
    override var isHighlighted: Bool {
        didSet {
            if isHighlighted {
                contentView.alpha = 0.4
            } else {
                UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut]) {
                    self.contentView.alpha = 1
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
}
