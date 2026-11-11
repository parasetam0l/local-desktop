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
    /// Client → host: `[frame u32]` big-endian, the highest video frame number received
    /// (frames are numbered from 1 per connection; over the stream alone that is the
    /// count received), sent for every frame (clients from 1.2.29).
    case frameAck = 0x12
    /// Client → host, QUIC only, after `authOK`: `{maxSize}`, the client takes video as
    /// datagrams (`RDVideoDatagram`) from now on (from 1.2.29).
    case videoDatagrams = 0x13
    /// Client → host, after `authOK`: `{quicFallback}`, why this connection left QUIC
    /// for TCP, for the host's log (from 1.2.29).
    case transportNote = 0x14

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
    case displays = 0x54
    case selectDisplay = 0x55
    case setLocalInputBlock = 0x56
    case setSizedMirror = 0x57
    case setHideDock = 0x58
    case textFocus = 0x59
    case setTextFocusReports = 0x5A
    case setClipboardSharing = 0x5B
    case clipboard = 0x5C
    case clipboardImage = 0x5D
    case bye = 0x60

    // App Switcher & Actions
    case requestApps = 0x70
    case runningApps = 0x71
    case activateApp = 0x72
    case systemAction = 0x73
    case requestFrontWindow = 0x74
    case frontWindow = 0x75

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

struct TransportNoteMsg: Codable {
    /// The client's reason and QUIC event trace, at most 1,000 characters.
    var quicFallback: String
}

struct VideoDatagramsMsg: Codable {
    /// The largest datagram the client's QUIC connection accepts.
    var maxSize: Int
}

struct RequestKeyframeMsg: Codable {
    var reason: String?
}

struct HostStateMsg: Codable, Equatable {
    /// macOS calls the screen locked as soon as the display sleeps, even when no password
    /// is due yet and the next input just wakes it. So a lock only counts once the display
    /// is awake and still locked; until then clients show that the display is sleeping.
    static func reportsLocked(isLocked: Bool, isDisplaySleeping: Bool) -> Bool {
        isLocked && !isDisplaySleeping
    }

    var isLocked: Bool
    var isDisplaySleeping: Bool
    /// Whether the Mac blocks its own keyboard and trackpad while devices are connected
    /// (nil from Macs before 1.2.4, which can't).
    var blocksLocalInput: Bool? = nil
    /// Whether this MacBook's lid is shut (nil from older Macs, which don't say).
    var isLidClosed: Bool? = nil
    /// Whether a display other than the built-in one is active, i.e. a closed lid can
    /// still be used in clamshell mode (nil from older Macs, which don't say).
    var hasExternalDisplay: Bool? = nil
    /// Whether the Mac hides its Dock for the connected clients (nil from Macs before
    /// 1.2.13, or when this macOS can't).
    var hidesDock: Bool? = nil
    /// Whether the Mac takes the `window…` system actions (nil from Macs before 1.2.16).
    var windowActions: Bool? = nil
    /// Whether the Mac's Caps Lock is on, so the key bar's caps key can light up like the
    /// keyboard's own light (nil from older Macs, which don't say).
    var capsLock: Bool? = nil
}

/// After a click from a client that asked for these reports: whether the Mac's keyboard
/// focus is now in something to type into, so the client can show or hide its keyboard.
struct RDTextFocusMsg: Codable {
    let editable: Bool
}

/// Turns the `textFocus` reports on or off for this client (off until asked).
struct RDSetTextFocusReportsMsg: Codable {
    let enabled: Bool
}

/// Turns clipboard sharing on or off for this client (off until asked; from 1.2.21). Only while
/// it is on does the Mac send this client its clipboard changes and take the client's clipboard.
struct RDSetClipboardSharingMsg: Codable {
    let enabled: Bool
}

/// Plain text copied on one side during a session, to put on the other side's clipboard (from 1.2.21).
struct RDClipboardMsg: Codable {
    let text: String

