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
    var centerOnMouse = true
    var qualityRaw = RDQualityPreset.sharp.rawValue
    var codecRaw = RDCodec.hevc.rawValue
    var showRemoteCursor = false
    var showScrollHelpers = true
    var pointerSpeedMultiplier: Double = 1.5
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

    private var didAutoConnect = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
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
            Task { @MainActor in
                guard let self, self.session == nil else { return }
                self.browser.restart()
            }
        }

        // Auto-connection: on launch, dial the last trusted Mac directly.
        if settings.autoConnect, !didAutoConnect, session == nil,
           let last = recents.first,
           TrustStore.token(serverId: last.serverId) != nil, !last.host.isEmpty {
            didAutoConnect = true
            connectRecent(last)
        }

        #if targetEnvironment(simulator)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.session == nil, let sim = self.browser.hosts.first else { return }
            self.connect(endpoint: sim.endpoint, fallbackName: sim.name)
        }
        #endif
    }

    // MARK: Connecting

    func connect(endpoint: NWEndpoint, fallbackName: String? = nil) {
        reconnectTask?.cancel()
        manualError = nil
        let newSession = ClientSession(deviceName: UIDevice.current.name)
        newSession.autoReconnect = settings.autoReconnect
        session = newSession

        newSession.onConnected = { [weak self] connected in
            guard let self, self.session === connected else { return }
            self.reconnectAttempts = 0
            self.recordRecent(connected, fallbackName: fallbackName)
            let preset = RDQualityPreset.from(self.settings.qualityRaw)
            let codec = RDCodec(rawValue: self.settings.codecRaw) ?? .hevc
            connected.setQuality(preset, showRemoteCursor: self.settings.showRemoteCursor, codec: codec)
        }
        newSession.onEnded = { [weak self] ended in
            // Reconnection is now fully handled inside ClientSession's fail() state machine!
            // We only need to clear the session if the user explicitly ended it, or if it gave up.
        }
        newSession.connect(to: endpoint, fallbackName: fallbackName)
    }

    func connectRecent(_ recent: RecentHost) {
        if let mac = recent.macAddress {
            WakeOnLAN.wake(macAddress: mac)
        }
        if let live = browser.hosts.first(where: {
            (!recent.serverId.isEmpty && $0.serverId == recent.serverId) ||
            (!recent.serverId.isEmpty && $0.name.contains(String(recent.serverId.prefix(4)))) ||
            $0.name.hasPrefix(recent.name) || recent.name.hasPrefix($0.name)
        }) {
            connect(endpoint: live.endpoint, fallbackName: live.name)
            return
        }
        let portToUse = recent.port > 0 ? recent.port : 52341
        guard let port = NWEndpoint.Port(rawValue: portToUse), !recent.host.isEmpty else {
            manualError = "Could not find \(recent.name). Tap Refresh above or connect from Nearby Macs."
            return
        }
        connect(endpoint: .hostPort(host: NWEndpoint.Host(recent.host), port: port),
                fallbackName: recent.name)
    }

    func deleteRecent(at offsets: IndexSet) {
        recents.remove(atOffsets: offsets)
        persistRecents()
    }

    func connectManual(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var hostPart = trimmed
        var portPart: UInt16?
        if let colon = trimmed.lastIndex(of: ":") {
            hostPart = String(trimmed[..<colon])
            portPart = UInt16(trimmed[trimmed.index(after: colon)...])
        }
        guard !hostPart.isEmpty, let port = portPart else {
            manualError = "Use the format ip:port (the port is shown in the Mac's Local Desktop menu)."
            return
        }
        connect(endpoint: .hostPort(host: NWEndpoint.Host(hostPart), port: NWEndpoint.Port(rawValue: port)!),
                fallbackName: hostPart)
    }

    func endSession() {
        didAutoConnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        let current = session
        session = nil
        current?.disconnect()
    }

    // MARK: Auto-connect / auto-reconnect

    private func hostsChanged(_ hosts: [DiscoveredHost]) {
        guard settings.autoConnect, !didAutoConnect, session == nil,
              let target = recents.first, !target.name.isEmpty else { return }
        if let match = hosts.first(where: {
            (!target.serverId.isEmpty && $0.serverId == target.serverId) ||
            (!target.serverId.isEmpty && $0.name.contains(String(target.serverId.prefix(4)))) ||
            $0.name.hasPrefix(target.name) || target.name.hasPrefix($0.name)
        }) {
            didAutoConnect = true
            connect(endpoint: match.endpoint, fallbackName: target.name)
        }
    }

    // MARK: Recents

    private func recordRecent(_ connected: ClientSession, fallbackName: String?) {
        var host = ""
        var port: UInt16 = 0
        if case .hostPort(let h, let p)? = connected.currentEndpoint {
            host = "\(h)"
            port = p.rawValue
        }
        let name = connected.displayName
        let recent = RecentHost(name: name,
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
}
