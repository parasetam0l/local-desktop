import Foundation
import CryptoKit

/// Crypto helpers shared by host and client.
enum RDCrypto {
    static func makePrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return diff == 0
    }
}

/// The v2 handshake:
///
/// 1. Both sides exchange ephemeral X25519 keys (`hello` / `serverHello`).
/// 2. The transcript hash binds both ephemeral keys, the device id, the host's
///    long-term identity key and its server id.
/// 3. The host signs the transcript with its identity key; clients pin that key
///    when they pair, so a different machine can't pose as a paired Mac.
/// 4. Session keys are derived per direction with the transcript as HKDF salt.
/// 5. A paired device proves itself by signing the transcript with its own key,
///    so no reusable secret ever crosses the wire.
enum RDHandshake {
    struct SessionKeys {
        let clientToServer: SymmetricKey
        let serverToClient: SymmetricKey
    }

    static func transcriptHash(clientKey: Data,
                               deviceId: String,
                               serverKey: Data,
                               serverIdentity: Data,
                               serverId: String) -> Data {
        var hasher = SHA256()
        let fields = [Data("rd-handshake-v2".utf8), clientKey, Data(deviceId.utf8),
                      serverKey, serverIdentity, Data(serverId.utf8)]
        for field in fields {
            var length = Data()
            length.appendBE32(UInt32(field.count))
            hasher.update(data: length)
            hasher.update(data: field)
        }
        return Data(hasher.finalize())
    }

    static func sessionKeys(privateKey: Curve25519.KeyAgreement.PrivateKey,
                            peerPublicKey: Data,
                            transcript: Data) -> SessionKeys? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        func derive(_ label: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                           salt: transcript,
                                           sharedInfo: Data(label.utf8),
                                           outputByteCount: 32)
        }
        return SessionKeys(clientToServer: derive("rd-v2 client->server"),
                           serverToClient: derive("rd-v2 server->client"))
    }

    /// Bytes the host signs with its identity key.
    static func serverProof(transcript: Data) -> Data {
        Data("rd-server-auth-v2".utf8) + transcript
    }

    /// Bytes a paired device signs with its device key.
    static func deviceProof(transcript: Data) -> Data {
        Data("rd-device-auth-v2".utf8) + transcript
    }

    /// The server id is derived from the identity key, so a host can't claim
    /// another host's id without also presenting (and signing with) its key.
    static func serverId(for identityKey: Data) -> String {
        RDCrypto.sha256(identityKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Human-comparable fingerprint shown on both the Mac and the iPhone.
    static func fingerprint(of identityKey: Data) -> String {
        let hex = RDCrypto.sha256(identityKey).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    struct HostResponse {
        let serverHello: ServerHelloMsg
        let transcript: Data
        let keys: SessionKeys
    }

    /// The host's half of the handshake: a fresh ephemeral key, the transcript, the
    /// session keys, and a `serverHello` signed with the identity key via `sign`.
    static func respond(to hello: HelloMsg,
                        identityKey: Data,
                        serverId: String,
                        serverName: String,
                        sign: (Data) -> Data?) -> HostResponse? {
        let ephemeral = RDCrypto.makePrivateKey()
        let serverKey = ephemeral.publicKey.rawRepresentation
        let transcript = transcriptHash(clientKey: hello.pubKey,
                                        deviceId: hello.deviceId,
                                        serverKey: serverKey,
                                        serverIdentity: identityKey,
                                        serverId: serverId)
        guard let keys = sessionKeys(privateKey: ephemeral, peerPublicKey: hello.pubKey, transcript: transcript),
              let signature = sign(serverProof(transcript: transcript)) else { return nil }
        let serverHello = ServerHelloMsg(serverId: serverId,
                                         serverName: serverName,
                                         pubKey: serverKey,
                                         identityKey: identityKey,
                                         signature: signature)
        return HostResponse(serverHello: serverHello, transcript: transcript, keys: keys)
    }

    static func isValidSignature(_ signature: Data, publicKey: Data, message: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}
