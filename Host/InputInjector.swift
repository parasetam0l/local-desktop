import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

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
                               units: .pixel,
                               wheelCount: 2,
                               wheel1: Int32(dy.rounded()),
                               wheel2: Int32(dx.rounded()),
                               wheel3: 0) {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Types text as unicode key events, one code point per down/up pair.
    static func text(_ string: String) {
        for scalar in string.unicodeScalars {
            var buffer = Array(String(scalar).utf16)
            guard !buffer.isEmpty else { continue }
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            up?.post(tap: .cghidEventTap)
        }
    }

    static func key(code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
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
