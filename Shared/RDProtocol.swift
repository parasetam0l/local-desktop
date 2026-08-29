import Foundation

// MARK: - Constants

enum RDService {
    static let type = "_rd-desktop._tcp"
    static let protocolVersion = 1
    static let maxPayload = 32 * 1024 * 1024
}

// MARK: - Wire message types

enum RDWire: UInt8 {
    // Handshake / auth
    case hello = 0x01
    case serverHello = 0x02
    case authPin = 0x03
    case authToken = 0x04
    case authOK = 0x05
    case authFailed = 0x06

    // Video
    case frame = 0x10

    // Mouse
    case mouseMoveAbs = 0x20
    case mouseMoveRel = 0x21
    case mouseDown = 0x22
    case mouseUp = 0x23
    case scroll = 0x24

    // Keyboard
    case keyEvent = 0x30
    case textEvent = 0x31

    // Keepalive
    case ping = 0x40
    case pong = 0x41

    // Session
    case setQuality = 0x50
    case bye = 0x60
}

// MARK: - Stream framing: [u32 length BE][u8 type][payload]

enum RDFrame {
    static let headerLength = 5

    static func pack(_ wire: RDWire, payload: Data) -> Data {
        var out = Data(capacity: RDFrame.headerLength + payload.count)
        out.appendBE32(UInt32(payload.count))
        out.append(UInt8(wire.rawValue))
        out.append(payload)
        return out
    }

    static func unpackHeader(_ data: Data) -> (wire: RDWire, length: Int)? {
        guard data.count >= RDFrame.headerLength else { return nil }
        let length = Int(data.be32(at: 0))
        guard let wire = RDWire(rawValue: data[data.startIndex + 4]), length <= RDService.maxPayload else { return nil }
        return (wire, length)
    }
}

// MARK: - Video frame payload: [u16 w BE][u16 h BE][u8 codec][pixels]

enum RDCodec: UInt8 {
    case jpeg = 0
    case h264 = 1
}

enum RDFrameCodec {
    static func pack(width: Int, height: Int, codec: RDCodec, data: Data) -> Data {
        var out = Data(capacity: 5 + data.count)
        out.appendBE16(UInt16(clamping: width))
        out.appendBE16(UInt16(clamping: height))
        out.append(codec.rawValue)
        out.append(data)
        return out
    }

    static func unpack(_ payload: Data) -> (width: Int, height: Int, codec: RDCodec, data: Data)? {
        guard payload.count > 5 else { return nil }
        let width = Int(payload.be16(at: 0))
        let height = Int(payload.be16(at: 2))
        guard let codec = RDCodec(rawValue: payload[4]) else { return nil }
        return (width, height, codec, payload.subdata(in: 5..<payload.count))
    }
}

// MARK: - Data helpers

extension Data {
    mutating func appendBE16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func be16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) << 8 | UInt16(self[startIndex + offset + 1])
    }

    func be32(at offset: Int) -> UInt32 {
        (UInt32(self[startIndex + offset]) << 24)
            | (UInt32(self[startIndex + offset + 1]) << 16)
            | (UInt32(self[startIndex + offset + 2]) << 8)
            | UInt32(self[startIndex + offset + 3])
    }
}

// MARK: - JSON

enum RDJSON {
    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Message bodies

struct HelloMsg: Codable {
    var version = RDService.protocolVersion
    var deviceId: String
    var deviceName: String
    var pubKey: Data
}

struct ServerHelloMsg: Codable {
    var version = RDService.protocolVersion
    var serverId: String
    var serverName: String
    var pubKey: Data
    var requiresPin: Bool
    var macAddress: String?
}

struct AuthPinMsg: Codable {
    var pin: String
    var trust: Bool
}

struct AuthTokenMsg: Codable {
    var token: Data
}

struct AuthOKMsg: Codable {
    var serverName: String
    var trusted: Bool
    var token: Data?
}

struct AuthFailedMsg: Codable {
    var reason: String
}

struct MouseMoveAbsMsg: Codable {
    var x: Double
    var y: Double
}

struct MouseMoveRelMsg: Codable {
    var dx: Double
    var dy: Double
}

struct MouseButtonMsg: Codable {
    var button: Int // 0 = left, 1 = right
}

struct ScrollMsg: Codable {
    var dx: Double
    var dy: Double
}

struct KeyEventMsg: Codable {
    var code: UInt16 // Mac virtual key code
    var down: Bool
    var flags: UInt8 // RDModifiers raw value
}

struct TextMsg: Codable {
    var s: String
}

struct PingMsg: Codable {
    var t: Double
}

struct SetQualityMsg: Codable {
    var preset: Int
    var cursor: Bool?   // true = show real Mac cursor in stream, false/nil = hide it
}

struct ByeMsg: Codable {
    var reason: String?
}

// MARK: - Mac virtual key codes

enum RDKey: UInt16 {
    case space = 49
    case returnKey = 36
    case escape = 53
    case tab = 48
    case delete = 51
    case forwardDelete = 117
    case home = 115
    case end = 119
    case pageUp = 116
    case pageDown = 121
    case up = 126
    case down = 125
    case left = 123
    case right = 124
    case f1 = 122
    case f2 = 120
    case f3 = 99
    case f4 = 118
    case f5 = 96
    case f6 = 97
    case f7 = 98
    case f8 = 100
    case f9 = 101
    case f10 = 109
    case f11 = 103
    case f12 = 111
}

struct RDModifiers: OptionSet {
    let rawValue: UInt8
    static let shift = RDModifiers(rawValue: 1 << 0)
    static let control = RDModifiers(rawValue: 1 << 1)
    static let option = RDModifiers(rawValue: 1 << 2)
    static let command = RDModifiers(rawValue: 1 << 3)
}

// MARK: - Quality presets

enum RDQualityPreset: Int, CaseIterable, Identifiable {
    case low = 0
    case balanced = 1
    case high = 2
    case sharp = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .balanced: return "Balanced"
        case .high: return "High"
        case .sharp: return "Sharp"
        }
    }

    /// Longest allowed image edge in pixels; 0 = native Retina resolution.
    var maxDimension: Int {
        switch self {
        case .low: return 1280
        case .balanced: return 1920
        case .high: return 2560
        case .sharp: return 0
        }
    }

    var jpegQuality: Double {
        switch self {
        case .low: return 0.4
        case .balanced: return 0.6
        case .high: return 0.8
        case .sharp: return 0.95
        }
    }

    var fps: Int {
        switch self {
        case .low: return 30
        case .balanced: return 60
        case .high: return 60
        case .sharp: return 60
        }
    }

    var targetBitrate: Int {
        switch self {
        case .low: return 8_000_000
        case .balanced: return 24_000_000
        case .high: return 48_000_000
        case .sharp: return 120_000_000
        }
    }

    static func from(_ raw: Int) -> RDQualityPreset {
        RDQualityPreset(rawValue: raw) ?? .balanced
    }
}
