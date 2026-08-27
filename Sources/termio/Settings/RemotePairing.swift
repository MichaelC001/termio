import AppKit
import SwiftUI
import TermioShared

/// Pairing a phone with a box that is not this Mac.
///
/// The invite is minted **on the box**, by the `termiod` already deployed there:
/// `termiod pair --json` prints the URL it is reachable at, the token it will
/// demand, and its `host_id`. This Mac only carries the answer over the SSH it
/// already has and draws the QR — it never invents a token, and it never decides
/// where a remote box is reachable, because only the box knows either.
///
/// That is the ladder `termiod`'s own `run_pair` describes: a Mac with SSH runs
/// `--json` and pushes the invite; an operator sitting on the box runs `--qr`
/// and scans the screen in front of them. This is the first rung, wired to a UI.
enum RemotePairing {
    /// What `termiod pair --json` prints. `host_id` is the box's identity, not a
    /// name — the phone names the box itself (device architecture §4).
    struct Invite: Equatable {
        let url: String
        let token: String
        let hostID: String
        let proto: Int

        /// The `termio://device` link the iPhone parses, from a scanned QR or a
        /// paste. Built here rather than asked of the box so it stays in step
        /// with `Models.parseDeviceInvite` on the phone.
        var link: String {
            var components = URLComponents()
            components.scheme = "termio"
            components.host = "device"
            components.queryItems = [
                URLQueryItem(name: "url", value: url),
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "host_id", value: hostID),
                URLQueryItem(name: "proto", value: String(proto)),
            ]
            return components.string ?? ""
        }
    }

    /// The box refused, and said why. `termiod`'s own message is carried through
    /// verbatim: it already names the two ways out ("pass `--url …`", "start the
    /// daemon with `--wss-origin …`"), and a sentence written here would be a
    /// worse copy of one written next to the code that failed.
    struct Failure: Error, Equatable {
        let message: String
    }

    /// Asks `<alias>` for an invite. `rotate` issues a new token first, which
    /// signs out every phone already paired with that box.
    ///
    /// `url` answers the one question the box cannot: what public name fronts
    /// it. The listener binds loopback on purpose — a daemon that bound `0.0.0.0`
    /// would be a shell server on the open internet — so nothing on the box can
    /// derive the address a phone would dial, and `termiod pair` refuses rather
    /// than mint a QR pointing nowhere.
    ///
    /// Runs on a detached task: this forks `ssh`, and a box that is asleep or
    /// behind a slow link would otherwise block whatever called it.
    static func invite(
        from alias: String, url: String? = nil, rotate: Bool = false
    ) async throws -> Invite {
        var command = "\(Termiod.remoteBinary()) pair --json\(rotate ? " --rotate" : "")"
        if let url, !url.isEmpty {
            command += " --url \(shellQuoted(url))"
        }
        let result = try await run(alias: alias, command: command)
        guard result.status == 0 else {
            throw Failure(message: message(from: result))
        }
        guard let invite = decode(result.stdout) else {
            throw Failure(message: localized("\(alias) answered, but not with a pairing invite. Its termiod is probably older than this app — deploy it again."))
        }
        return invite
    }

    // MARK: - Running it

    /// Single-quoted for the remote's shell, which is what `ssh host <command>`
    /// hands the string to. A URL is user-typed and reaches a login shell on
    /// another machine; anything less than quoting is a command injection.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(alias: String, command: String) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            // `.userInitiated`: someone is looking at a spinner.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                // The app's own ssh options — multiplexing, BatchMode, the
                // connect timeout — so this pays the same 26–33 ms a warm master
                // costs rather than a fresh handshake, and never stalls on a
                // password prompt nobody can answer.
                process.arguments = Termiod.sshArguments(host: alias) + [alias, command]
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure(
                        message: localized("Could not run ssh: \(error.localizedDescription)")))
                    return
                }
                // Both pipes drain before the wait: a child that fills either one
                // blocks forever against a parent waiting on exit.
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: String(data: stdout, encoding: .utf8) ?? "",
                    stderr: String(data: stderr, encoding: .utf8) ?? ""))
            }
        }
    }

    /// What to show when the command failed. `termiod`'s message when it has one;
    /// otherwise ssh's, which is the case where the box was never reached at all.
    private static func message(from result: Result) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stderr.isEmpty else { return stderr }
        return localized("Exited with status \(Int(result.status)).")
    }

    private static func decode(_ json: String) -> Invite? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String,
              let token = object["token"] as? String,
              let hostID = object["host_id"] as? String
        else { return nil }
        // `proto` is informational here — the phone enforces it on the handshake,
        // which is the only place that can refuse a mismatch honestly.
        let proto = object["proto"] as? Int ?? 0
        return Invite(url: url, token: token, hostID: hostID, proto: proto)
    }
}

