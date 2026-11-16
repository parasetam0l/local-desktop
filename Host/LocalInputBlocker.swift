import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Drops this Mac's own keyboard and trackpad (or mouse) input while a remote session
/// asks for it, so whatever lies on the keyboard can't type or click. Events that
/// LocalDesktop injects carry `injectedEventTag` and pass.
///
/// An event tap can't stop the pointer from moving (the window server moves it before
/// taps see the event), so a moved pointer is put back where LocalDesktop last left it.
/// The tap runs on its own thread because every input event on the Mac waits for its
/// callback. macOS removes the tap with the process, so input comes back even if
/// LocalDesktop quits or crashes. Password fields (Secure Input) hide keystrokes from
/// event taps, so typing into one isn't blocked; `isSecureInputActive` tracks that
/// state (including when another app leaves Secure Input active after leaving a password
/// field) and the heartbeat keeps the tap enabled once macOS allows it again. Key
/// releases pass so nothing stays pressed. A volume key held when blocking starts keeps
/// acting until it stops, because its release never reaches the tap.
///
/// Sessions run on the main queue, so anything that stalls it, such as a modal alert,
/// stops sessions from ending or injecting input, and only the Mac's own input can clear
/// it. So blocking lets input through while the main queue is stuck.
final class LocalInputBlocker: @unchecked Sendable {
    /// `InputInjector` sets this as the user data of every event it posts.
    static let injectedEventTag: Int64 = 0x4C44_6573_6B74 // "LDeskt"

    private let lock = NSLock()
    private let isSecureInputEnabled: @Sendable () -> Bool
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    /// Where LocalDesktop last put the pointer; set before the tap starts, then only on its thread.
    private var heldPosition: CGPoint?
    /// How long the main queue may go quiet before the Mac's own input passes.
    static let mainQueueStallLimit: TimeInterval = 3
    private var lastMainQueueBeat: TimeInterval?
    private var _isSecureInputActive = false
    private var restartedWhileDisabled = false
    private var heartbeat: DispatchSourceTimer?
    private var _onStateChange: (@Sendable () -> Void)?
    var onStateChange: (@Sendable () -> Void)? {
        get { lock.withLock { _onStateChange } }
        set { lock.withLock { _onStateChange = newValue } }
    }

