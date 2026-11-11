import Foundation
import Network
import UIKit
import Combine

struct RecentHost: Codable, Identifiable, Equatable {
    var id: String {
        if !serverId.isEmpty { return serverId }
        if let mac = macAddress, !mac.isEmpty { return mac }
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }
    var name: String
    var serverId: String
    var host: String
    var port: UInt16
    var lastUsed: Date
    var macAddress: String?
}

struct AppSettings: Codable {
    var autoConnect = false
    var autoReconnect = true
    var defaultTouchpad = true
    var qualityRaw = RDQualityPreset.sharp.rawValue
    var codecRaw = RDCodec.hevc.rawValue
    var showRemoteCursor = false
    var showScrollHelpers = true
    var pointerSpeedMultiplier: Double = 1.5
    /// Optional so settings saved before it existed still decode.
    var zoomLocked: Bool? = nil
    /// The `UIInterfaceOrientation` the app stays in; nil turns with the device.
    var lockedOrientation: Int? = nil
    var oneFingerScroll: Bool? = nil
    /// The desktop size sessions start with, when it is one of the standard sizes.
    var defaultMirrorSize: RDMirrorSize? = nil
    /// The desktop size sessions start with, when it follows this device's screen: a
    /// percentage of the picture's area. Both nil is the Mac's own size.
    var defaultDeviceSizePercent: Int? = nil
    /// Sessions start with the Mac's Dock hidden. Optional so older settings decode.
    var hideDock: Bool? = nil
    /// The keyboard opens when a tap lands in a text field on the Mac (on unless turned off).
    var autoKeyboard: Bool? = nil
    /// Sessions share the clipboard with the Mac (off unless turned on).
    var shareClipboard: Bool? = nil
    /// Sessions hide the status bar and dim the home indicator (on unless turned off).
    var fullScreen: Bool? = nil
    /// How opaque the collapsed session controls' handle is, 0.2 to 1 (0.85 unless changed).
    var handleOpacity: Double? = nil
    /// How big the handle is: 1 small (the default), 1.4 medium, 1.8 large.
    var handleScale: Double? = nil
    /// Ids of the key bar's favourite keys; nil until the user changes the default set.
    var favouriteKeys: [String]? = nil

    /// Pinch doesn't zoom, and a two-finger drag always scrolls the Mac.
    var isZoomLocked: Bool {
        get { zoomLocked ?? false }
        set { zoomLocked = newValue }
    }

    /// In direct mode a one-finger drag scrolls the Mac, and touch-and-hold then drag
    /// is the mouse drag.
    var isOneFingerScroll: Bool {
        get { oneFingerScroll ?? false }
        set { oneFingerScroll = newValue }
    }

    /// The desktop size sessions start with.
    var defaultDesktopSize: DesktopSizeChoice {
        get {
            if let percent = defaultDeviceSizePercent { return .device(percent: percent) }
            if let size = defaultMirrorSize { return .standard(size) }
            return .macOwn
        }
        set {
            defaultDeviceSizePercent = nil
            defaultMirrorSize = nil
            switch newValue {
            case .macOwn: break
            case .device(let percent): defaultDeviceSizePercent = percent
            case .standard(let size): defaultMirrorSize = size
            }
        }
    }

    var preset: RDQualityPreset { RDQualityPreset.from(qualityRaw) }
    var codec: RDCodec { RDCodec(rawValue: codecRaw) ?? .hevc }
}

@MainActor
final class AppModel: ObservableObject {
    let browser = HostBrowser()

    @Published var session: ClientSession? {
        didSet {
            // Looking for Macs on the network has no use during a session.
            if session == nil, oldValue != nil {
                browser.restart()
            } else if session != nil, oldValue == nil {
                browser.stop()
            }
        }
    }
    @Published var recents: [RecentHost] = []
    @Published var manualError: String?
    @Published var settings: AppSettings {
        didSet { persistSettings() }
    }
    /// Server ids of Macs this device has paired with (cached from the Keychain).
    @Published private(set) var pairedServerIds: Set<String> = []

