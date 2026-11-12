import Foundation
import Network
import CryptoKit
import Security

/// The two transports that carry the byte protocol. Both are plain reliable byte
/// streams to the code above them (an `NWConnection`): TCP, or a single
/// bidirectional QUIC stream. Framing, the handshake and encryption are identical.
enum RDTransport: String, Sendable {
    case tcp
    case quic
}

/// QUIC transport settings shared by host and client (from 1.2.29).
///
/// SECURITY: QUIC always runs TLS 1.3, but we do **not** rely on it for trust. The
/// host presents a self-signed certificate and the client accepts any certificate.
/// Authenticity and secrecy come from our own handshake on top, unchanged from TCP:
/// the host's identity-key signature over the transcript, PIN pairing, the device
/// signature, and the session keys it derives (`RDHandshake`, `RDCipher`). TLS here
/// only adds a second, unauthenticated layer of encryption.
enum RDQUIC {
    static let alpn = "localdesktop/1"

    /// Bonjour TXT keys: `quic=1` when the host listens for QUIC, and `qport` with the
    /// UDP port when it differs from the advertised TCP port.
    static let txtFlag = "quic"
    static let txtPort = "qport"

    /// How long the client waits for a QUIC connection to become ready before it
    /// falls back to TCP.
    static let fallbackDelay: TimeInterval = 1.0

    /// Client parameters: accepts any server certificate (see the type's note).
    static func clientParameters(verifyQueue: DispatchQueue) -> NWParameters {
        parameters(clientOptions(verifyQueue: verifyQueue))
    }

    /// Options for a datagram flow (`NWConnection(from:using:)`) on `group`: the group's
    /// own QUIC options object with `isDatagram` set. A fresh options object, even one
    /// built the same way, made macOS 26 and iOS 17 try a separate path that failed with
    /// "Network is down", so video stayed on the stream; macOS 27 accepted either. Set
    /// only after the group's streams exist, since the flag lives on the shared object.
    static func datagramFlowOptions(for group: NWConnectionGroup) -> NWProtocolQUIC.Options? {
        guard let options = group.parameters.defaultProtocolStack.transportProtocol as? NWProtocolQUIC.Options
        else { return nil }
        options.isDatagram = true
        return options
    }

    private static func clientOptions(verifyQueue: DispatchQueue) -> NWProtocolQUIC.Options {
        let options = makeOptions()
        // As tested with the host's group listener (0 kept the host's group from becoming ready).
        options.initialMaxStreamsBidirectional = 1
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
            // Trust comes from our handshake on top, never from this certificate.
            complete(true)
        }, verifyQueue)
        return options
    }

    /// Host parameters: presents `identity` (a self-signed certificate).
    static func serverParameters(identity: SecIdentity) -> NWParameters? {
        serverOptions(identity: identity).map(parameters)
    }

    private static func serverOptions(identity: SecIdentity) -> NWProtocolQUIC.Options? {
        guard let secIdentity = sec_identity_create(identity) else { return nil }
        let options = makeOptions()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        // The control stream that carries the whole protocol. A connection group client
        // (`NWMultiplexGroup`) holds stream 0 open without using it and opens its own
        // next, and may replace a control stream that failed once; the host takes the
        // first stream that becomes ready.
        options.initialMaxStreamsBidirectional = 3
        options.initialMaxStreamsUnidirectional = 0
        return options
    }

    private static func makeOptions() -> NWProtocolQUIC.Options {
        let options = NWProtocolQUIC.Options(alpn: [alpn])
        // Longer than any silence our protocol allows (the host waits up to 120 s for a
        // PIN with no traffic), so QUIC never ends a connection TCP would have kept; our
        // own pings and timeouts detect a dead peer, this only reaps leftovers.
        options.idleTimeout = 150_000
        // Generous flow-control windows so a keyframe never waits on window updates.
        options.initialMaxData = 32 << 20
        options.initialMaxStreamDataBidirectionalLocal = 16 << 20
        options.initialMaxStreamDataBidirectionalRemote = 16 << 20
        // Enables QUIC datagrams (RFC 9221) for video (`RDVideoDatagram`).
        options.maxDatagramFrameSize = 65_535
        return options
    }

    private static func parameters(_ options: NWProtocolQUIC.Options) -> NWParameters {
        let params = NWParameters(quic: options)
        // Asks Wi-Fi to give this connection's packets the low-delay video queue.
        params.serviceClass = .interactiveVideo
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        return params
    }
}

