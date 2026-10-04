import Foundation
import Network
import AppKit
import CoreGraphics
import Combine

/// Menu-bar host: listens for client connections, tracks sessions, and
/// coordinates screen streaming and power state for them.
@MainActor
final class HostServer: ObservableObject {
    static let shared = HostServer()

    @Published private(set) var running = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var clientName: String?
    @Published private(set) var displays: [RDDisplay] = [] {
        didSet { if displays != oldValue { broadcastDisplays() } }
    }
    /// The display to stream, chosen in the menu or from a client.
    @Published private(set) var selectedDisplayID: CGDirectDisplayID? {
        didSet { if selectedDisplayID != oldValue { broadcastDisplays() } }
    }
    @Published var preset: RDQualityPreset = .high
    @Published var lastError: String?
    /// Why screen capture last failed; cleared once capture runs again.
    @Published var captureError: String?
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenGranted = false
    @Published private(set) var isHostLocked = false
    @Published private(set) var isDisplaySleeping = false

    static let computerName: String = Host.current().localizedName ?? "Mac"

    /// Unauthenticated connections allowed at once (in total and per remote address); more are refused.
    private static let maxPendingSessions = 16
    private static let maxPendingSessionsPerAddress = 2
    /// Remembers whether the user wants sharing on, so a crash relaunch restores it.
    private static let sharingWantedKey = "rd.sharingWanted"

