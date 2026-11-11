import Foundation
import CryptoKit
import Security

/// The host's TLS identity for QUIC: a P-256 key and a self-signed certificate, made
/// once and kept in Application Support beside `identity.key` (0600 files, not the
/// Keychain, for the same reason as `AuthStore`'s identity key).
///
/// This identity carries no trust: clients accept any certificate, and the host is
/// authenticated by its Curve25519 identity key in our own handshake (see `RDQUIC`).
/// Losing or regenerating these files therefore changes nothing for paired devices.
enum QUICIdentityStore {
    static func loadOrCreate() -> SecIdentity? {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("localdesktop.host", isDirectory: true)
        let keyFile = dir.appendingPathComponent("quic-tls.key")
        let certFile = dir.appendingPathComponent("quic-tls.cer")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])

        if let keyData = try? Data(contentsOf: keyFile),
           let certData = try? Data(contentsOf: certFile),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: keyData),
           let identity = RDSelfSignedIdentity.identity(key: key, certificate: certData) {
            return identity
        }
        let key = P256.Signing.PrivateKey()
        guard let certData = try? RDSelfSignedIdentity.makeCertificate(for: key),
              let identity = RDSelfSignedIdentity.identity(key: key, certificate: certData) else {
            HostLog.write("QUIC: could not create the TLS identity; TCP only")
            return nil
        }
        try? fm.removeItem(at: keyFile)
        try? fm.removeItem(at: certFile)
        fm.createFile(atPath: keyFile.path, contents: key.rawRepresentation,
                      attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: certFile.path, contents: certData,
                      attributes: [.posixPermissions: 0o600])
        return identity
    }
}
