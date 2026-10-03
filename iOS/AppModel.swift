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

    var preset: RDQualityPreset { RDQualityPreset.from(qualityRaw) }
    var codec: RDCodec { RDCodec(rawValue: codecRaw) ?? .hevc }
}

@MainActor
final class AppModel: ObservableObject {
    let browser = HostBrowser()

    @Published var session: ClientSession?
    @Published var recents: [RecentHost] = []
    @Published var manualError: String?
    @Published var settings: AppSettings {
        didSet { persistSettings() }
    }
    /// Server ids of Macs this device has paired with (cached from the Keychain).
    @Published private(set) var pairedServerIds: Set<String> = []

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
                 retryWhileWaking: Bool = false) {
        manualError = nil
        // Never leave a previous session running (and reconnecting) in the background.
        session?.disconnect()
        let newSession = ClientSession(deviceName: UIDevice.current.name)
        newSession.autoReconnect = settings.autoReconnect
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
                           retryWhileWaking: retryWhileWaking)
    }

    func connect(to host: DiscoveredHost) {
        connect(endpoint: host.endpoint, fallbackName: host.name, expectedServerId: host.serverId)
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
            manualError = "Use the format ip:port (the port is shown in the Mac's Local Desktop menu)."
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
