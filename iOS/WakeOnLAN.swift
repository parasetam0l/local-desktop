import Foundation
import Network

enum WakeOnLAN {
    static func wake(macAddress: String) {
        let components = macAddress.split(separator: ":")
        guard components.count == 6 else { return }
        
        var macBytes = [UInt8]()
        for hex in components {
            guard let byte = UInt8(hex, radix: 16) else { return }
            macBytes.append(byte)
        }
        
        var magicPacket = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            magicPacket.append(contentsOf: macBytes)
        }
        let payload = Data(magicPacket)
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        guard let port = NWEndpoint.Port(rawValue: 9) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("255.255.255.255"), port: port)
        
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
}
