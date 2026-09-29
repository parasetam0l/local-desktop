import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.pwr_mgt
import Carbon

/// Posts mouse, scroll, and keyboard events into the system event stream.
enum InputInjector {
    private static let source = CGEventSource(stateID: .hidSystemState)
    private static var trackedPosition: CGPoint?

    /// Cocoa screen coordinates have a bottom-left origin; CGEvent wants top-left.
    static var currentPositionTopLeft: CGPoint {
        if let pos = trackedPosition {
            return pos
        }
        if let loc = CGEvent(source: nil)?.location {
            trackedPosition = loc
            return loc
        }
        let location = NSEvent.mouseLocation
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let p = CGPoint(x: location.x, y: mainHeight - location.y)
        trackedPosition = p
        return p
    }

    /// Buttons are ignored for `.mouseMoved`; passing `.left` satisfies the initializer.
    static func moveAbs(_ x: Double, _ y: Double) {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let point = CGPoint(x: min(max(x, bounds.minX), bounds.maxX),
                            y: min(max(y, bounds.minY), bounds.maxY))
        trackedPosition = point
        CGWarpMouseCursorPosition(point)
        // CGWarp hides the cursor by dissociating it; re-associate to keep it visible
        // in both the display and the ScreenCaptureKit stream.
        CGAssociateMouseAndMouseCursorPosition(1)
        if let event = CGEvent(mouseEventSource: nil,
                               mouseType: .mouseMoved,
                               mouseCursorPosition: point,
                               mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    static func moveRel(dx: Double, dy: Double) {
        let base = currentPositionTopLeft
        moveAbs(base.x + dx, base.y + dy)
    }

    private static var lastUserActivityTickle: TimeInterval = 0

    /// Throttled user activity declaration to inform macOS powerd of ongoing local interaction.
    static func tickleUserActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUserActivityTickle > 4.0 else { return }
        lastUserActivityTickle = now

        var id: IOPMAssertionID = 0
        let ret = IOPMAssertionDeclareUserActivity("Local Desktop User Activity" as CFString, kIOPMUserActiveLocal, &id)
        if ret == kIOReturnSuccess && id != 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                IOPMAssertionRelease(id)
            }
        }
    }

    /// Awakens the display from dark wake / power saving state using a multi-vector wake sequence:
    /// 1. IOKit local user active power assertion
    /// 2. Asynchronous caffeinate -u invocation
    /// 3. Non-zero hardware cursor delta nudge
    /// 4. Non-destructive modifier key pulse (Shift key tap)
    static func wakeDisplay() {
        lastUserActivityTickle = ProcessInfo.processInfo.systemUptime
        // 1. Declare User Activity to IOKit Power Management
        var assertionID: IOPMAssertionID = 0
        let ret = IOPMAssertionDeclareUserActivity("Local Desktop Wake Display" as CFString, kIOPMUserActiveLocal, &assertionID)
        if ret == kIOReturnSuccess && assertionID != 0 {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 1.5) {
                IOPMAssertionRelease(assertionID)
            }
        }

        // 2. Invoke caffeinate -u -t 3 asynchronously to trigger system display wake via powerd
        DispatchQueue.global(qos: .userInteractive).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            proc.arguments = ["-u", "-t", "3"]
            try? proc.run()
        }

        // 3. Move cursor by an actual non-zero delta (+2, +2 then back) so WindowServer processes motion
        let base = currentPositionTopLeft
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let offsetX: Double = (base.x + 2 > bounds.maxX) ? -2 : 2
        let offsetY: Double = (base.y + 2 > bounds.maxY) ? -2 : 2
        moveAbs(base.x + offsetX, base.y + offsetY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            moveAbs(base.x, base.y)
        }

        // 4. Inject a quick non-destructive modifier pulse (Shift key down and up: keyCode 0x38)
        let shiftKeyCode: CGKeyCode = 0x38
        if let eventDown = CGEvent(keyboardEventSource: source, virtualKey: shiftKeyCode, keyDown: true) {
            eventDown.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            if let eventUp = CGEvent(keyboardEventSource: source, virtualKey: shiftKeyCode, keyDown: false) {
                eventUp.post(tap: .cghidEventTap)
            }
        }
    }

    private static var lastClickTime: TimeInterval = 0
    private static var clickCount: Int64 = 1

    static func buttonDown(_ button: Int) {
        let position = currentPositionTopLeft
        let mouseType: CGEventType = button == 1 ? .rightMouseDown : .leftMouseDown
        let mouseButton: CGMouseButton = button == 1 ? .right : .left

        let now = Date().timeIntervalSince1970
        if now - lastClickTime < NSEvent.doubleClickInterval {
            clickCount = min(clickCount + 1, 3)
        } else {
            clickCount = 1
        }
        lastClickTime = now

        if let event = CGEvent(mouseEventSource: source,
                               mouseType: mouseType,
                               mouseCursorPosition: position,
                               mouseButton: mouseButton) {
            event.setIntegerValueField(.mouseEventClickState, value: clickCount)
            event.post(tap: .cghidEventTap)
        }
    }

    static func buttonUp(_ button: Int) {
        let position = currentPositionTopLeft
        let mouseType: CGEventType = button == 1 ? .rightMouseUp : .leftMouseUp
        let mouseButton: CGMouseButton = button == 1 ? .right : .left
        if let event = CGEvent(mouseEventSource: source,
                               mouseType: mouseType,
                               mouseCursorPosition: position,
                               mouseButton: mouseButton) {
            event.setIntegerValueField(.mouseEventClickState, value: clickCount)
            event.post(tap: .cghidEventTap)
        }
    }

    /// dy > 0 scrolls toward the end of the document (finger swipe up on the client).
    static func scroll(dx: Double, dy: Double) {
        if let event = CGEvent(scrollWheelEvent2Source: source,
                               units: .line,
                               wheelCount: 2,
                               wheel1: Int32(dy.rounded()),
                               wheel2: Int32(dx.rounded()),
                               wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }

    private struct KeyMapping {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    private static let keyMapLock = NSLock()
    private static var cachedLayoutID: String = ""
    private static var charToKeyMap: [String: KeyMapping] = [:]

    private static func keyMapping(for character: String) -> KeyMapping? {
        keyMapLock.lock()
        defer { keyMapLock.unlock() }

        updateKeyMapIfNeeded()
        return charToKeyMap[character]
            ?? charToKeyMap[character.precomposedStringWithCanonicalMapping]
            ?? charToKeyMap[character.decomposedStringWithCanonicalMapping]
    }

    private static func updateKeyMapIfNeeded() {
        guard let (layoutData, layoutID) = getLayoutData() else {
            if charToKeyMap.isEmpty {
                buildFallbackKeyMap()
            }
            return
        }

        if layoutID == cachedLayoutID && !charToKeyMap.isEmpty {
            return
        }

        cachedLayoutID = layoutID
        charToKeyMap.removeAll(keepingCapacity: true)

        let keyLayoutPtr = CFDataGetBytePtr(layoutData)
        guard let rawBase = keyLayoutPtr else {
            buildFallbackKeyMap()
            return
        }
        let keyLayout = UnsafeRawPointer(rawBase).bindMemory(to: UCKeyboardLayout.self, capacity: 1)

        let modifierCombos: [(UInt32, CGEventFlags)] = [
            (0, []),
            (UInt32(shiftKey >> 8), [.maskShift]),
            (UInt32(optionKey >> 8), [.maskAlternate]),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate])
        ]

        for (modState, flags) in modifierCombos {
            for code: UInt16 in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length: Int = 0
                let err = UCKeyTranslate(
                    keyLayout,
                    code,
                    UInt16(kUCKeyActionDown),
                    modState,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    4,
                    &length,
                    &chars
                )
                if err == noErr && length > 0 {
                    let str = String(utf16CodeUnits: chars, count: length)
                    let mapping = KeyMapping(keyCode: CGKeyCode(code), flags: flags)
                    if charToKeyMap[str] == nil {
                        charToKeyMap[str] = mapping
                        charToKeyMap[str.precomposedStringWithCanonicalMapping] = mapping
                        charToKeyMap[str.decomposedStringWithCanonicalMapping] = mapping
                    }
                }
            }
        }

        if charToKeyMap["\n"] == nil { charToKeyMap["\n"] = KeyMapping(keyCode: 36, flags: []) }
        if charToKeyMap["\r"] == nil { charToKeyMap["\r"] = KeyMapping(keyCode: 36, flags: []) }
        if charToKeyMap["\t"] == nil { charToKeyMap["\t"] = KeyMapping(keyCode: 48, flags: []) }
        if charToKeyMap[" "] == nil { charToKeyMap[" "] = KeyMapping(keyCode: 49, flags: []) }
    }

    private static func getLayoutData() -> (CFData, String)? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
            let id = (TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
                .map { unsafeBitCast($0, to: CFString.self) as String }) ?? "current"
            if let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
                let data = unsafeBitCast(layoutDataRef, to: CFData.self)
                return (data, id)
            }
        }
        if let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            let id = (TISGetInputSourceProperty(asciiSource, kTISPropertyInputSourceID)
                .map { unsafeBitCast($0, to: CFString.self) as String }) ?? "ascii"
            if let layoutDataRef = TISGetInputSourceProperty(asciiSource, kTISPropertyUnicodeKeyLayoutData) {
                let data = unsafeBitCast(layoutDataRef, to: CFData.self)
                return (data, id)
            }
        }
        return nil
    }

    private static func buildFallbackKeyMap() {
        let ansiBase: [(Character, CGKeyCode)] = [
            ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3), ("g", 5),
            ("h", 4), ("i", 34), ("j", 38), ("k", 40), ("l", 37), ("m", 46), ("n", 45),
            ("o", 31), ("p", 35), ("q", 12), ("r", 15), ("s", 1), ("t", 17), ("u", 32),
            ("v", 9), ("w", 13), ("x", 7), ("y", 16), ("z", 6),
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23),
            ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29),
            (" ", 49), ("\t", 48), ("\n", 36), ("\r", 36),
            ("-", 27), ("=", 24), ("[", 33), ("]", 30), ("\\", 42),
            (";", 41), ("'", 39), (",", 43), (".", 47), ("/", 44), ("`", 50)
        ]
        for (char, code) in ansiBase {
            charToKeyMap[String(char)] = KeyMapping(keyCode: code, flags: [])
            let upper = String(char).uppercased()
            if upper != String(char) && charToKeyMap[upper] == nil {
                charToKeyMap[upper] = KeyMapping(keyCode: code, flags: [.maskShift])
            }
        }
        let shiftedSymbols: [(Character, CGKeyCode)] = [
            ("!", 18), ("@", 19), ("#", 20), ("$", 21), ("%", 23),
            ("^", 22), ("&", 26), ("*", 28), ("(", 25), (")", 29),
            ("_", 27), ("+", 24), ("{", 33), ("}", 30), ("|", 42),
            (":", 41), ("\"", 39), ("<", 43), (">", 47), ("?", 44), ("~", 50)
        ]
        for (char, code) in shiftedSymbols {
            charToKeyMap[String(char)] = KeyMapping(keyCode: code, flags: [.maskShift])
        }
    }

    /// Types text by mapping characters to actual virtual key codes and modifiers,
    /// ensuring hypervisors (like Parallels Desktop), remote sessions, and native macOS apps
    /// receive both physical keycodes and Unicode payloads.
    static func text(_ string: String) {
        for character in string {
            let charStr = String(character)
            var buffer = Array(charStr.utf16)
            guard !buffer.isEmpty else { continue }

            if let mapping = keyMapping(for: charStr) {
                let needsShift = mapping.flags.contains(.maskShift)
                let needsAlt = mapping.flags.contains(.maskAlternate)

                // 1. Press modifier keys if required so hypervisors (Parallels/VMware) see the modifier state
                if needsShift {
                    if let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true) {
                        shiftDown.type = .flagsChanged
                        shiftDown.flags = [.maskShift]
                        shiftDown.post(tap: .cghidEventTap)
                    }
                }
                if needsAlt {
                    if let altDown = CGEvent(keyboardEventSource: source, virtualKey: 58, keyDown: true) {
                        altDown.type = .flagsChanged
                        var f: CGEventFlags = [.maskAlternate]
                        if needsShift { f.insert(.maskShift) }
                        altDown.flags = f
                        altDown.post(tap: .cghidEventTap)
                    }
                }

                // 2. Dispatch mapped keycode with Unicode payload attached
                if let down = CGEvent(keyboardEventSource: source, virtualKey: mapping.keyCode, keyDown: true) {
                    down.flags = mapping.flags
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
                    down.post(tap: .cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: source, virtualKey: mapping.keyCode, keyDown: false) {
                    up.flags = mapping.flags
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
                    up.post(tap: .cghidEventTap)
                }

                // 3. Release modifier keys
                if needsAlt {
                    if let altUp = CGEvent(keyboardEventSource: source, virtualKey: 58, keyDown: false) {
                        altUp.type = .flagsChanged
                        altUp.flags = needsShift ? [.maskShift] : []
                        altUp.post(tap: .cghidEventTap)
                    }
                }
                if needsShift {
                    if let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) {
                        shiftUp.type = .flagsChanged
                        shiftUp.flags = []
                        shiftUp.post(tap: .cghidEventTap)
                    }
                }
            } else {
                // Fallback for unmapped characters (emojis, complex scripts)
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
                down?.post(tap: .cghidEventTap)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
                up?.post(tap: .cghidEventTap)
            }
        }
    }


    static func key(code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let isModifier = (code == 56 || code == 60 || code == 55 || code == 54 || code == 58 || code == 61 || code == 59 || code == 62)
        
        if isModifier {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) {
                event.type = .flagsChanged
                var cleanFlags = flags
                if !down {
                    if code == 56 || code == 60 { cleanFlags.remove(.maskShift) }
                    if code == 55 || code == 54 { cleanFlags.remove(.maskCommand) }
                    if code == 58 || code == 61 { cleanFlags.remove(.maskAlternate) }
                    if code == 59 || code == 62 { cleanFlags.remove(.maskControl) }
                }
                event.flags = cleanFlags
                event.post(tap: .cghidEventTap)
            }
        } else {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        }
    }

    static func flags(_ modifiers: RDModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    /// Checks the Accessibility permission; optionally shows the system prompt.
    static func checkAccessibility(prompt: Bool = true) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }
}
