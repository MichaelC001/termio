import AppKit
import SwiftUI
import TermioShared

/// The horizontal layout's tabs: the selected group's sessions in a row above the cards, as
/// Safari shows a tab group's tabs. A tab is a split group or a lone session; its mark carries the
/// same status the sidebar row would — working, waiting on you, finished — so an agent that needs
/// you is visible from any tab.
///
/// The strip takes the window's top row, centred on the traffic lights' line. With the sidebar
/// collapsed it also carries the navigator toggle and a menu of the groups, so every group stays
/// one click away.
struct SessionTabStrip: View {
    @EnvironmentObject var store: TermioStore

    var body: some View {
        let group = store.selectedSessionID.flatMap(store.group(of:))
        HStack(spacing: 4) {
            if !store.sidebarVisible {
                NavigatorToggleButton()
                ChromeMenuButton(icon: .cardStack, help: localized("Groups"), makeMenu: groupMenu)
            }
            if let group {
                // Safari's sizing: the tabs share the strip's width equally, so one or two fill it.
                // Past the point where a share drops under `SessionTab.minimumWidth` they stop
                // shrinking and scroll instead, the selected one kept in view.
                let tabs = store.tabs(in: group)
                let activeIndex = tabs.firstIndex { store.selectedSessionID.map($0.contains) ?? false }
                GeometryReader { geometry in
                    let tabWidth = SessionTab.width(sharing: geometry.size.width, count: tabs.count)
                    ScrollViewReader { scroller in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                ForEach(Array(tabs.enumerated()), id: \.element) { index, ids in
                                    if index > 0 {
                                        // No divider beside the selected pill: its own edge parts it.
                                        TabDivider(hidden: activeIndex == index || activeIndex == index - 1)
                                    }
                                    SessionTab(ids: ids, width: tabWidth).id(ids.first)
                                }
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 3)
                        }
                        // Scrolled-off tabs end at the strip's own rounded edge instead of drawing
                        // on past it, under the controls beside it.
                        .clipShape(Capsule(style: .continuous))
                        .onChange(of: store.selectedSessionID, initial: true) { _, selected in
                            guard let tab = tabs.first(where: { selected.map($0.contains) ?? false }) else { return }
                            scroller.scrollTo(tab.first)
                        }
                    }
                }
                .frame(height: SessionTab.height + 4)
            }
            ChromeIconButton(icon: .add, help: localized("New Terminal"), prominence: .glass) {
                store.addTerminalHere()
            }
            if group == nil { Spacer(minLength: 0) }
        }
        .padding(.leading, store.sidebarVisible
                 ? 0
                 : WindowChrome.leadingInset(isFullScreen: store.windowIsFullScreen, columnMinX: 0))
        .frame(height: WindowChrome.rowHeight)
        .background(WindowDragArea())
    }

    /// Every group, the current one checked — the collapsed sidebar's list, as a menu.
    private func groupMenu() -> NSMenu {
        let menu = NSMenu()
        let current = store.selectedSessionID.flatMap(store.group(of:))
        for group in store.sessionGroups {
            let item = ClosureMenuItem(title: store.title(of: group)) { store.open(group) }
            item.state = group == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

/// A thin rule between two tabs, hidden beside the selected one.
private struct TabDivider: View {
    let hidden: Bool

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 14)
            .opacity(hidden ? 0 : 1)
    }
}

/// The selected tab's pill, the only glass in the strip: the rest of the tabs sit on the window's
/// own ground, as the sidebar does. Glass the way Safari's selected tab reads — a face a step
/// lighter than the ground, a hairline, and a rim lit from the top leading corner — and no drop
/// shadow: the system `glassEffect` floats its capsule on one, which read as a raised button
/// rather than a pane of glass.
private struct SelectedTabGlass: ViewModifier {
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if isActive {
            let dark = colorScheme == .dark
            let shape = Capsule(style: .continuous)
            content.background {
                shape.fill(Color.white.opacity(dark ? 0.09 : 0.55))
                    .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.10 : 0.07), lineWidth: 0.5))
                    .overlay(GlassRim(shape: shape))
            }
        } else {
            content
        }
    }
}

/// A session's mark in a rounded tile — the tab's icon. A split group fans its members' tiles out
/// behind the first, like a hand of cards, so a tab that opens several cards says so at a glance.
private struct TabIconStack: View {
    @EnvironmentObject var store: TermioStore
    let ids: [Session.ID]
    let status: SessionStatus

    private static let tile: CGFloat = 20
    /// Each tile behind the first sits this much further right and turns this much further,
    /// pivoting on its bottom edge.
    private static let fanOffset: CGFloat = 5
    private static let fanAngle: Double = 10

