import GhosttyTheme
import SwiftUI
import UIKit

/// The app's settings sheet — ChatGPT-style two-level: this root is a small
/// menu of categories, each pushing its own page. Appearance carries the
/// terminal look; Connectivity carries the Mac pairing and its live status.
final class SettingsViewController: UITableViewController {
    private enum Row: Int, CaseIterable {
        case appearance, connectivity

        var title: String {
            switch self {
            case .appearance: "Appearance"
            case .connectivity: "Connectivity"
            }
        }

        var icon: String {
            switch self {
            case .appearance: "paintbrush"
            case .connectivity: "antenna.radiowaves.left.and.right"
            }
        }

        func makePage() -> UIViewController {
            switch self {
            case .appearance: AppearanceSettingsViewController()
            case .connectivity: ConnectivitySettingsViewController()
            }
        }
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let row = Row.allCases[indexPath.row]
        cell.textLabel?.text = row.title
        cell.imageView?.image = UIImage(systemName: row.icon)
        cell.imageView?.tintColor = .label
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(Row.allCases[indexPath.row].makePage(), animated: true)
    }
}

// MARK: - Appearance

/// The terminal appearance controls — the mobile counterpart of the Mac's
/// Settings window: appearance mode, the light/dark theme pair, and font
/// size. Every change lands in `MobileSettings` and applies to open
/// terminals live.
final class AppearanceSettingsViewController: UITableViewController {
    private let settings = MobileSettings.shared

    private enum Row: Int, CaseIterable {
        case appearance, lightTheme, darkTheme, fontSize
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Appearance"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Coming back from a theme picker: refresh the theme rows' values.
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Terminal"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // A static four-row form; building cells directly beats reuse plumbing.
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch Row(rawValue: indexPath.row) {
        case .appearance:
            cell.textLabel?.text = "Appearance"
            cell.selectionStyle = .none
            let modes = MobileSettings.AppearanceMode.allCases
            let control = UISegmentedControl(items: modes.map(\.label))
            control.selectedSegmentIndex = modes.firstIndex(of: settings.appearanceMode) ?? 0
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                settings.appearanceMode = modes[control.selectedSegmentIndex]
            }, for: .valueChanged)
            control.sizeToFit()
            cell.accessoryView = control
        case .lightTheme:
            cell.textLabel?.text = "Light Theme"
            cell.detailTextLabel?.text = settings.lightThemeName
            cell.accessoryType = .disclosureIndicator
        case .darkTheme:
            cell.textLabel?.text = "Dark Theme"
            cell.detailTextLabel?.text = settings.darkThemeName
            cell.accessoryType = .disclosureIndicator
        case .fontSize, nil:
            cell.textLabel?.text = "Font Size"
            cell.detailTextLabel?.text = Self.pointsLabel(settings.fontSize)
            cell.selectionStyle = .none
            let stepper = UIStepper()
            stepper.minimumValue = MobileSettings.fontSizeRange.lowerBound
            stepper.maximumValue = MobileSettings.fontSizeRange.upperBound
            stepper.stepValue = 1
            stepper.value = settings.fontSize
            stepper.addAction(UIAction { [weak self, weak cell, weak stepper] _ in
                guard let self, let stepper else { return }
                settings.fontSize = stepper.value
                cell?.detailTextLabel?.text = Self.pointsLabel(stepper.value)
            }, for: .valueChanged)
            cell.accessoryView = stepper
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row) {
        case .lightTheme:
            navigationController?.pushViewController(ThemePickerViewController(slot: .light), animated: true)
        case .darkTheme:
            navigationController?.pushViewController(ThemePickerViewController(slot: .dark), animated: true)
        default:
            break
        }
    }

    private static func pointsLabel(_ size: Double) -> String {
        "\(Int(size)) pt"
    }
}

// MARK: - Connectivity

