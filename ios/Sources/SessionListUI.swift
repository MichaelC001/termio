import SwiftUI
import TermioShared
import UIKit

extension Color {
    /// Monochrome ink for the working spinner, matching the Mac sidebar's
    /// black/white comet: the motion already says "working", so color stays
    /// reserved for the status dots (green done / orange attention) that have no
    /// other channel. Adapts to light/dark like the Mac's appearance-matched ink.
    static let sessionWorkingInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : .black
    })
}

// Pieces shared by the two home levels (the Projects root and a pushed
// project page): the session row, the zero state, and the floating glass
// chrome they both draw.

// MARK: - Session row

/// A session row, Rex-list style: the agent's tile leading (its working
/// spinner while it runs), the title at body size, the status dot when it has
/// something to say, and a quiet chevron. When the session carries live
/// activity text (a pending question, the running command), it appears as a
/// gray preview line under the title — Messages' "last message", shown only
/// when there is one, so quiet sessions stay one line. Cross-project strips (the
/// root's "Needs You") pass `showsProject` so the row says where it lives.
///
/// Each row draws its own slice of the group's card, so `isFirst` / `isLast`
/// say which corners round and where the hairline stops.
struct SessionRow: View {
    let session: MockSession
    let isCurrent: Bool
    var showsProject = false
    var isFirst = false
    var isLast = false

    var body: some View {
        HStack(alignment: .center, spacing: ListCard.tileSpacing) {
            ListTile {
                if session.status == .working {
                    WorkingIndicator(tint: .sessionWorkingInk)
                } else {
                    AgentIconView(
                        ref: session.agent.iconRef,
                        size: 18,
                        tint: session.agent.tintColor
                    )
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            // The dot only enters the layout when it has something to say, so
            // idle rows don't reserve invisible width.
            if session.status == .done || session.status == .needsAttention {
                StatusDot(status: session.status)
            }
            ListChevron()
        }
        .listCard(isFirst: isFirst, isLast: isLast, isHighlighted: isCurrent)
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsProject, !session.project.isEmpty { parts.append(session.project) }
        // The worktree's branch, verbatim like the Mac sidebar's label — only
        // set for sessions living off the main checkout, so plain rows don't
        // repeat the project branch.
        if let branch = session.worktreeBranch { parts.append(branch) }
        if !session.subtitle.isEmpty { parts.append(session.subtitle) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Grouped card

/// The metrics every home list shares, so a session row and a project row line
/// up inside the same card and the section header sits over their tiles.
enum ListCard {
    static let cornerRadius: CGFloat = 18
    static let horizontalPadding: CGFloat = 14
    static let tileSize: CGFloat = 32
    static let tileSpacing: CGFloat = 12
    /// The hairline starts at the title, past the tile.
    static let separatorInset: CGFloat = horizontalPadding + tileSize + tileSpacing
    /// The cell margin outside the card; callers pass it to `UIHostingConfiguration`.
    static let outerMargin: CGFloat = 16
    /// Where a section header's text starts, over the tiles' leading edge.
    static let headerInset: CGFloat = outerMargin + horizontalPadding
}

/// The rounded square a row's mark sits in, drawn like a macOS 26 app icon: a
/// body lit from above, a specular rim brightest on the top edge, and a soft
/// shadow under it. Hand-drawn rather than `glassEffect`, because the material
/// is for floating controls and a list is content. The body stays neutral,
/// never a hue: the mark inside keeps its own tint.
struct ListTile<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let isDark = colorScheme == .dark
        content
            .shadow(color: .black.opacity(isDark ? 0.35 : 0.12), radius: 0.5, y: 0.5)
            .frame(width: ListCard.tileSize, height: ListCard.tileSize)
            .background {
                shape.fill(LinearGradient(
                    colors: isDark
                        ? [Color.white.opacity(0.20), Color.white.opacity(0.07)]
                        : [Color.white, Color.black.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: isDark
                        ? [Color.white.opacity(0.45), Color.white.opacity(0.06)]
                        : [Color.white, Color.black.opacity(0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                ), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(isDark ? 0.40 : 0.14), radius: 2, y: 1)
    }
}

struct ListChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

extension View {
    /// One row's slice of its group's card: only the group's outer corners
    /// round, and the hairline runs under every row but the last.
    func listCard(isFirst: Bool, isLast: Bool, isHighlighted: Bool = false) -> some View {
        let radius = ListCard.cornerRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? radius : 0,
            bottomLeadingRadius: isLast ? radius : 0,
            bottomTrailingRadius: isLast ? radius : 0,
            topTrailingRadius: isFirst ? radius : 0,
            style: .continuous
        )
        return self
            .padding(.horizontal, ListCard.horizontalPadding)
            .padding(.vertical, 10)
            // Fill whatever height the hosting cell settles on (its self-sizing
            // floor can exceed the row's ideal height), so the content centers
            // and the separator pins to the real cell bottom.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if !isLast {
                    RowSeparator(leadingInset: ListCard.separatorInset)
                        .padding(.trailing, ListCard.horizontalPadding)
                }
            }
            .background(Color.primary.opacity(isHighlighted ? 0.13 : 0.06), in: shape)
            .contentShape(shape)
    }
}

// MARK: - Scrolling title bar

extension UITableView {
    /// Puts a page's title bar into the scroll content, so it scrolls away with
    /// the rows the way Rex's header does, instead of standing pinned over them.
    /// The owner calls `sizeScrollingHeaderToFit()` from `viewDidLayoutSubviews`,
    /// because a table header never sizes itself.
    func setScrollingHeader(_ bar: UIView, horizontalInset: CGFloat, top: CGFloat, bottom: CGFloat) {
        let container = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontalInset),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontalInset),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom),
        ])
        tableHeaderView = container
    }

    func sizeScrollingHeaderToFit() {
        guard let header = tableHeaderView, bounds.width > 0 else { return }
        let height = header.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let size = CGSize(width: bounds.width, height: height)
        guard header.frame.size != size else { return }
        header.frame.size = size
        // Reassigning is what makes the table re-read the header's height.
        tableHeaderView = header
    }
}

