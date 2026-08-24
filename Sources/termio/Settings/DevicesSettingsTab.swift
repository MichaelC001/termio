import AppKit
import SwiftUI

/// Settings ▸ Devices: the connectable hosts from `~/.ssh/config`, each one click
/// away from a terminal. The config file stays the single source of truth —
/// termio reads the same hosts `ssh` itself resolves and writes nothing behind
/// the user's back: Add Host appends a plain block, Edit opens the raw file.
struct DevicesSettingsTab: View {
    @ObservedObject var settings: AppSettings
    /// Opens an SSH terminal to the alias in the main window (wired to
    /// `TermioStore.addSSHSession` by the app delegate).
    let onConnect: (String) -> Void
    /// Runs `ssh-copy-id <alias>` with a public key, for a host whose probe found
    /// it wants a password (wired to `TermioStore.addKeyInstallSession`).
    let onSetUpKey: (String, String) -> Void

    @State private var hosts: [SSHConfigHost] = []
    @State private var publicKeys: [SSHPublicKey] = []
    @State private var addingHost = false
    @State private var configEditor: ConfigEditorTarget?
    /// The key whose Copy button is briefly confirming, so the click visibly took.
    @State private var copiedKeyID: String?

    /// Which file the editor sheet shows — usually `~/.ssh/config`, but a host
    /// defined in an `Include`d file opens that file, at its `Host` line.
    private struct ConfigEditorTarget: Identifiable {
        let url: URL
        let line: Int?
        var id: String { "\(url.path)#\(line ?? 0)" }
    }

