import AppKit
import ApplicationServices

/// Tells whether the keyboard focus on the Mac is in something you type into, so a
/// client can bring up its keyboard after a click. It asks the Accessibility API (the
/// permission the host already has for input). Apps that report focus poorly simply
/// read as "not text"; the client's keyboard button still works there.
enum TextFocusProbe {
    private static let queue = DispatchQueue(label: "rd.text-focus", qos: .userInitiated)
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Checks shortly after a click, once the app has moved its focus, off the main
    /// thread because a busy app can take a moment to answer.
    @MainActor
    static func check(after delay: TimeInterval = 0.25, completion: @escaping @MainActor (Bool) -> Void) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        queue.asyncAfter(deadline: .now() + delay) {
            let editable = isTextFocused(frontmostPID: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(editable) }
            }
        }
    }

    private static func isTextFocused(frontmostPID: pid_t?) -> Bool {
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
}