    /// One fanned tile: which session, and how far back in the fan it sits (0 is the front).
    private struct Fanned: Identifiable {
        let id: Session.ID
        let depth: Int
    }

    /// Back to front, so the first session's tile is drawn last — on top, upright.
    private var fanned: [Fanned] {
        let shown = Array(ids.prefix(3))
        return shown.indices.reversed().map { Fanned(id: shown[$0], depth: $0) }
    }

    private var width: CGFloat {
        let behind = CGFloat(min(ids.count, 3) - 1)
        return Self.tile + behind * Self.fanOffset + (behind > 0 ? 3 : 0)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(fanned) { tile in
                fannedTile(tile)
            }
        }
        .frame(width: width, height: Self.tile, alignment: .leading)
        .overlay(alignment: .leading) {
            StatusDot(status: status).frame(width: Self.tile, height: Self.tile)
        }
    }

    private func fannedTile(_ fanned: Fanned) -> some View {
        let depth = CGFloat(fanned.depth)
        return tile(for: fanned.id, isLead: fanned.depth == 0)
            .rotationEffect(.degrees(Double(fanned.depth) * Self.fanAngle), anchor: .bottom)
            .offset(x: depth * Self.fanOffset)
    }

    @ViewBuilder
    private func tile(for id: Session.ID, isLead: Bool) -> some View {
        ZStack {
            GlassTile()
            if isLead, status == .working {
                WorkingIndicator(tint: .sidebarWorkingInk)
                    .frame(width: 12, height: 12)
            } else if let session = store.session(id) {
                AgentIconView(agent: store.effectiveAgent(for: session), size: 12)
            }
        }
        .frame(width: Self.tile, height: Self.tile)
    }
}

/// An app-icon tile drawn as glass: an opaque base so fanned tiles hide the ones behind them,
/// a sheen that fades down the face, and a rim lit at the top edge and dark at the bottom.
struct GlassTile: View {
    @Environment(\.colorScheme) private var colorScheme
    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        let dark = colorScheme == .dark
        shape
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(
                shape.fill(LinearGradient(
                    colors: [.white.opacity(dark ? 0.20 : 0.9), .white.opacity(dark ? 0.04 : 0.35)],
                    startPoint: .top, endPoint: .bottom)))
            .overlay(
                shape.strokeBorder(LinearGradient(
                    stops: [
                        .init(color: .white.opacity(dark ? 0.55 : 1), location: 0),
                        .init(color: .white.opacity(dark ? 0.10 : 0.5), location: 0.45),
                        .init(color: .white.opacity(dark ? 0.22 : 0.7), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75))
            .overlay(shape.strokeBorder(Color.black.opacity(dark ? 0.45 : 0.14), lineWidth: 0.5).padding(-0.5))
            // A hard 1pt drop, not `.shadow`: a blurred shadow costs an offscreen pass per tile,
            // and the sidebar draws dozens of these while it scrolls.
            .background(shape.fill(Color.black.opacity(dark ? 0.35 : 0.12)).offset(y: 1))
    }
}

private struct SessionTab: View {
    @EnvironmentObject var store: TermioStore
    let ids: [Session.ID]
    let width: CGFloat
    @State private var isHovering = false

    static let height: CGFloat = 26
    static let minimumWidth: CGFloat = 120

    /// One tab's share of a strip `available` wide: the strip less its end padding and the 1pt
    /// dividers between tabs, split evenly, but never under `minimumWidth`.
    static func width(sharing available: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return minimumWidth }
        let room = available - 6 - CGFloat(count - 1)
        return max(minimumWidth, (room / CGFloat(count)).rounded(.down))
    }

    private var isActive: Bool { store.selectedSessionID.map(ids.contains) ?? false }

    var body: some View {
        let lead = ids.first.flatMap(store.session)
        let title = lead.map(store.displayTitle(for:)) ?? ""
        HStack(spacing: 8) {
            TabIconStack(ids: ids, status: store.combinedStatus(of: ids))
            Text(title)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            // Only a lone session closes from its tab: a split group's tab holds several, and
            // which one an × meant would be a guess.
            if ids.count == 1, let lead {
                Button { store.requestCloseSession(lead.id) } label: {
                    HugeIconView(icon: .close, size: 10, color: .secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localized("Close Session"))
                .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(width: width, height: Self.height)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(!isActive && isHovering ? 0.06 : 0)))
        .modifier(SelectedTabGlass(isActive: isActive))
        .contentShape(Capsule())
        .onTapGesture {
            // Opens the tab on its first card.
            guard !isActive, let first = ids.first else { return }
            store.selectedSessionID = first
        }
        .onHover { isHovering = $0 }
        .help(title)
    }
}
