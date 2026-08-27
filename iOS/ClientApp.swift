import SwiftUI

@main
struct LocalDesktopClientApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ConnectView()
                .environmentObject(app)
        }
    }
}
