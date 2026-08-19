import Foundation

/// The session tree's on-disk home: it owns the file location and the JSON
/// (de)serialization, so `TermioStore` only ever hands it values. Live state
/// (terminal surfaces, per-session activity) is intentionally never written —
/// shells restart fresh, so only the tree and the current selection persist.
struct StateFile {
    struct Snapshot: Codable {
        /// The workspaces the sidebar scopes by. Absent in every state file
        /// written before workspaces existed, which is what `legacyProjects`
        /// below is decoded for.
        var workspaces: [Workspace]?
        /// The workspace the sidebar was showing when the app closed.
        var currentWorkspaceID: Workspace.ID?
        var projects: [Project]
        /// The same `projects` key read through the pre-workspace shape, filled
        /// in only when `workspaces` is missing. A project no longer carries the
        /// funnel fields (`kind`, `sshHost`), so the upgrade has to read the file
        /// the way it was written — see `WorkspaceMigration`.
        var legacyProjects: [WorkspaceMigration.LegacyProject]?
        var selectedSessionID: Session.ID?
        /// The single split layout builds before split *groups* used to write.
        /// Never written anymore, only decoded — `TermioStore.restored` migrates
        /// it into `splitGroups` as one group.
        var splitRoot: SplitNode?
        /// The split groups (see `TermioStore.splitGroups`). Optional so state
        /// files written before groups existed still decode.
        var splitGroups: [SplitNode]?
        /// Each session's inspector layout, keyed by session `id.uuidString`. Only the
        /// durable subset is written — the tab and the open *file* — since a diff / PR /
        /// trace is a snapshot of data that gets re-fetched (see `TermioStore.InspectorState`).
        /// Optional so older state files still decode.
        var inspectorLayouts: [String: InspectorLayout]?

        init(
            workspaces: [Workspace]?,
            currentWorkspaceID: Workspace.ID?,
            projects: [Project],
            selectedSessionID: Session.ID?,
            splitRoot: SplitNode? = nil,
            splitGroups: [SplitNode]?,
            inspectorLayouts: [String: InspectorLayout]?
        ) {
            self.workspaces = workspaces
            self.currentWorkspaceID = currentWorkspaceID
            self.projects = projects
            self.selectedSessionID = selectedSessionID
            self.splitRoot = splitRoot
            self.splitGroups = splitGroups
            self.inspectorLayouts = inspectorLayouts
        }

        private enum CodingKeys: String, CodingKey {
            case workspaces, currentWorkspaceID, projects, selectedSessionID, splitRoot,
                 splitGroups, inspectorLayouts
        }

        /// `projects` is decoded twice on an upgrade — once as the live shape, once
        /// as the shape the file was written in — because one JSON key has to
        /// answer to both until every user's state file has been rewritten. A file
        /// that already has `workspaces` skips the second read.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces)
            currentWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .currentWorkspaceID)
            projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
            legacyProjects = workspaces == nil
                ? try c.decodeIfPresent([WorkspaceMigration.LegacyProject].self, forKey: .projects)
                : nil
            selectedSessionID = try c.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
            splitRoot = try c.decodeIfPresent(SplitNode.self, forKey: .splitRoot)
            splitGroups = try c.decodeIfPresent([SplitNode].self, forKey: .splitGroups)
            inspectorLayouts = try c.decodeIfPresent(
                [String: InspectorLayout].self, forKey: .inspectorLayouts)
        }

        /// `legacyProjects` never round-trips: it is the same `projects` array read
        /// a second way, and writing it would leave a duplicate key in the file.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(workspaces, forKey: .workspaces)
            try c.encodeIfPresent(currentWorkspaceID, forKey: .currentWorkspaceID)
            try c.encode(projects, forKey: .projects)
            try c.encodeIfPresent(selectedSessionID, forKey: .selectedSessionID)
            try c.encodeIfPresent(splitGroups, forKey: .splitGroups)
            try c.encodeIfPresent(inspectorLayouts, forKey: .inspectorLayouts)
        }
    }

    /// The persisted slice of a session's inspector layout: which tab, and the file it
    /// had open (validated for existence on restore, since the file may have been deleted
    /// or its worktree removed while the app was closed).
    struct InspectorLayout: Codable {
        var tab: InspectorTab
        var filePath: String?
        var fileLine: Int?
        var fileReadOnly: Bool?
    }

    let url = AppChannel.supportDirectory

    private var stateURL: URL { url.appendingPathComponent("state.json") }

    /// The saved snapshot, or `nil` on first launch or an unreadable/corrupt file
    /// (in which case the caller seeds fresh state rather than failing).
    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Best-effort, atomic write. Failures are logged rather than crashing —
    /// losing a save is recoverable, trapping is not. Indented and key-sorted so
    /// the file reads like a config and diffs cleanly, not a one-line blob.
    func save(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: stateURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("termio: failed to persist state: \(error)\n".utf8))
        }
    }
}