    /// Keeps the app in the orientation it is in now, or lets it turn with the device.
    var isOrientationLocked: Bool {
        get { settings.lockedOrientation != nil }
        set {
            settings.lockedOrientation = newValue ? OrientationLock.current?.rawValue : nil
            OrientationLock.apply(settings.lockedOrientation)
        }
    }

    private var didAutoConnect = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        if let data = UserDefaults.standard.data(forKey: "rd.recents"),
           let list = try? JSONDecoder().decode([RecentHost].self, from: data) {
            recents = AppModel.deduplicateRecents(list)
        }
        if let data = UserDefaults.standard.data(forKey: "rd.settings"),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
            // Before 1.2.17 the device's own size was saved as a fixed size (its whole
            // screen, landscape); now it follows the picture's area and the rotation.
            if let size = saved.defaultMirrorSize {
                let screen = UIScreen.main.bounds.size
                let wasDevice = size.width == Int(max(screen.width, screen.height))
                    && size.height == Int(min(screen.width, screen.height))
                if wasDevice || !DesktopSizeChoice.standardSizes.contains(size) {
                    settings.defaultDesktopSize = DesktopSizeChoice.deviceOptions[DesktopSizeChoice.ownSizeIndex].choice
                }
            }
        } else {
            settings = AppSettings()
        }
        persistRecents()
        TrustStore.removeLegacyTokens()
        pairedServerIds = TrustStore.pairedServerIds()

        browser.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        browser.onHostsChanged = { [weak self] hosts in
            self?.hostsChanged(hosts)
        }
        browser.start()

        // mDNS subscriptions can go stale after backgrounding or a permission
        // flip; re-arming on foreground keeps discovery self-healing.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session == nil else { return }
                self.browser.restart()
            }
        }

        // Auto-connection: prefer finding the Mac over Bonjour (see hostsChanged);
        // if it hasn't shown up shortly after launch, dial its last known address.
        if settings.autoConnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.settings.autoConnect, !self.didAutoConnect, self.session == nil,
                          let last = self.recents.first, self.isPaired(last.serverId), !last.host.isEmpty else { return }
                    self.didAutoConnect = true
                    self.connectRecent(last)
                }
            }
        }

        #if targetEnvironment(simulator)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session == nil, let sim = self.browser.hosts.first else { return }
                self.connect(endpoint: sim.endpoint, fallbackName: sim.name)
            }
        }
        #endif
    }

    func isPaired(_ serverId: String?) -> Bool {
        guard let serverId, !serverId.isEmpty else { return false }
        return pairedServerIds.contains(serverId)
    }

    // MARK: Connecting

    func connect(endpoint: NWEndpoint, fallbackName: String? = nil, expectedServerId: String? = nil,
                 quic: RDQUICAdvert? = nil, retryWhileWaking: Bool = false) {
        manualError = nil
        // Never leave a previous session running (and reconnecting) in the background.
        session?.disconnect()
        let newSession = ClientSession(deviceName: UIDevice.current.name)
        newSession.autoReconnect = settings.autoReconnect
        newSession.setDesktopSize(settings.defaultDesktopSize, byUser: false)
        newSession.defaultHideDock = settings.hideDock ?? false
        newSession.autoKeyboard = settings.autoKeyboard ?? true
        newSession.sharesClipboard = settings.shareClipboard ?? false
        session = newSession

        newSession.onConnected = { [weak self] connected in
            guard let self, self.session === connected else { return }
            self.recordRecent(connected)
            connected.setQuality(self.settings.preset, showRemoteCursor: self.settings.showRemoteCursor,
                                 codec: self.settings.codec)
        }
        newSession.onPaired = { [weak self] serverId in
            self?.pairedServerIds.insert(serverId)
        }
        newSession.connect(to: endpoint, fallbackName: fallbackName, expectedServerId: expectedServerId,
                           quic: quic, retryWhileWaking: retryWhileWaking)
    }

    func connect(to host: DiscoveredHost) {
        connect(endpoint: host.endpoint, fallbackName: host.name, expectedServerId: host.serverId,
                quic: host.quic)
    }

    func connectRecent(_ recent: RecentHost) {
        var sentWake = false
        if let mac = recent.macAddress {
            WakeOnLAN.wake(macAddress: mac, lastKnownHost: recent.host.isEmpty ? nil : recent.host)
            sentWake = true
        }
        if !recent.serverId.isEmpty, let live = browser.hosts.first(where: { $0.serverId == recent.serverId }) {
            connect(to: live)
            return
        }
        let portToUse = recent.port > 0 ? recent.port : RDService.defaultPort
        guard let port = NWEndpoint.Port(rawValue: portToUse), !recent.host.isEmpty else {
            manualError = "Could not find \(recent.name). Pull to refresh or connect from Nearby Macs."
            return
        }
        // A Mac we just tried to wake may need a few seconds before it answers.
        connect(endpoint: .hostPort(host: NWEndpoint.Host(recent.host), port: port),
                fallbackName: recent.name,
                expectedServerId: recent.serverId,
                retryWhileWaking: sentWake)
    }

    func deleteRecent(at offsets: IndexSet) {
        recents.remove(atOffsets: offsets)
        persistRecents()
    }

    func connectManual(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var hostPart = trimmed
        var portPart: UInt16? = RDService.defaultPort
        if let colon = trimmed.lastIndex(of: ":") {
            hostPart = String(trimmed[..<colon])
            portPart = UInt16(trimmed[trimmed.index(after: colon)...])
        }
        guard !hostPart.isEmpty, let rawPort = portPart, let port = NWEndpoint.Port(rawValue: rawPort) else {
            manualError = "Use the format ip:port (the port is shown in the Mac's LocalDesktop menu)."
            return
        }
        connect(endpoint: .hostPort(host: NWEndpoint.Host(hostPart), port: port), fallbackName: hostPart)
    }

    func endSession() {
        didAutoConnect = true
        let current = session
        session = nil
        current?.disconnect()
    }

    /// Removes a Mac's pinned identity so the next connection pairs from scratch.
    func forgetHost(serverId: String) {
        TrustStore.forgetHost(serverId: serverId)
        pairedServerIds.remove(serverId)
    }

    func forgetAllHosts() {
        TrustStore.forgetAllHosts()
        pairedServerIds.removeAll()
        recents = []
        persistRecents()
    }

    // MARK: Auto-connect

    private func hostsChanged(_ hosts: [DiscoveredHost]) {
        guard settings.autoConnect, !didAutoConnect, session == nil,
              let target = recents.first, isPaired(target.serverId),
              let match = hosts.first(where: { $0.serverId == target.serverId }) else { return }
        didAutoConnect = true
        connect(to: match)
    }

    // MARK: Recents

    private func recordRecent(_ connected: ClientSession) {
        var host = ""
        var port: UInt16 = 0
        if case .hostPort(let h, let p)? = connected.currentEndpoint {
            host = "\(h)"
            port = p.rawValue
        }
        let recent = RecentHost(name: connected.displayName,
                                serverId: connected.serverId,
                                host: host,
                                port: port,
                                lastUsed: Date(),
                                macAddress: connected.serverMacAddress)
        let cleanName = recent.name.trimmingCharacters(in: .whitespaces).lowercased()
        recents.removeAll { existing in
            existing.id == recent.id ||
            (!recent.serverId.isEmpty && existing.serverId == recent.serverId) ||
            (existing.macAddress != nil && recent.macAddress != nil && existing.macAddress == recent.macAddress) ||
            existing.name.trimmingCharacters(in: .whitespaces).lowercased() == cleanName
        }
        recents.insert(recent, at: 0)
        recents = AppModel.deduplicateRecents(recents)
        if recents.count > 6 {
            recents = Array(recents.prefix(6))
        }
        persistRecents()
    }

    static func deduplicateRecents(_ list: [RecentHost]) -> [RecentHost] {
        var seenNames = Set<String>()
        var seenServerIds = Set<String>()
        var seenMacs = Set<String>()
        var unique: [RecentHost] = []

        for item in list {
            let cleanName = item.name.trimmingCharacters(in: .whitespaces).lowercased()
            if !cleanName.isEmpty && seenNames.contains(cleanName) { continue }
            if !item.serverId.isEmpty && seenServerIds.contains(item.serverId) { continue }
            if let mac = item.macAddress, !mac.isEmpty && seenMacs.contains(mac) { continue }

            if !cleanName.isEmpty { seenNames.insert(cleanName) }
            if !item.serverId.isEmpty { seenServerIds.insert(item.serverId) }
            if let mac = item.macAddress, !mac.isEmpty { seenMacs.insert(mac) }
            unique.append(item)
        }
        return unique
    }

    func persistRecents() {
        UserDefaults.standard.set((try? JSONEncoder().encode(recents)) ?? Data(), forKey: "rd.recents")
    }

    private func persistSettings() {
        UserDefaults.standard.set((try? JSONEncoder().encode(settings)) ?? Data(), forKey: "rd.settings")
    }

    /// Pushes the current quality settings to the live session, if any.
    func applyQualitySettings() {
        session?.setQuality(settings.preset, showRemoteCursor: settings.showRemoteCursor, codec: settings.codec)
    }
}

