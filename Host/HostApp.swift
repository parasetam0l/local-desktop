import SwiftUI

/// Quits immediately when another live copy of the host is already running,
/// surfacing the existing instance instead.
@MainActor
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
            becomePrimaryInstance()
            return
        }
        // Trust only a twin that is still present after the launch dust settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                guard let existing = self.otherInstances().first else {
                    self.becomePrimaryInstance()
                    return
                }
                // This copy never started crash recovery or sharing, so quitting it
                // leaves the primary's supervisor and listener untouched.
                existing.activate()
                NSApp.terminate(nil)
            }
        }
    }

    private func becomePrimaryInstance() {
        CrashRecoveryManager.shared.start()
        let afterCrash = CommandLine.arguments.contains(CrashRecoveryManager.recoveredArgument)
        HostServer.shared.autoStartIfNeeded(afterCrash: afterCrash)
        // Starts Sparkle's daily update check (release builds only).
        AppUpdater.shared.start()
        // First launch, or a permission went missing (e.g. after an update): walk through setup.
        if !HostServer.shared.missingSetup.isEmpty {
            SetupWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CrashRecoveryManager.shared.markCleanExit()
    }
}

struct LocalDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var server = HostServer.shared
    @StateObject private var auth = AuthStore.shared
    @StateObject private var launchManager = LaunchManager.shared
    @StateObject private var updater = AppUpdater.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(server)
                .environmentObject(auth)
                .environmentObject(launchManager)
        } label: {
            // An arrow badge while an update is waiting to be looked at.
            Image(systemName: updater.pendingUpdateVersion == nil ? "desktopcomputer" : "desktopcomputer.and.arrow.down")
                .accessibilityLabel(updater.pendingUpdateVersion == nil
                                    ? "LocalDesktop"
                                    : "LocalDesktop, update available")
        }
        .menuBarExtraStyle(.window)
    }
}