/// What a host's Bonjour TXT record says about QUIC.
enum RDQUICAdvert: Equatable, Sendable {
    /// UDP on the same port number as the advertised TCP port.
    case samePort
    /// UDP on this port.
    case port(UInt16)

    init?(txt: NWTXTRecord) {
        guard txt[RDQUIC.txtFlag] == "1" else { return nil }
        if let raw = txt[RDQUIC.txtPort], let port = UInt16(raw) {
            self = .port(port)
        } else {
            self = .samePort
        }
    }

    /// Where to try QUIC for a host reached over TCP at `tcp`; nil when that can't be
    /// derived (a Bonjour service endpoint whose UDP port differs: TCP only).
    func endpoint(forTCP tcp: NWEndpoint) -> NWEndpoint? {
        switch (self, tcp) {
        case (.samePort, _):
            return tcp
        case (.port(let port), .hostPort(let host, _)):
            guard let udp = NWEndpoint.Port(rawValue: port) else { return nil }
            return .hostPort(host: host, port: udp)
        default:
            return nil
        }
    }
}

/// A minimal self-signed X.509 certificate for the host's QUIC/TLS identity, built
/// with public APIs only (CryptoKit + `SecIdentityCreate`). The certificate carries
/// no trust (see `RDQUIC`); it exists because TLS 1.3 requires the server to have one.
enum RDSelfSignedIdentity {
    /// A DER certificate for `key`, signed by itself.
    static func makeCertificate(for key: P256.Signing.PrivateKey,
                                commonName: String = "LocalDesktop") throws -> Data {
        let ecdsaWithSHA256: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
        let idECPublicKey: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        let prime256v1: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        let commonNameOID: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]

        let name = der(0x30, der(0x31, der(0x30, Data(commonNameOID) + der(0x0C, Data(commonName.utf8)))))
        var serial = Data([0x01])
        serial.append(contentsOf: (0..<8).map { _ in UInt8.random(in: 0...255) })
        let validity = der(0x30, der(0x17, Data("250101000000Z".utf8)) + der(0x17, Data("491231235959Z".utf8)))
        let spki = der(0x30, der(0x30, Data(idECPublicKey) + Data(prime256v1))
                       + der(0x03, Data([0x00]) + key.publicKey.x963Representation))
        let signatureAlgorithm = der(0x30, Data(ecdsaWithSHA256))

        let tbs = der(0x30,
                      der(0xA0, der(0x02, Data([0x02])))   // version v3
                      + der(0x02, serial)
                      + signatureAlgorithm
                      + name                                // issuer
                      + validity
                      + name                                // subject
                      + spki)
        let signature = try key.signature(for: tbs).derRepresentation
        return der(0x30, tbs + signatureAlgorithm + der(0x03, Data([0x00]) + signature))
    }

    /// An in-memory identity (no keychain) from a key and its certificate; nil when they
    /// don't belong together or don't parse.
    static func identity(key: P256.Signing.PrivateKey, certificate: Data) -> SecIdentity? {
        guard let cert = SecCertificateCreateWithData(nil, certificate as CFData) else { return nil }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                         kSecAttrKeySizeInBits as String: 256]
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData,
                                                attributes as CFDictionary, nil) else { return nil }
        return SecIdentityCreate(nil, cert, secKey)
    }

    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else if count <= 0xFF {
            out.append(contentsOf: [0x81, UInt8(count)])
        } else {
            out.append(contentsOf: [0x82, UInt8(count >> 8), UInt8(count & 0xFF)])
        }
        out.append(content)
        return out
    }
}