/// How a session's desktop size is chosen.
enum DesktopSizeChoice: Hashable {
    /// The Mac's own layout.
    case macOwn
    /// The room the Mac's picture has on this device, at a percentage of its size. It
    /// follows the rotation, so the picture fills the screen either way up.
    case device(percent: Int)
    /// One of `standardSizes`, turned to lie the way the device is held.
    case standard(RDMirrorSize)

    /// The size to ask the Mac for with `area` points of room for the picture. Nil is
    /// the Mac's own size; ask only once `area` is known.
    func size(for area: CGSize) -> RDMirrorSize? {
        switch self {
        case .macOwn: return nil
        case .device(let percent): return RDMirrorSize.filling(area, percent: percent)
        case .standard(let size): return size.oriented(like: area)
        }
    }

    @MainActor private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    @MainActor static var deviceName: String { isPad ? "This iPad" : "This iPhone" }
    @MainActor static var fillsDeviceTitle: String { isPad ? "Fills this iPad" : "Fills this iPhone" }

    /// Sizes that fill this device's screen. A Mac desktop the size of an iPhone's
    /// screen is too small to use (and for macOS to draw sharply), so an iPhone's start
    /// at one and a half times its screen.
    @MainActor static var deviceOptions: [(name: String, choice: DesktopSizeChoice)] {
        isPad
            ? [("Larger Text", .device(percent: 85)), ("Same Size", .device(percent: 100)),
               ("More Space", .device(percent: 125)), ("Most Space", .device(percent: 150))]
            : [("Larger Text", .device(percent: 150)), ("Medium", .device(percent: 175)),
               ("More Space", .device(percent: 200))]
    }
    /// Where `deviceOptions` has the size closest to the device's own.
    @MainActor static var ownSizeIndex: Int { isPad ? 1 : 0 }

    /// The usual 4:3 sizes, for a desktop that should not depend on the device.
    static let standardSizes = [
        RDMirrorSize(width: 1024, height: 768), RDMirrorSize(width: 1112, height: 834),
        RDMirrorSize(width: 1366, height: 1024), RDMirrorSize(width: 1600, height: 1200),
    ]

    /// The name of a choice in a menu's value column.
    @MainActor var name: String {
        switch self {
        case .macOwn: return "Mac's own"
        case .device: return Self.deviceOptions.first { $0.choice == self }?.name ?? Self.deviceName
        case .standard(let size): return size.label
        }
    }

    /// The room a session's picture gets right now: the window without its safe areas.
    /// A session measures its own; this is for showing sizes outside one.
    @MainActor static var currentPictureArea: CGSize {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        guard let window else { return UIScreen.main.bounds.size }
        return window.bounds.inset(by: window.safeAreaInsets).size
    }
}
