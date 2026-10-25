import AppKit
import SwiftUI

/// One accessibility element on the simulator's screen, as the pane's element
/// picker shows it and hands it to a chat.
struct SimulatorElement: Equatable, Sendable {
    let type: String
    let label: String?
    let value: String?
    let identifier: String?
    /// VoiceOver's hint: what happens on activating it, when the app says.
    let hint: String?
    /// UIKit's accessibility traits — `Button`, `Header`, `Selected` — as idb
    /// names them; empty for none.
    let traits: [String]
    /// In interface points, top-left origin — what `termio sim tap` takes.
    let frame: CGRect

    /// The line `termio sim inspect` prints for it, so an agent handed one
    /// reads the same shape it reads from its own inspects.
    var summary: String {
        var line = type
        if let label { line += " \"\(label)\"" }
        if let value, value != label { line += " = \"\(value)\"" }
        if let identifier { line += " #\(identifier)" }
        line += " @ \(Int(frame.minX.rounded())),\(Int(frame.minY.rounded()))"
        line += " \(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
        if !traits.isEmpty { line += " traits: \(traits.joined(separator: ", "))" }
        if let hint { line += " hint: \"\(hint)\"" }
        return line
    }

    /// The element a point lands on, from the helper's hit-test document: the
    /// innermost one under the point that says something — a label, value or
    /// identifier — or the innermost one at all when none does, the way an
    /// icon's image has no label of its own. A container larger than the
    /// screen holds a layout no longer shown and is passed over, with all it
    /// holds; the root is exempt, since an iPad app's root reports a square.
    /// UIKit's private element types lose to anything else under the point.
    static func pick(from document: [String: Any], at point: CGPoint, interface: CGSize) -> SimulatorElement? {
        var speaking: SimulatorElement?
        var any: SimulatorElement?
        func walk(_ elements: [[String: Any]], level: Int) {
            for raw in elements {
                guard let element = SimulatorElement(raw) else {
                    walk(raw["children"] as? [[String: Any]] ?? [], level: level + 1)
                    continue
                }
                if level > 0, element.frame.width > interface.width + 1 || element.frame.height > interface.height + 1 {
                    continue
                }
                guard element.frame.contains(point) else { continue }
                // UIKit's private views — the scroll indicators above all, invisible
                // at rest and a finger wide down a list's edge — are picked only
                // when nothing else is there.
                let isPrivate = element.type.hasPrefix("_")
                if !isPrivate || any == nil { any = element }
                if !isPrivate, element.label != nil || element.value != nil || element.identifier != nil {
                    speaking = element
                }
                walk(raw["children"] as? [[String: Any]] ?? [], level: level + 1)
            }
        }
        walk(document["elements"] as? [[String: Any]] ?? [], level: 0)
        return speaking ?? any
    }

    private init?(_ raw: [String: Any]) {
        guard let frame = raw["frame"] as? [String: Any],
              let x = (frame["x"] as? NSNumber)?.doubleValue, let y = (frame["y"] as? NSNumber)?.doubleValue,
              let width = (frame["width"] as? NSNumber)?.doubleValue,
              let height = (frame["height"] as? NSNumber)?.doubleValue
        else { return nil }
        func text(_ value: Any?) -> String? {
            if let string = value as? String { return string.isEmpty ? nil : string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        type = text(raw["type"]) ?? "Element"
        label = text(raw["label"])
        value = text(raw["value"])
        identifier = text(raw["identifier"])
        // idb's key for the hint is `help`, after the macOS attribute it maps to.
        hint = text(raw["help"])
        traits = (raw["traits"] as? [String] ?? []).filter { $0 != "None" }
        self.frame = CGRect(x: x, y: y, width: width, height: height)
    }
}

extension SimulatorHost {
    /// The frontmost app's whole accessibility tree, for picking elements by
    /// point. A point read answers only the deepest element there — a list's
    /// invisible scroll indicator over the list, nothing at all over a title
    /// that is drawn rather than a view — where the tree has every element
    /// under the point to choose among.
    func elementTree(on screen: SimulatorScreen) async throws -> [String: Any] {
        let data = try await call("inspect", ["udid": screen.udid])
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimulatorHostError.malformedReply
        }
        return document
    }
}

/// The element picked with Select Element, under the screen: what it is, and
/// the step that nearly always follows — handing it to the agent, which can
/// tap it by label or point from the line it is given.
struct SimulatorElementCard: View {
    let element: SimulatorElement
    let deviceName: String
    let dismiss: () -> Void
    @EnvironmentObject private var store: TermioStore

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(element.label.map { "\(element.type) “\($0)”" } ?? element.type)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(details)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !element.traits.isEmpty {
                    Text(element.traits.joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let hint = element.hint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            TreeHeaderButton(huge: .copy, help: localized("Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(element.summary, forType: .string)
                SimulatorHost.shared.notice = localized("Copied")
            }
            TreeHeaderButton(huge: .bubbleChatAdd, help: localized("Add to Chat")) {
                if store.addSnippetToSelectedSessionPrompt("\(element.summary) — on the \(deviceName) simulator") {
                    dismiss()
                } else {
                    SimulatorHost.shared.notice = localized("Select a session to add this to.")
                }
            }
            TreeHeaderButton(huge: .close, help: localized("Close")) { dismiss() }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    private var details: String {
        let frame = element.frame
        var parts: [String] = []
        if let identifier = element.identifier { parts.append("#\(identifier)") }
        if let value = element.value, value != element.label { parts.append("= \(value)") }
        parts.append("\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())) "
            + "\(Int(frame.width.rounded()))×\(Int(frame.height.rounded()))")
        return parts.joined(separator: " · ")
    }
}
