import SwiftUI

@main
struct LocalDesktopClientApp: App {
    @UIApplicationDelegateAdaptor(OrientationLock.self) private var orientationLock
    @StateObject private var app = AppModel()
    @StateObject private var updater = AppUpdater()
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false

    var body: some Scene {
        WindowGroup {
            ConnectView()
                .environmentObject(app)
                .environmentObject(updater)
        }
        .onChange(of: scenePhase, initial: true) {
            switch scenePhase {
            case .active:
                OrientationLock.apply(app.settings.lockedOrientation)
                if wasBackgrounded {
                    wasBackgrounded = false
                    // Text copied in another app while this one was away.
                    app.session?.syncClipboardToMacAfterBackgroundReturn()
                }
                Task { await updater.checkIfDue() }
            case .background:
                wasBackgrounded = true
                updater.endInstall()
            default:
                break
            }
        }
    }
}
