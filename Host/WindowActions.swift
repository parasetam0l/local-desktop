import AppKit
import ApplicationServices

/// Acts on the front app's focused window for a client: close, minimise, full screen,
/// and placing it on a half or the whole of its screen. It uses the Accessibility API
/// (the permission the host already has for input), off the main thread because a busy
/// app can take a moment to answer. Apps without standard windows simply don't react.
enum WindowActions {
    private static let queue = DispatchQueue(label: "rd.window-actions", qos: .userInitiated)

    /// A screen's usable area (without menu bar and Dock) in the top-left based
    /// coordinates accessibility uses.
    private struct ScreenArea {
        let full: CGRect
        let usable: CGRect
    }

    /// Describes the front app's focused window.
    @MainActor
    static func describe(after delay: TimeInterval = 0, completion: @escaping @MainActor (RDFrontWindowMsg) -> Void) {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier
        let name = front.localizedName ?? ""
        queue.asyncAfter(deadline: .now() + delay) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var message = RDFrontWindowMsg(app: name, title: nil, isFullScreen: false)
            if let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) {
                AXUIElementSetMessagingTimeout(window, 0.5)
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                message = RDFrontWindowMsg(app: name, title: (title as? String) ?? "",
                                           isFullScreen: bool(window, "AXFullScreen") ?? false)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(message) }
            }
        }
    }

    /// Does `action`, then describes the window that is in front afterwards.
    @MainActor
    static func perform(_ action: RDSystemActionType, completion: @escaping @MainActor (RDFrontWindowMsg) -> Void) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        // Cocoa measures from the bottom of the primary screen, accessibility from its top.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let areas = NSScreen.screens.map { screen in
            ScreenArea(full: flipped(screen.frame, primaryHeight: primaryHeight),
                       usable: flipped(screen.visibleFrame, primaryHeight: primaryHeight))
        }
        queue.async {
            let done = run(action, pid: pid, areas: areas)
            HostLog.write("window \(action.rawValue) \(done ? "done" : "not possible")")
            DispatchQueue.main.async {
                // Full screen and close animate; describe once the window has settled.
                MainActor.assumeIsolated { describe(after: action == .windowFullScreen ? 1.0 : 0.45, completion: completion) }
            }
        }
    }

    private static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func run(_ action: RDSystemActionType, pid: pid_t, areas: [ScreenArea]) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { return false }
        AXUIElementSetMessagingTimeout(window, 0.5)

        switch action {
        case .windowClose:
            guard let button = element(window, kAXCloseButtonAttribute) else { return false }
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        case .windowMinimize:
            return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        case .windowFullScreen:
            let isFullScreen = bool(window, "AXFullScreen") ?? false
            return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString,
                                                isFullScreen ? kCFBooleanFalse : kCFBooleanTrue) == .success
        case .windowLeftHalf, .windowRightHalf, .windowFill:
            // A full screen window has no frame to set; it has to leave full screen first.
            guard bool(window, "AXFullScreen") != true, let frame = frame(of: window) else { return false }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard let area = (areas.first { $0.full.contains(center) } ?? areas.first)?.usable else { return false }
            var target = area
            if action == .windowLeftHalf {
                target.size.width = (area.width / 2).rounded(.down)
            } else if action == .windowRightHalf {
                target.size.width = (area.width / 2).rounded(.down)
                target.origin.x = area.maxX - target.width
            }
            return setFrame(target, of: window)
        default:
            return false
        }
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func setFrame(_ frame: CGRect, of window: AXUIElement) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return false }
        // Size, position, size: a window near a screen edge may refuse to grow until it
        // has moved, and may be clamped while moving until it has shrunk.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success
        let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent) == .success
        return moved && sized
    }
}
