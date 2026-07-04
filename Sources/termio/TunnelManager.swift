import AppKit
import Foundation

/// Fronts the companion server with a public tunnel so the iPhone can connect
/// away from the LAN. Two providers, same shape: spawn the CLI pointed at the
/// companion port, scrape the public URL it prints, publish it for the QR.
/// The CLI is found on the usual install paths or downloaded once from its
/// GitHub release into Application Support — the app itself stays small and
/// tunnel updates stay decoupled from app releases.
///
/// The tunnel is a dumb pipe: every connection that arrives through it still
/// has to present the pairing token before the server serves it anything.
@MainActor
final class TunnelManager: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case off
        case tunelo
        case cloudflared

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: "Off"
            case .tunelo: "Tunelo"
            case .cloudflared: "Cloudflare"
            }
        }

        var binaryName: String {
            switch self {
            case .off: ""
            case .tunelo: "tunelo"
            case .cloudflared: "cloudflared"
            }
        }
    }

    enum Status: Equatable {
        case off
        /// First use on a machine without the CLI: fetching it from GitHub.
        case installing
        /// Process spawned, waiting for it to print its public URL.
        case starting
        /// Tunnel up; the URL is the public https endpoint.
        case running(URL)
        case failed(String)
    }

    static let shared = TunnelManager()
    private static let providerKey = "companion.tunnelProvider"

    @Published private(set) var provider: Provider
    @Published private(set) var status: Status = .off

    private var process: Process?
    private var outputBuffer = Data()
    private var terminationObserver: NSObjectProtocol?

    private init() {
        provider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(Provider.init(rawValue:)) ?? .off
        // Process children outlive their parent; a tunnel left behind would
        // keep serving a dead socket's URL.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TunnelManager.shared.stopProcess() }
        }
    }

    /// App-launch hook: resume the tunnel the user had on last quit.
    func startIfEnabled() {
        if provider != .off { restart() }
    }

    func setProvider(_ newProvider: Provider) {
        guard newProvider != provider else { return }
        provider = newProvider
        UserDefaults.standard.set(newProvider.rawValue, forKey: Self.providerKey)
        restart()
    }

    private func restart() {
        stopProcess()
        guard provider != .off else {
            status = .off
            return
        }
        let target = provider
        status = .starting
        Task {
            var binary = Self.findBinary(named: target.binaryName)
            if binary == nil {
                status = .installing
                do {
                    binary = try await Self.install(target)
                } catch {
                    if self.provider == target {
                        status = .failed("couldn't install \(target.binaryName): \(error.localizedDescription)")
                    }
                    return
                }
            }
            // The user may have flipped the picker while the download ran.
            guard self.provider == target, let binary else { return }
            spawn(binary, for: target)
        }
    }

    private func spawn(_ binary: URL, for provider: Provider) {
        let process = Process()
        process.executableURL = binary
        process.arguments = switch provider {
        case .tunelo:
            ["port", String(CompanionServer.defaultPort)]
        case .cloudflared:
            ["tunnel", "--url", "http://127.0.0.1:\(CompanionServer.defaultPort)", "--no-autoupdate"]
        case .off:
            []
        }
        // Both CLIs print their public URL to the console (tunelo on stdout,
        // cloudflared inside a stderr banner); one merged pipe catches either.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        outputBuffer.removeAll()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.scanOutput(data, from: process) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.process === process else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.status = .failed("\(provider.binaryName) exited — pick the tunnel again to retry")
            }
        }
        do {
            try process.run()
        } catch {
            status = .failed("couldn't launch \(provider.binaryName): \(error.localizedDescription)")
            return
        }
        self.process = process
        status = .starting
        // Relay unreachable, DNS down, rate-limited — the CLI can sit silent
        // for a long time; give the user an answer within half a minute.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            Task { @MainActor in
                guard let self, self.process === process, self.status == .starting else { return }
                self.stopProcess()
                self.status = .failed("\(provider.binaryName) didn't come up — check the network and retry")
            }
        }
    }

    private func scanOutput(_ data: Data, from process: Process) {
        guard self.process === process, status == .starting else { return }
        outputBuffer.append(data)
        // ANSI color codes may sit right against the URL; the character class
        // stops at the escape byte either way.
        guard let text = String(data: outputBuffer, encoding: .utf8),
              let range = text.range(
                  of: #"https://[a-zA-Z0-9-]+\.(trycloudflare\.com|tunelo\.net)"#,
                  options: .regularExpression
              ),
              let url = URL(string: String(text[range]))
        else { return }
        status = .running(url)
    }

    private func stopProcess() {
        guard let process else { return }
        process.terminationHandler = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminate()
        self.process = nil
        status = .off
    }

    // MARK: - Binary discovery & install

    /// Where a user-managed install would be, then our own downloaded copy.
    /// A brew/cargo binary wins because the user keeps it updated.
    nonisolated private static func findBinary(named name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.cargo/bin/\(name)",
            installDirectory.appendingPathComponent(name).path,
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    nonisolated private static var installDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("termio/bin", isDirectory: true)
    }

    /// One-time fetch from the provider's GitHub release. tunelo ships a bare
    /// binary; cloudflared ships a single-file tgz. Both are small enough to
    /// pull on first use, and neither ends up inside the app bundle (which
    /// would bloat every Sparkle update and freeze their CVE fixes to ours).
    nonisolated private static func install(_ provider: Provider) async throws -> URL {
        #if arch(arm64)
        let (tuneloArch, cfArch) = ("arm64", "arm64")
        #else
        let (tuneloArch, cfArch) = ("amd64", "amd64")
        #endif
        let source = switch provider {
        case .tunelo:
            "https://github.com/jiweiyuan/tunelo/releases/latest/download/tunelo-macos-\(tuneloArch)"
        case .cloudflared:
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-\(cfArch).tgz"
        case .off:
            ""
        }
        let (temp, response) = try await URLSession.shared.download(from: URL(string: source)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "termio.tunnel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))",
            ])
        }
        let directory = installDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(provider.binaryName)
        try? FileManager.default.removeItem(at: destination)
        if source.hasSuffix(".tgz") {
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", temp.path, "-C", directory.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else {
                throw NSError(domain: "termio.tunnel", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "couldn't unpack the archive",
                ])
            }
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }
}