    /// Largest encoded `clipboard` body either side sends (the host's limit for client messages).
    static let maxPayload = 1024 * 1024

    /// The encoded body for `text`, or nil when it is empty or too large to share.
    static func payload(for text: String) -> Data? {
        guard !text.isEmpty, text.utf8.count <= maxPayload else { return nil }
        let data = RDJSON.encode(RDClipboardMsg(text: text))
        guard !data.isEmpty, data.count <= maxPayload else { return nil }
        return data
    }
}

/// An image copied on one side during a session, sent as PNG (JPEG for a photo copied as JPEG,
/// or one too large as PNG) in binary pieces small enough
/// for the host's 1 MB limit on client messages (from 1.2.21). Each piece is
/// `[id u32][index u16][count u16][image bytes]`, big-endian; the pieces of one image share
/// an id and are sent back to back, in order.
enum RDClipboardImage {
    static let headerLength = 8
    static let chunkSize = 512 * 1024
    /// Larger images aren't shared.
    static let maxSize = 20 * 1024 * 1024

    /// Whether `data` starts with the PNG signature (otherwise it is JPEG).
    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    /// The pieces to send for `png`, or nil when it is empty or larger than `maxSize`.
    static func chunks(of png: Data, id: UInt32) -> [Data]? {
        guard !png.isEmpty, png.count <= maxSize else { return nil }
        let count = (png.count + chunkSize - 1) / chunkSize
        return (0..<count).map { index in
            let start = png.startIndex + index * chunkSize
            let end = min(start + chunkSize, png.endIndex)
            var chunk = Data(capacity: headerLength + end - start)
            chunk.appendBE32(id)
            chunk.appendBE16(UInt16(index))
            chunk.appendBE16(UInt16(count))
            chunk.append(png[start..<end])
            return chunk
        }
    }
}

/// Puts the pieces of a `clipboardImage` back together. A piece that doesn't follow the
/// previous one drops the image being assembled; a first piece starts a new one.
struct RDClipboardImageAssembler {
    private var id: UInt32 = 0
    private var nextIndex = 0
    private var count = 0
    private var data = Data()

    /// The whole PNG once its last piece arrives, otherwise nil.
    mutating func add(_ chunk: Data) -> Data? {
        let maxCount = (RDClipboardImage.maxSize + RDClipboardImage.chunkSize - 1) / RDClipboardImage.chunkSize
        guard chunk.count > RDClipboardImage.headerLength else { reset(); return nil }
        let chunkId = chunk.be32(at: 0)
        let index = Int(chunk.be16(at: 4))
        let chunkCount = Int(chunk.be16(at: 6))
        guard chunkCount > 0, chunkCount <= maxCount, index < chunkCount else { reset(); return nil }
        if index == 0 {
            reset()
            id = chunkId
            count = chunkCount
        } else if chunkId != id || index != nextIndex || chunkCount != count {
            reset()
            return nil
        }
        data.append(chunk[(chunk.startIndex + RDClipboardImage.headerLength)...])
        guard data.count <= RDClipboardImage.maxSize else { reset(); return nil }
        nextIndex = index + 1
        guard nextIndex == count else { return nil }
        let png = data
        reset()
        return png
    }

    mutating func reset() {
        id = 0
        nextIndex = 0
        count = 0
        data = Data()
    }
}

/// Asks the Mac to hide its Dock (the Dock's own auto-hide) until the last client leaves,
/// or to show it again. It applies to every client; answered with `hostState`.
struct RDSetHideDockMsg: Codable {
    let enabled: Bool
}

