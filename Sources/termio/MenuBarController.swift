import AppKit
import Combine

/// The menu-bar (tray) presence, modelled on unpeel's status item: a single
/// glyph that stays calm when nothing needs you, pulses while an agent works,
/// and rings (amber bell) when a session is waiting on you. Clicking it drops a
/// roster of every session grouped by project, each with its own status dot;
/// picking one focuses that session and brings the window forward.
///
/// We manage a raw `NSStatusItem` (not SwiftUI's `MenuBarExtra`) because termio
/// drives an explicit `NSApplication` rather than the SwiftUI app lifecycle.
@MainActor
final class MenuBarController {
    private let store: TermioStore
    private let onSelect: (Session.ID) -> Void
    private let statusItem: NSStatusItem
    // SF Symbol effects don't reliably apply to a status button's own image, so
    // we animate an embedded image view instead (a known AppKit gotcha).
    private let iconView = NSImageView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    private var cancellable: AnyCancellable?

    init(store: TermioStore, onSelect: @escaping (Session.ID) -> Void) {
        self.store = store
        self.onSelect = onSelect
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            iconView.imageScaling = .scaleProportionallyUpOrDown
            button.addSubview(iconView)
        }

        cancellable = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        applyIcon(for: store.aggregateStatus)
        statusItem.menu = buildMenu()
    }

    private func applyIcon(for status: SessionStatus) {
        iconView.removeAllSymbolEffects()
        switch status {
        case .idle:
            setIcon("terminal", tint: nil, template: true)
        case .working:
            setIcon("circle.dotted", tint: nil, template: true)
            iconView.addSymbolEffect(.pulse, options: .repeating)
        case .needsAttention:
            setIcon("bell.badge.fill", tint: .systemOrange, template: false)
        }
    }

    private func setIcon(_ symbol: String, tint: NSColor?, template: Bool) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "termio agents")
        image?.isTemplate = template
        iconView.image = image
        iconView.contentTintColor = tint
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        for project in store.projects where !project.sessions.isEmpty {
            let header = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for session in project.sessions {
                let item = NSMenuItem(
                    title: store.displayTitle(for: session),
                    action: #selector(didPickSession(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id.uuidString
                item.image = dot(for: store.status(for: session.id))
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit termio",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    /// A coloured dot image for a roster row, matching the sidebar's `StatusDot`.
    private func dot(for status: SessionStatus) -> NSImage? {
        let color: NSColor
        switch status {
        case .idle: color = .tertiaryLabelColor
        case .working: color = .systemBlue
        case .needsAttention: color = .systemOrange
        }
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    @objc private func didPickSession(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw)
        else { return }
        onSelect(id)
    }
}
