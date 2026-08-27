import Foundation
import TermioShared

/// Running one command on a device over the SSH the app already has.
///
/// A sibling of `RemotePairing`'s own runner, which should fold into this once
/// the two files stop being edited in parallel.
enum RemoteShell {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { status == 0 }
        /// stderr when there is any, else a bare exit code — the shape an alert
        /// wants, since a remote failure usually explains itself on stderr.
        var failure: String {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? localized("Exited with status \(Int(status)).") : text
        }
    }

    /// Single-quoted for the far shell. Every value that crosses `ssh` is data,
    /// not code: a URL, a path or a user-typed command reaching a login shell on
    /// another machine is a command injection unless it is quoted.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func run(alias: String, command: String) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = Termiod.sshArguments(host: alias) + [alias, command]
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    continuation.resume(returning: Output(
                        status: -1, stdout: "",
                        stderr: localized("Could not run ssh: \(error.localizedDescription)")))
                    return
                }
                // Both pipes drain before the wait: a child that fills either one
                // blocks forever against a parent waiting on exit.
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: String(data: stdout, encoding: .utf8) ?? "",
                    stderr: String(data: stderr, encoding: .utf8) ?? ""))
            }
        }
    }
}

/// How a device is published to the internet, as a choice the user makes — the
/// same list the Mac's own Mobile Access offers (`TunnelManager.Provider`), run
/// on the far box instead of locally.
///
/// It is deliberately the same vocabulary. A user who has already picked a
/// tunnel for their Mac knows what these words mean, and the reason to offer
/// them at all is the same: **we cannot be everyone's relay.** Termio's own
/// relay has finite capacity, so every alternative here is a first-class path,
/// not a grudging fallback.
enum RemoteTunnelProvider: String, CaseIterable, Identifiable, Sendable {
    /// Nothing published. The box is reachable over SSH from this Mac and by
    /// nothing else — which is the correct default, not a broken state.
    case off
    case tunelo
    case cloudflare
    case ngrok
    /// A relay the user runs, or a tool we do not bundle: their command, their
    /// regex. Same contract as the Mac's Custom entry.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return localized("Off — SSH only")
        case .tunelo: return "Tunelo"
        case .cloudflare: return "Cloudflare"
        case .ngrok: return "ngrok"
        case .custom: return localized("Custom")
        }
    }

    /// Whether the published address survives the tunnel restarting.
    ///
    /// On the Mac this was a papercut: a new URL meant pairing again. Here it is
    /// **correctness**. The phone stores the address *and* the origin it must
    /// send (`Models.adopt`), and the daemon pins that same origin — so a name
    /// that rotates strands every paired phone and invalidates the pin, and the
    /// symptom is a QR that scans and then never connects.
    ///
    /// So an unstable provider is offered, but it has to say so.
    var keepsItsAddress: Bool {
        switch self {
        // `--identity` derives the subdomain from a persistent Ed25519 key and
        // only that machine can reclaim it (tunelo 0.3.0).
        case .tunelo: return true
        // A quick tunnel mints a fresh `*.trycloudflare.com` per process. A
        // *named* tunnel is stable, needs a Cloudflare account and a zone, and
        // is what Custom is for until we model account-backed tunnels.
        case .cloudflare: return false
        // Free ngrok rotates; a reserved domain does not. Same story as above.
        case .ngrok: return false
        // Unknowable — it is the user's command. Assume the good case rather
        // than warn on every custom relay, most of which are stable.
        case .custom, .off: return true
        }
    }

    /// What the user has to have done before this can work.
    var prerequisite: String? {
        switch self {
        case .off: return nil
        case .tunelo: return nil
        case .cloudflare:
            return localized("Restarting the tunnel changes the address, and every paired iPhone has to scan again.")
        case .ngrok:
            return localized("Needs `ngrok config add-authtoken` on that machine first. The free address changes on every restart.")
        case .custom:
            return localized("Runs on that machine with your login’s privileges — no shell, arguments split on spaces. Use {port} for the daemon’s port.")
        }
    }

    /// argv after the binary. `{port}` stands in for the daemon's loopback port,
    /// exactly as the Mac's Custom field does.
    ///
    /// `custom` is passed rather than read from a global: the Mac's own relay
    /// command and a VPS's are different commands on different machines, and
    /// sharing one setting between them would configure the wrong box.
    func arguments(port: Int, custom: RemoteCustomTunnel) -> [String] {
        switch self {
        case .off: return []
        case .tunelo:
            // The identity file is what makes the subdomain stable; it lives in
            // the user's own config dir, 0600, minted on first use.
            return ["port", String(port), "--identity", RemoteTunnelPaths.tuneloIdentity]
        case .cloudflare:
            return ["tunnel", "--url", "http://127.0.0.1:\(port)", "--no-autoupdate"]
        case .ngrok:
            // `--log stdout` turns off the interactive TUI and prints the public
            // URL as a logfmt field this can scrape.
            return ["http", String(port), "--log", "stdout"]
        case .custom:
            return custom.command
                .split(separator: " ").map(String.init).dropFirst()
                .map { $0.replacingOccurrences(of: "{port}", with: String(port)) }
        }
    }

    func binaryName(custom: RemoteCustomTunnel) -> String {
        switch self {
        case .off: return ""
        case .tunelo: return "tunelo"
        case .cloudflare: return "cloudflared"
        case .ngrok: return "ngrok"
        case .custom:
            return custom.command.split(separator: " ").first.map(String.init) ?? ""
        }
    }

    /// Regex matching the public https URL the tool prints when it comes up.
    func urlPattern(custom: RemoteCustomTunnel) -> String {
        switch self {
        case .off: return ""
        case .tunelo: return #"https://[a-zA-Z0-9-]+\.tunelo\.net"#
        case .cloudflare: return #"https://[a-zA-Z0-9-]+\.trycloudflare\.com"#
        case .ngrok: return #"https://[a-zA-Z0-9-]+\.ngrok(?:-free)?\.(?:app|io)"#
        case .custom: return custom.urlPattern
        }
    }

    /// Where to fetch the Linux build, by the architecture the box reports.
    ///
    /// `nil` means bring-your-own-on-PATH. ngrok is deliberately in that group:
    /// it needs `ngrok config add-authtoken` run once against the user's own
    /// account, so fetching the bare binary would not save the real setup step.
    func downloadURL(arch: RemoteArchitecture) -> String? {
        switch self {
        case .off, .ngrok, .custom: return nil
        case .tunelo:
            return "https://github.com/jiweiyuan/tunelo/releases/latest/download/tunelo-linux-\(arch.rawValue)"
        case .cloudflare:
            return "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-\(arch.rawValue)"
        }
    }
}

