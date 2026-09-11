import SwiftUI

/// Quits immediately when another live copy of the host is already running,
/// surfacing the existing instance instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Live processes with our bundle ID other than ourselves. A freshly
    /// killed twin can linger in this list briefly, so callers double-check.
    private func otherInstances() -> [NSRunningApplication] {
        let bundleID = Bundle.main.bundleIdentifier ?? "localdesktop.host"
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated && kill($0.processIdentifier, 0) == 0 }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !otherInstances().isEmpty else {
            CrashRecoveryManager.shared.start()
            return
        }
        // Trust only a twin that is still present after the launch dust settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let existing = self.otherInstances().first else {
                CrashRecoveryManager.shared.start()
                return
            }
            CrashRecoveryManager.shared.markCleanExit()
            existing.activate()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CrashRecoveryManager.shared.markCleanExit()
    }
}

struct LocalDesktopHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var server = HostServer.shared
    @StateObject private var auth = AuthStore.shared
    @StateObject private var launchManager = LaunchManager.shared

    var body: some Scene {
        MenuBarExtra("Local Desktop Host", systemImage: "desktopcomputer") {
            MenuBarView()
                .environmentObject(server)
                .environmentObject(auth)
                .environmentObject(launchManager)
        }
        .menuBarExtraStyle(.window)
    }
}
