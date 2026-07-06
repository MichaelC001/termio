import Foundation
import Security

/// Secrets store for SSH — passwords and private keys — backed by the iOS
/// Keychain. Metadata (hosts, key records) lives in `SSHStore`'s JSON; the
/// secret bytes only ever live here, marked device-only and available after
/// first unlock, so they neither sync nor leave the phone.
enum SSHKeychain {
    private static let passwordService = "sh.termio.ssh.password"
    private static let privateKeyService = "sh.termio.ssh.privateKey"

    static func setPassword(_ password: String?, for hostID: UUID) {
        set(password, service: passwordService, account: hostID.uuidString)
    }

    static func password(for hostID: UUID) -> String? {
        get(service: passwordService, account: hostID.uuidString)
    }

    static func setPrivateKey(_ pem: String?, for keyID: UUID) {
        set(pem, service: privateKeyService, account: keyID.uuidString)
    }

    static func privateKey(for keyID: UUID) -> String? {
        get(service: privateKeyService, account: keyID.uuidString)
    }

    // MARK: - Primitive get/set

    /// Upsert (nil value deletes). Overwrites any existing item for the pair so
    /// editing a host's password just replaces it.
    private static func set(_ value: String?, service: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            Log.ssh.error("SSHKeychain: failed to store secret (\(service), status \(status))")
        }
    }

    private static func get(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
