// Minimal parser for unencrypted OpenSSH ed25519 private keys (the
// `openssh-key-v1` container behind `-----BEGIN OPENSSH PRIVATE KEY-----`),
// following gterm's approach: verify magic + "none" cipher/kdf + matching
// checkints, then take the first 32 bytes of the 64-byte ed25519 secret as
// the Curve25519 seed. Encrypted keys and other algorithms are rejected.

import Crypto
import Foundation
import NIOSSH

public enum SSHKeyError: Error, CustomStringConvertible {
    case notOpenSSHKey
    case encryptedKeyUnsupported
    case unsupportedAlgorithm(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .notOpenSSHKey:
            "Not an OpenSSH private key (expected -----BEGIN OPENSSH PRIVATE KEY-----)"
        case .encryptedKeyUnsupported:
            "Passphrase-protected keys are not supported yet — export an unencrypted key"
        case .unsupportedAlgorithm(let algo):
            "Unsupported key algorithm \(algo) — only ssh-ed25519 is supported"
        case .malformed(let reason):
            "Malformed key: \(reason)"
        }
    }
}

public enum SSHKeyParser {
    public static func parseED25519(openSSHPrivateKey text: String) throws -> NIOSSHPrivateKey {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.contains("BEGIN OPENSSH PRIVATE KEY") == true,
              lines.last?.contains("END OPENSSH PRIVATE KEY") == true
        else { throw SSHKeyError.notOpenSSHKey }

        let base64 = lines.dropFirst().dropLast().joined()
        guard let blob = Data(base64Encoded: base64) else {
            throw SSHKeyError.malformed("bad base64 body")
        }

        var reader = BlobReader(blob)
        let magic = "openssh-key-v1\0"
        guard let head = reader.bytes(magic.utf8.count),
              String(decoding: head, as: UTF8.self) == magic
        else { throw SSHKeyError.notOpenSSHKey }

        guard let cipher = reader.string(), let kdf = reader.string(), reader.lengthPrefixed() != nil else {
            throw SSHKeyError.malformed("truncated header")
        }
        guard cipher == "none", kdf == "none" else {
            throw SSHKeyError.encryptedKeyUnsupported
        }
        guard let keyCount = reader.uint32(), keyCount == 1 else {
            throw SSHKeyError.malformed("expected exactly one key")
        }
        guard reader.lengthPrefixed() != nil else {
            throw SSHKeyError.malformed("missing public key blob")
        }
        guard let privateSection = reader.lengthPrefixed() else {
            throw SSHKeyError.malformed("missing private section")
        }

        var priv = BlobReader(privateSection)
        guard let check1 = priv.uint32(), let check2 = priv.uint32(), check1 == check2 else {
            throw SSHKeyError.malformed("checkint mismatch (encrypted key?)")
        }
        guard let algo = priv.string() else {
            throw SSHKeyError.malformed("missing key type")
        }
        guard algo == "ssh-ed25519" else {
            throw SSHKeyError.unsupportedAlgorithm(algo)
        }
        guard priv.lengthPrefixed() != nil, let secret = priv.lengthPrefixed(), secret.count == 64 else {
            throw SSHKeyError.malformed("bad ed25519 secret length")
        }

        let seed = secret.prefix(32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return NIOSSHPrivateKey(ed25519Key: key)
    }
}

/// Big-endian length-prefixed reader for SSH wire-format blobs.
private struct BlobReader {
    private let blob: Data
    private var offset = 0

    init(_ blob: Data) { self.blob = blob }

    mutating func bytes(_ count: Int) -> Data? {
        guard offset + count <= blob.count else { return nil }
        defer { offset += count }
        return blob.subdata(in: (blob.startIndex + offset) ..< (blob.startIndex + offset + count))
    }

    mutating func uint32() -> UInt32? {
        guard let raw = bytes(4) else { return nil }
        return raw.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func lengthPrefixed() -> Data? {
        guard let length = uint32() else { return nil }
        return bytes(Int(length))
    }

    mutating func string() -> String? {
        guard let raw = lengthPrefixed() else { return nil }
        return String(data: raw, encoding: .utf8)
    }
}
