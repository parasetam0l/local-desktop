import Foundation
import Network
import AppKit
import CoreGraphics
import Combine
import IOKit.pwr_mgt

/// Menu-bar host: listens for client connections, brokers the PIN/trust
/// handshake, streams screen frames, and injects client input events.
@MainActor
final class HostServer: ObservableObject {
    static let shared = HostServer()

    @Published private(set) var running = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var clientName: String?
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var preset: RDQualityPreset = .high
    @Published private(set) var captureStats = ""
    @Published var lastError: String?
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenGranted = false
    @Published private(set) var isHostLocked = false
    @Published private(set) var isDisplaySleeping = false

    static let computerName: String = Host.current().localizedName ?? "Mac"

    private var displaySleepAssertion: IOPMAssertionID = 0
    private var systemSleepAssertion: IOPMAssertionID = 0

    /// First IPv4 address on a physical interface (en0…), for display in the menu.
    static func primaryLANAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var result: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr, result == nil {
            defer { ptr = p.pointee.ifa_next }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en"),
                  let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var addr = sockaddr_in()
            memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = addr.sin_addr
            guard inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: buf)
            if !ip.hasPrefix("127.") { result = ip }
        }
        return result
    }

    private var listener: NWListener?
    /// Connections still performing the handshake.
    private var pendingSessions: [ClientSession] = []
    /// All authenticated, streaming sessions.
    private(set) var activeSessions: [ClientSession] = []

    var bonjourName: String {
        "\(HostServer.computerName) [\(String(AuthStore.shared.serverId.prefix(4)))]"
    }

    private init() {
        ScreenStreamer.shared.onVideoPacket = { [weak self] data, width, height, codec in
            Task { @MainActor in
                guard let self, !self.activeSessions.isEmpty else { return }
                for session in self.activeSessions {
                    session.sendVideoFrame(data, width: width, height: height, codec: codec)
                }
            }
        }
        ScreenStreamer.shared.isReady = { [weak self] in
            guard let self else { return false }
            return self.activeSessions.contains(where: { $0.canSendFrame })
        }
        ScreenStreamer.shared.onError = { [weak self] message in
            Task { @MainActor in
                self?.lastError = message
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isHostLocked = true
                self?.broadcastHostState()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isHostLocked = false
                self?.broadcastHostState()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isDisplaySleeping = true
                self?.broadcastHostState()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isDisplaySleeping = false
                self.broadcastHostState()
                if !self.activeSessions.isEmpty {
                    try? await ScreenStreamer.shared.restart(displayID: self.selectedDisplayID, preset: self.preset, codec: ScreenStreamer.shared.currentCodec)
                }
            }
        }

        Task { @MainActor in
            if AuthStore.shared.hasPIN && CGPreflightScreenCaptureAccess() && InputInjector.checkAccessibility(prompt: false) {
                self.start()
            }
        }
    }

    func toggle() {
        running ? stop() : start()
    }

    func start() {
        guard !running else { return }
        guard AuthStore.shared.hasPIN else {
            lastError = "Set a 4-digit PIN before sharing."
            return
        }
        // Refuse to advertise a session we cannot actually deliver.
        guard InputInjector.checkAccessibility(prompt: false) else {
            lastError = "Grant Accessibility (Input Monitoring) before sharing."
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            lastError = "Grant Screen Recording before sharing."
            return
        }
        accessibilityGranted = true
        screenGranted = true
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableFastOpen = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }
            let preferredPort = NWEndpoint.Port(rawValue: 52341) ?? .any
            let newListener: NWListener
            if let specific = try? NWListener(using: parameters, on: preferredPort) {
                newListener = specific
            } else {
                newListener = try NWListener(using: parameters, on: .any)
            }
            var initialTxt = NWTXTRecord()
            if let ip = HostServer.primaryLANAddress() {
                initialTxt["ip"] = ip
            }
            newListener.service = NWListener.Service(name: bonjourName,
                                                     type: RDService.type,
                                                     domain: nil,
                                                     txtRecord: initialTxt.data)
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let portRaw = newListener.port?.rawValue ?? 0
                        self.port = portRaw
                    case .failed(let error):
                        self.lastError = "Server error: \(error.localizedDescription)"
                    default:
                        break
                    }
                }
            }
            listener = newListener
            newListener.start(queue: .main)
            running = true
            refreshDisplays()
        } catch {
            lastError = "Could not start server: \(error.localizedDescription)"
        }
    }

    func stop() {
        for s in pendingSessions { s.close() }
        for s in activeSessions { s.close() }
        pendingSessions.removeAll()
        activeSessions.removeAll()
        releasePowerAssertions()
        listener?.cancel()
        listener = nil
        ScreenStreamer.shared.stop()
        running = false
        port = 0
        clientName = nil
        captureStats = ""
    }

    /// Re-checks both privacy permissions without prompting.
    func refreshPermissions() {
        accessibilityGranted = InputInjector.checkAccessibility(prompt: false)
        screenGranted = CGPreflightScreenCaptureAccess()
    }

    func refreshDisplays() {
        Task {
            let list = await ScreenStreamer.shared.loadDisplays()
            displays = list
            if selectedDisplayID == nil { selectedDisplayID = list.first?.id }
        }
    }

    func setPreset(_ newPreset: RDQualityPreset) {
        preset = newPreset
        Task { await ScreenStreamer.shared.updatePreset(newPreset) }
    }

    func setDisplay(_ id: CGDirectDisplayID) {
        guard selectedDisplayID != id else { return }
        selectedDisplayID = id
        guard running else { return }
        Task {
            try await ScreenStreamer.shared.start(displayID: id, preset: preset, codec: ScreenStreamer.shared.currentCodec)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard running else {
            connection.cancel()
            return
        }
        let session = ClientSession(connection: connection, server: self)
        pendingSessions.append(session)
        session.start()
    }

    // MARK: Called by ClientSession

    func sessionDidAuthenticate(_ session: ClientSession, name: String) {
        pendingSessions.removeAll { $0 === session }
        if !activeSessions.contains(where: { $0 === session }) {
            activeSessions.append(session)
        }

        // Force wake the display from Dark Wake when a client connects.
        acquirePowerAssertions()
        InputInjector.wakeDisplay()
        isDisplaySleeping = false

        // Inform client of current screen lock & display sleep state
        session.sendHostState(HostStateMsg(isLocked: isHostLocked, isDisplaySleeping: isDisplaySleeping))

        if activeSessions.count == 1 {
            clientName = name
        } else {
            clientName = "\(activeSessions.count) devices connected"
        }
        if let keyframe = ScreenStreamer.shared.lastKeyframe {
            session.sendVideoFrame(keyframe.data, width: keyframe.width, height: keyframe.height, codec: keyframe.codec)
        }
        Task {
            do {
                try await ScreenStreamer.shared.restart(displayID: selectedDisplayID, preset: preset, codec: ScreenStreamer.shared.currentCodec)
            } catch {
                lastError = "Screen capture: \(error.localizedDescription)"
            }
        }
    }

    func handleWakeDisplayRequest() {
        acquirePowerAssertions()
        InputInjector.wakeDisplay()
        isDisplaySleeping = false
        broadcastHostState()
        Task {
            try? await ScreenStreamer.shared.restart(displayID: selectedDisplayID, preset: preset, codec: ScreenStreamer.shared.currentCodec)
        }
    }

    func handleRefreshVideoRequest() {
        Task {
            try? await ScreenStreamer.shared.restart(displayID: selectedDisplayID, preset: preset, codec: ScreenStreamer.shared.currentCodec)
        }
    }

    func sessionDidEnd(_ session: ClientSession) {
        pendingSessions.removeAll { $0 === session }
        activeSessions.removeAll { $0 === session }
        if activeSessions.isEmpty {
            clientName = nil
            captureStats = ""
            releasePowerAssertions()
            ScreenStreamer.shared.stop()
        } else if activeSessions.count == 1 {
            clientName = activeSessions.first?.peerDisplayName
        } else {
            clientName = "\(activeSessions.count) devices connected"
        }
    }

    private func acquirePowerAssertions() {
        if displaySleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Local Desktop Active Remote Session" as CFString,
                &displaySleepAssertion
            )
        }
        if systemSleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Local Desktop Active Remote Session" as CFString,
                &systemSleepAssertion
            )
        }
    }

    private func releasePowerAssertions() {
        if displaySleepAssertion != 0 {
            IOPMAssertionRelease(displaySleepAssertion)
            displaySleepAssertion = 0
        }
        if systemSleepAssertion != 0 {
            IOPMAssertionRelease(systemSleepAssertion)
            systemSleepAssertion = 0
        }
    }

    func broadcastHostState() {
        let msg = HostStateMsg(isLocked: isHostLocked, isDisplaySleeping: isDisplaySleeping)
        for s in activeSessions {
            s.sendHostState(msg)
        }
    }

    func applyPresetFromClient(_ raw: Int, showRemoteCursor: Bool? = nil, codec rawCodec: Int? = nil) {
        let newPreset = RDQualityPreset.from(raw)
        let newCodec = rawCodec.flatMap { RDCodec(rawValue: UInt8($0)) } ?? ScreenStreamer.shared.currentCodec
        var needsRestart = false

        if let showCursor = showRemoteCursor, ScreenStreamer.shared.showRemoteCursor != showCursor {
            ScreenStreamer.shared.showRemoteCursor = showCursor
            needsRestart = true
        }

        if newPreset != preset || newCodec != ScreenStreamer.shared.currentCodec {
            preset = newPreset
            UserDefaults.standard.set(preset.rawValue, forKey: "QualityPreset")
            needsRestart = true
        }

        if needsRestart {
            Task {
                let currentDisplay = ScreenStreamer.shared.currentDisplay
                ScreenStreamer.shared.stop()
                try? await ScreenStreamer.shared.start(displayID: currentDisplay, preset: preset, codec: newCodec)
            }
        }
    }

    /// Maps a point in streamed-frame pixel space to global CG coordinates
    /// (top-left origin), which is what CGEvent expects.
    func globalPoint(x: Double, y: Double) -> CGPoint? {
        let bounds = CGDisplayBounds(ScreenStreamer.shared.currentDisplay)
        let size = ScreenStreamer.shared.frameSize
        guard size.width > 1, size.height > 1 else { return nil }
        return CGPoint(x: bounds.minX + x / Double(size.width) * bounds.width,
                       y: bounds.minY + y / Double(size.height) * bounds.height)
    }

    /// Returns the current hardware mouse position in streamed-frame pixel space.
    func currentCursorInFrame() -> (x: Double, y: Double)? {
        let bounds = CGDisplayBounds(ScreenStreamer.shared.currentDisplay)
        let size = ScreenStreamer.shared.frameSize
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return nil }
        let mousePos = InputInjector.currentPositionTopLeft
        let x = (mousePos.x - bounds.minX) / bounds.width * Double(size.width)
        let y = (mousePos.y - bounds.minY) / bounds.height * Double(size.height)
        return (x: min(max(x, 0), Double(size.width)),
                y: min(max(y, 0), Double(size.height)))
    }
}
