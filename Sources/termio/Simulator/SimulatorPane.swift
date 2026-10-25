import AppKit
import SwiftUI

/// The inspector's Simulator pane: one iOS Simulator, live, under a header that
/// picks the device and holds the hardware buttons a mouse can't reach. The
/// device is driven by pointer and keyboard here, and by agents through
/// `termio sim` — both act on the same device, the one this pane shows.
struct SimulatorPane: View {
    @ObservedObject private var host = SimulatorHost.shared
    @State private var screenshotNote: String?

    var body: some View {
        VStack(spacing: 0) {
            if let reason = host.unavailableReason {
                PaneEmptyState(localized("Simulator Unavailable"), icon: .smartPhone, message: reason)
            } else {
                header
                content
            }
        }
        .task {
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
            Spacer(minLength: 8)
            if let screen = host.screen {
                TreeHeaderButton(huge: .home, help: localized("Home")) {
                    host.fire("button", ["udid": screen.udid, "name": "home"])
                }
                TreeHeaderButton(huge: .refresh, help: localized("Rotate Right")) {
                    host.fire("rotate", ["udid": screen.udid, "direction": "right"])
                }
                TreeHeaderButton(huge: .camera, help: localized("Save Screenshot to Desktop")) {
                    Task { await saveScreenshot(of: screen) }
                }
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
            Divider()
            Button(localized("Refresh")) { Task { await host.refreshDevices() } }
        } label: {
            Text(host.booting.flatMap { udid in host.devices.first { $0.udid == udid }?.name }
                 ?? host.screen?.name ?? localized("Choose a Simulator"))
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task { await host.refreshDevices() }
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
            SimulatorScreenRepresentable(screen: screen)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if let screenshotNote {
                        Text(screenshotNote)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                    }
                }
        } else if let error = host.lastError {
            PaneEmptyState(localized("Simulator Unavailable"), icon: .smartPhone, message: error)
        } else {
            PaneEmptyState(
                localized("No Simulator Running"), icon: .smartPhone,
                message: localized("Choose a device above to boot it."))
        }
    }

    /// Simulator.app's own convention: a PNG on the Desktop, named for the
    /// device and the moment.
    private func saveScreenshot(of screen: SimulatorScreen) async {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Simulator Screenshot - \(screen.name) - \(formatter.string(from: Date())).png"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let path = desktop.appendingPathComponent(name).path
        do {
            _ = try await host.call("screenshot", ["udid": screen.udid, "path": path])
            screenshotNote = localized("Saved to Desktop")
        } catch {
            screenshotNote = error.localizedDescription
        }
        do {
            try await Task.sleep(for: .seconds(2))
        } catch {
            return  // The pane went away; nothing is left to clear.
        }
        screenshotNote = nil
    }
}
