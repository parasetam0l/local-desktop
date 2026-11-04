import AppKit
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
/// event taps, so typing into one isn't blocked. Key releases pass so nothing stays
/// pressed. A volume key held when blocking starts keeps acting until it stops, because
/// its release never reaches the tap.
final class LocalInputBlocker: @unchecked Sendable {
    /// `InputInjector` sets this as the user data of every event it posts.
    static let injectedEventTag: Int64 = 0x4C44_6573_6B74 // "LDeskt"

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    /// Where LocalDesktop last put the pointer; set before the tap starts, then only on its thread.
    private var heldPosition: CGPoint?

    var isActive: Bool { lock.withLock { tap != nil } }

    /// Starts blocking. False when macOS refuses the event tap, which needs the
    /// Accessibility permission.
    func start() -> Bool {
        if isActive { return true }
        heldPosition = CGEvent(source: nil)?.location

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
            lock.withLock {
                self.tap = tap
                self.runLoop = runLoop
            }
            created = true
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "LocalDesktop input blocker"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        return created
    }

    func stop() {
        let (tap, runLoop) = lock.withLock {
            defer {
                self.tap = nil
                self.runLoop = nil
            }
            return (self.tap, self.runLoop)
        }
        guard let tap, let runLoop else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        CFRunLoopStop(runLoop)
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
                heldPosition = event.location
            }
            return Unmanaged.passUnretained(event)
        }
        // A key held when blocking started would otherwise stay pressed. A release does
        // nothing on its own.
        if Self.isRelease(type, event) { return Unmanaged.passUnretained(event) }
        if isPointerMove, let heldPosition {
            CGWarpMouseCursorPosition(heldPosition)
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
