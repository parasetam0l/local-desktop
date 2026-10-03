import Foundation

// MARK: - Constants

enum RDService {
    static let type = "_rd-desktop._tcp"
    static let protocolVersion = 2
    static let defaultPort: UInt16 = 52341
    static let maxPayload = 32 * 1024 * 1024
    /// Everything exchanged before authentication is a small JSON body; larger
    /// frames are rejected so unauthenticated peers can't make us buffer megabytes.
    static let maxHandshakePayload = 16 * 1024
}

// MARK: - Wire message types

enum RDWire: UInt8 {
    // Handshake / auth
    case hello = 0x01
    case serverHello = 0x02
    case authPin = 0x03
    case authDevice = 0x04
    case authOK = 0x05
    case authFailed = 0x06

    // Video
    case frame = 0x10
    case requestKeyframe = 0x11

    // Mouse
    case mouseMoveAbs = 0x20
    case mouseMoveRel = 0x21
    case mouseDown = 0x22
    case mouseUp = 0x23
    case scroll = 0x24

    // Keyboard
    case keyEvent = 0x30
    case textEvent = 0x31

    // Keepalive & Telemetry
    case ping = 0x40
    case pong = 0x41
    case networkStats = 0x42

    // Session
    case setQuality = 0x50
    case hostState = 0x52
    case wakeDisplay = 0x53
    case bye = 0x60

    // App Switcher & Actions
    case requestApps = 0x70
    case runningApps = 0x71
    case activateApp = 0x72
    case systemAction = 0x73

    // Hardware Controls
    case getHardwareControls = 0x80
    case setHardwareControls = 0x81
    case hardwareControlsState = 0x82
}

// MARK: - Stream framing: [u32 length BE][u8 type][payload]

enum RDFrame {
    static let headerLength = 5

    static func header(_ wire: RDWire, length: Int) -> Data {
        var out = Data(capacity: headerLength)
        out.appendBE32(UInt32(length))
        out.append(wire.rawValue)
        return out
    }

    /// Plaintext frame; only used for `hello`, `serverHello`, and a pre-handshake `authFailed`.
    static func pack(_ wire: RDWire, payload: Data) -> Data {
        var out = header(wire, length: payload.count)
        out.append(payload)
        return out
    }

    /// Parses a frame header. `wire` is nil for message types this build doesn't know;
    /// callers still consume (and decrypt) such frames so the stream stays in sync.
    static func unpackHeader(_ data: Data) -> (wire: RDWire?, length: Int)? {
        guard data.count >= headerLength else { return nil }
        let length = Int(data.be32(at: 0))
        guard length <= RDService.maxPayload else { return nil }
        return (RDWire(rawValue: data[data.startIndex + 4]), length)
    }
}

// MARK: - Video frame payload: [u16 w BE][u16 h BE][u8 codec][Annex-B data]

enum RDCodec: UInt8, CaseIterable, Identifiable {
    case h264 = 1
    case hevc = 2

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        }
    }

    /// Decodes the optional `codec` field of `setQuality`, rejecting out-of-range values.
    static func from(_ raw: Int?) -> RDCodec? {
        raw.flatMap { UInt8(exactly: $0) }.flatMap(RDCodec.init(rawValue:))
    }
}

enum RDFrameCodec {
    static let headerLength = 5

    static func pack(width: Int, height: Int, codec: RDCodec, data: Data) -> Data {
        var out = Data(capacity: headerLength + data.count)
        out.appendBE16(UInt16(clamping: width))
        out.appendBE16(UInt16(clamping: height))
        out.append(codec.rawValue)
        out.append(data)
        return out
    }

