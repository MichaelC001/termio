import Foundation
import TermioShared

/// The horizontal layout's top level: what the sidebar lists while a group's sessions sit as
/// tabs above the cards (`TabLayout.horizontal`). Terminals and Chats are groups the way a
/// project is.
enum TabGroup: Hashable {
    case project(Project.ID)
    case terminals
    case chats
}

extension TermioStore {
    /// The group `id` is filed under.
    func group(of id: Session.ID) -> TabGroup? {
        switch locate(id) {
        case .project(let index, _): return .project(projects[index].id)
        case .terminals: return .terminals
        case .chats: return .chats
        case nil: return nil
        }
    }

    /// The groups the sidebar lists in the horizontal layout: Terminals and Chats while they
    /// hold anything, then the workspace's projects in the sidebar's own order.
    var sessionGroups: [TabGroup] {
        let workspace = currentWorkspace
        var groups: [TabGroup] = []
        if !workspace.terminals.isEmpty { groups.append(.terminals) }
        if !workspace.chats.isEmpty { groups.append(.chats) }
        groups += orderedProjects.map { .project($0.id) }
        return groups
    }

    func sessions(in group: TabGroup) -> [Session] {
        switch group {
        case .project(let id): return projects.first { $0.id == id }?.sessions ?? []
        case .terminals: return currentWorkspace.terminals
        case .chats: return currentWorkspace.chats
        }
    }

    func title(of group: TabGroup) -> String {
        switch group {
        case .project(let id): return projects.first { $0.id == id }?.name ?? ""
        case .terminals: return localized("Terminals")
        case .chats: return localized("Chats")
        }
    }

    /// A group's tabs: each split group once, at its first member's place, and every other
    /// session on its own. A tab is its sessions' ids, in the split's own order.
    func tabs(in group: TabGroup) -> [[Session.ID]] {
        var placed = Set<Session.ID>()
        var tabs: [[Session.ID]] = []
        for session in sessions(in: group) where !placed.contains(session.id) {
            if let split = splitGroups.first(where: { $0.contains(session.id) }) {
                let members = split.leafIDs
                placed.formUnion(members)
                tabs.append(members)
            } else {
                placed.insert(session.id)
                tabs.append([session.id])
            }
        }
        return tabs
    }

    /// The status a group or a tab shows for its sessions together: whatever most needs the
    /// person — blocked on them, then working, then finished.
    func combinedStatus(of ids: [Session.ID]) -> SessionStatus {
        let statuses = ids.map(status(for:))
        if statuses.contains(.needsAttention) { return .needsAttention }
        if statuses.contains(.working) { return .working }
        if statuses.contains(.done) { return .done }
        return .idle
    }

    /// Opens a group the way a browser opens a tab group: back on the session last selected in
    /// it, else its first. A project with no sessions gets a terminal.
    func open(_ group: TabGroup) {
        let members = sessions(in: group)
        if let last = lastGroupSelection[group], members.contains(where: { $0.id == last }) {
            selectedSessionID = last
        } else if let first = members.first {
            selectedSessionID = first.id
        } else if case .project(let id) = group {
            addSession(to: id)
        }
    }
}
