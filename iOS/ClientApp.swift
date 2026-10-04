import SwiftUI

@main
struct LocalDesktopClientApp: App {
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
            if scenePhase == .active {
                Task { await updater.checkIfDue() }
            }
        }
    }
}
