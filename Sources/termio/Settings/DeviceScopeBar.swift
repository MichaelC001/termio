import SwiftUI

/// Which device the page below is about.
///
/// Several settings pages are already per-device and only ever said so in a
/// footnote — the Agents roster reported readiness for whichever machine the
/// current workspace happened to run on, with no control saying which that was
/// or letting you change it. A scope that exists but cannot be seen or set is
/// worse than either having one or not.
///
/// It is a **control**, not a sidebar group and not a drill-down:
///
/// - A sidebar group would name the axis and still not answer it — you would
///   arrive under "Device" and have to pick one anyway — and it splits the
///   sidebar by something nobody navigates by. People look for *Agents*, not for
///   the device section.
/// - A drill-down (Devices ▸ a device ▸ what it runs) is right for *inspecting
///   one box* and wrong for the task these pages serve, which is reading the same
///   subject across machines. Comparing two devices should not mean backing out
///   and re-entering.
///
/// This is the shape Displays, Sound and Printers & Scanners use: the device
/// selector sits at the top of the pane and the pane answers for it.
///
/// Pinned above the list rather than filed as its first row — the opposite of
/// where `AddDeviceRow` belongs, and for the opposite reason. An action belongs
/// with the thing it acts on and may scroll away with it; a scope has to stay
/// legible while you read what it scopes.
struct DeviceScopeBar: View {
    @ObservedObject var store: TermioStore
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            Text(localized("Device"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker(localized("Device"), selection: $selection) {
                ForEach(devices, id: \.settingsKey) { device in
                    Text(device.name).tag(device.settingsKey)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        // A roster that lost the selected device — an alias deleted from
        // `~/.ssh/config` while Settings was open — falls back to this Mac
        // rather than leaving the picker showing a device that is not there.
        .onChange(of: devices.map(\.settingsKey), initial: true) { _, keys in
            guard !keys.contains(selection) else { return }
            selection = KnownDevice.thisMac.settingsKey
        }
    }

    /// The same roster the Devices tab lists, minus the aliases termio has never
    /// worked on: this control scopes a page to a machine, and a box that has
    /// never run a session has nothing for one to report.
    private var devices: [KnownDevice] {
        DeviceRoster.known(in: store)
    }
}

@MainActor
extension KnownDevice {
    /// The device a settings scope key names, or this Mac when it names nothing
    /// on the roster.
    static func onRoster(_ settingsKey: String, in store: TermioStore) -> KnownDevice {
        DeviceRoster.known(in: store).first { $0.settingsKey == settingsKey } ?? .thisMac
    }
}
