import Foundation

/// The saved SSH hosts and keys — metadata only, persisted as JSON in
/// Application Support. Secrets are held separately by `SSHKeychain`. A single
/// shared instance backs the Settings SSH tab and the quick-connect palette;
/// it posts `didChange` so open lists refresh.
final class SSHStore {
    static let shared = SSHStore()

    static let didChange = Notification.Name("SSHStore.didChange")

    private(set) var hosts: [SSHHost] = []
    private(set) var keys: [SSHKeyRecord] = []

    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("ssh-hosts.json")
        load()
    }

    // MARK: - Hosts

    func upsertHost(_ host: SSHHost) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
        } else {
            hosts.append(host)
        }
        persist()
    }

    func deleteHost(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        SSHKeychain.setPassword(nil, for: host.id)
        persist()
    }

    func key(for host: SSHHost) -> SSHKeyRecord? {
        guard case .key(let keyID) = host.auth else { return nil }
        return keys.first { $0.id == keyID }
    }

    // MARK: - Keys

    func upsertKey(_ key: SSHKeyRecord) {
        if let i = keys.firstIndex(where: { $0.id == key.id }) {
            keys[i] = key
        } else {
            keys.append(key)
        }
        persist()
    }

    func deleteKey(_ key: SSHKeyRecord) {
        keys.removeAll { $0.id == key.id }
        SSHKeychain.setPrivateKey(nil, for: key.id)
        // Hosts that referenced it fall back to password auth rather than
        // dangling at a missing key.
        for i in hosts.indices where hosts[i].auth == .key(keyID: key.id) {
            hosts[i].auth = .password
        }
        persist()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var hosts: [SSHHost]
        var keys: [SSHKeyRecord]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        hosts = snapshot.hosts
        keys = snapshot.keys
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(Snapshot(hosts: hosts, keys: keys))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.ssh.error("SSHStore: failed to persist hosts (\(error.localizedDescription))")
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
