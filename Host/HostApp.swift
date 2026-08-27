import SwiftUI

/// Quits immediately when another live copy of the host is already running,
/// surfacing the existing instance instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Live processes with our bundle ID other than ourselves. A freshly
    /// killed twin can linger in this list briefly, so callers double-check.
    private func otherInstances() -> [NSRunningApplication] {
        let bundleID = Bundle.main.bundleIdentifier ?? "localdesktop.LocalDesktopHost"
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !otherInstances().isEmpty else { return }
        // Trust only a twin that is still present after the launch dust settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let existing = self.otherInstances().first else { return }
            existing.activate()
            NSApp.terminate(nil)
        }
    }
}

@main
struct LocalDesktopHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var server = HostServer.shared
    @StateObject private var auth = AuthStore.shared

    var body: some Scene {
        MenuBarExtra("Local Desktop Host", systemImage: "desktopcomputer") {
            MenuBarView()
                .environmentObject(server)
                .environmentObject(auth)
        }
        .menuBarExtraStyle(.window)
    }
}
