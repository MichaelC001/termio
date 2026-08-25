import AppKit
import SwiftUI

/// Settings ▸ Machines: one row per machine sessions can run on, each pushing
/// that machine's pane.
///
/// This tab is where the RFC's D2 collision was resolved. The shipped "Devices"
/// tab was the renamed SSH tab — a `~/.ssh/config` projection, which
/// `docs/design/20260814-remote-to-device.decisions.md` §1 classifies as *routes* —
/// so machine identity had no home and the name it wanted was taken. Two tabs
/// that both list machines would force the user to learn the route/identity
/// distinction before they could find anything; one pane that shows both does
/// not. So: **one tab, one row per machine, and the two halves are sections
/// inside a machine's pane** — *Reached by* (alias, destination, key, Test
/// Connection, Edit in Config) above *Runs* (what is installed on it).
///
/// What stays at this level is what is not per-machine: `~/.ssh/config` itself,
/// and the public keys in `~/.ssh`. Those are about the user's own credentials,
/// not about any one box.
///
/// A grouped `Form`, like every other pane in this window and like System
/// Settings itself. It was a `List` to keep `onMove` live in case the roster ever
/// became reorderable — a container chosen for a feature that does not exist and
/// cannot: the order here is `~/.ssh/config`'s own, and reordering would mean
/// rewriting the user's file. The cost was real and visible: this was the only
/// tab in the app without the grouped cards, so its rows sat flat on the window
/// with full-bleed separators and the first one clipped under the toolbar.
struct DevicesSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: TermioStore
    /// Opens an SSH terminal to the alias in the main window (wired to
    /// `TermioStore.addSSHSession` by the app delegate).
    let onConnect: (String) -> Void
    /// Runs `ssh-copy-id <alias>` with a public key, for a host whose probe found
    /// it wants a password (wired to `TermioStore.addKeyInstallSession`).
    let onSetUpKey: (String, String) -> Void

    @State private var hosts: [SSHConfigHost] = []
    @State private var publicKeys: [SSHPublicKey] = []
    @State private var addingHost = false
    @State private var configEditor: SSHConfigEditorTarget?
    /// The key whose Copy button is briefly confirming, so the click visibly took.
    @State private var copiedKeyID: String?

    var body: some View {
        Form {
            // No section header: the tab is called Devices and this is the
            // only list of them in it. The add row is the last row of the
            // list it adds to rather than a bar pinned to the window bottom,
            // which in a tall window sat a screen away from the roster with
            // two unrelated sections in between — and so read as adding a
            // public key.
            Section {
                ForEach(machines) { machine in
                    NavigationLink(value: DeviceRoute(key: machine.settingsKey)) {
                        DeviceListRow(machine: machine, host: host(for: machine))
                    }
                }
                AddDeviceRow { addingHost = true }
            } footer: {
                Text(localized("Open one to see how it is reached and what it runs."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            if !publicKeys.isEmpty {
                Section {
                    ForEach(publicKeys) { key in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.name)
                                Text(key.comment.isEmpty
                                     ? key.algorithm : "\(key.algorithm) · \(key.comment)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(copiedKeyID == key.id
                                   ? localized("Copied") : localized("Copy")) { copy(key) }
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
        }
        .formStyle(.grouped)
        .navigationDestination(for: DeviceRoute.self) { route in
            if let machine = machines.first(where: { $0.settingsKey == route.key }) {
                DevicePane(
                    machine: machine,
                    host: host(for: machine),
                    settings: settings,
                    keyToInstall: host(for: machine).flatMap {
                        SSHConfigFile.publicKeyToInstall(for: $0, keys: publicKeys)
                    },
                    onConnect: onConnect,
                    onSetUpKey: onSetUpKey,
                    onEditConfig: { presentEditor(for: host(for: machine)) }
                )
                .id(route.key)
            } else {
                // The alias left `~/.ssh/config` while its pane was open.
                ContentUnavailableView {
                    Text(localized("Device Unavailable"))
                } description: {
                    Text(localized("This device is no longer in your configuration."))
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $addingHost, onDismiss: reload) {
            AddSSHHostSheet(existingAliases: Set(hosts.map(\.alias)))
        }
        .sheet(item: $configEditor, onDismiss: reload) { target in
            SSHConfigEditorSheet(target: target, settings: settings) { configEditor = nil }
        }
    }

    /// This Mac first, then every machine Termio has worked on, then the aliases
    /// in `~/.ssh/config` it has not. The last group matters: a box you configured
    /// but never opened is exactly the one you came here to set up.
    private var machines: [KnownDevice] {
        let known = DeviceRoster.known(in: store)
        return known + DeviceRoster.unusedAliases(known: known)
            .map { KnownDevice(alias: $0, deviceID: nil) }
    }

    /// The `~/.ssh/config` block that reaches this machine, when one names it.
    /// `nil` for this Mac, and for a device known only from a session record.
    private func host(for machine: KnownDevice) -> SSHConfigHost? {
        machine.alias.flatMap { alias in hosts.first { $0.alias == alias } }
    }

    private func presentEditor(for host: SSHConfigHost?) {
        // Symlinks resolve before the editor opens: its atomic auto-save would
        // otherwise replace a dotfile-managed link with a plain file.
        if let host {
            configEditor = SSHConfigEditorTarget(
                url: host.file.resolvingSymlinksInPath(), line: host.line)
        } else {
            try? SSHConfigFile.ensureConfigExists()
            configEditor = SSHConfigEditorTarget(url: SSHConfigFile.writableConfigURL, line: nil)
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

/// What a machine row pushes. A named type rather than the bare key so the
/// settings window's shared navigation stack can't confuse a machine with the
/// Agents tab's string destination.
private struct DeviceRoute: Hashable {
    let key: String
}

/// One machine on the roster: its name over how it is reached. No status here —
/// a roster that probed every host on appear would fire ssh at every configured
/// box each time Settings opens, and a sleeping VPS would make that take as long
/// as its timeout. The pane asks; the roster lists.
private struct DeviceListRow: View {
    let machine: KnownDevice
    let host: SSHConfigHost?

    /// Empty for a Mac whose name cannot be read, so the row is one line rather
    /// than one line and a gap.
    private var detail: String {
        // The host name, not "the machine you're on" — a subtitle restating the
        // title is a line that costs a row's height and answers nothing. Apple's
        // rows put the *fact* there ("65 apps", "Off"); here the fact is which
        // Mac this is.
        guard machine.alias != nil else { return Host.current().localizedName ?? "" }
        guard let host else { return localized("From your session history") }
        guard let identityFile = host.identityFile else { return host.destinationLabel }
        return "\(host.destinationLabel) · \((identityFile as NSString).lastPathComponent)"
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsSymbolBadge(
                symbol: machine.isLocal ? "laptopcomputer" : "server.rack",
                tint: machine.isLocal ? .secondary : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
        }
    }
}

/// The roster's add action, as the last row of the roster.
///
/// Styled as a row of the group rather than a bar with its own inset background:
/// inside a grouped `Form` the card already draws the surface, and a second
/// rounded rect on top of it is what made this read as bolted on.
private struct AddDeviceRow: View {
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 12) {
                // No badge — an action is not a device — but it takes the same
                // leading width so its label starts on the roster's text column.
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: settingsRowIconWidth, height: 26)
                Text(localized("Add Device"))
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

