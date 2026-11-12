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
    /// The size the desktop is laid out at for the clients, while that mode is on.
    @Published private(set) var mirrorSize: RDMirrorSize? {
        didSet { if mirrorSize != oldValue { broadcastDisplays() } }
    }
    private let sizedMirror = SizedMirror()
    /// Whether a client asked for the Dock to be hidden; ends with the last session.
    private(set) var hidesDock = false
    /// The display that was streamed before the sized mirror took over.
    private var displayBeforeSizedMirror: CGDirectDisplayID?
    /// A size a client asked for while the lid was shut with no display to lay out.
    private var pendingMirrorSize: RDMirrorSize?
    /// A new virtual display is being set up, which takes a moment.
    private var isStartingSizedMirror = false
    /// What was asked for while it was (the inner nil is the Mac's own layout); done next.
    private var mirrorSizeAfterStart: RDMirrorSize??
    private var mirrorSizeRetries = 0
    /// Puts the desktop size and the Dock back a while after the last client left.
    private var sessionSettingsReset: DispatchWorkItem?
    @Published var preset: RDQualityPreset = .high
    @Published var lastError: String?
    /// Why screen capture last failed; cleared once capture runs again.
    @Published var captureError: String?
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenGranted = false
    @Published private(set) var isHostLocked = HostServer.readIsLocked()
    @Published private(set) var isDisplaySleeping = false
    /// Whether this MacBook's lid is shut, and whether a non-built-in display is active.
    /// With the lid shut and no external display macOS forces clamshell sleep, so there is
    /// no screen to stream until the lid opens or a display is attached.
    @Published private(set) var isLidClosed = false
    @Published private(set) var hasExternalDisplay = false
    /// The lid is shut and there is no external display: a forced-sleep state the host
    /// can't fight with power assertions.
    /// A client's touch asked to wake the Mac anyway. The display often does wake with the
    /// lid shut, so an explicit request is tried; only automatic wakes stay off. Cleared when
    /// the lid or displays change or the last client leaves.
    private var wakeRequestedWithClosedLid = false
    var isHeadlessClosedLid: Bool { isLidClosed && !hasExternalDisplay && !wakeRequestedWithClosedLid }
    /// The setting: block this Mac's own keyboard and trackpad while devices are connected.
    @Published private(set) var blocksLocalInput = UserDefaults.standard.bool(forKey: HostServer.blocksLocalInputKey)
    /// Whether they're blocked right now.
    @Published private(set) var isBlockingLocalInput = false
    @Published private(set) var localInputBlockError: String?

    static let computerName: String = Host.current().localizedName ?? "Mac"

    /// Unauthenticated connections allowed at once (in total and per remote address); more are refused.
    private static let maxPendingSessions = 16
    private static let maxPendingSessionsPerAddress = 2
    /// Remembers whether the user wants sharing on, so a crash relaunch restores it.
    private static let sharingWantedKey = "rd.sharingWanted"
    private static let blocksLocalInputKey = "rd.blocksLocalInput"

    let appSwitcher = AppSwitcher()
    private let power = PowerAssertions()
    private let inputBlocker = LocalInputBlocker()
    private let lid = LidStateMonitor()
    /// Coalesces the bursts of host-state notifications macOS emits around sleep/wake and
    /// lock/unlock into a single send; remembers what was last sent so it isn't repeated.
    private var hostStateBroadcastWorkItem: DispatchWorkItem?
    private var capsLockTimer: Timer?
    private var lastBroadcastHostState: HostStateMsg?
    private static let hostStateDebounce: TimeInterval = 0.5

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
    /// The QUIC listener beside the TCP one (UDP, same port number when it's free).
    private var quicListener: NWListener?
    /// The UDP port QUIC listens on, once its listener is ready.
    private var quicPort: UInt16?
    /// Incoming QUIC connections, kept until they close (a session cancels its own).
    private lazy var quicAcceptor = QUICAcceptor(
        queue: .main,
        log: { HostLog.write($0) },
        onStream: { [weak self] stream, group, firstBytes in
            MainActor.assumeIsolated {
                self?.accept(stream, transport: .quic, group: group, initialData: firstBytes)
            }
        })
    /// Connections still performing the handshake.
    private var pendingSessions: [ClientSession] = []
    /// All authenticated, streaming sessions.
    private(set) var activeSessions: [ClientSession] = []
    /// Shares the clipboard with the sessions that turned it on.
    private(set) lazy var clipboard = ClipboardSync { [weak self] in
        self?.activeSessions.filter { $0.sharesClipboard } ?? []
    }
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

        lid.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.lidStateChanged()
            }
        }

        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsLocked")) { server, _ in
            HostLog.write("screen locked | \(HostLog.displaySummary())")
            server.isHostLocked = true
            server.scheduleHostStateBroadcast()
        }
        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsUnlocked")) { server, _ in
            HostLog.write("screen unlocked | \(HostLog.displaySummary())")
            server.isHostLocked = false
            server.scheduleHostStateBroadcast()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { server, _ in
            HostLog.write("screens did sleep | \(HostLog.displaySummary())")
            server.isDisplaySleeping = true
            server.lid.refresh()
            server.scheduleHostStateBroadcast()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { server, _ in
            HostLog.write("screens did wake | \(HostLog.displaySummary())")
            server.isDisplaySleeping = false
            server.applyPendingMirrorSize()
            // A missed unlock notification mustn't leave a false lock behind.
            server.isHostLocked = Self.readIsLocked()
            server.lid.refresh()
            server.scheduleHostStateBroadcast()
            if !server.activeSessions.isEmpty, !server.isHeadlessClosedLid {
                server.restartCapture()
            }
        }
        // Displays came or went (lid opened, display plugged in); pick capture back up.
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { server, _ in
            HostLog.write("screens changed | \(HostLog.displaySummary())")
            server.sizedMirror.mirrorReturnedDisplays()
            server.refreshDisplays()
            server.lid.refresh()
            server.scheduleHostStateBroadcast()
            if !server.activeSessions.isEmpty, !server.isHeadlessClosedLid, !ScreenStreamer.shared.isRunning {
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

    /// The lid opened/closed or an external display appeared/vanished. While macOS forces
    /// clamshell sleep there is nothing capture can use, so capture waits instead of
    /// retrying; once a usable display exists again it picks back up.
    private func lidStateChanged() {
        if lid.isLidClosed != isLidClosed || lid.hasExternalDisplay != hasExternalDisplay {
            wakeRequestedWithClosedLid = false
        }
        isLidClosed = lid.isLidClosed
        hasExternalDisplay = lid.hasExternalDisplay
        HostLog.write("lid closed=\(isLidClosed) external=\(hasExternalDisplay) headless=\(isHeadlessClosedLid) sessions=\(activeSessions.count) | \(HostLog.displaySummary())")
        scheduleHostStateBroadcast()
        updatePowerAssertions()
        sizedMirror.mirrorReturnedDisplays()
        // macOS can refuse to mirror a panel that only just came back; once more shortly
        // after (it does nothing when the first try worked).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.sizedMirror.mirrorReturnedDisplays() }
        }
        applyPendingMirrorSize()
        guard !activeSessions.isEmpty, !ScreenStreamer.shared.isRunning, !isHeadlessClosedLid else { return }
        restartCapture()
    }

    /// Keeps the Mac awake only for a session that can use it. macOS forces clamshell sleep
    /// with the lid shut and no external display whatever is held, and holding anything then
    /// only stretches the brief wakes during that sleep, which costs battery.
    private func updatePowerAssertions() {
        if activeSessions.isEmpty || isHeadlessClosedLid {
            power.release()
        } else {
            power.acquire()
        }
    }

    /// Reads the real display-sleep state so a client isn't told stale news after a wake
    /// request. With the lid shut and no external display the screen is simply gone.
    private func refreshDisplaySleepState() {
        isDisplaySleeping = isHeadlessClosedLid ? true : CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Starts sharing at launch when everything it needs is in place. After a crash
    /// relaunch, sharing is only restored if the user hadn't stopped it.
    func autoStartIfNeeded(afterCrash: Bool) {
        // A host that crashed or was killed mid-session left the Dock hidden.
        DockHider.restore()
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
            // Asks Wi-Fi to give this connection's packets the low-delay video queue.
            parameters.serviceClass = .interactiveVideo
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
            newListener.service = advertisedService()
            newListener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    self?.accept(connection, transport: .tcp)
                }
            }
            newListener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.port = newListener.port?.rawValue ?? 0
                        self.readvertise()
                    case .failed(let error):
                        self.lastError = "Server error: \(error.localizedDescription)"
                    default:
                        break
                    }
                }
            }
            listener = newListener
            newListener.start(queue: .main)
            startQUICListener(on: preferredPort)
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
        clipboard.update()
        sessionSettingsReset?.cancel()
        sessionSettingsReset = nil
        endSizedMirror()
        setHidesDock(false)
        lid.stop()
        stopCapsLockWatch()
        power.release()
        hostStateBroadcastWorkItem?.cancel()
        hostStateBroadcastWorkItem = nil
        lastBroadcastHostState = nil
        updateLocalInputBlocking()
        listener?.cancel()
        listener = nil
        quicListener?.cancel()
        quicListener = nil
        quicPort = nil
        quicAcceptor.cancelAll()
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
        // A display still being set up is no desktop yet; this runs again once it is.
        guard !isStartingSizedMirror else { return }
        displays = Self.currentDisplays()
        // The sized mirror's display is listed a moment after it is created.
        if let mirror = sizedMirror.displayID, selectedDisplayID == mirror, CGDisplayIsOnline(mirror) != 0 { return }
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

    var displaysMessage: RDDisplaysMsg {
        RDDisplaysMsg(displays: displays, selectedId: selectedDisplayID,
                      sizedMirrorAvailable: SizedMirror.isAvailable, mirrorSize: mirrorSize)
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

    /// Lays the desktop out at `size` and streams that (the Mac's main display mirrors a
    /// virtual display of that size), or goes back to the Mac's own layout with nil.
    func setSizedMirror(_ size: RDMirrorSize?) {
        let wanted = size.map(SizedMirror.clamped)
        HostLog.write("size wanted=\(wanted?.label ?? "own") current=\(mirrorSize?.label ?? "own") headless=\(isHeadlessClosedLid) | \(HostLog.displaySummary())")
        guard !isStartingSizedMirror else {
            mirrorSizeAfterStart = .some(wanted)
            return
        }
        guard wanted != mirrorSize else { return }
        guard let wanted else {
            pendingMirrorSize = nil
            mirrorSizeRetries = 0
            endSizedMirror()
            return
        }
        guard running, !activeSessions.isEmpty else { return }
        // With the lid shut and no display there is no desktop to lay out yet; it is
        // done as soon as a touch on the client wakes the Mac (or the lid opens).
        guard !isHeadlessClosedLid else {
            pendingMirrorSize = wanted
            return
        }
        pendingMirrorSize = nil
        if mirrorSize == nil { displayBeforeSizedMirror = selectedDisplayID }
        // A size change of the display already there (a turn of the device, say) leaves
        // the windows where they were, so they are fitted to it afterwards.
        let areasBefore = mirrorSize != nil ? WindowActions.screenAreas() : nil
        isStartingSizedMirror = true
        Task { [weak self] in
            guard let self else { return }
            let id = await self.sizedMirror.start(size: wanted)
            self.isStartingSizedMirror = false
            self.finishSizedMirror(wanted, display: id)
            if id != nil, let areasBefore {
                WindowActions.fitWindows(since: areasBefore, settling: .milliseconds(300))
            }
            if let next = self.mirrorSizeAfterStart {
                self.mirrorSizeAfterStart = nil
                self.setSizedMirror(next)
            }
        }
    }

    private func finishSizedMirror(_ wanted: RDMirrorSize, display: CGDirectDisplayID?) {
        guard let id = display else {
            HostLog.write("size failed lid=\(isLidClosed) tries=\(mirrorSizeRetries) | \(HostLog.displaySummary())")
            // Nothing may be left of an earlier virtual display, so the mode is off now.
            endSizedMirror(force: true)
            // With the lid shut the displays are still settling after a wake; the next
            // lid, wake or screen event tries again, a few times at most.
            if isLidClosed, mirrorSizeRetries < 3 {
                mirrorSizeRetries += 1
                pendingMirrorSize = wanted
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    MainActor.assumeIsolated { self?.applyPendingMirrorSize() }
                }
            } else {
                captureError = "Could not set up the \(wanted.label) display."
            }
            return
        }
        // The last client left while the display was being set up.
        guard running, !activeSessions.isEmpty else {
            endSizedMirror(force: true)
            return
        }
        mirrorSizeRetries = 0
        HostLog.write("size started display=\(id) | \(HostLog.displaySummary())")
        mirrorSize = wanted
        selectedDisplayID = id
        refreshDisplays()
        restartCapture()
    }

    /// The desktop size and the hidden Dock outlive the last client for a while: a client
    /// that only dropped or went to the background comes back to the same desktop, without
    /// the displays being rebuilt (which, with the lid shut, removes the only display and
    /// locks the Mac). With the lid open the Mac's own screen is in use, so the wait is short.
    private func scheduleSessionSettingsReset(leftOnPurpose: Bool) {
        sessionSettingsReset?.cancel()
        guard mirrorSize != nil || hidesDock else { return }
        // Nobody is coming back after pressing Disconnect, so there is nothing to wait
        // for. With the lid shut the wait stays: removing the display would lock the Mac.
        if leftOnPurpose, !isLidClosed {
            sessionSettingsReset = nil
            endSizedMirror()
            setHidesDock(false)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activeSessions.isEmpty else { return }
                self.sessionSettingsReset = nil
                self.endSizedMirror()
                self.setHidesDock(false)
            }
        }
        sessionSettingsReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isLidClosed ? 180 : 3), execute: work)
    }

    private func endSizedMirror(force: Bool = false) {
        guard !isStartingSizedMirror else {
            mirrorSizeAfterStart = .some(nil)
            return
        }
        guard force || mirrorSize != nil else { return }
        HostLog.write("size ended force=\(force) sessions=\(activeSessions.count)")
        sizedMirror.stop()
        mirrorSize = nil
        selectedDisplayID = displayBeforeSizedMirror
        displayBeforeSizedMirror = nil
        refreshDisplays()
        if running, !activeSessions.isEmpty { restartCapture() }
    }

    func setCodec(_ codec: RDCodec) {
        Task { await ScreenStreamer.shared.updateConfiguration(preset: preset, codec: codec) }
    }

    /// Debounced capture restart; superseded restarts are expected and not errors.
    private func restartCapture(codec: RDCodec? = nil) {
        Task {
            // The last client may have left between scheduling this and running it.
            guard !activeSessions.isEmpty else { return }
            // With the lid shut and no external display there is nothing capture can use
            // until the lid opens (or a display is attached); `lidStateChanged` retries then.
            guard !isHeadlessClosedLid else { return }
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
        // Forced clamshell sleep takes the display away; waiting for the lid is quieter
        // than a retry loop that can never succeed.
        guard !isHeadlessClosedLid else { return }
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

    // MARK: Transports

    /// The Bonjour record: `sid`, `name`, and `quic=1` (+ `qport` when the UDP port
    /// differs from the TCP one) once the QUIC listener is ready.
    private func advertisedService() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt["sid"] = AuthStore.shared.serverId
        txt["name"] = HostServer.computerName
        if let quicPort {
            txt[RDQUIC.txtFlag] = "1"
            if quicPort != port {
                txt[RDQUIC.txtPort] = String(quicPort)
            }
        }
        return NWListener.Service(name: bonjourName, type: RDService.type, domain: nil, txtRecord: txt.data)
    }

    /// Updates the TXT record (setting the service again re-registers it).
    private func readvertise() {
        listener?.service = advertisedService()
    }

    /// Listens for QUIC on UDP beside TCP. Each incoming stream is a byte stream like a
    /// TCP connection and becomes a `ClientSession` the same way. Failure only means
    /// clients keep using TCP.
    private func startQUICListener(on preferredPort: NWEndpoint.Port, isRetry: Bool = false) {
        guard let identity = QUICIdentityStore.loadOrCreate(),
              let parameters = RDQUIC.serverParameters(identity: identity),
              let newListener = try? NWListener(using: parameters, on: preferredPort) else {
            HostLog.write("QUIC: listener unavailable; TCP only")
            return
        }
        newListener.newConnectionGroupHandler = { [weak self] group in
            MainActor.assumeIsolated {
                guard let self, self.running else { return group.cancel() }
                self.quicAcceptor.accept(group)
            }
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            MainActor.assumeIsolated {
                guard let self, let newListener, self.quicListener === newListener else { return }
                switch state {
                case .ready:
                    self.quicPort = newListener.port?.rawValue
                    HostLog.write("QUIC: listening on UDP \(self.quicPort ?? 0)")
                    self.readvertise()
                case .failed(let error):
                    newListener.cancel()
                    self.quicListener = nil
                    self.quicPort = nil
                    self.readvertise()
                    HostLog.write("QUIC: listener failed (\(error.localizedDescription))")
                    if !isRetry, preferredPort != .any {
                        self.startQUICListener(on: .any, isRetry: true)
                    }
                default:
                    break
                }
            }
        }
        quicListener = newListener
        newListener.start(queue: .main)
    }

    private func accept(_ connection: NWConnection, transport: RDTransport, group: NWConnectionGroup? = nil,
                        initialData: Data = Data()) {
        guard running else {
            connection.cancel()
            group?.cancel()
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
            group?.cancel()
            return
        }
        let session = ClientSession(connection: connection, server: self, remoteAddress: address, quicGroup: group,
                                    initialData: initialData)
        HostLog.write("session from \(address) over \(transport == .quic ? "QUIC" : "TCP")")
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

    func sessionDidAuthenticate(_ session: ClientSession) {
        sessionSettingsReset?.cancel()
        sessionSettingsReset = nil
        HostLog.write("session started lid=\(isLidClosed) headless=\(isHeadlessClosedLid) | \(HostLog.displaySummary())")
        refreshDisplays()
        pendingSessions.removeAll { $0 === session }
        // Only a session needs the lid state, so nothing polls while no one is connected.
        lid.start()
        startCapsLockWatch()
        if !activeSessions.contains(where: { $0 === session }) {
            activeSessions.append(session)
        }

        // A client should get a live screen when one is available. Waking is pointless
        // (and only restarts the sleep/wake loop) with the lid shut and no external
        // display, where macOS forces clamshell sleep regardless of any assertion.
        updatePowerAssertions()
        if !isHeadlessClosedLid {
            InputInjector.wakeDisplay(within: streamedDisplayBounds)
        }
        refreshDisplaySleepState()

        let state = hostStateMessage
        session.sendHostState(state)
        lastBroadcastHostState = state
        session.sendRunningApps(appSwitcher.runningApps())
        session.sendHardwareControls(HardwareController.getState())
        session.sendDisplays(displaysMessage)

        updateClientName()
        updateFrameGate()
        updateLocalInputBlocking()
        if let keyframe = ScreenStreamer.shared.lastKeyframe {
            session.sendVideoFrame(keyframe.data, isKeyframe: true, width: keyframe.width, height: keyframe.height, codec: keyframe.codec)
        }
        restartCapture()
    }

    func sessionDidEnd(_ session: ClientSession) {
        HostLog.write("session ended, \(activeSessions.filter { $0 !== session }.count) left")
        pendingSessions.removeAll { $0 === session }
        activeSessions.removeAll { $0 === session }
        clipboard.update()
        updateFrameGate()
        updateLocalInputBlocking()
        if activeSessions.isEmpty {
            clientName = nil
            wakeRequestedWithClosedLid = false
            pendingMirrorSize = nil
            mirrorSizeRetries = 0
            scheduleSessionSettingsReset(leftOnPurpose: session.leftOnPurpose)
            lid.stop()
            stopCapsLockWatch()
            power.release()
            ScreenStreamer.shared.stop()
            hostStateBroadcastWorkItem?.cancel()
            hostStateBroadcastWorkItem = nil
            lastBroadcastHostState = nil
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
        ScreenStreamer.shared.setDynamicBitrate(encoderBitrate)
    }

    /// The bitrate the shared encoder runs at.
    var encoderBitrate: Int {
        let factor = activeSessions.map(\.bitrateFactor).min() ?? 1.0
        return Int(Double(preset.targetBitrate) * factor)
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
        lid.refresh()
        HostLog.write("wake request lid=\(isLidClosed) headless=\(isHeadlessClosedLid) locked=\(isHostLocked) sleeping=\(isDisplaySleeping) | \(HostLog.displaySummary())")
        updatePowerAssertions()
        // Wake requests come from the user's touches on the client, so try even with the lid
        // shut and no external display: the display often wakes then. Automatic wakes
        // (on connect, after capture loss) still skip that state to avoid a wake/sleep loop.
        if isLidClosed, !hasExternalDisplay, !wakeRequestedWithClosedLid {
            wakeRequestedWithClosedLid = true
            updatePowerAssertions()
        }
        InputInjector.wakeDisplay(within: streamedDisplayBounds)
        isDisplaySleeping = false
        broadcastHostState()
        restartCapture()
        applyPendingMirrorSize()
    }

    private func applyPendingMirrorSize() {
        guard let size = pendingMirrorSize, !isHeadlessClosedLid, !activeSessions.isEmpty else { return }
        pendingMirrorSize = nil
        setSizedMirror(size)
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

    var hostStateMessage: HostStateMsg {
        HostStateMsg(isLocked: HostStateMsg.reportsLocked(isLocked: isHostLocked, isDisplaySleeping: isDisplaySleeping),
                     isDisplaySleeping: isDisplaySleeping,
                     blocksLocalInput: blocksLocalInput,
                     isLidClosed: isLidClosed,
                     hasExternalDisplay: hasExternalDisplay,
                     hidesDock: DockHider.isAvailable ? hidesDock : nil,
                     windowActions: true,
                     capsLock: InputInjector.isCapsLockOn)
    }

    /// Caps Lock can change on the Mac's own keyboard too, and macOS posts nothing for it,
    /// so its state is read twice a second while a device is connected.
    private func startCapsLockWatch() {
        guard capsLockTimer == nil else { return }
        capsLockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capsLockMayHaveChanged() }
        }
    }

    private func stopCapsLockWatch() {
        capsLockTimer?.invalidate()
        capsLockTimer = nil
    }

    /// Tells the clients at once when Caps Lock flipped, without the usual debounce.
    func capsLockMayHaveChanged() {
        guard let last = lastBroadcastHostState, last.capsLock != InputInjector.isCapsLockOn else { return }
        broadcastHostState()
    }

    /// Hides the Dock for the connected clients or shows it again, and tells every client.
    func setHidesDock(_ on: Bool) {
        guard DockHider.isAvailable, on != hidesDock, !on || !activeSessions.isEmpty else { return }
        hidesDock = on
        WindowActions.fitWindowsToDock { if on { DockHider.hide() } else { DockHider.restore() } }
        scheduleHostStateBroadcast()
    }

    /// Changes the setting, from the menu or a client, and tells every client.
    func setBlocksLocalInput(_ on: Bool) {
        guard on != blocksLocalInput else { return }
        blocksLocalInput = on
        UserDefaults.standard.set(on, forKey: Self.blocksLocalInputKey)
        updateLocalInputBlocking()
        broadcastHostState()
    }

    /// Blocks the Mac's own input while the setting is on and a device is connected.
    private func updateLocalInputBlocking() {
        let wanted = blocksLocalInput && !activeSessions.isEmpty
        if wanted, !inputBlocker.isActive {
            localInputBlockError = inputBlocker.start()
                ? nil
                : "macOS didn't allow it. Check that LocalDesktop is on under Privacy & Security → Accessibility."
        } else if !wanted {
            inputBlocker.stop()
            if !blocksLocalInput { localInputBlockError = nil }
        }
        isBlockingLocalInput = inputBlocker.isActive
    }

    nonisolated private static func readIsLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Sends the current host state to every client. Identical state is not re-sent.
    func broadcastHostState() {
        hostStateBroadcastWorkItem?.cancel()
        hostStateBroadcastWorkItem = nil
        let msg = hostStateMessage
        guard msg != lastBroadcastHostState else { return }
        lastBroadcastHostState = msg
        for s in activeSessions {
            s.sendHostState(msg)
        }
    }

    /// Coalesces the bursts of state changes macOS emits around sleep/wake and
    /// lock/unlock, so the client sees one settled state instead of flickering.
    func scheduleHostStateBroadcast() {
        hostStateBroadcastWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.broadcastHostState()
            }
        }
        hostStateBroadcastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hostStateDebounce, execute: work)
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
