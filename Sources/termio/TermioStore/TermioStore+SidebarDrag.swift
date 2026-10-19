import AppKit
import Foundation
import SwiftUI

/// The sidebar-only state of a session row drag (`TermioStore.sidebarDrag`). The sidebar's
/// views observe it beside the store; nothing else in the window does.
@MainActor
final class SidebarDragState: ObservableObject {
    @Published var rowDrop: TermioStore.SessionRowDrop?
    @Published var groupTarget: Session.ID?
    @Published var arming: Session.ID?
    @Published var settling: Session.ID?
    /// The dragged row has rested on its own slot: the floating copy snaps into it, the
    /// answer to a hold that has no other row to group with.
    @Published var snapped = false
    /// The group target came from a gap opened between two of its rows, not from a hold:
    /// the row joins where the gap is, and the floating copy follows the pointer rather
    /// than stacking onto a row.
    @Published var joinsInPlace = false
}

extension TermioStore {
    /// `sessions` as the sidebar draws them: in the order a drop would leave them,
    /// while a dragged row is over one of them.
    func sidebarOrder(_ sessions: [Session]) -> [Session] {
        guard let moved = draggingSessionID, let drop = sessionRowDrop else { return sessions }
        return droppedOrder(sessions, moved: moved, drop: drop)
    }

    private func droppedOrder(_ sessions: [Session], moved: Session.ID, drop: SessionRowDrop) -> [Session] {
        droppedOrder(sessions, moved: moved, drop: drop, joining: sessionRowGroupTarget)
    }

    private func droppedOrder(_ sessions: [Session], moved: Session.ID, drop: SessionRowDrop,
                              joining target: Session.ID?) -> [Session] {
        var groups = splitGroups.map(\.leafIDs)
        // An armed group already counts the dragged row as the target's, as "Group with"
        // will: gathered as its old group's member, it would preview at that group's end.
        if let target {
            groups = groups.map { $0.filter { $0 != moved } }
            if let index = groups.firstIndex(where: { $0.contains(target) }) {
                groups[index].append(moved)
            } else {
                groups.append([target, moved])
            }
        }
        return committedRowDrop(sessions, moved: moved, beside: drop.row, insert: drop.insert,
                                groups: groups)
    }

    /// Moves the gap the dragged row would land in, animated so the rows between
    /// slide over rather than jump. Published only on a change: the drop delegate
    /// calls this at pointer rate.
    func previewSessionRowDrop(_ drop: SessionRowDrop) {
        cancelSessionGroupDwell()
        guard sessionRowDrop != drop else { return }
        withAnimation(Self.rowReflow) { sessionRowDrop = drop }
    }

    /// Over a row the dragged one cannot land beside, another project's or worktree's: the
    /// rows close back up and any group lets go, so a release there leaves everything as it was.
    func withdrawSessionRowPreview() {
        cancelSessionGroupDwell()
        leaveOwnSlot()
        guard sessionRowDrop != nil else { return }
        withAnimation(Self.rowReflow) { sessionRowDrop = nil }
    }

    /// Opens the gap between two rows of a group the dragged row is not in: it joins the
    /// group right there, and the bracket grows around the gap. No hold, because the
    /// position already says which group and where.
    func previewSessionRowJoin(_ drop: SessionRowDrop, place: UUID) {
        sessionGroupDwell?.work.cancel()
        sessionGroupDwell = nil
        if sessionGroupArming != nil { sessionGroupArming = nil }
        guard !(sidebarDrag.joinsInPlace && sessionRowGroupTarget == drop.row && sessionRowDrop == drop)
        else { return }
        sessionGroupTargetPlace = place
        withAnimation(Self.rowReflow) {
            sessionRowGroupTarget = drop.row
            sidebarDrag.joinsInPlace = true
            sessionRowDrop = drop
        }
    }