/// The Mac pairing page: live link status (the same state as the sidebar's
/// presence dot), the saved address, and forget. The sidebar owns the socket;
/// this page reads `CompanionLink.state` and posts `pairingDidChange` for the
/// sidebar to act on.
final class ConnectivitySettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case mac, forget
    }

    private enum MacRow: Int, CaseIterable {
        case status, address
    }

    private var stateObserver: NSObjectProtocol?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connectivity"
        stateObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tableView.reloadData()
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        // Nothing to forget while unpaired. Live state, not the saved URL:
        // dev runs pair via a launch arg without touching defaults.
        CompanionLink.state == .unpaired && CompanionLink.savedURL == nil
            ? 1 : Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == Section.mac.rawValue ? MacRow.allCases.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == Section.mac.rawValue ? "Mac" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == Section.mac.rawValue else { return nil }
        return "Pair once with the address termio on your Mac is serving — every project and session rides this one link."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch (Section(rawValue: indexPath.section), MacRow(rawValue: indexPath.row)) {
        case (.mac, .status):
            cell.textLabel?.text = "Status"
            cell.selectionStyle = .none
            cell.imageView?.image = UIImage(systemName: "circle.fill")
            cell.imageView?.preferredSymbolConfiguration = .init(pointSize: 11)
            switch CompanionLink.state {
            case .unpaired:
                cell.imageView?.tintColor = .tertiaryLabel
                cell.detailTextLabel?.text = "Not Paired"
            case .connecting:
                cell.imageView?.tintColor = .systemOrange
                cell.detailTextLabel?.text = "Reconnecting…"
            case .connected:
                cell.imageView?.tintColor = .systemGreen
                cell.detailTextLabel?.text = "Connected"
            }
        case (.mac, .address):
            cell.textLabel?.text = "Address"
            cell.detailTextLabel?.text = CompanionLink.savedURL?.absoluteString ?? "Not Set"
            cell.accessoryType = .disclosureIndicator
        default:
            cell.textLabel?.text = "Forget This Mac"
            cell.textLabel?.textColor = .systemRed
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (Section(rawValue: indexPath.section), MacRow(rawValue: indexPath.row)) {
        case (.mac, .address):
            presentEditAddress()
        case (.forget, _):
            forgetMac()
        default:
            break
        }
    }

    // MARK: - Actions

    private func presentEditAddress() {
        let alert = UIAlertController(
            title: "Connect to Mac",
            message: "The address termio on your Mac is serving.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "ws://mac-hostname:8787"
            field.text = CompanionLink.savedURL?.absoluteString
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            guard let raw = alert?.textFields?.first?.text,
                  let url = CompanionLink.normalize(raw) else { return }
            UserDefaults.standard.set(url.absoluteString, forKey: CompanionLink.defaultsKey)
            NotificationCenter.default.post(name: CompanionLink.pairingDidChange, object: nil)
            self?.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func forgetMac() {
        UserDefaults.standard.removeObject(forKey: CompanionLink.defaultsKey)
        NotificationCenter.default.post(name: CompanionLink.pairingDidChange, object: nil)
        tableView.reloadData()
    }
}

// MARK: - Theme picker

/// Full-catalog picker for one slot of the theme pair: the curated popular
/// shortlist up top (same names the Mac picker leads with — dark schemes for
/// the Dark slot, light for Light), the whole Ghostty catalog underneath,
/// and a search field over all of it. Picking a row applies immediately —
/// no confirm step, matching the Mac's live-preview behavior.
final class ThemePickerViewController: UITableViewController {
    enum Slot {
        case light, dark
    }

    private let slot: Slot
    private let settings = MobileSettings.shared

    /// The Mac picker's popular shortlists, filtered against the catalog so
    /// a package rename drops a stale entry instead of showing a dead row.
    private static let popularDarkNames: [String] = [
        "Dracula",
        "Catppuccin Mocha",
        "TokyoNight Storm",
        "Nord",
        "Gruvbox Dark",
        "Atom One Dark",
        "Monokai Pro",
        "Rose Pine",
        "Ayu Mirage",
        "Night Owl",
        "Kanagawa Wave",
        "Everforest Dark Hard",
        "GitHub Dark Default",
        "iTerm2 Solarized Dark",
    ].filter { GhosttyThemeCatalog.theme(named: $0) != nil }

    private static let popularLightNames: [String] = [
        "Catppuccin Latte",
        "Rose Pine Dawn",
        "Gruvbox Light",
        "Ayu Light",
        "Atom One Light",
        "GitHub Light Default",
        "TokyoNight Day",
        "Everforest Light Med",
        "iTerm2 Solarized Light",
    ].filter { GhosttyThemeCatalog.theme(named: $0) != nil }

    private let popular: [GhosttyThemeDefinition]
    private let all = GhosttyThemeCatalog.allThemes.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    private var query = ""
    private var matches: [GhosttyThemeDefinition] = []

    private var selectedName: String {
        get { slot == .light ? settings.lightThemeName : settings.darkThemeName }
        set {
            if slot == .light {
                settings.lightThemeName = newValue
            } else {
                settings.darkThemeName = newValue
            }
        }
    }

    init(slot: Slot) {
        self.slot = slot
        popular = (slot == .light ? Self.popularLightNames : Self.popularDarkNames)
            .compactMap { GhosttyThemeCatalog.theme(named: $0) }
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = slot == .light ? "Light Theme" : "Dark Theme"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "theme")

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private var isSearching: Bool { !query.isEmpty }

    private func theme(at indexPath: IndexPath) -> GhosttyThemeDefinition {
        if isSearching { return matches[indexPath.row] }
        return indexPath.section == 0 ? popular[indexPath.row] : all[indexPath.row]
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        isSearching ? 1 : 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isSearching { return matches.count }
        return section == 0 ? popular.count : all.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if isSearching { return nil }
        return section == 0 ? "Popular" : "All Themes"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "theme", for: indexPath)
        let theme = theme(at: indexPath)
        cell.contentConfiguration = UIHostingConfiguration {
            ThemeRow(theme: theme, isSelected: theme.name == selectedName)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectedName = theme(at: indexPath).name
        // The pick shows up in every visible copy of the row (popular + all).
        tableView.reloadData()
    }
}

extension ThemePickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        if !query.isEmpty {
            matches = GhosttyThemeCatalog.search(query).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        tableView.reloadData()
    }
}

/// One catalog row: a small background/foreground swatch so themes are
/// recognizable at a glance without applying them one by one.
private struct ThemeRow: View {
    let theme: GhosttyThemeDefinition
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(swatchHex: theme.background))
                Text("Aa")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(swatchHex: theme.foreground))
            }
            .frame(width: 36, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.15))
            )
            Text(theme.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }
}

private extension Color {
    init(swatchHex hex: String) {
        if let color = UIColor(ghosttyHex: hex) {
            self.init(uiColor: color)
        } else {
            self = .primary
        }
    }
}
