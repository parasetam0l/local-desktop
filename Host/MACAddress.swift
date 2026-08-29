import Foundation
import SystemConfiguration

func getPrimaryMACAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }

    var ptr = ifaddr
    var fallbackMac: String? = nil

    while let current = ptr {
        defer { ptr = current.pointee.ifa_next }
        
        let interface = current.pointee
        guard let nameCString = interface.ifa_name else { continue }
        let name = String(cString: nameCString)
        
        if name.hasPrefix("en") {
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_LINK) {
                let sockaddr = unsafeBitCast(interface.ifa_addr, to: UnsafeMutablePointer<sockaddr_dl>.self)
                let nameLen = Int(sockaddr.pointee.sdl_nlen)
                let addrLen = Int(sockaddr.pointee.sdl_alen)
                
                if addrLen == 6 {
                    let macBytes = withUnsafeBytes(of: sockaddr.pointee.sdl_data) { rawPtr -> [UInt8] in
                        let base = rawPtr.baseAddress!.bindMemory(to: UInt8.self, capacity: 256)
                        return Array(UnsafeBufferPointer(start: base + nameLen, count: addrLen))
                    }
                    let macString = macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                    if name == "en0" {
                        return macString
                    } else if fallbackMac == nil {
                        fallbackMac = macString
                    }
                }
            }
        }
    }
    return fallbackMac
}