/// The Linux architectures we ship tunnel binaries for, as `uname -m` reports
/// them. The same two `termiod remote deploy` already cross-compiles for.
enum RemoteArchitecture: String, Sendable {
    case arm64
    case amd64

    init?(uname: String) {
        switch uname.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "aarch64", "arm64": self = .arm64
        case "x86_64", "amd64": self = .amd64
        default: return nil
        }
    }
}

/// Paths on the far machine. All under the user's own home: publishing a box
/// must never need root, which is most of why this is a tunnel and not a
/// reverse proxy.
enum RemoteTunnelPaths {
    static let binaryDirectory = "$HOME/.local/bin"
    static let stateDirectory = "$HOME/.local/state/termio"
    /// Where `systemctl --user` looks. A *user* unit directory, never
    /// `/etc/systemd/system`: a system unit needs root, and needing root is the
    /// thing this whole feature exists to avoid.
    static let unitDirectory = "$HOME/.config/systemd/user"
    static let tuneloIdentity = "$HOME/.config/tunelo/termio.key"
    static var tunnelLog: String { "\(stateDirectory)/tunnel.log" }
    static var daemonLog: String { "\(stateDirectory)/termiod.log" }
}

/// A relay the user runs themselves, remembered per machine.
///
/// Same contract as the Mac's Custom entry — a command and a regex — because it
/// is the same job on a different box. Stored per `settingsKey`: the command
/// that publishes a VPS is not the command that publishes a laptop.
struct RemoteCustomTunnel: Equatable {
    var command: String = ""
    var urlPattern: String = ""

    /// Whether the pattern compiles. A pattern that never matches would leave
    /// the tunnel "starting" forever, so an unusable one keeps the Publish
    /// button off rather than failing eight seconds later.
    var isUsable: Bool {
        !command.isEmpty && !urlPattern.isEmpty
            && (try? NSRegularExpression(pattern: urlPattern)) != nil
    }

    static func load(device: String) -> RemoteCustomTunnel {
        let defaults = UserDefaults.standard
        return RemoteCustomTunnel(
            command: defaults.string(forKey: "remoteTunnel.\(device).command") ?? "",
            urlPattern: defaults.string(forKey: "remoteTunnel.\(device).urlPattern") ?? "")
    }

