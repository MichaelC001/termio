import AppKit
import CryptoKit
import Foundation
import GhosttyTerminal
import TermioShared

/// The transfer plane: bytes crossing the viewer↔device boundary.
///
/// The clipboard belongs to the viewer and the agent belongs to the device
/// (device architecture §4.1), so pasting a screenshot at an agent running on
/// another machine is not an upload to a server — it is a crossing, and this is
/// where it happens. Locally the crossing does not exist, because the agent
/// reads the Mac's pasteboard itself.
///
/// Transfers ride their **own control channel**, never a session's attach
/// channel: the anti-100× invariant says byte delivery must not queue behind
/// anything, and the daemon enforces the same split by refusing `U` frames on
/// an attachment. Chunks are credit-of-one — the next one is held until the
/// previous is acked — which bounds what a keystroke could ever wait behind to
/// a single 64 KiB frame even when the two channels share one SSH connection.
extension Termiod {
    /// One `U` frame's worth of payload, sized so the whole frame (header, id,
    /// offset, bytes) stays inside the daemon's 64 KiB cap for this kind.
    static let uploadChunkSize = 64 * 1024 - 512

    /// Lands `data` in `session`'s scratch directory on the device `route`
    /// leads to and returns the absolute path **on that machine** — the string
    /// an agent over there can open.
    ///
    /// Blocking; call it off the main thread. A transfer that loses its pipe
    /// part-way is retried once by re-opening, which resumes at the bytes the
    /// daemon already holds rather than re-sending them.
    static func uploadToSessionScratch(
        route: TermiodRoute,
        session: String,
        name: String,
        data: Data
    ) throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        do {
            return try performUpload(
                route: route, session: session, dest: "temp:\(name)",
                data: data, sha256: digest).path
        } catch TermiodClientError.connectionClosed {
            Log.termiod.info("""
            transfer to \(session, privacy: .public) lost its pipe; resuming
            """)
            return try performUpload(
                route: route, session: session, dest: "temp:\(name)",
                data: data, sha256: digest).path
        }
    }

    /// Writes `data` back to `path` on the device, replacing what is there.
    ///
    /// The same transfer as a paste — open, chunk, commit — pointed at a path
    /// inside a checkout instead of a session's scratch directory. That is what
    /// makes this *save*: the host lands the bytes in a dotfile beside the
    /// destination and `rename`s them over it, so a reader on that machine sees
    /// either the old file or the new one and never a half-written one.
    ///
    /// `ifUnmodifiedSince` is the version the caller read. The host refuses the
    /// commit when the file has changed since, which arrives here as
    /// `DeviceFileError.conflict` — the person is asked, rather than the other
    /// writer's work being thrown away.
    ///
    /// Blocking; call it off the main thread.
    /// - Returns: the version the write produced, which the next save of the
    ///   same file must claim.
    static func writeFile(
        route: TermiodRoute,
        root: String,
        path: String,
        data: Data,
        ifUnmodifiedSince: UInt64?
    ) throws -> UInt64 {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // Deliberately not retried on a lost pipe the way a paste is: a resumed
        // open would re-check the version against a file the retry has already
        // spent time not holding, and a save is small enough that starting over
        // costs nothing. The caller sees the failure and can press save again.
        return try performUpload(
            route: route, session: nil, root: root, dest: path,
            data: data, sha256: digest, ifUnmodifiedSince: ifUnmodifiedSince).mtime
    }

    private static func performUpload(
        route: TermiodRoute,
        session: String?,
        root: String? = nil,
        dest: String,
        data: Data,
        sha256: String,
        ifUnmodifiedSince: UInt64? = nil
    ) throws -> (path: String, mtime: UInt64) {
        let transport = try Transport.open(route)
        defer { transport.close() }
        try performHello(transport, role: "control", caps: ["upload"])

        let opened = try request(transport, UploadOpenOperation(
            dest: dest,
            session: session,
            root: root,
            size: UInt64(data.count),
            sha256: sha256,
            seq: 1
        )) { control in
            if case .uploadOpened(let payload) = control { return payload }
            return nil
        }

        var offset = Int(clamping: opened.offset)
        // A daemon that reports more bytes than we hold is describing a
        // different transfer under the same name; start over rather than
        // commit something we cannot account for.
        if offset > data.count { offset = 0 }
        while offset < data.count {
            let end = min(offset + uploadChunkSize, data.count)
            try writeFrame(transport.writeDescriptor, kind: .upload,
                           payload: uploadChunkPayload(
                               uploadID: opened.uploadId,
                               offset: UInt64(offset),
                               data: data.subdata(in: offset ..< end)))
            let ack = try readReply(transport) { control in
                if case .uploadAck(let payload) = control { return payload }
                return nil
            }
            let acked = Int(clamping: ack.offset)
            // The ack is the daemon's own running total, so it — not our
            // arithmetic — decides where the next chunk starts. Refusing to go
            // backwards keeps a confused daemon from looping us forever.
            guard acked > offset else {
                throw TermiodClientError.requestFailed(
                    "transfer stalled at \(offset) of \(data.count) bytes")
            }
            offset = acked
        }

        let committed = try request(
            transport,
            UploadCommitOperation(
                uploadId: opened.uploadId,
                ifUnmodifiedSince: ifUnmodifiedSince,
                seq: 2)
        ) { control in
            if case .uploadCommitted(let payload) = control { return payload }
            return nil
        }
        return (committed.path, committed.mtime)
    }

    /// Send one request and read frames until `match` claims one. A typed
    /// `error` reply fails the call with the daemon's own message, so a refused
    /// transfer says why rather than timing out.
    private static func request<Operation: Encodable, Reply>(
        _ transport: Transport,
        _ operation: Operation,
        _ match: (IncomingControl) -> Reply?
    ) throws -> Reply {
        try writeFrame(transport.writeDescriptor, kind: .control,
                       payload: encodeControl(operation))
        return try readReply(transport, match)
    }

    private static func readReply<Reply>(
        _ transport: Transport,
        _ match: (IncomingControl) -> Reply?
    ) throws -> Reply {
        while true {
            let frame = try readFrame(transport.readDescriptor)
            guard frame.kind == .control else { continue }
            let control = try decodeControl(frame.payload)
            if let reply = match(control) { return reply }
            if case .error(let failure) = control {
                // A refused version is its own answer, not a failed request: the
                // client asks the person whether to overwrite. The host says so
                // in the code (`ErrorCode::Conflict`), which is why this reads
                // the code rather than pattern-matching English.
                if failure.code == "conflict" {
                    throw DeviceFileError.conflict(failure.message)
                }
                throw TermiodClientError.requestFailed(failure.message)
            }
        }
    }
}

