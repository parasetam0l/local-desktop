import SwiftUI

@main
struct LocalDesktopClientApp: App {
    @UIApplicationDelegateAdaptor(OrientationLock.self) private var orientationLock
    @StateObject private var app = AppModel()
    @StateObject private var updater = AppUpdater()
    @Environment(\.scenePhase) private var scenePhase

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
                Task { await updater.checkIfDue() }
            case .background:
                updater.endInstall()
            default:
                break
            }
        }
    }
}
