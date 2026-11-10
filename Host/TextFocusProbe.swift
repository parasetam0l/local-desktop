import AppKit
import ApplicationServices

/// Tells whether a click landed in something you type into on the Mac, so a client can
/// bring up its keyboard after it. A field that only took the focus by itself (a dialog
/// that opens with its text field active) doesn't count: the click has to be inside it.
/// It asks the Accessibility API (the permission the host already has for input). Apps
/// that report focus poorly simply read as "not text"; the client's keyboard button
/// still works there.
enum TextFocusProbe {
    private static let queue = DispatchQueue(label: "rd.text-focus", qos: .userInitiated)
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Checks shortly after a click, once the app has moved its focus, off the main
    /// thread because a busy app can take a moment to answer.
    @MainActor
    static func check(after delay: TimeInterval = 0.25, completion: @escaping @MainActor (Bool) -> Void) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Where the click was, in the top-left based coordinates accessibility uses.
        let click = CGEvent(source: nil)?.location
        queue.asyncAfter(deadline: .now() + delay) {
            let editable = isTextFocused(frontmostPID: pid, click: click)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(editable) }
            }
        }
    }

    private static func isTextFocused(frontmostPID: pid_t?, click: CGPoint?) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        if let frontmostPID {
            // Electron apps build their accessibility tree only when asked to.
            let app = AXUIElementCreateApplication(frontmostPID)
            AXUIElementSetMessagingTimeout(app, 0.3)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)

        guard isText(element) else { return false }
        // An element that doesn't tell where it is counts as clicked, as before.
        guard let click, let frame = frame(of: element) else { return true }
        return frame.insetBy(dx: -4, dy: -4).contains(click)
    }

    private static func isText(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String, textRoles.contains(role) {
            return true
        }
        // Web pages and custom editors: anything whose text selection can be set.
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
}