/// The Mobile pane's remote arm: one card for one box, holding whatever that box
/// last said when asked for an invite.
///
/// It asks on appear rather than behind a button. Everything the card can show —
/// the QR, the address, the reason there is neither — is the answer to the same
/// single question, so making the user press something first would only add a
/// state in which the card says nothing at all.
struct RemotePairingSection: View {
    let machine: KnownDevice

    private enum Phase: Equatable {
        case asking
        case ready(RemotePairing.Invite)
        case failed(String)
    }

    @State private var phase = Phase.asking
    @State private var copied = false
    @State private var confirmRotate = false
    /// The public address the user typed, kept across a retry so a rotate or a
    /// failed attempt does not make them type it again.
    @State private var address = ""

    var body: some View {
        Section {
            switch phase {
            case .asking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized("Asking \(machine.name)…"))
                        .foregroundStyle(.secondary)
                }
            case .ready(let invite):
                // QR and its link are one unit — "scan this, or send yourself the
                // same thing" — so no divider comes between them.
                VStack(spacing: 12) {
                    if let qr = pairingQRImage(for: invite.link) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 180, height: 180)
                            .padding(10)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    addressRow(invite)
                }
                rotateRow
            case .failed(let message):
                unreachable(message)
            }
        } header: {
            SectionHeaderLabel(title: machine.name)
        } footer: {
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await ask() }
    }

    // MARK: - Pieces

    private func addressRow(_ invite: RemotePairing.Invite) -> some View {
        HStack(spacing: 8) {
            Text(invite.url)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            // The *link*, not the address: a bare URL is not enough to pair
            // with, and copying one that looks like it should be is how someone
            // spends ten minutes wondering why the phone refuses it.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(invite.link, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(
                    copied ? localized("Copied") : localized("Copy Invite"),
                    systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .fixedSize()
        }
    }

    private var rotateRow: some View {
        LabeledContent {
            Button(localized("Rotate Token…")) { confirmRotate = true }
                .confirmationDialog(
                    localized("Rotate the pairing token?"),
                    isPresented: $confirmRotate,
                    titleVisibility: .visible
                ) {
                    Button(localized("Rotate Token"), role: .destructive) {
                        Task { await ask(rotate: true) }
                    }
                    Button(localized("Cancel"), role: .cancel) {}
                } message: {
                    Text(localized("Every iPhone paired with \(machine.name) is signed out and must re-scan the new QR to reconnect."))
                }
        } label: {
            SettingsLabel(
                title: localized("Pairing Token"),
                subtext: localized("Issues a new token and revokes every paired iPhone."),
                titleFont: .headline)
        }
    }

    /// The box could not mint an invite. Its own words, verbatim and monospaced —
    /// they are terminal output, and the fixes they name are commands.
    ///
    /// The address field is the first of those fixes, made typable: `termiod`
    /// says "pass `--url https://<host>/termio/`", and this is that flag with a
    /// text box in front of it. Only the box's *name* is missing; everything
    /// else about pairing already works, which is why one field closes it.
    private func unreachable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(localized("\(machine.name) has nothing to pair against"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(
                    localized("Public address"), text: $address,
                    prompt: Text(verbatim: "https://example.com/termio/"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { pair(at: address) }
                Button(localized("Pair")) { pair(at: address) }
                    .buttonStyle(.bordered)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(localized("Try Again")) { Task { await ask() } }
                    .buttonStyle(.bordered)
            }
            // Said once, here, where someone is about to type an address: this
            // invite carries it, the next one will not. Persisting it is the
            // daemon's `--wss-origin`, which is a decision about how the box
            // runs — not something an app should write behind the user's back.
            Text(localized("Used for this invite only. To make it stick, start the daemon there with --wss-origin."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The typed address, or `nil` when there is none — so a rotate carries the
    /// address that worked rather than dropping back to the box's own idea of
    /// itself, which is the one that already failed.
    private var nonEmptyAddress: String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func pair(at url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { await ask(url: trimmed) }
    }

    private var footnote: String {
        switch phase {
        case .ready:
            return localized("On iPhone, tap the Mac pill ▸ Scan QR Code. The token is minted on \(machine.name) and demanded on every connection.")
        default:
            return localized("A box can only be paired with once its termiod is running and reachable from outside — a tunnel, or a proxy in front of it.")
        }
    }

    /// `url` empty means "ask the box what it knows" — the first attempt, and
    /// the right one whenever the daemon there was started with `--wss-origin`.
    private func ask(url: String? = nil, rotate: Bool = false) async {
        guard let alias = machine.alias else { return }
        phase = .asking
        do {
            phase = .ready(try await RemotePairing.invite(
                from: alias, url: url ?? nonEmptyAddress, rotate: rotate))
        } catch let failure as RemotePairing.Failure {
            phase = .failed(failure.message)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