    func save(device: String) {
        let defaults = UserDefaults.standard
        defaults.set(command, forKey: "remoteTunnel.\(device).command")
        defaults.set(urlPattern, forKey: "remoteTunnel.\(device).urlPattern")
    }
}

extension RemoteTunnelProvider {
    /// The provider last chosen for a machine. Remembered so re-publishing after
    /// a reboot is one click, not a re-decision.
    static func remembered(device: String) -> RemoteTunnelProvider {
        UserDefaults.standard.string(forKey: "remoteTunnel.\(device).provider")
            .flatMap(RemoteTunnelProvider.init(rawValue:)) ?? .off
    }

    func remember(device: String) {
        UserDefaults.standard.set(rawValue, forKey: "remoteTunnel.\(device).provider")
    }
}

/// The two long-running processes publishing a box needs, expressed as
/// `systemd --user` units.
///
/// A `setsid nohup` outlives the SSH session that started it and nothing else.
/// That is the wrong lifetime for this: the point of publishing a VPS is that
/// the phone reaches it later, and "later" includes after the box reboots. So
/// the supervisor is systemd, at the *user* level — which needs no root, and
/// which `loginctl enable-linger` extends across logout and reboot.
///
/// Using a supervisor at all is also what removes `pkill` from this file. There
/// is no safe unanchored `pkill -f`: its pattern is matched against **every**
/// command line on the box, including the `bash -c` that ssh spawned to run the
/// pkill itself, so a pattern general enough to find the tunnel kills the shell
/// looking for it. `systemctl --user restart` addresses a unit, not a string.
struct RemoteSystemdUnit {
    let name: String
    let title: String
    let executable: String
    let arguments: [String]
    let log: String
    /// Whether to empty the log at every start.
    ///
    /// True for the tunnel, whose log is read as a *value* — the public address
    /// it prints — so a stale line from the previous provider must never be
    /// mistaken for this run's answer. False for the daemon, whose log is read
    /// as *evidence* and is worth keeping across a restart loop.
    let freshLog: Bool