    init(isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }) {
        self.isSecureInputEnabled = isSecureInputEnabled
    }

    var isActive: Bool { lock.withLock { tap != nil } }
    var isSecureInputActive: Bool { lock.withLock { _isSecureInputActive } }

    /// Starts blocking. False when macOS refuses the event tap, which needs the
    /// Accessibility permission.
    func start() -> Bool {
        if isActive { return true }
        let initialPosition = CGEvent(source: nil)?.location
        lock.withLock {
            heldPosition = initialPosition
            restartedWhileDisabled = false
        }

        let started = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var created = false
        let thread = Thread { [self] in
            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            // At the HID level, ahead of the session, so system shortcuts like modifier and
            // function key combinations can't act on input first.
            guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: Self.eventMask,
                                              callback: tapCallback, userInfo: userInfo),
                  let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                started.signal()
                return
            }
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            let secure = isSecureInputEnabled()
            lock.withLock {
                self.tap = tap
                self.runLoop = runLoop
                self._isSecureInputActive = secure
            }
            created = true
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "LocalDesktop input blocker"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        if created { startHeartbeat() }
        return created
    }

    /// Runs on the same queue as sessions, so it stops exactly when they do.
    private func startHeartbeat() {
        heartbeat?.cancel()
        noteMainQueueAlive()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.noteMainQueueAlive()
            self.refreshHealth()
        }
        timer.resume()
        heartbeat = timer
    }

    func noteMainQueueAlive(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock { lastMainQueueBeat = time }
    }

    private var isMainQueueStalledLocked: Bool {
        guard let beat = lastMainQueueBeat else { return false }
        return ProcessInfo.processInfo.systemUptime - beat > Self.mainQueueStallLimit
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        let (tap, runLoop) = lock.withLock {
            defer {
                self.tap = nil
                self.runLoop = nil
                self.heldPosition = nil
                self.lastMainQueueBeat = nil
                self._isSecureInputActive = false
                self.restartedWhileDisabled = false
            }
            return (self.tap, self.runLoop)
        }
        guard let tap, let runLoop else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        CFRunLoopStop(runLoop)
    }

    /// Re-checks Secure Input and verifies macOS didn't leave the tap disabled (e.g.
    /// after a timeout during Secure Input or across sleep/wake).
    func refreshHealth() {
        let tap = lock.withLock { self.tap }
        guard let tap else { return }
        evaluateHealth(
            tapEnabled: { CGEvent.tapIsEnabled(tap: tap) },
            enableTap: {
                CGEvent.tapEnable(tap: tap, enable: true)
                return CGEvent.tapIsEnabled(tap: tap)
            },
            restartTap: { [self] in
                stop()
                return start()
            }
        )
    }

    func evaluateHealth(tapEnabled: () -> Bool,
                        enableTap: () -> Bool,
                        restartTap: () -> Bool) {
        let secure = isSecureInputEnabled()
        let (wasSecure, alreadyRestarted) = lock.withLock {
            let previousSecure = _isSecureInputActive
            _isSecureInputActive = secure
            return (previousSecure, restartedWhileDisabled)
        }
        var stateChanged = (secure != wasSecure)

        if tapEnabled() {
            lock.withLock { restartedWhileDisabled = false }
        } else if enableTap() {
            lock.withLock { restartedWhileDisabled = false }
        } else if !secure && !alreadyRestarted {
            // macOS may keep an old Mach port disabled after wake/unlock or a timeout;
            // replace it once per disable episode once Secure Input is clear.
            let restarted = restartTap()
            let nowSecure = lock.withLock {
                restartedWhileDisabled = true
                return _isSecureInputActive
            }
            if !restarted || nowSecure != wasSecure {
                stateChanged = true
            }
        }

        if stateChanged {
            onStateChange?()
        }
    }

    /// The tap's decision: LocalDesktop's own events, the tap's housekeeping and releases
    /// pass, anything else is dropped.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off; keep blocking.
            if let tap = lock.withLock({ self.tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        default:
            break
        }

        let isPointerMove = Self.pointerMoves.contains(type)
        if event.getIntegerValueField(.eventSourceUserData) == Self.injectedEventTag {
            if isPointerMove || Self.pointerButtons.contains(type) {
                lock.withLock { heldPosition = event.location }
            }
            return Unmanaged.passUnretained(event)
        }
        let (stalled, held) = lock.withLock { (isMainQueueStalledLocked, heldPosition) }
        // A key held when blocking started would otherwise stay pressed. A release does
        // nothing on its own.
        if Self.isRelease(type, event) || stalled { return Unmanaged.passUnretained(event) }
        if isPointerMove, let held {
            CGWarpMouseCursorPosition(held)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        return nil
    }

    static func isRelease(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .keyUp, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return true
        case .flagsChanged:
            guard let flag = modifierFlags[event.getIntegerValueField(.keyboardEventKeycode)] else { return false }
            return event.flags.rawValue & flag == 0
        default:
            // Media and brightness keys: system-defined events with the key state in data1.
            guard type.rawValue == 14, let systemEvent = NSEvent(cgEvent: event),
                  systemEvent.subtype.rawValue == 8 else { return false }
            return (systemEvent.data1 & 0xFF00) >> 8 == 0x0B
        }
    }

    // NX_DEVICE*KEYMASK for each modifier, and the Fn flag. Caps Lock toggles in hardware
    // below the tap, so its events have no release to pass.
    private static let modifierFlags: [Int64: UInt64] = [
        54: 0x10, 55: 0x08, 56: 0x02, 60: 0x04, 59: 0x01, 62: 0x2000, 58: 0x20, 61: 0x40, 63: 0x800000,
    ]

    private static let pointerMoves: Set<CGEventType> = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    private static let pointerButtons: Set<CGEventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                                           .otherMouseDown, .otherMouseUp]

    static let eventMask: CGEventMask = {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel, .tabletPointer, .tabletProximity]
        let raw = (types + Array(pointerMoves) + Array(pointerButtons)).map(\.rawValue) + [
            14,                                 // system-defined: media, brightness and volume keys
            18, 19, 20, 29, 30, 31, 32, 33, 34, // trackpad gestures (rotate, magnify, swipe, force click…)
        ]
        return raw.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
    }()
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<LocalInputBlocker>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}
