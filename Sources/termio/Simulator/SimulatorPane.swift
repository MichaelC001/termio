import AppKit
import AVFoundation
import Quartz
import SwiftUI

/// The inspector's Simulator pane: one iOS Simulator, live, under a header that
/// picks the device and holds the hardware buttons a mouse can't reach. The
/// device is driven by pointer and keyboard here, and by agents through
/// `termio sim` — both act on the same device, the one this pane shows.
struct SimulatorPane: View {
    @ObservedObject private var host = SimulatorHost.shared
    @State private var runtimes: [SimulatorRuntime] = []

    var body: some View {
        VStack(spacing: 0) {
            if let reason = host.unavailableReason {
                PaneEmptyState(localized("Simulator Unavailable"), icon: .smartPhone, message: reason)
            } else if let problem = host.setupProblem {
                SimulatorSetupView(problem: problem)
            } else {
                header
                content
            }
        }
        .sheet(item: $host.annotating) { source in
            SimulatorAnnotationEditor(source: source) { host.annotating = nil }
        }
        .task {
            await host.checkSetup()
            guard host.setupProblem == nil else { return }
            await host.refreshDevices()
            guard host.screen == nil, host.booting == nil else { return }
            // The device used last, booting it if it was shut down since, so it
            // is warm by the time an agent asks for it; else one already running.
            let last = host.lastDevice.flatMap { udid in host.devices.first { $0.udid == udid } }
            if let device = last ?? host.devices.first(where: \.isBooted) {
                await host.show(device.udid)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            deviceMenu
            if let rate = host.frameRate {
                Text(rate == 0 ? localized("FPS: idle") : localized("FPS: \(rate)"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 8)
            if let screen = host.screen {
                TreeHeaderButton(huge: .home, help: localized("Home")) {
                    host.fire("button", ["udid": screen.udid, "name": "home"])
                }
                TreeHeaderButton(huge: .refresh, help: localized("Rotate Right")) {
                    host.fire("rotate", ["udid": screen.udid, "direction": "right"])
                }
                TreeHeaderButton(huge: .camera, help: localized("Save Screenshot to Desktop")) {
                    Task { await host.perform(.screenshot, on: screen) }
                }
                TreeHeaderButton(
                    symbol: "cursorarrow.rays",
                    help: host.inspecting ? localized("Stop Selecting") : localized("Select Element"),
                    isOn: host.inspecting
                ) {
                    host.inspecting.toggle()
                }
                TreeHeaderButton(symbol: "pencil.tip.crop.circle", help: localized("Annotate")) {
                    Task { await host.attempt("annotate") { try await host.annotate(screen) } }
                }
                if let recording = host.recording {
                    RecordingClock(started: recording.started)
                    TreeHeaderButton(symbol: "stop.circle", help: localized("Stop Recording")) {
                        Task { await host.perform(.record, on: screen) }
                    }
                } else {
                    TreeHeaderButton(symbol: "record.circle", help: localized("Record Screen to Desktop")) {
                        Task { await host.perform(.record, on: screen) }
                    }
                }
                SimulatorMoreMenu(screen: screen)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }

    /// Booted devices first; picking a shut-down one boots it.
    private var deviceMenu: some View {
        Menu {
            ForEach(host.devices) { device in
                Button {
                    Task { await host.show(device.udid) }
                } label: {
                    if device.udid == host.screen?.udid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.isBooted ? device.name : "\(device.name) — \(device.os)")
                    }
                }
            }
            if let screen = host.screen {
                Divider()
                Button(localized("Restart")) {
                    Task { await host.attempt("restart") { try await host.restart(screen.udid) } }
                }
                Button(localized("Shut Down")) {
                    Task { await host.attempt("shut down") { try await host.shutDown(screen.udid) } }
                }
                Button(localized("Rename…")) { rename(screen) }
                Button(localized("Erase All Content and Settings…")) { erase(screen) }
                Button(localized("Delete…")) { delete(screen) }
            }
            Divider()
            Menu(localized("New Simulator")) {
                if runtimes.isEmpty {
                    Text(localized("No iOS runtimes are installed in Xcode."))
                }
                ForEach(runtimes, id: \.identifier) { runtime in
                    Menu(runtime.name) {
                        ForEach(runtime.deviceTypes, id: \.identifier) { type in
                            Button(type.name) {
                                Task {
                                    await host.attempt("new simulator") {
                                        try await host.create(
                                            name: type.name, deviceType: type.identifier, runtime: runtime.identifier)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Button(localized("Refresh")) { Task { await host.refreshDevices() } }
        } label: {
            Text(host.booting.flatMap { udid in host.devices.first { $0.udid == udid }?.name }
                 ?? host.screen?.name ?? localized("Choose a Simulator"))
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task {
            await host.refreshDevices()
            do {
                runtimes = try await host.runtimes()
            } catch {
                Log.simulator.error("listing runtimes failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func rename(_ screen: SimulatorScreen) {
        let alert = NSAlert()
        alert.messageText = localized("Rename Simulator")
        let field = NSTextField(string: screen.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: localized("Rename"))
        alert.addButton(withTitle: localized("Cancel"))
        alert.window.initialFirstResponder = field
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let chosen = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !chosen.isEmpty, chosen != name else { return }
        Task { await host.attempt("rename") { try await host.rename(screen.udid, to: chosen) } }
    }

    private func erase(_ screen: SimulatorScreen) {
        guard confirm(
            localized("Erase all content and settings on \(screen.name)?"),
            localized("Its apps, data and settings are removed, as on a new device. It restarts when the erase is done."),
            action: localized("Erase"))
        else { return }
        Task { await host.attempt("erase") { try await host.erase(screen.udid) } }
    }

    private func delete(_ screen: SimulatorScreen) {
        guard confirm(
            localized("Delete \(screen.name)?"),
            localized("The simulator and everything on it are removed from this Mac."),
            action: localized("Delete"))
        else { return }
        Task { await host.attempt("delete") { try await host.delete(screen.udid) } }
    }

    private func confirm(_ message: String, _ detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = true
        alert.addButton(withTitle: localized("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @ViewBuilder
    private var content: some View {
        if let booting = host.booting {
            let name = host.devices.first { $0.udid == booting }?.name ?? booting
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(localized("Booting \(name)…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let screen = host.screen {
            // The card and the notice sit below the device, never over it: the
            // screen shrinks to make room, and nothing on it is hidden.
            VStack(spacing: 6) {
                SimulatorScreenRepresentable(
                    screen: screen, zoom: host.zoom, highlight: host.hoveredElement ?? host.selectedElement)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let notice = host.notice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .task(id: notice) {
                            do { try await Task.sleep(for: .seconds(3)) } catch { return }
                            if host.notice == notice { host.notice = nil }
                        }
                }
                if let element = host.selectedElement {
                    SimulatorElementCard(element: element, deviceName: screen.name) { host.selectedElement = nil }
                }
                if let capture = host.lastCapture {
                    SimulatorCaptureCard(url: capture, deviceName: screen.name) { host.lastCapture = nil }
                }
                if host.logsShown {
                    SimulatorLogsDrawer(udid: screen.udid)
                        .frame(height: 180)
                }
            }
            .padding(12)
        } else if let error = host.lastError {
            PaneEmptyState(localized("Simulator Unavailable"), icon: .smartPhone, message: error)
        } else {
            PaneEmptyState(
                localized("No Simulator Running"), icon: .smartPhone,
                message: localized("Choose a device above to boot it."))
        }
    }
}

/// The pane's "…" menu: the device's hardware and settings that have no
/// button of their own, each with Simulator.app's shortcut beside it. The
/// shortcuts work while the screen has focus (`SimulatorScreenView`).
struct SimulatorMoreMenu: View {
    let screen: SimulatorScreen
    @State private var anchor = MenuAnchor()

    var body: some View {
        TreeHeaderButton(symbol: "ellipsis", help: localized("More")) {
            Task { await popMenu() }
        }
        .background(MenuAnchorView(anchor: anchor))
    }

    /// Built on every open, after reading the states its checkmarks show.
    @MainActor
    private func popMenu() async {
        let host = SimulatorHost.shared
        let udid = screen.udid
        async let dark = host.isDark(udid)
        async let slow = host.slowAnimations(udid)
        let (isDark, isSlow) = await (dark, slow)
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        for command in [SimulatorCommand.home, .lock, .rotateLeft, .rotateRight, .shake, .volumeUp, .volumeDown] {
            menu.addItem(item(for: command))
        }
        menu.addItem(.separator())
        menu.addItem(item(for: .screenshot))
        let record = item(for: .record)
        if host.recording != nil { record.title = localized("Stop Recording") }
        menu.addItem(record)
        menu.addItem(.separator())

        let zoom = NSMenuItem(title: localized("Zoom"), action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu()
        for command in [SimulatorCommand.zoomToFit, .physicalSize] {
            let row = item(for: command)
            row.state = (command == .zoomToFit ? host.zoom == .fit : host.zoom == .physical) ? .on : .off
            zoomMenu.addItem(row)
        }
        zoomMenu.addItem(.separator())
        zoomMenu.addItem(item(for: .zoomIn))
        zoomMenu.addItem(item(for: .zoomOut))
        zoom.submenu = zoomMenu
        menu.addItem(zoom)

        let appearance = NSMenuItem(title: localized("Appearance"), action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu()
        for dark in [false, true] {
            let row = ClosureMenuItem(title: dark ? localized("Dark") : localized("Light")) {
                Task { await host.attempt("appearance") { try await host.setDark(dark, on: udid) } }
            }
            row.state = dark == isDark ? .on : .off
            appearanceMenu.addItem(row)
        }
        appearanceMenu.addItem(.separator())
        appearanceMenu.addItem(item(for: .toggleAppearance))
        appearance.submenu = appearanceMenu
        menu.addItem(appearance)

        let statusBar = NSMenuItem(title: localized("Status Bar"), action: nil, keyEquivalent: "")
        let statusMenu = NSMenu()
        let current = host.statusBars[udid] ?? .live
        for preset in SimulatorStatusBar.allCases {
            let row = ClosureMenuItem(title: preset.title) {
                Task { await host.attempt("status bar") { try await host.setStatusBar(preset, on: udid) } }
            }
            row.state = preset == current ? .on : .off
            statusMenu.addItem(row)
        }
        statusBar.submenu = statusMenu
        menu.addItem(statusBar)

        let slowRow = ClosureMenuItem(title: localized("Slow Animations")) {
            Task { await host.attempt("slow animations") { try await host.setSlowAnimations(!isSlow, on: udid) } }
        }
        slowRow.state = isSlow ? .on : .off
        menu.addItem(slowRow)
        let frameRate = ClosureMenuItem(title: localized("Show Frame Rate")) { host.showsFrameRate.toggle() }
        frameRate.state = host.showsFrameRate ? .on : .off
        menu.addItem(frameRate)
        let logs = ClosureMenuItem(title: localized("App Logs")) { host.logsShown.toggle() }
        logs.state = host.logsShown ? .on : .off
        menu.addItem(logs)
        let keyboard = item(for: .toggleKeyboard)
        keyboard.state = host.onScreenKeyboard.contains(udid) ? .on : .off
        menu.addItem(keyboard)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func item(for command: SimulatorCommand) -> NSMenuItem {
        let screen = self.screen
        let item = ClosureMenuItem(title: command.title) {
            Task { await SimulatorHost.shared.perform(command, on: screen) }
        }
        item.keyEquivalent = command.shortcut.key
        item.keyEquivalentModifierMask = command.shortcut.modifiers
        return item
    }
}

/// How long the recording has run, beside its Stop button.
private struct RecordingClock: View {
    let started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(started)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }
}

/// The screenshot or recording just saved, under the screen until it is
/// dismissed or replaced: the step after a capture is nearly always handing it
/// to someone — an agent, a chat, an issue — so the card offers that, and the
/// bin for a capture that missed.
struct SimulatorCaptureCard: View {
    let url: URL
    let deviceName: String
    let dismiss: () -> Void
    @EnvironmentObject private var store: TermioStore
    @State private var thumbnail: NSImage?

    private var isMovie: Bool { url.pathExtension.lowercased() == "mp4" }

    var body: some View {
        HStack(spacing: 8) {
            Button { CapturePreview.shared.show(url) } label: { preview }
                .buttonStyle(.plain)
                .help(localized("Preview"))
            Spacer(minLength: 4)
            if !isMovie {
                TreeHeaderButton(symbol: "pencil.tip.crop.circle", help: localized("Annotate")) {
                    SimulatorHost.shared.annotating = SimulatorAnnotationSource(url: url, deviceName: deviceName)
                }
            }
            TreeHeaderButton(huge: .copy, help: isMovie ? localized("Copy") : localized("Copy Image")) { copy() }
            TreeHeaderButton(huge: .bubbleChatAdd, help: localized("Add to Chat")) {
                if store.addPathToSelectedSessionPrompt(url) {
                    dismiss()
                } else {
                    SimulatorHost.shared.notice = localized("Select a session to add this to.")
                }
            }
            TreeHeaderButton(symbol: "trash", help: localized("Move to Trash")) { trash() }
            TreeHeaderButton(huge: .close, help: localized("Close")) { dismiss() }
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        .contextMenu {
            Button(localized("Copy Path")) { copyPath() }
            Button(localized("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .task(id: url) { thumbnail = await Self.thumbnail(of: url) }
    }

    /// The thumbnail and the name: a click previews the capture in Quick Look.
    private var preview: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 22, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(isMovie ? localized("Recording Saved") : localized("Screenshot Saved"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(url.lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
    }

    /// A screenshot goes on the pasteboard as the image and the file, so it
    /// pastes into a chat as a picture and into Finder as the PNG; a movie only
    /// as the file.
    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var items: [NSPasteboardWriting] = [url as NSURL]
        if !isMovie, let image = NSImage(contentsOf: url) { items.insert(image, at: 0) }
        if !pasteboard.writeObjects(items) {
            SimulatorHost.shared.notice = localized("Couldn’t copy the capture.")
            return
        }
        SimulatorHost.shared.notice = localized("Copied")
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        SimulatorHost.shared.notice = localized("Copied")
    }

    private func trash() {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            dismiss()
        } catch {
            Log.simulator.error("trashing a capture failed: \(error.localizedDescription, privacy: .public)")
            SimulatorHost.shared.notice = error.localizedDescription
        }
    }

    private static func thumbnail(of url: URL) async -> NSImage? {
        guard url.pathExtension.lowercased() == "mp4" else { return NSImage(contentsOf: url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 240)
        do {
            let (image, _) = try await generator.image(at: .zero)
            return NSImage(cgImage: image, size: .zero)
        } catch {
            Log.simulator.error("recording thumbnail failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Quick Look for the capture card: the panel Finder shows on Space, so a
/// movie plays and a screenshot opens full size without leaving Termio.
@MainActor
final class CapturePreview: NSObject, QLPreviewPanelDataSource {
    static let shared = CapturePreview()
    // Read from the panel's callbacks, which AppKit makes on the main thread.
    nonisolated(unsafe) private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url.map { $0 as NSURL }
    }
}

/// An app's log while it runs, under the screen: the read `termio sim logs`
/// makes, repeated every two seconds from where the last one ended. One app at
/// a time, because a whole simulator logs thousands of lines a second; the app
/// an agent last launched is picked first.
struct SimulatorLogsDrawer: View {
    let udid: String
    @ObservedObject private var host = SimulatorHost.shared
    @State private var apps: [(name: String, bundleID: String)] = []
    @State private var bundleID: String?
    @State private var lines: [String] = []
    @State private var filter = ""
    @State private var problem: String?

    /// What the drawer keeps; older lines scroll away.
    private static let kept = 2000

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(apps, id: \.bundleID) { app in
                        Button(app.name) { bundleID = app.bundleID }
                    }
                    if apps.isEmpty { Text(localized("No apps are installed on this simulator.")) }
                } label: {
                    Text(apps.first { $0.bundleID == bundleID }?.name ?? localized("Choose an App"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                TextField(localized("Filter"), text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TreeHeaderButton(symbol: "trash", help: localized("Clear")) { lines = [] }
                TreeHeaderButton(huge: .close, help: localized("Close")) { host.logsShown = false }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Self.isError(line) ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(6)
                }
                .onChange(of: lines.count) {
                    if let last = shown.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
                .overlay {
                    if let problem {
                        Text(problem).font(.system(size: 11)).foregroundStyle(.secondary).padding()
                    } else if bundleID != nil, lines.isEmpty {
                        Text(localized("Nothing logged yet.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        .task(id: udid) { await loadApps() }
        .task(id: bundleID) { await follow() }
        // An app launched while the drawer is open is the one being worked on.
        .onChange(of: host.lastLaunched[udid]) { _, launched in
            guard let launched else { return }
            Task {
                await loadApps()
                bundleID = launched
            }
        }
    }

    private var shown: [String] {
        filter.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private static func isError(_ line: String) -> Bool {
        line.contains(" error ") || line.contains(" fault ")
    }

    private func loadApps() async {
        do {
            apps = try await host.userApps(on: udid)
            problem = apps.isEmpty ? localized("No apps are installed on this simulator.") : nil
        } catch {
            Log.simulator.error("listing apps failed: \(error.localizedDescription, privacy: .public)")
            problem = error.localizedDescription
        }
        if bundleID == nil {
            bundleID = host.lastLaunched[udid].flatMap { launched in apps.first { $0.bundleID == launched }?.bundleID }
                ?? apps.first?.bundleID
        }
    }

    /// The last minute first, then what came after each read, until the
    /// drawer closes or another app is picked.
    private func follow() async {
        guard let bundleID else { return }
        lines = []
        var cursor: String?
        while !Task.isCancelled {
            do {
                let read = try await host.logs(
                    udid: udid, bundleID: bundleID, since: cursor, minutes: 1, tail: 500, level: "info", filter: nil)
                if !read.lines.isEmpty {
                    lines = Array((lines + read.lines).suffix(Self.kept))
                }
                cursor = read.cursor ?? cursor
                problem = nil
            } catch {
                Log.simulator.error("reading \(bundleID, privacy: .public)'s log failed: \(error.localizedDescription, privacy: .public)")
                problem = error.localizedDescription
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
}