    var text: String {
        let argv = ([executable] + arguments).map(Self.argument).joined(separator: " ")
        var lines = [
            "[Unit]",
            "Description=\(title)",
            "After=network-online.target",
            "Wants=network-online.target",
            // systemd gives up on a unit that restarts five times in ten
            // seconds and leaves it down for good. That default protects a
            // machine from a crash loop; here it would turn a relay outage the
            // tunnel would have ridden out into a box that never comes back,
            // and the user learns about it from a phone that stopped working.
            "StartLimitIntervalSec=0",
            "",
            "[Service]",
            "Type=simple",
            "ExecStartPre=/bin/mkdir -p \(Self.argument(RemoteTunnelPaths.stateDirectory))",
        ]
        if freshLog {
            // The raw path, not a converted one: `argument` does the conversion
            // itself, and feeding it output that already says `%h` escapes the
            // specifier into the literal `%%h` and the unit exits 2.
            lines.append("ExecStartPre=/bin/sh -c \(Self.argument(": > \(log)"))")
        }
        lines += [
            "ExecStart=\(argv)",
            "StandardOutput=append:\(Self.specifiers(log))",
            "StandardError=append:\(Self.specifiers(log))",
            // The tunnel and the daemon are both things the user asked to keep
            // running; a crash is a reason to come back, not to stay down.
            "Restart=always",
            "RestartSec=3",
            "",
            "[Install]",
            "WantedBy=default.target",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// A path as a unit file reads it. `$HOME` is a *shell* expansion, and a
    /// unit is not run through a shell — systemd spells the same thing `%h`.
    /// `%` therefore has to be escaped first, or a literal one in a user's own
    /// command would be read as a specifier.
    static func specifiers(_ raw: String) -> String {
        raw.replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "$HOME", with: "%h")
    }

    /// One `ExecStart` word. systemd splits on whitespace unless the word is
    /// double-quoted, and expands specifiers before it parses the quotes — so a
    /// quoted `%h/...` still resolves.
    static func argument(_ raw: String) -> String {
        let escaped = specifiers(raw)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// Publishing one device: put the tool on it, run it, and read back the address
/// it was given.
///
/// Everything happens under the user's own login — `~/.local/bin`,
/// `~/.local/state`, `systemctl --user` — so publishing a box never asks for
/// root. That is the whole reason this is a tunnel rather than a reverse proxy:
/// nginx needs root and a domain, and requiring either turns "connect my phone"
/// into sysadmin work.
enum RemoteTunnelService {
    struct Failure: Error, Equatable {
        let message: String
    }

    /// What publishing a box produced: the address, and whether it will still be
    /// there tomorrow.
    struct Publication: Equatable {
        let address: String
        /// False when `loginctl enable-linger` was refused. The tunnel and the
        /// daemon still run — but only until this login ends, so a reboot takes
        /// the box off the air and nothing on screen would otherwise say so.
        let survivesReboot: Bool
    }

    static let tunnelUnit = "termio-tunnel.service"
    /// The name the daemon already looks for. `termiod service` writes a launchd
    /// agent and refuses on Linux, but `termiod status` still probes
    /// `systemctl --user is-active termiod` to name its supervisor
    /// (`lifecycle.rs`) — so this is the existing convention, not a second one,
    /// and a box published from here reports `service: systemd --user`.
    static let daemonUnit = "termiod.service"

    /// `uname -m`, mapped to the builds we publish.
    static func architecture(of alias: String) async throws -> RemoteArchitecture {
        let probe = await RemoteShell.run(alias: alias, command: "uname -m")
        guard probe.succeeded else { throw Failure(message: probe.failure) }
        guard let arch = RemoteArchitecture(uname: probe.stdout) else {
            throw Failure(message: localized("\(alias) reports an architecture we have no build for: \(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        return arch
    }

    /// Ensures the tool is on the box, fetching it when we publish a build and
    /// it is missing. A tool already on `PATH` always wins: the user's own
    /// install is the one they configured, and ours would shadow it.
    ///
    /// The path comes back **absolute**, expanded by the far shell rather than
    /// assembled here: it goes into a unit file, where `$HOME` is four literal
    /// characters and the process would fail to exec.
    static func ensureBinary(
        alias: String, provider: RemoteTunnelProvider, arch: RemoteArchitecture,
        custom: RemoteCustomTunnel
    ) async throws -> String {
        let name = provider.binaryName(custom: custom)
        guard !name.isEmpty else { throw Failure(message: localized("No command to run.")) }

        let found = await RemoteShell.run(
            alias: alias,
            command: "command -v \(RemoteShell.quoted(name)) 2>/dev/null || ls \(RemoteTunnelPaths.binaryDirectory)/\(name) 2>/dev/null")
        let path = found.stdout.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, path.hasPrefix("/") { return path }

        guard let url = provider.downloadURL(arch: arch) else {
            throw Failure(message: localized("\(name) isn’t installed on \(alias), and Termio doesn’t ship a build of it. Install it there, then try again."))
        }
        // Downloaded beside the target and renamed over it — atomic, and safe to
        // repeat, the same shape `termiod remote deploy` uses.
        let install = """
            mkdir -p \(RemoteTunnelPaths.binaryDirectory) && \
            curl -fsSL -o \(RemoteTunnelPaths.binaryDirectory)/\(name).new \(RemoteShell.quoted(url)) && \
            chmod +x \(RemoteTunnelPaths.binaryDirectory)/\(name).new && \
            mv \(RemoteTunnelPaths.binaryDirectory)/\(name).new \(RemoteTunnelPaths.binaryDirectory)/\(name) && \
            echo \(RemoteTunnelPaths.binaryDirectory)/\(name)
            """
        let fetched = await RemoteShell.run(alias: alias, command: install)
        let installed = fetched.stdout.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard fetched.succeeded, let installed, installed.hasPrefix("/") else {
            throw Failure(message: localized("Couldn’t install \(name) on \(alias).\n\(fetched.failure)"))
        }
        return installed
    }

    /// Starts the tunnel under `systemd --user` and returns the public address
    /// it printed.
    static func publish(
        alias: String, provider: RemoteTunnelProvider, port: Int,
        custom: RemoteCustomTunnel
    ) async throws -> Publication {
        guard provider != .off else { throw Failure(message: localized("No tunnel selected.")) }
        let pattern = provider.urlPattern(custom: custom)
        guard !pattern.isEmpty,
              (try? NSRegularExpression(pattern: pattern)) != nil else {
            // A pattern that never compiles could never match, so the tunnel
            // would sit "starting" forever. Refuse while it is still fixable.
            throw Failure(message: localized("This relay has no valid URL pattern, so its address could never be read back."))
        }

        let arch = try await architecture(of: alias)
        let binary = try await ensureBinary(
            alias: alias, provider: provider, arch: arch, custom: custom)
        let lingering = await enableLinger(alias: alias)

        let unit = RemoteSystemdUnit(
            name: tunnelUnit,
            title: "Termio tunnel (\(provider.label))",
            executable: binary,
            arguments: provider.arguments(port: port, custom: custom),
            log: RemoteTunnelPaths.tunnelLog,
            freshLog: true)
        try await start(unit, on: alias, failing: localized("Couldn’t start \(provider.label) on \(alias)."))

        // Polled rather than slept on: a cold tunnel that has to dial a relay
        // takes longer than a warm one, and a fixed wait would either lie or
        // waste the difference.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(750))
            let log = await RemoteShell.run(
                alias: alias, command: "cat \(RemoteTunnelPaths.tunnelLog) 2>/dev/null")
            if let address = firstMatch(of: pattern, in: log.stdout) {
                return Publication(address: address, survivesReboot: lingering)
            }
        }
        throw Failure(message: localized("\(provider.label) started on \(alias) but never printed an address.\n\(await diagnosis(alias: alias, unit: tunnelUnit, log: RemoteTunnelPaths.tunnelLog))"))
    }

    /// Keeps the user's services running when nobody is logged in — which is
    /// every minute between closing the laptop and picking up the phone, and
    /// every minute after a reboot. Without it `systemd --user` stops the whole
    /// manager at logout and the box quietly goes dark.
    ///
    /// Returns whether it took. It is not fatal: the tunnel is up either way,
    /// and a box whose polkit refuses this is still publishable for as long as
    /// the login lasts. The caller says so rather than pretending otherwise.
    /// What the last publish found, per machine. Remembered rather than
    /// re-probed: the pane is rebuilt every time it appears, and a warning that
    /// only survives the click that produced it is a warning nobody reads twice.
    /// Absent means never published from here, which claims nothing either way.
    static func lingers(device: String) -> Bool {
        UserDefaults.standard.object(forKey: "remoteTunnel.\(device).lingers") as? Bool ?? true
    }

    static func rememberLinger(_ on: Bool, device: String) {
        UserDefaults.standard.set(on, forKey: "remoteTunnel.\(device).lingers")
    }

    private static func enableLinger(alias: String) async -> Bool {
        _ = await RemoteShell.run(
            alias: alias, command: "loginctl enable-linger \"$USER\" 2>/dev/null || true")
        let state = await RemoteShell.run(
            alias: alias, command: "loginctl show-user \"$USER\" -p Linger --value 2>/dev/null || true")
        return state.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    /// Writes the unit, reloads, and (re)starts it enabled.
    ///
    /// `enable` and `restart` rather than `enable --now`: the unit is usually
    /// already installed by the time someone publishes a second time, and
    /// `--now` would leave the old command running while the new file sat on
    /// disk unread. `reset-failed` first, because a unit an earlier attempt left
    /// in `failed` refuses to start again until its counters are cleared, and
    /// the fix the user just made would look like the same failure.
    private static func start(
        _ unit: RemoteSystemdUnit, on alias: String, failing summary: String
    ) async throws {
        let path = "\(RemoteTunnelPaths.unitDirectory)/\(unit.name)"
        let install = """
            mkdir -p \(RemoteTunnelPaths.unitDirectory) \(RemoteTunnelPaths.stateDirectory) && \
            printf '%s' \(RemoteShell.quoted(unit.text)) > \(path).new && \
            mv \(path).new \(path) && \
            systemctl --user daemon-reload && \
            systemctl --user enable \(unit.name) > /dev/null && \
            { systemctl --user reset-failed \(unit.name) 2>/dev/null || true; } && \
            systemctl --user restart \(unit.name)
            """
        let launched = await RemoteShell.run(alias: alias, command: install)
        guard launched.succeeded else {
            throw Failure(message: "\(summary)\n\(launched.failure)")
        }
    }

    /// What to show when a unit was started and then did not do its job. The
    /// log alone is not enough: a unit that failed to exec at all never wrote a
    /// line, and only the journal knows why.
    private static func diagnosis(alias: String, unit: String, log: String) async -> String {
        let report = await RemoteShell.run(
            alias: alias,
            command: """
                systemctl --user is-active \(unit); \
                journalctl --user -u \(unit) -n 8 --no-pager 2>/dev/null; \
                tail -n 12 \(log) 2>/dev/null
                """)
        return report.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let found = Range(match.range, in: text) else { return nil }
        return String(text[found])
    }
}

extension RemoteTunnelService {
    /// Points the daemon at the address the tunnel just published, and restarts
    /// it so the listener actually exists.
    ///
    /// Both halves are needed and both need the restart: `--wss` is what opens
    /// the loopback listener at all, and `--wss-origin` is what lets the phone's
    /// `Origin` past the CSRF check. Running `serve` explicitly with the two
    /// flags also *persists* them (`wss.bind`, `wss.origin`, 0600), so a
    /// client-triggered autostart on a box whose unit was never installed still
    /// comes back armed.
    ///
    /// **This ends every session the daemon is hosting.** The caller asks first;
    /// this does not, because it cannot know whether the caller already did.
    static func arm(alias: String, origin: String, port: Int) async throws {
        // `termiod stop`, never `pkill`: the daemon is found by the credential
        // on its socket, so this stops the one actually serving this user and
        // cannot stop anything else — including the ssh wrapper running the
        // command, which is what an unanchored pattern match reaches.
        // `--force` because the caller has already named what will end.
        _ = await RemoteShell.run(
            alias: alias,
            command: "\(Termiod.remoteBinary()) stop --force > /dev/null 2>&1 || true")

        let unit = RemoteSystemdUnit(
            name: daemonUnit,
            title: "termiod session host",
            executable: Termiod.remoteBinary(),
            arguments: ["serve", "--wss", "127.0.0.1:\(port)", "--wss-origin", origin],
            log: RemoteTunnelPaths.daemonLog,
            freshLog: false)
        try await start(
            unit, on: alias,
            failing: localized("Couldn’t start termiod on \(alias) with a listener."))

        // The daemon binds its socket before it serves; wait for it rather than
        // guessing, so the pair that follows is not answered by a corpse.
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(500))
            let up = await RemoteShell.run(
                alias: alias, command: "ss -ltn 2>/dev/null | grep -q ':\(port) ' && echo up || true")
            if up.stdout.contains("up") { return }
        }
        throw Failure(message: localized("termiod on \(alias) never opened its listener.\n\(await diagnosis(alias: alias, unit: daemonUnit, log: RemoteTunnelPaths.daemonLog))"))
    }
}

extension RemoteTunnelService {
    /// Dials the published address the way the iPhone will, and returns the
    /// `host_id` the daemon answers with.
    ///
    /// This exists because a successful `termiod pair` proves nothing about
    /// reachability: `pair` reads the token and the origin off disk and never
    /// contacts the daemon, let alone the tunnel in front of it. A QR minted
    /// from it can scan perfectly and then 403, and the user finds out on the
    /// phone, alone, with no error to read.
    ///
    /// The two derivations below are the phone's, from `Models.websocketURL`
    /// and `Models.originValue`. They are duplicated rather than shared because
    /// the point is to *reproduce* what the phone does — a shared helper would
    /// still agree with itself if the phone's rule changed.
    static func handshake(url: String, token: String) async throws -> String {
        guard var components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              let host = components.host else {
            throw Failure(message: localized("\(url) is not an address the iPhone could dial."))
        }
        let secure = scheme == "https" || scheme == "wss"
        let path = components.path.hasSuffix("/")
            ? String(components.path.dropLast()) : components.path
        components.scheme = secure ? "wss" : "ws"
        components.path = path + "/ws"
        components.query = nil
        components.fragment = nil
        let port = components.port.map { ":\($0)" } ?? ""
        let origin = "\(secure ? "https" : "http")://\(host)\(port)"

        guard let dial = components.url else {
            throw Failure(message: localized("\(url) is not an address the iPhone could dial."))
        }

        var request = URLRequest(url: dial)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        // The token rides the subprotocol, never the query string — the daemon
        // refuses it anywhere else, and a query would leak it into proxy logs.
        request.setValue("termiod.\(token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        do {
            let hello = try Termiod.helloPayload(role: "control", caps: [], client: "termio-mac")
            try await socket.send(.data(Termiod.frame(kind: .control, payload: hello)))
            let message = try await socket.receive()
            guard case .data(let bytes) = message, bytes.count > 5 else {
                throw Failure(message: localized("\(origin) answered, but not with the handshake termiod sends."))
            }
            // `[kind: u8][len: u32be][payload]`, frozen since v0.
            let payload = bytes.dropFirst(5)
            guard case .helloOk(let handshake) = try Termiod.decodeControl(Data(payload)) else {
                throw Failure(message: localized("\(origin) refused the handshake."))
            }
            return handshake.hostId
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: localized("\(origin) is published, but the connection an iPhone would make was refused.\n\(error.localizedDescription)"))
        }
    }
}