/// Turns the Mac's setting for blocking its own keyboard and trackpad during remote
/// sessions on or off. It applies to every client, like the switch in the Mac's menu.
struct RDSetLocalInputBlockMsg: Codable {
    let enabled: Bool
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
    case home = 115
    case end = 119
    case pageUp = 116
    case pageDown = 121
    case up = 126
    case down = 125
    case left = 123
    case right = 124
    case key5 = 23
    case keyF = 3
    case keyA = 0
    case keyC = 8
    case keyV = 9
    case keyX = 7
    case keyZ = 6
    case keyW = 13
    case grave = 50
    case forwardDelete = 117
    case f1 = 122, f2 = 120, f3 = 99, f4 = 118, f5 = 96, f6 = 97
    case f7 = 98, f8 = 100, f9 = 101, f10 = 109, f11 = 103, f12 = 111

    static let functionKeys: [RDKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
    case capsLock = 57
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

/// The front app's focused window, for the window controls (Macs from 1.2.16). Sent in
/// answer to `requestFrontWindow` and again after a `window…` system action.
struct RDFrontWindowMsg: Codable, Equatable {
    let app: String
    /// Nil when the app has no window to act on.
    let title: String?
    let isFullScreen: Bool
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
    /// The front app's focused window (Macs from 1.2.16, see `HostStateMsg.windowActions`).
    case windowClose
    case windowMinimize
    case windowFullScreen
    case windowLeftHalf
    case windowRightHalf
    case windowFill
}

struct RDSystemActionMsg: Codable {
    let action: RDSystemActionType
}

// MARK: - Displays

/// One of the Mac's displays. Sizes are in points, as macOS lists them.
struct RDDisplay: Codable, Equatable, Identifiable {
    let id: UInt32          // CGDirectDisplayID
    let name: String        // e.g. "Built-in Retina Display"
    let width: Int
    let height: Int
    let isMain: Bool        // the one with the menu bar

    var resolution: String { "\(width)×\(height)" }
}

/// The Mac's displays and the one being streamed. The host sends it after
/// authentication and whenever either changes.
struct RDDisplaysMsg: Codable, Equatable {
    let displays: [RDDisplay]
    let selectedId: UInt32?
    /// Whether the Mac can lay its desktop out at a client's size (nil before 1.2.12).
    var sizedMirrorAvailable: Bool?
    /// The size the desktop is laid out at while that mode is on.
    var mirrorSize: RDMirrorSize?
}

/// A desktop size in points.
struct RDMirrorSize: Codable, Equatable, Hashable {
    let width: Int
    let height: Int

    var label: String { "\(width)×\(height)" }
}

extension RDMirrorSize {
    /// macOS draws a desktop with a shorter side than this without Retina, at twice the
    /// size asked for (seen on macOS 27 with 393 and 480 points; 558 is fine).
    static let shortestSide = 540
    static let longestSide = 2732

    /// Lying the way `area` does: taller than wide in portrait, wider than tall otherwise.
    func oriented(like area: CGSize) -> RDMirrorSize {
        (area.height > area.width) == (height > width) ? self : RDMirrorSize(width: height, height: width)
    }

    /// A desktop with the proportions of `area` (the room the picture has on the device,
    /// in points) at `percent` of its size, so the picture fills that room without bars.
    /// The scale gives way where the limits above need it; nil when `area` is empty.
    static func filling(_ area: CGSize, percent: Int) -> RDMirrorSize? {
        let short = Double(min(area.width, area.height))
        let long = Double(max(area.width, area.height))
        guard short >= 1 else { return nil }
        var scale = Double(percent) / 100
        scale = max(scale, Double(shortestSide) / short)
        scale = min(scale, Double(longestSide) / long)
        return RDMirrorSize(width: Int((Double(area.width) * scale).rounded()),
                            height: Int((Double(area.height) * scale).rounded()))
    }
}

/// Asks the host to lay the desktop out at `size` (the Mac's own screen mirrors it for
/// the session), or to go back to the Mac's own layout when `size` is nil. Like
/// `selectDisplay` it applies to every connected client.
struct RDSetSizedMirrorMsg: Codable {
    let size: RDMirrorSize?
}

/// Asks the host to stream another display. It applies to every connected client,
/// like choosing it in the Mac's menu.
struct RDSelectDisplayMsg: Codable {
    let id: UInt32
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