    static func unpack(_ payload: Data) -> (width: Int, height: Int, codec: RDCodec, data: Data)? {
        guard payload.count > headerLength else { return nil }
        let width = Int(payload.be16(at: 0))
        let height = Int(payload.be16(at: 2))
        guard let codec = RDCodec(rawValue: payload[payload.startIndex + 4]) else { return nil }
        return (width, height, codec, payload.subdata(in: payload.startIndex + headerLength..<payload.endIndex))
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

    mutating func appendBE64(_ value: UInt64) {
        appendBE32(UInt32(truncatingIfNeeded: value >> 32))
        appendBE32(UInt32(truncatingIfNeeded: value))
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
    /// Ephemeral X25519 public key for this connection.
    var pubKey: Data
}

struct ServerHelloMsg: Codable {
    var version = RDService.protocolVersion
    /// Derived from `identityKey` (see `RDHandshake.serverId(for:)`).
    var serverId: String
    var serverName: String
    /// Ephemeral X25519 public key for this connection.
    var pubKey: Data
    /// The host's long-term Ed25519 public key, pinned by clients when they pair.
    var identityKey: Data
    /// Ed25519 signature over `RDHandshake.serverProof(transcript:)`.
    var signature: Data
}

struct AuthPinMsg: Codable {
    var pin: String
    var trust: Bool
    /// The device's long-term Ed25519 public key, registered on the host when `trust` is set.
    var deviceKey: Data?
}

struct AuthDeviceMsg: Codable {
    /// Ed25519 signature over `RDHandshake.deviceProof(transcript:)` with the paired device key.
    var signature: Data
}

struct AuthOKMsg: Codable {
    var serverName: String
    var trusted: Bool
    /// Primary MAC address, shared only after authentication (used for Wake-on-LAN).
    var macAddress: String?
}

enum RDAuthFailure: String, Codable {
    case incorrectPin
    case lockedOut
    case busy
    case untrusted
    case tooManyAttempts
    case unsupportedVersion
}

struct AuthFailedMsg: Codable {
    var reason: String
    var kind: RDAuthFailure?
    /// Seconds until another PIN attempt is accepted (for `lockedOut`).
    var retryAfter: Double?
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
    /// Lines, or points when `precise` is true. dy > 0 scrolls up (toward the
    /// start of the document), like rolling a mouse wheel away from you.
    var dx: Double
    var dy: Double
    var precise: Bool?
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

struct NetworkStatsMsg: Codable {
    var rttMs: Double
    var decodeMs: Double
    var fps: Double
    var droppedFrames: Int
}

struct RequestKeyframeMsg: Codable {
    var reason: String?
}

struct HostStateMsg: Codable {
    var isLocked: Bool
    var isDisplaySleeping: Bool
}

struct SetQualityMsg: Codable {
    var preset: Int
    var cursor: Bool?   // true = show real Mac cursor in stream, false/nil = hide it
    var codec: Int?     // RDCodec rawValue (1 = h264, 2 = hevc)
}

enum RDByeReason {
    static let userDisconnect = "user_disconnect"
    /// The host stopped sharing; clients should not reconnect on their own.
    static let hostStopped = "host_stopped"
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
    case key5 = 23
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

struct RDModifiers: OptionSet, Hashable {
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
        case .low: return "Low (30 FPS)"
        case .balanced: return "Balanced (60 FPS)"
        case .high: return "High (60 FPS)"
        case .sharp: return "Sharp (Native 60 FPS)"
        }
    }

    var shortLabel: String {
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

    var fps: Int {
        switch self {
        case .low: return 30
        case .balanced, .high, .sharp: return 60
        }
    }

    var targetBitrate: Int {
        switch self {
        case .low: return 8_000_000
        case .balanced: return 20_000_000
        case .high: return 36_000_000
        case .sharp: return 50_000_000
        }
    }

    static func from(_ raw: Int) -> RDQualityPreset {
        RDQualityPreset(rawValue: raw) ?? .high
    }
}

// MARK: - App Switcher

struct RDRunningApp: Codable, Identifiable, Equatable {
    var id: String { bundleId }
    let bundleId: String
    let name: String
    let isActive: Bool
    let isHidden: Bool
    let iconPNG: String?
}

struct RDRunningAppsMsg: Codable {
    let apps: [RDRunningApp]
}

struct RDActivateAppMsg: Codable {
    let bundleId: String
}

enum RDSystemActionType: String, Codable {
    case showDesktop
    case missionControl
    case launchpad
    case lockScreen
}

struct RDSystemActionMsg: Codable {
    let action: RDSystemActionType
}

// MARK: - Hardware Controls

struct RDHardwareControls: Codable, Equatable {
    var brightness: Float // 0.0 ... 1.0
    var volume: Int       // 0 ... 100
    var isMuted: Bool
}

struct RDSetHardwareControlsMsg: Codable {
    var brightness: Float?
    var volume: Int?
    var isMuted: Bool?
    var sleepDisplay: Bool?
    var lockScreen: Bool?
}