/// The system-separator hairline, drawn inside the row (UIKit's own table
/// separators can't do this layout: grouped tables add full-width borders at
/// section edges, and plain tables pin their headers).
struct RowSeparator: View {
    let leadingInset: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.leading, leadingInset)
    }
}

// MARK: - Workspace grouping

/// One workspace's containers — the group a list draws as a section. The Mac's
/// tree is Device → Workspace → Project → Session, and a phone list that
/// flattens it pours every machine's rows into one column, where a VPS clone is
/// indistinguishable from a local one. The workspace is the group; `deviceAlias`
/// is the machine it is on, named in the header the way the Mac names it, and
/// never a level you navigate.
struct WorkspaceGroup {
    let id: String
    let name: String
    let deviceAlias: String?
    var projects: [MockProject]

    /// The machine to put after the workspace name, and nil when there is
    /// nothing to add: this Mac carries no mark — being on the machine you
    /// paired with is the absence of one — and neither does a workspace already
    /// named after its box, where the header says it once. Both rules are the
    /// desktop sidebar's.
    var machineLabel: String? {
        guard let deviceAlias,
              deviceAlias.caseInsensitiveCompare(name) != .orderedSame
        else { return nil }
        return deviceAlias
    }

    /// Every session in the group's containers, in roster order — what the
    /// session tabs (Terminals, Chats) list under the header, where the
    /// container itself is the tab and only its sessions are rows.
    var sessions: [MockSession] { projects.flatMap(\.sessions) }