    let appSwitcher = AppSwitcher()
    private let power = PowerAssertions()

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
            let ip = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !ip.hasPrefix("127.") { result = ip }
        }
        return result
    }

    private var listener: NWListener?
    /// Connections still performing the handshake.
    private var pendingSessions: [ClientSession] = []
    /// All authenticated, streaming sessions.
    private(set) var activeSessions: [ClientSession] = []
    /// When capture last retried after losing its display.
    private var lastDisplayLossRetry = Date.distantPast

    var bonjourName: String {
        "\(HostServer.computerName) [\(String(AuthStore.shared.serverId.prefix(4)))]"
    }

    private init() {
        ScreenStreamer.shared.onVideoPacket = { [weak self] data, isKeyframe, width, height, codec in
            // Hop to main in order; ClientSession (and its cipher) lives there.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for session in self.activeSessions {
                        session.sendVideoFrame(data, isKeyframe: isKeyframe, width: width, height: height, codec: codec)
                    }
                }
            }
        }
        ScreenStreamer.shared.onCaptureStopped = { [weak self] error in
            self?.captureDidStop(error)
        }

        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsLocked")) { server, _ in
            server.isHostLocked = true
            server.broadcastHostState()
        }
        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsUnlocked")) { server, _ in
            server.isHostLocked = false
            server.broadcastHostState()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { server, _ in
            server.isDisplaySleeping = true
            server.broadcastHostState()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { server, _ in
            server.isDisplaySleeping = false
            server.broadcastHostState()
            if !server.activeSessions.isEmpty {
                server.restartCapture()
            }
        }
        // Displays came or went (lid opened, display plugged in); pick capture back up.
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { server, _ in
            server.refreshDisplays()
            if !server.activeSessions.isEmpty, !ScreenStreamer.shared.isRunning {
                server.restartCapture()
            }
        }
        let appNotifications = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        for name in appNotifications {
            observe(workspace, name) { server, name in
                if name == NSWorkspace.didActivateApplicationNotification,
                   let activeApp = NSWorkspace.shared.frontmostApplication,
                   activeApp.activationPolicy == .regular,
                   let bid = activeApp.bundleIdentifier {
                    server.appSwitcher.trackActivation(bid)
                }
                server.broadcastRunningApps()
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor @Sendable (HostServer, Notification.Name) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            let name = notification.name
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, name)
            }
        }
    }

    /// Starts sharing at launch when everything it needs is in place. After a crash
    /// relaunch, sharing is only restored if the user hadn't stopped it.
    func autoStartIfNeeded(afterCrash: Bool) {
        refreshPermissions()
        let wanted = UserDefaults.standard.object(forKey: Self.sharingWantedKey) as? Bool ?? true
        guard !afterCrash || wanted else { return }
        if missingSetup.isEmpty {
            start()
        }
    }

    /// The menu bar sharing switch.
    func setSharing(_ on: Bool) {
        if on {
            start()
        } else if running {
            UserDefaults.standard.set(false, forKey: Self.sharingWantedKey)
            stop()
        }
    }

    /// What still has to be done before sharing can start.
    var missingSetup: [SetupItem] {
        var items: [SetupItem] = []
        if !screenGranted { items.append(.permission(.screenRecording)) }
        if !accessibilityGranted { items.append(.permission(.accessibility)) }
        if !AuthStore.shared.hasPIN { items.append(.pin) }
        return items
    }

    func start() {
        guard !running else { return }
        // Refuse to advertise a session we cannot actually deliver.
        refreshPermissions()
        guard missingSetup.isEmpty else {
            SetupWindowController.shared.show()
            return
        }
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
            let preferredPort = NWEndpoint.Port(rawValue: RDService.defaultPort) ?? .any
            let newListener: NWListener
            if let specific = try? NWListener(using: parameters, on: preferredPort) {
                newListener = specific
            } else {
                newListener = try NWListener(using: parameters, on: .any)
            }
            var txt = NWTXTRecord()
            txt["sid"] = AuthStore.shared.serverId
            txt["name"] = HostServer.computerName
            newListener.service = NWListener.Service(name: bonjourName,
                                                     type: RDService.type,
                                                     domain: nil,
                                                     txtRecord: txt.data)
            newListener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    self?.accept(connection)
                }
            }
            newListener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.port = newListener.port?.rawValue ?? 0
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
            lastError = nil
            UserDefaults.standard.set(true, forKey: Self.sharingWantedKey)
            refreshDisplays()
        } catch {
            lastError = "Could not start server: \(error.localizedDescription)"
        }
    }

    func stop() {
        let sessions = pendingSessions + activeSessions
        pendingSessions.removeAll()
        activeSessions.removeAll()
        // Tell clients not to reconnect on their own.
        for session in sessions {
            session.close(sendingBye: RDByeReason.hostStopped)
        }
        power.release()
        listener?.cancel()
        listener = nil
        ScreenStreamer.shared.stop()
        updateFrameGate()
        running = false
        port = 0
        clientName = nil
    }

    /// Re-checks both privacy permissions without prompting.
    func refreshPermissions() {
        accessibilityGranted = Permissions.isGranted(.accessibility)
        screenGranted = Permissions.isGranted(.screenRecording)
    }

    /// Re-reads the Mac's displays; clients hear about any change. A chosen display
    /// that's gone gives way to the main one.
    func refreshDisplays() {
        displays = Self.currentDisplays()
        if selectedDisplayID.map({ id in !displays.contains { $0.id == id } }) ?? true {
            selectedDisplayID = displays.first?.id
        }
    }

    /// The active displays, the main one (with the menu bar) first. Displays with the
    /// same name are numbered so they can be told apart.
    private static func currentDisplays() -> [RDDisplay] {
        var nameCounts: [String: Int] = [:]
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            var name = screen.localizedName
            nameCounts[name, default: 0] += 1
            if let count = nameCounts[name], count > 1 { name += " \(count)" }
            return RDDisplay(id: number.uint32Value, name: name,
                             width: Int(screen.frame.width), height: Int(screen.frame.height),
                             isMain: number.uint32Value == CGMainDisplayID())
        }
    }

    private var displaysMessage: RDDisplaysMsg {
        RDDisplaysMsg(displays: displays, selectedId: selectedDisplayID)
    }

    private func broadcastDisplays() {
        let message = displaysMessage
        for session in activeSessions {
            session.sendDisplays(message)
        }
    }

    func setPreset(_ newPreset: RDQualityPreset) {
        preset = newPreset
        Task { await ScreenStreamer.shared.updatePreset(newPreset) }
    }

    /// Streams another display, chosen in the menu or by a client; unknown ids are ignored.
    func setDisplay(_ id: CGDirectDisplayID) {
        guard selectedDisplayID != id, displays.contains(where: { $0.id == id }) else { return }
        selectedDisplayID = id
        guard running, !activeSessions.isEmpty else { return }
        restartCapture()
    }

    func setCodec(_ codec: RDCodec) {
        Task { await ScreenStreamer.shared.updateConfiguration(preset: preset, codec: codec) }
    }

    /// Debounced capture restart; superseded restarts are expected and not errors.
    private func restartCapture(codec: RDCodec? = nil) {
        Task {
            // The last client may have left between scheduling this and running it.
            guard !activeSessions.isEmpty else { return }
            let requested = selectedDisplayID
            do {
                try await ScreenStreamer.shared.restart(displayID: requested, preset: preset,
                                                        codec: codec ?? ScreenStreamer.shared.currentCodec)
                captureError = nil
                // The chosen display was gone and capture fell back to another one.
                let streamed = ScreenStreamer.shared.currentDisplay
                if requested != nil, streamed != requested, selectedDisplayID == requested {
                    selectedDisplayID = streamed
                }
            } catch is CancellationError {
            } catch where ScreenStreamer.isDisplayUnavailable(error) {
                // Nothing to capture until a display wakes or returns; the observers restart it then.
            } catch {
                captureError = "Screen capture: \(error.localizedDescription)"
            }
            if activeSessions.isEmpty {
                ScreenStreamer.shared.stop()
            }
        }
    }

    /// The system ended capture. A display that went away is routine, so capture moves to
    /// another display if there is one and otherwise waits quietly for one to come back.
    private func captureDidStop(_ error: Error) {
        guard !activeSessions.isEmpty else { return }
        guard ScreenStreamer.isDisplayUnavailable(error) else {
            captureError = "Screen capture stopped: \(error.localizedDescription)"
            return
        }
        // One retry finds another display if one is left. Should that capture die
        // too, the wake and screen-change observers restart it instead of a loop here.
        if Date().timeIntervalSince(lastDisplayLossRetry) > 5 {
            lastDisplayLossRetry = Date()
            restartCapture()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard running else {
            connection.cancel()
            return
        }
        // One address can't occupy every pre-authentication slot (each may wait up to
        // two minutes for a PIN). At its cap, its own oldest attempt makes room, so a
        // device whose earlier attempts went stale can still get in.
        let address = Self.remoteAddress(of: connection)
        let fromAddress = pendingSessions.filter { $0.remoteAddress == address }
        if fromAddress.count >= Self.maxPendingSessionsPerAddress, let oldest = fromAddress.first {
            oldest.close()
        }
        guard pendingSessions.count < Self.maxPendingSessions else {
            connection.cancel()
            return
        }
        let session = ClientSession(connection: connection, server: self, remoteAddress: address)
        pendingSessions.append(session)
        session.start()
    }

    private static func remoteAddress(of connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint {
            return "\(host)"
        }
        return "\(connection.endpoint)"
    }

    // MARK: Called by ClientSession

    func sessionDidAuthenticate(_ session: ClientSession, name: String) {
        refreshDisplays()
        pendingSessions.removeAll { $0 === session }
        if !activeSessions.contains(where: { $0 === session }) {
            activeSessions.append(session)
        }

        // Force wake the display from Dark Wake when a client connects.
        power.acquire()
        InputInjector.wakeDisplay(within: streamedDisplayBounds)
        isDisplaySleeping = false

        session.sendHostState(HostStateMsg(isLocked: isHostLocked, isDisplaySleeping: isDisplaySleeping))
        session.sendRunningApps(appSwitcher.runningApps())
        session.sendHardwareControls(HardwareController.getState())
        session.sendDisplays(displaysMessage)

        updateClientName()
        updateFrameGate()
        if let keyframe = ScreenStreamer.shared.lastKeyframe {
            session.sendVideoFrame(keyframe.data, isKeyframe: true, width: keyframe.width, height: keyframe.height, codec: keyframe.codec)
        }
        restartCapture()
    }

    func sessionDidEnd(_ session: ClientSession) {
        pendingSessions.removeAll { $0 === session }
        activeSessions.removeAll { $0 === session }
        updateFrameGate()
        if activeSessions.isEmpty {
            clientName = nil
            power.release()
            ScreenStreamer.shared.stop()
        } else {
            updateClientName()
            updateBitrate()
        }
    }

    /// A session's send backlog changed; capture only encodes while someone can take a frame.
    func updateFrameGate() {
        ScreenStreamer.shared.setClientsReady(activeSessions.contains { $0.canSendFrame })
    }

    /// One encoder serves every client, so it runs at the rate the slowest one can take.
    func updateBitrate() {
        let factor = activeSessions.map(\.bitrateFactor).min() ?? 1.0
        ScreenStreamer.shared.setDynamicBitrate(Int(Double(preset.targetBitrate) * factor))
    }

    private func updateClientName() {
        if activeSessions.count == 1 {
            clientName = activeSessions.first?.peerDisplayName
        } else if activeSessions.count > 1 {
            clientName = "\(activeSessions.count) devices connected"
        } else {
            clientName = nil
        }
    }

    func handleWakeDisplayRequest() {
        power.acquire()
        InputInjector.wakeDisplay(within: streamedDisplayBounds)
        isDisplaySleeping = false
        broadcastHostState()
        restartCapture()
    }

    func handleRefreshVideoRequest() {
        restartCapture()
    }

    func broadcastRunningApps() {
        guard !activeSessions.isEmpty else { return }
        let apps = appSwitcher.runningApps()
        for session in activeSessions {
            session.sendRunningApps(apps)
        }
    }

    func toggleShowDesktop() {
        appSwitcher.toggleShowDesktop()
        broadcastRunningApps()
    }

    func broadcastHostState() {
        let msg = HostStateMsg(isLocked: isHostLocked, isDisplaySleeping: isDisplaySleeping)
        for s in activeSessions {
            s.sendHostState(msg)
        }
    }

    func applyPresetFromClient(_ raw: Int, showRemoteCursor: Bool? = nil, codec requestedCodec: RDCodec? = nil) {
        let newPreset = RDQualityPreset.from(raw)
        let newCodec = requestedCodec ?? ScreenStreamer.shared.currentCodec
        var needsRestart = false

        if let showCursor = showRemoteCursor, ScreenStreamer.shared.showRemoteCursor != showCursor {
            ScreenStreamer.shared.showRemoteCursor = showCursor
            needsRestart = true
        }

        if newPreset != preset || newCodec != ScreenStreamer.shared.currentCodec {
            preset = newPreset
            needsRestart = true
        }

        if needsRestart {
            restartCapture(codec: newCodec)
        }
    }

    /// Global bounds (top-left origin) of the display being streamed.
    var streamedDisplayBounds: CGRect {
        CGDisplayBounds(ScreenStreamer.shared.currentDisplay)
    }

    /// Maps a point in streamed-frame pixel space to global CG coordinates
    /// (top-left origin), which is what CGEvent expects.
    func globalPoint(x: Double, y: Double) -> CGPoint? {
        let bounds = streamedDisplayBounds
        let size = ScreenStreamer.shared.frameSize
        guard size.width > 1, size.height > 1, x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: bounds.minX + x / Double(size.width) * bounds.width,
                       y: bounds.minY + y / Double(size.height) * bounds.height)
    }

    /// Returns the current hardware mouse position in streamed-frame pixel space.
    func currentCursorInFrame() -> (x: Double, y: Double)? {
        let bounds = streamedDisplayBounds
        let size = ScreenStreamer.shared.frameSize
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return nil }
        let mousePos = InputInjector.currentPositionTopLeft
        let x = (mousePos.x - bounds.minX) / bounds.width * Double(size.width)
        let y = (mousePos.y - bounds.minY) / bounds.height * Double(size.height)
        return (x: min(max(x, 0), Double(size.width)),
                y: min(max(y, 0), Double(size.height)))
    }
}