    /// Starts the hold that groups the dragged session with `row`. Resting anywhere
    /// else cancels it, so a pointer passing through never groups. When it runs, the
    /// gap sits next to `row` on the side the drag came from and the bracket joins the
    /// two (`SidebarView.splitLinkMarks`): the drop's result is on screen before the drop.
    func beginSessionGroupDwell(on row: Session.ID, place: UUID) {
        // The same session shown twice: the hold follows the appearance under the pointer.
        if sessionRowGroupTarget == row {
            sessionGroupTargetPlace = place
            return
        }
        guard sessionGroupDwell?.row != row else { return }
        cancelSessionGroupDwell()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionGroupDwell?.row == row else { return }
            self.sessionGroupDwell = nil
            self.sessionGroupArming = nil
            self.sessionGroupTargetPlace = place
            self.sidebarDrag.joinsInPlace = false
            // It joins on the side it came from: the gap is already there, so the target
            // holds still and nothing jumps past it.
            let side = self.sideOfDraggedRow(relativeTo: row)
            withAnimation(Self.rowReflow) {
                self.sessionRowGroupTarget = row
                self.sessionRowDrop = SessionRowDrop(row: row, insert: side)
            }
        }
        sessionGroupDwell = (row, place, work)
        sessionGroupArming = row
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.groupDwell, execute: work)
    }

    /// The pointer rests on the dragged row's own slot, where a release lands it as drawn.
    /// After the same hold a group takes, the floating copy snaps into the slot: a hold
    /// always gets an answer, and here the answer is "it lands here".
    func restOnOwnSlot() {
        guard sessionRowGroupTarget == nil, !sidebarDrag.snapped, slotRest == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.slotRest != nil else { return }
            self.slotRest = nil
            withAnimation(Self.rowReflow) { self.sidebarDrag.snapped = true }
        }
        slotRest = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.groupDwell, execute: work)
    }

    /// The pointer left the slot: the copy lets go and follows it again.
    func leaveOwnSlot() {
        slotRest?.cancel()
        slotRest = nil
        if sidebarDrag.snapped {
            withAnimation(Self.rowReflow) { sidebarDrag.snapped = false }
        }
    }

    /// Ends a hold. `keepingTarget` leaves one that already armed: once the gap has
    /// moved under the target, the pointer rests on the gap, and that is still the
    /// hold the user meant.
    func cancelSessionGroupDwell(keepingTarget: Bool = false) {
        sessionGroupDwell?.work.cancel()
        sessionGroupDwell = nil
        if sessionGroupArming != nil { sessionGroupArming = nil }
        if !keepingTarget, sessionRowGroupTarget != nil {
            sessionRowGroupTarget = nil
            sidebarDrag.joinsInPlace = false
        }
    }

    /// Commits a release over the sidebar's rows: the group it was held for, else
    /// the gap it was drawn in. A release on its own slot with neither is still a
    /// drop that succeeded, so the drag image does not slide back to where the row
    /// already is.
    func commitSessionRowDrop() -> Bool {
        let moved = resolveDraggedSession()
        let group = sessionRowGroupTarget
        let gap = sessionRowDrop
        endSessionRowDrag()
        guard let moved else { return false }
        if let group {
            groupSession(moved, with: group, slot: gap?.insert == .above ? .first : .second)
        } else if let gap {
            reorderSession(moved, relativeTo: gap.row, insert: gap.insert)
        }
        // The sidebar's floating copy eases into the slot; the row shows when it lands.
        sessionRowSettling = moved
        return true
    }

    /// Clears every trace of a row drag. One transaction with the commit before
    /// it, so the rows the preview drew and the roster the drop wrote are the same
    /// frame, and nothing moves on release.
    func endSessionRowDrag() {
        strandedSessionDragCheck?.cancel()
        strandedSessionDragCheck = nil
        slotRest?.cancel()
        slotRest = nil
        sidebarDrag.snapped = false
        sidebarDrag.joinsInPlace = false
        sessionGroupDwell?.work.cancel()
        sessionGroupDwell = nil
        sessionGroupArming = nil
        sessionRowGroupTarget = nil
        sessionRowDrop = nil
        draggingSessionID = nil
    }

    /// Called each frame the sidebar draws a dragged row. A drag released where nothing
    /// takes it, outside the window say, calls no drop delegate and sends this window no
    /// mouse-moved event to clean up after it, so the row would stay hidden. Once the
    /// button has been up a beat with the drag still open, nothing is coming: end it.
    func noticeSessionDragFrame() {
        guard draggingSessionID != nil, strandedSessionDragCheck == nil,
              NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.strandedSessionDragCheck = nil
            guard self.draggingSessionID != nil, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            withAnimation(Self.rowReflow) { self.endSessionRowDrag() }
        }
        strandedSessionDragCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: check)
    }

    /// How fast rows make room for a dragged one: short, with no overshoot, the
    /// tab strip's `reflow`.
    static let rowReflow = Animation.smooth(duration: 0.2)
    /// How long a dragged row has to rest on another before a release groups them.
    static let groupDwell: TimeInterval = 0.3

    /// Which side of `target` the dragged row's gap is on in the order drawn now.
    private func sideOfDraggedRow(relativeTo target: Session.ID) -> RowInsertion {
        guard let moved = draggingSessionID, let slot = locate(moved) else { return .below }
        let rows = roster(at: slot)
        let drawn = sessionRowDrop.map { droppedOrder(rows, moved: moved, drop: $0) } ?? rows
        guard let from = drawn.firstIndex(where: { $0.id == moved }),
              let to = drawn.firstIndex(where: { $0.id == target }) else { return .below }
        return from < to ? .above : .below
    }

    /// What the edge of a row answers to a dragged row.
    enum RowDropAnswer {
        /// Nothing to move: the pointer is resting on the row, which may group.
        case rest
        /// The gap moves there.
        case move
        /// The gap opens there, inside a group the dragged row joins (`previewSessionRowJoin`).
        case join
    }

    /// What `candidate` would do. The edge of a row in a group the dragged row is not in
    /// joins that group there, at its outer edges as well as between its rows: a row
    /// brought against a group is meant to join it. The same slot outside the group is
    /// reached from the neighbouring row, so the row under the pointer decides. Elsewhere a
    /// gap that would not move anything is a row the pointer is resting on, not one it is
    /// passing: the target holds still until the pointer crosses into its far third, as a
    /// tab swaps only past the middle.
    func sessionRowDropAnswer(_ candidate: SessionRowDrop) -> RowDropAnswer {
        guard let moved = draggingSessionID, let slot = locate(moved) else { return .rest }
        if isInSplitGroup(candidate.row), canGroup(moved, with: candidate.row),
           !sharesSplitGroup(moved, candidate.row) {
            return .join
        }
        let rows = roster(at: slot).filter { $0.id == moved || canReorder(moved, relativeTo: $0.id) }
        let plain = droppedOrder(rows, moved: moved, drop: candidate, joining: nil)
        guard let at = plain.firstIndex(where: { $0.id == moved }),
              let beside = plain.firstIndex(where: { $0.id == candidate.row }),
              at == (candidate.insert == .above ? beside - 1 : beside + 1)
        else {
            return canGroup(moved, with: candidate.row) && !sharesSplitGroup(moved, candidate.row)
                ? .join : .rest
        }
        let now = sessionRowDrop.map { droppedOrder(rows, moved: moved, drop: $0) } ?? rows
        return plain.map(\.id) != now.map(\.id) ? .move : .rest
    }
}

