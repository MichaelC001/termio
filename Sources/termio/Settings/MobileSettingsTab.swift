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

    private var url: String {
        "ws://\(selectedHost):\(CompanionServer.defaultPort)"
    }

    var body: some View {
        Form {
            Section {
                if hosts.isEmpty {
                    Text("No network address found. Join a network, then reopen this tab.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    qrCard
                    if hosts.count > 1 {
                        Picker("Address", selection: $selectedHost) {
                            ForEach(hosts, id: \.self) { host in
                                Text(host).tag(host)
                            }
                        }
                    }
                    copyRow
                }
            } header: {
                SectionHeaderLabel(title: "Pair iPhone")
            } footer: {
                Text("On the iPhone app, tap the Mac pill on the session list (or Settings ▸ Connectivity) and choose Scan QR Code. Both devices must be on the same network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshHosts)
    }

    private var qrCard: some View {
        HStack {
            Spacer()
            VStack(spacing: 10) {
                if let qr = Self.qrImage(for: url) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .padding(10)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Text(url)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var copyRow: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc")
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
