import Foundation
import Network

/// Sends Wake-on-LAN magic packets for a Mac.
///
/// iOS only lets apps send to the broadcast address with the
/// `com.apple.developer.networking.multicast` entitlement (which Apple grants on
/// request), so the packet also goes by unicast to the Mac's last known address.
/// That works while the Wi-Fi router still knows the Mac's MAC address, and a
/// Bonjour Sleep Proxy will wake the Mac when the connection attempt follows.
enum WakeOnLAN {
    private static let queue = DispatchQueue(label: "rd.wol", qos: .utility)

    static func wake(macAddress: String, lastKnownHost: String?) {
        guard let payload = magicPacket(for: macAddress) else { return }
        send(payload, to: "255.255.255.255")
        if let lastKnownHost {
            send(payload, to: lastKnownHost)
        }
    }

    static func magicPacket(for macAddress: String) -> Data? {
        let components = macAddress.split(separator: ":")
        guard components.count == 6 else { return nil }
        var macBytes = [UInt8]()
        for hex in components {
            guard let byte = UInt8(hex, radix: 16) else { return nil }
            macBytes.append(byte)
        }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }
        return Data(packet)
    }

    private static func send(_ payload: Data, to host: String) {
        guard let port = NWEndpoint.Port(rawValue: 9) else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: port), using: parameters)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .failed, .waiting:
                connection.cancel()
            case .cancelled:
                // Break the connection ↔ handler reference cycle.
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Never leave an attempt hanging if it neither succeeds nor fails.
        queue.asyncAfter(deadline: .now() + 3) {
            connection.cancel()
        }
    }
}