    /// Containers grouped by workspace. Workspaces keep the order the Mac pushed
    /// them in — the sidebar's own order — and only the projects inside a group
    /// re-sort when the caller asks for Name, so switching sort never reshuffles
    /// the machines out from under the user.
    static func grouped(_ projects: [MockProject], sortedByName: Bool = false) -> [WorkspaceGroup] {
        var groups: [WorkspaceGroup] = []
        var indexByWorkspace: [String: Int] = [:]
        for project in projects {
            if let index = indexByWorkspace[project.workspaceID] {
                groups[index].projects.append(project)
                continue
            }
            indexByWorkspace[project.workspaceID] = groups.count
            groups.append(WorkspaceGroup(
                id: project.workspaceID,
                name: project.workspaceName,
                deviceAlias: project.deviceAlias,
                projects: [project]
            ))
        }
        guard sortedByName else { return groups }
        return groups.map { group in
            var sorted = group
            sorted.projects.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return sorted
        }
    }
}

extension Array where Element == WorkspaceGroup {
    /// Whether the sections are headed by their workspace. One unnamed local
    /// workspace is the case almost everyone is in, and the Mac hides its own
    /// workspace switcher there too — the page title already says what the list
    /// is. A second workspace, or one that names a machine, is what makes the
    /// grouping worth a header.
    var namesWorkspaces: Bool {
        count > 1 || contains { $0.deviceAlias != nil && !$0.name.isEmpty }
    }
}

/// A gray label capping a workspace group, with room for one
/// trailing detail — the machine that workspace is on. Mail and Files head their
/// groups the same way: the account or location names the section, and the rows
/// underneath say nothing more about where they live.
///
/// The detail keeps its own case. It is an `~/.ssh/config` alias, a literal the
/// user typed, and uppercasing it would make it something they can't find again.
final class WorkspaceSectionHeaderView: UITableViewHeaderFooterView {
    static let reuseID = "workspaceSectionHeader"
    /// The height a table should give it — the Projects list's, so the three
    /// workspace-grouped lists cap their groups identically.
    static let height: CGFloat = 40

    private let label = UILabel()
    private let detailLabel = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 15, weight: .regular)
        detailLabel.textColor = .tertiaryLabel
        detailLabel.textAlignment = .right
        // The workspace name is the section's identity; the machine gives way
        // when there isn't room for both.
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        contentView.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: ListCard.headerInset),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            detailLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -ListCard.headerInset),
            detailLabel.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, detail: String? = nil) {
        // The name as the user wrote it, like Rex's project headers: a
        // workspace is a proper noun, and caps make it one you can't search for.
        label.text = title
        detailLabel.text = detail
        detailLabel.isHidden = detail == nil
        isAccessibilityElement = true
        accessibilityTraits = .header
        // VoiceOver reads the group once, so the machine belongs in the same
        // breath as the name rather than as a second, orphaned element.
        accessibilityLabel = detail.map { "\(title), \(localized("on \($0)"))" } ?? title
    }
}

// MARK: - Empty state view

/// The centered zero state — a quiet glyph (or spinner), a title, a line of
/// guidance, and an optional pill button. Modeled on Messages/Telegram's empty
/// inbox: never fake content, always a status + a next step.
final class ListEmptyStateView: UIView {
    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    /// Fired when the pill button is tapped (only shown when it has a title).
    var onAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        icon.contentMode = .center
        icon.tintColor = .tertiaryLabel
        icon.preferredSymbolConfiguration = .init(pointSize: 44, weight: .regular)
        spinner.color = .secondaryLabel
        spinner.hidesWhenStopped = true

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        actionButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        actionButton.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, spinner, titleLabel, messageLabel, actionButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(20, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Nudged above dead-center so it reads as content, not a modal.
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -44),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 44),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(icon glyph: HugeIcon?, title: String, message: String, actionTitle: String?, busy: Bool) {
        if let glyph {
            icon.image = glyph.strokeImage(boxSize: 44)
            icon.isHidden = false
        } else {
            icon.isHidden = true
        }
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        titleLabel.text = title
        messageLabel.text = message
        if let actionTitle {
            actionButton.setTitle(actionTitle, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }
}
