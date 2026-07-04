import CoreImage
import SwiftUI

/// Pairing page for the iPhone companion app: a QR code of the address the
/// companion server is serving on this Mac. The phone scans it once (session
/// list ▸ Mac pill ▸ Scan QR Code, or Settings ▸ Connectivity) and every
/// project and session rides that one link — no typing ws:// URLs on a phone
/// keyboard.
struct MobileSettingsTab: View {
    /// The reachable addresses, refreshed on open: Wi-Fi/Ethernet IPv4s
    /// first (the proven path), the Bonjour `.local` name as a fallback that
    /// survives DHCP lease changes.
    @State private var hosts: [String] = []
    @State private var selectedHost = ""
    @State private var copied = false
    @State private var token = PairingToken.current
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mobile = MobileAccess.shared

    /// What the QR encodes: the tunnel's public URL while one is running,
    /// the LAN address otherwise — either way carrying the pairing token the
    /// server demands before serving anything.
    private var url: String {
        if case .running(let publicURL) = tunnel.status {
            let host = publicURL.absoluteString.replacingOccurrences(of: "https://", with: "wss://")
            return "\(host)/?t=\(token)"
        }
        return "ws://\(selectedHost):\(CompanionServer.defaultPort)/?t=\(token)"
    }

    private var tunnelRunning: Bool {
        if case .running = tunnel.status { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                Toggle("Mobile Access", isOn: $mobile.isEnabled)
            } footer: {
                Text("When off, this Mac stops listening and your iPhone disconnects — but stays paired. Turn it back on to reconnect; no new QR needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Everything below only means anything while we're serving, so the
            // master switch reveals it — a dimmed, unscannable QR (and an
            // address nothing is listening on) is more misleading than absent.
            if mobile.isEnabled {
                Section {
                    if hosts.isEmpty, !tunnelRunning {
                        Text("No network address found. Join a network, then reopen this tab.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        qrCard
                        if hosts.count > 1, !tunnelRunning {
                            Picker("Address", selection: $selectedHost) {
                                ForEach(hosts, id: \.self) { host in
                                    Text(host).tag(host)
                                }
                            }
                        }
                        addressRow
                    }
                } header: {
                    SectionHeaderLabel(title: "Pair iPhone")
                } footer: {
                    Text(tunnelRunning
                        ? "On the iPhone app, tap the Mac pill on the session list (or Settings ▸ Connectivity) and choose Scan QR Code. The tunnel address works from anywhere."
                        : "On the iPhone app, tap the Mac pill on the session list (or Settings ▸ Connectivity) and choose Scan QR Code. Both devices must be on the same network.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Tunnel", selection: Binding(
                        get: { tunnel.provider },
                        set: { tunnel.setProvider($0) }
                    )) {
                        ForEach(TunnelManager.Provider.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    statusRow
                } header: {
                    SectionHeaderLabel(title: "Remote Access")
                } footer: {
                    Text("Fronts this Mac with a public URL so the iPhone can connect away from home. The QR above switches to the tunnel address while one is running; every connection still has to present this Mac's pairing token.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Reset Pairing…", role: .destructive) {
                        token = PairingToken.regenerate()
                    }
                } footer: {
                    Text("Generates a new pairing token. Every previously paired phone is signed out until it scans the new QR.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshHosts)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Text("Status")
            Spacer()
            switch tunnel.status {
            case .off:
                Text("Off — LAN only")
                    .foregroundStyle(.secondary)
            case .installing:
                ProgressView().controlSize(.small)
                Text("Installing \(tunnel.provider.binaryName)…")
                    .foregroundStyle(.secondary)
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting tunnel…")
                    .foregroundStyle(.secondary)
            case .running(let publicURL):
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text(publicURL.host ?? publicURL.absoluteString)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var qrCard: some View {
        HStack {
            Spacer()
            if let qr = Self.qrImage(for: url) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(10)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    /// The scannable address as a value row: the URL leading (monospaced,
    /// middle-truncated so the token tail never pushes the button off-screen),
    /// a trailing Copy the way Apple pins Copy to a serial-number row.
    private var addressRow: some View {
        HStack(spacing: 8) {
            Text(url)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .fixedSize()
        }
    }

    private func refreshHosts() {
        hosts = Self.lanIPv4Addresses() + [Self.bonjourName()].compactMap { $0 }
        if !hosts.contains(selectedHost) {
            selectedHost = hosts.first ?? ""
        }
    }

    /// IPv4 addresses of the real interfaces (`en*` — Wi-Fi and Ethernet),
    /// skipping link-local self-assignments.
    private static func lanIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en"),
                  let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254."), !addresses.contains(ip) {
                addresses.append(ip)
            }
        }
        return addresses
    }

    /// The `<name>.local` mDNS hostname, when the system reports one.
    private static func bonjourName() -> String? {
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? name : nil
    }

    /// Plain CoreImage QR (medium error correction), rendered nearest-neighbor
    /// so the modules stay sharp at display size.
    private static func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(string.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