    var body: some View {
        Form {
            hostsSection
            configSection
            if !publicKeys.isEmpty { keysSection }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .sheet(isPresented: $addingHost, onDismiss: reload) {
            AddSSHHostSheet(existingAliases: Set(hosts.map(\.alias)))
        }
        .sheet(item: $configEditor, onDismiss: reload) { target in
            FileEditorView(
                url: target.url,
                settings: settings,
                jumpLine: target.line,
                showsInspectorChrome: false,
                onClose: { configEditor = nil }
            )
            .frame(minWidth: 640, minHeight: 460)
            // The editor's own header controls belong to the inspector, which a sheet
            // doesn't have — so supply the one control that still applies. Escape closes
            // too; the visible button is the guaranteed way out.
            .overlay(alignment: .topTrailing) {
                Button { configEditor = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(localized("Close (Esc)"))
                .padding(8)
            }
        }
    }

    private var hostsSection: some View {
        Section {
            if hosts.isEmpty {
                Text(localized("No hosts yet — add one, or write a Host block in ~/.ssh/config."))
                    .foregroundStyle(.secondary)
            }
            ForEach(hosts) { host in
                SSHHostRow(
                    host: host,
                    keyToInstall: SSHConfigFile.publicKeyToInstall(for: host, keys: publicKeys),
                    connect: { onConnect(host.alias) },
                    setUpKey: { onSetUpKey(host.alias, $0.url.path) },
                    editInConfig: { presentEditor(for: host) }
                )
            }
            Button { addingHost = true } label: {
                Label(localized("Add Host"), systemImage: "plus")
            }
        } header: {
            SectionHeaderLabel(title: localized("Hosts"))
        } footer: {
            Text(.init(localized("Your Host entries from ~/.ssh/config — the same aliases `ssh` resolves. Right-click a host to connect.")))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var configSection: some View {
        Section {
            LabeledContent {
                Button(localized("Edit")) { presentEditor(for: nil) }
            } label: {
                SettingsLabel(
                    title: "~/.ssh/config",
                    subtext: localized("Reads ~/.ssh/config directly — Termio keeps no separate host list."),
                    titleFont: .headline
                )
            }
        } header: {
            SectionHeaderLabel(title: localized("Config file"))
        }
    }

    private var keysSection: some View {
        Section {
            ForEach(publicKeys) { key in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name)
                        Text(key.comment.isEmpty ? key.algorithm : "\(key.algorithm) · \(key.comment)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(copiedKeyID == key.id ? localized("Copied") : localized("Copy")) { copy(key) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        } header: {
            SectionHeaderLabel(title: localized("Public keys"))
        } footer: {
            Text(localized("The public keys in ~/.ssh. Copy one to paste into a server’s authorized_keys — private keys are never read."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Opens the editor sheet on a host's defining file at its `Host` line, or on
    /// `~/.ssh/config` itself. The config is created empty first when missing so
    /// the editor never opens onto a nonexistent file.
    private func presentEditor(for host: SSHConfigHost?) {
        // Symlinks resolve before the editor opens: its atomic auto-save would
        // otherwise replace a dotfile-managed link with a plain file.
        if let host {
            configEditor = ConfigEditorTarget(url: host.file.resolvingSymlinksInPath(), line: host.line)
        } else {
            try? SSHConfigFile.ensureConfigExists()
            configEditor = ConfigEditorTarget(url: SSHConfigFile.writableConfigURL, line: nil)
        }
    }

    private func reload() {
        hosts = SSHConfigFile.hosts()
        publicKeys = SSHConfigFile.publicKeys()
    }

    private func copy(_ key: SSHPublicKey) {
        guard let text = try? String(contentsOf: key.url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string
        )
        copiedKeyID = key.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedKeyID == key.id { copiedKeyID = nil }
        }
    }
}

/// One host row: alias over its `user@host` destination (with the pinned key's
/// filename when the block sets one), and a Test Connection probe. Live
/// connecting is a launch, not a setting — it lives in the context menu (and
/// the sidebar / File menu), keeping this pane about configuring and verifying
/// hosts.
private struct SSHHostRow: View {
    let host: SSHConfigHost
    /// The key an install would put on this host, or nil when there is none to
    /// send — which is what decides whether the password advice can offer a fix.
    let keyToInstall: SSHPublicKey?
    let connect: () -> Void
    let setUpKey: (SSHPublicKey) -> Void
    let editInConfig: () -> Void

    private enum ProbeState { case idle, running, result(SSHProbeResult) }
    @State private var probe: ProbeState = .idle

    /// `user@host`, plus the identity file's name when the block pins one — the
    /// full path stays in the tooltip.
    private var subtitle: String {
        guard let identityFile = host.identityFile else { return host.destinationLabel }
        let keyName = (identityFile as NSString).lastPathComponent
        return "\(host.destinationLabel) · \(keyName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.alias).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(host.identityFile.map { localized("Uses \($0)") } ?? "")
                }
                Spacer(minLength: 8)
                probeControl
            }
            if case .result(.wantsPassword) = probe { passwordAdvice }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(localized("Connect"), action: connect)
            Button(localized("Test Connection"), action: runProbe)
            if let keyToInstall {
                Button(localized("Set Up Key…")) { setUpKey(keyToInstall) }
            }
            Button(localized("Edit in Config"), action: editInConfig)
            Button(localized("Copy ssh Command")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("ssh \(host.alias)", forType: .string)
            }
        }
    }

    /// The one probe outcome with a fix worth offering in place. A password is a
    /// dead end for everything but the plain shell — the daemon connections that
    /// carry sessions and the file tree set `BatchMode=yes` and can never answer a
    /// prompt — so the row says that plainly and offers the install that ends it.
    @ViewBuilder
    private var passwordAdvice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(keyToInstall == nil
                 ? localized("This host takes a password. Termio signs in with keys, and there is no key in ~/.ssh yet — create one with ssh-keygen, then set it up here.")
                 : localized("This host takes a password. Termio signs in with keys, so set yours up once and every session, file tree and remote terminal can reach it."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let keyToInstall {
                Button(localized("Set Up Key…")) { setUpKey(keyToInstall) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(localized("Runs ssh-copy-id with \(keyToInstall.name) in a terminal — the host asks for your password once, there."))
            }
        }
        .padding(.top, 2)
    }

    /// The trailing control: a Test button that turns into a spinner while the
    /// probe runs, then a tinted result badge that re-tests on click.
    @ViewBuilder
    private var probeControl: some View {
        switch probe {
        case .idle:
            Button(localized("Test"), action: runProbe)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 44)
        case .result(let outcome):
            Button(action: runProbe) {
                Text(outcome.label)
                    .foregroundStyle(outcome.tint)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(localized("\(outcome.detail) — click to re-test"))
        }
    }

    /// Runs the non-interactive probe off the main thread, hopping back to update
    /// the badge. A fresh click just re-arms it.
    private func runProbe() {
        probe = .running
        Task { @MainActor in
            probe = .result(await SSHConfigFile.testConnection(alias: host.alias))
        }
    }
}

/// How each probe outcome reads in the row: a short tinted label — the wording
/// itself distinguishes outcomes, so color is reinforcement, not the only
/// signal — with the raw ssh detail in the tooltip.
private extension SSHProbeResult {
    var label: String {
        switch self {
        case .reachable: return localized("Reachable")
        case .wantsPassword: return localized("Wants a password")
        case .authFailed: return localized("Auth failed")
        case .unreachable(let reason): return reason
        }
    }

    var tint: Color {
        switch self {
        case .reachable: return .green
        case .wantsPassword, .authFailed: return .orange
        case .unreachable: return .red
        }
    }

    var detail: String {
        switch self {
        case .reachable: return localized("Connected and authenticated")
        case .wantsPassword(let message), .authFailed(let message),
             .unreachable(let message):
            return message
        }
    }
}

/// The Add Host sheet, appending a `Host` block to `~/.ssh/config` that is
/// indistinguishable from a hand-written one. Shared by Settings ▸ Devices' Add
/// Host button and the New SSH Connection ▸ Add Host… menu row (which connects
/// to the host right after adding it).
///
/// The address leads and everything else follows from it: `you@box.example.com:2222`
/// fills the user and port, and the name is the address's first label until the
/// user types their own. What remains is the pair that decides whether the host
/// will actually let you in — offered as one "Sign in as" row built from the
/// identities the config already uses, because a machine you add is almost always
/// reached as the same person with the same key as the last one. Port and an
/// explicit key stay behind Advanced: they are the exception, and a form that
/// shows every exception at once reads as five equally likely questions.
struct AddSSHHostSheet: View {
    let existingAliases: Set<String>
    /// When set (the AppKit-presented menu path), called with the added alias —
    /// nil on Cancel — instead of the SwiftUI dismiss, since the environment's
    /// DismissAction has no SwiftUI presentation to pop there.
    var completion: ((String?) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    /// Empty until the user types a name of their own; until then the field shows
    /// (and Add uses) the one derived from the address.
    @State private var typedAlias = ""
    @State private var identity: IdentityChoice = .other
    @State private var user = ""
    @State private var port = ""
    @State private var identityFile = ""
    @State private var advancedExpanded = false
    @State private var writeError: String?
    /// Read once, on appear: the sheet is modal, so the config cannot change under
    /// it, and re-deriving per keystroke would re-read every file `Include` pulls in.
    @State private var suggestions: [SSHIdentity] = []

    /// Which credentials the new block will carry: one the config already uses, or
    /// the fields under Advanced.
    private enum IdentityChoice: Hashable {
        case suggested(SSHIdentity)
        case other
    }

    private var parsedAddress: (user: String, host: String, port: String) {
        SSHConfigFile.parseDestination(address)
    }

    private var derivedAlias: String {
        SSHConfigFile.suggestedAlias(forHost: parsedAddress.host, avoiding: existingAliases)
    }

    private var effectiveAlias: String {
        typedAlias.isEmpty ? derivedAlias : typedAlias.trimmingCharacters(in: .whitespaces)
    }

    /// The address's own user/port win over the picked identity and the Advanced
    /// field: they were typed later, and typing them is a correction.
    private var effectiveUser: String {
        if !parsedAddress.user.isEmpty { return parsedAddress.user }
        if case .suggested(let suggestion) = identity { return suggestion.user }
        return user.trimmingCharacters(in: .whitespaces)
    }

    private var effectivePort: String {
        parsedAddress.port.isEmpty ? port.trimmingCharacters(in: .whitespaces) : parsedAddress.port
    }

    private var effectiveIdentityFile: String {
        if case .suggested(let suggestion) = identity { return suggestion.identityFile ?? "" }
        return identityFile.trimmingCharacters(in: .whitespaces)
    }

    /// The first thing standing between the sheet and a working Add, or nil when
    /// nothing is. Shown in place rather than left to a greyed-out button, which
    /// states the problem exists without saying what it is.
    private var validationMessage: String? {
        if parsedAddress.host.isEmpty { return nil }
        if effectiveAlias.contains(" ") {
            return localized("A name can’t contain spaces — it’s what you type after `ssh`.")
        }
        if existingAliases.contains(effectiveAlias) {
            return localized("“\(effectiveAlias)” is already in your config.")
        }
        if !effectivePort.isEmpty, Int(effectivePort).map({ (1...65535).contains($0) }) != true {
            return localized("A port is a number from 1 to 65535.")
        }
        // ssh_config has no escape for a literal double quote — such values can't
        // be written faithfully, so refuse rather than corrupt the file.
        let values = [effectiveAlias, parsedAddress.host, effectiveUser, effectiveIdentityFile]
        if values.contains(where: { $0.contains("\"") }) {
            return localized("A double quote can’t be written to ssh config.")
        }
        return nil
    }

    private var canAdd: Bool {
        !parsedAddress.host.isEmpty && !effectiveAlias.isEmpty && validationMessage == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(
                        localized("Address"), text: $address,
                        prompt: Text("server.example.com")
                    )
                    if !suggestions.isEmpty { identityPicker }
                    TextField(
                        localized("Name"), text: $typedAlias,
                        prompt: Text(derivedAlias.isEmpty ? "myserver" : derivedAlias)
                    )
                } header: {
                    SectionHeaderLabel(title: localized("Add SSH Host"))
                } footer: {
                    footer
                }
                Section {
                    DisclosureGroup(isExpanded: $advancedExpanded) {
                        if suggestions.isEmpty || identity == .other {
                            TextField(
                                localized("User"), text: $user,
                                prompt: Text(localized("optional"))
                            )
                            keyFileField
                        }
                        TextField(localized("Port"), text: $port, prompt: Text("22"))
                    } label: {
                        Text(localized("Advanced"))
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let writeError {
                    Text(writeError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button(localized("Cancel")) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                // On the menu path adding also opens the connection — the button
                // must promise both (HIG: the label describes the result).
                Button(completion == nil ? localized("Add") : localized("Add & Connect"), action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding(12)
        }
        .frame(width: 460, height: advancedExpanded ? 420 : 320)
        .animation(.easeOut(duration: 0.18), value: advancedExpanded)
        .onAppear {
            suggestions = SSHConfigFile.suggestedIdentities(in: SSHConfigFile.hosts())
            if let first = suggestions.first { identity = .suggested(first) }
        }
    }

    /// The identities already in the config, most-used first. The trailing row
    /// opens the fields under Advanced instead of asking for them up front.
    private var identityPicker: some View {
        Picker(localized("Sign in as"), selection: $identity) {
            ForEach(suggestions) { suggestion in
                Text(label(for: suggestion)).tag(IdentityChoice.suggested(suggestion))
            }
            Divider()
            Text(localized("Other…")).tag(IdentityChoice.other)
        }
        .onChange(of: identity) { _, choice in
            if choice == .other { advancedExpanded = true }
        }
    }

    private var keyFileField: some View {
        LabeledContent(localized("Key file")) {
            HStack(spacing: 6) {
                TextField(
                    "", text: $identityFile,
                    prompt: Text(localized("optional — ~/.ssh/id_ed25519"))
                )
                .labelsHidden()
                Button(localized("Choose…"), action: chooseIdentityFile)
            }
        }
    }

    /// Either what's wrong, or what the sheet is about to do — stated as the
    /// command the user will be able to type, since that is the result they get.
    @ViewBuilder
    private var footer: some View {
        if let validationMessage {
            Text(.init(validationMessage))
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text(.init(localized("Adds a Host block to ~/.ssh/config. You’ll be able to run `ssh \(effectiveAlias.isEmpty ? "myserver" : effectiveAlias)` anywhere.")))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// How an identity reads in the menu: `you · id_ed25519`, with whichever half
    /// it sets. A user it doesn't set is the local one, which is what ssh would do.
    private func label(for identity: SSHIdentity) -> String {
        let user = identity.user.isEmpty ? NSUserName() : identity.user
        return identity.keyName.isEmpty ? user : "\(user) · \(identity.keyName)"
    }

    private func add() {
        do {
            try SSHConfigFile.appendHost(
                alias: effectiveAlias,
                hostName: parsedAddress.host,
                user: effectiveUser,
                port: effectivePort,
                identityFile: effectiveIdentityFile
            )
            finish(effectiveAlias)
        } catch {
            writeError = localized("Couldn’t write ~/.ssh/config: \(error.localizedDescription)")
        }
    }

    private func finish(_ addedAlias: String?) {
        if let completion { completion(addedAlias) } else { dismiss() }
    }

    /// A file picker starting in `~/.ssh` with hidden files visible (the whole
    /// directory is dot-hidden). The chosen path is stored `~`-relative, the way
    /// ssh configs are conventionally written.
    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = SSHConfigFile.configURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        identityFile = path.hasPrefix(home + "/")
            ? "~" + path.dropFirst(home.count)
            : path
    }
}