/// `rows` with `moved` taken out and put back on the `insert` side of `beside`: the order a
/// drop there would leave. Unchanged when either row is not in `rows`, as when the dragged row
/// is over another roster.
func previewingRowDrop(_ rows: [Session], moved: Session.ID, beside target: Session.ID,
                       insert: TermioStore.RowInsertion) -> [Session] {
    guard moved != target, let from = rows.firstIndex(where: { $0.id == moved }) else { return rows }
    var result = rows
    let row = result.remove(at: from)
    guard let index = result.firstIndex(where: { $0.id == target }) else { return rows }
    result.insert(row, at: insert == .above ? index : index + 1)
    return result
}

/// The order a drop between rows commits: the gap (`previewingRowDrop`), then the split groups
/// gathered back into runs the way `reorderSession` gathers them, so a gap drawn inside a group
/// shows where the row really lands.
func committedRowDrop(_ rows: [Session], moved: Session.ID, beside target: Session.ID,
                      insert: TermioStore.RowInsertion, groups: [[Session.ID]]) -> [Session] {
    let previewed = previewingRowDrop(rows, moved: moved, beside: target, insert: insert)
    let gathered = gatheringSplitRuns(previewed.map(\.id), groups: groups)
    let byID = Dictionary(previewed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return gathered.compactMap { byID[$0] }
}
