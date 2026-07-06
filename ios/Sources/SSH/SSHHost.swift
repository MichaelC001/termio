import Foundation

/// A saved SSH destination. Metadata only — secrets (the password, or a key's
/// private bytes) never live here; they sit in the iOS Keychain keyed by `id`
/// (password) or the key record's id (see `SSHKeychain`).
struct SSHHost: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var host: String
    var port: Int
    var username: String
    var auth: SSHAuthMethod
    /// Set when this row was imported from the Mac's `~/.ssh/config` over the
    /// companion wire, so the list can badge it and a re-import can reconcile
    /// it. Hand-entered hosts leave it false.
    var importedFromConfig: Bool

    init(
        id: UUID = UUID(), label: String = "", host: String, port: Int = 22,
        username: String, auth: SSHAuthMethod = .password, importedFromConfig: Bool = false
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.importedFromConfig = importedFromConfig
    }

    /// The name shown in lists and the terminal header — the label if the user
    /// gave one, else `user@host`.
    var displayName: String {
        label.isEmpty ? "\(username)@\(host)" : label
    }
}

/// How a host authenticates. The referenced secret lives in the Keychain; this
/// enum only records which kind and (for keys) which record to look up.
enum SSHAuthMethod: Codable, Equatable {
    case password
    case key(keyID: UUID)
}

/// A stored SSH key's metadata. The private key bytes live in the Keychain
/// under `id`; only the shareable public line and type are kept here.
struct SSHKeyRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var type: SSHKeyType
    /// `authorized_keys` form (`ssh-ed25519 AAAA… label`), safe to display and
    /// copy to a server. nil until generation/import fills it in.
    var publicKeyLine: String?

    init(id: UUID = UUID(), label: String, type: SSHKeyType, publicKeyLine: String? = nil) {
        self.id = id
        self.label = label
        self.type = type
        self.publicKeyLine = publicKeyLine
    }
}

/// Key algorithms the engine (Apple swift-nio-ssh) can actually authenticate
/// with. RSA is deliberately absent — nio-ssh omits it, and Ed25519 is the
/// modern default; a v1 limitation, not an oversight.
enum SSHKeyType: String, Codable, CaseIterable {
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521

    var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsaP256: "ECDSA P-256"
        case .ecdsaP384: "ECDSA P-384"
        case .ecdsaP521: "ECDSA P-521"
        }
    }
}