/// ⌘V of an image at a session running on another device.
///
/// Locally this needs no code at all: the agent reads the Mac's pasteboard
/// itself when the terminal delivers Ctrl+V, which is what libghostty's wrapper
/// already does. That mechanism cannot survive the machine boundary — a
/// Ctrl+V delivered to a VPS makes the agent read *the VPS's* clipboard — so a
/// remote session gets the crossing instead: the bytes move to the device, and
/// the path they landed at is pasted as text. The agent then opens a local
/// file, which is a thing it can do anywhere.
///
/// Intercepted with a local key monitor for the same reason `TerminalContextMenu`
/// uses one: the wrapper instantiates its own view class, so there is no
/// subclass to override, and a monitor runs before the surface sees the key.
/// Everything that is not exactly this case — a local session, a text
/// clipboard, a non-terminal responder — falls straight through untouched.
@MainActor
final class TermiodImagePaste: NSObject {
    private weak var store: TermioStore?
    // Held for the app's lifetime; never removed.
    private var monitor: Any?
    /// Sessions with a transfer in flight. A second ⌘V is swallowed rather than
    /// starting a duplicate — and swallowed rather than passed on, because
    /// letting it reach ghostty would deliver the wrong paste entirely.
    private var inFlight: Set<Session.ID> = []

