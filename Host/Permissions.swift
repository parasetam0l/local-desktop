import AppKit
import ApplicationServices
import CoreGraphics

/// The privacy permissions sharing needs.
enum PermissionKind: CaseIterable, Identifiable, Hashable {
    case screenRecording
    case accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    /// Anchor of the matching pane in System Settings → Privacy & Security.
    fileprivate var settingsAnchor: String {
        switch self {
        case .screenRecording: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        }
    }

    /// Service name understood by `tccutil`.
    fileprivate var tccService: String {
        switch self {
        case .screenRecording: return "ScreenCapture"
        case .accessibility: return "Accessibility"
        }
    }
}

/// Checking, requesting, and repairing the host's privacy permissions.
@MainActor
enum Permissions {
    static func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    /// Shows the system prompt (only the first time macOS is asked) and adds this
    /// app to the list in System Settings, switched off.
    static func request(_ kind: PermissionKind) {
        switch kind {
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        case .accessibility: _ = InputInjector.checkAccessibility(prompt: true)
        }
    }

    static func openSettings(_ kind: PermissionKind) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Removes this app's entry for `kind`. After an update signed differently, macOS
    /// keeps showing the old entry as allowed while it no longer applies; resetting it
    /// lets the new build be added and allowed normally.
    static func reset(_ kind: PermissionKind) async {
        let bundleID = Bundle.main.bundleIdentifier ?? "localdesktop.host"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", kind.tccService, bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume()
            }
        }
    }

    /// Quits and starts a fresh copy. macOS only applies a new Screen Recording
    /// permission to processes launched after it was granted.
    static func relaunch() {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? relauncher.run()
        CrashRecoveryManager.shared.markCleanExit()
        NSApplication.shared.terminate(nil)
    }
}