    init(store: TermioStore) {
        self.store = store
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local event monitors are always called on the main thread; the
            // annotation just can't say so (and `NSEvent` isn't `Sendable`, so
            // only the Bool verdict crosses the `assumeIsolated` boundary).
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self.intercept(event) }
            return consumed ? nil : event
        }
    }

    /// Bare ⌘V only. Any other modifier is somebody else's binding, and the
    /// same key with a text clipboard is ghostty's `paste_from_clipboard`.
    private func intercept(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "v",
              event.modifierFlags.contains(.command),
              event.modifierFlags.isDisjoint(with: [.shift, .option, .control])
        else { return false }
        return pasteImage(into: focusedTerminalSessionID())
    }

    /// The right-click menu's Paste, which reaches the surface by selector
    /// rather than by key event. Returns whether the transfer took it over; the
    /// menu falls back to the surface's own `paste:` when it did not.
    func pasteImageFromMenu(sessionID: Session.ID?) -> Bool {
        pasteImage(into: sessionID)
    }

    /// Returns whether this paste was taken over. `false` means "not our case"
    /// and the ordinary paste must still happen.
    private func pasteImage(into sessionID: Session.ID?) -> Bool {
        guard let store, let sessionID,
              let session = store.session(sessionID),
              // The device boundary is the whole condition: a session on this
              // Mac keeps the local mechanism, unchanged.
              let host = session.termiodRemoteHost,
              let image = ClipboardImage.current()
        else { return false }

        guard !inFlight.contains(sessionID) else { return true }
        inFlight.insert(sessionID)

        let route = TermiodRoute(sshAlias: host)
        let name = image.scratchFileName
        // The name the *daemon* knows this session by, which is the app's own uuid
        // only for a session the app created. One adopted off the machine's roster
        // keeps the name it already had over there, so addressing the upload by
        // `session.id` asked ukvps about a session that has never existed on it.
        let target = store.daemonSessionName(for: session)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try Termiod.uploadToSessionScratch(
                    route: route, session: target, name: name, data: image.data)
            }
            DispatchQueue.main.async {
                self?.finish(result, for: sessionID, host: host, bytes: image.data.count)
            }
        }
        return true
    }

    private func finish(_ result: Result<String, Error>, for sessionID: Session.ID,
                        host: String, bytes: Int) {
        inFlight.remove(sessionID)
        switch result {
        case .success(let path):
            Log.termiod.info("""
            pasted \(bytes, privacy: .public) bytes to \
            \(host, privacy: .public):\(path, privacy: .public)
            """)
            // The path is what the agent reads, so it goes in as a paste — the
            // raw PTY seam, wrapped in bracketed paste, exactly as
            // `addSnippetToSelectedSessionPrompt` explains: hand-written
            // `\e[200~` re-encoded through ghostty's key encoder would arrive
            // as a literal `[200~`.
            guard let state = store?.surfaces[sessionID],
                  case let .inMemory(backend) = state.configuration.backend
            else { return }
            backend.sendInput(Data(("\u{1B}[200~" + path + " \u{1B}[201~").utf8))
        case .failure(let error):
            Log.termiod.error("""
            pasting an image to \(host, privacy: .public) failed: \
            \(error.localizedDescription, privacy: .public)
            """)
            let alert = NSAlert()
            alert.messageText = "Couldn't paste the image to \(host)"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// The session whose surface has the keyboard, resolved through the store's
    /// surface cache — the view and its cached state share a controller.
    private func focusedTerminalSessionID() -> Session.ID? {
        guard let window = NSApp.keyWindow,
              window.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName,
              let surface = window.firstResponder as? TerminalView
        else { return nil }
        return store?.surfaces.first { $0.value.controller === surface.controller }?.key
    }
}

/// An image on the pasteboard with no text form — a fresh screenshot, a copied
/// image — reduced to bytes plus the name they should land under.
///
/// The image-only rule is the wrapper's, kept verbatim so the two layers agree
/// on what a paste is: a clipboard carrying text is a text paste, whatever else
/// rides along with it.
struct ClipboardImage {
    let data: Data
    let fileExtension: String

    /// Unique per paste so two screenshots in one session never collide, and
    /// timestamped so the name says when it arrived. The daemon reaps the whole
    /// scratch directory with the session, so nothing accumulates.
    var scratchFileName: String {
        "paste-\(UInt64(Date().timeIntervalSince1970 * 1000)).\(fileExtension)"
    }

    static func current(_ pasteboard: NSPasteboard = .general) -> ClipboardImage? {
        guard pasteboard.string(forType: .string) == nil else { return nil }
        if let png = pasteboard.data(forType: .png) {
            return ClipboardImage(data: png, fileExtension: "png")
        }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            return ClipboardImage(data: jpeg, fileExtension: "jpg")
        }
        // Anything else an NSImage can read (TIFF, PDF page, a dragged icon)
        // is re-encoded, because the far side wants a file an agent will open,
        // not whichever pasteboard flavor happened to be first.
        guard let tiff = pasteboard.data(forType: .tiff),
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:])
        else { return nil }
        return ClipboardImage(data: png, fileExtension: "png")
    }
}
