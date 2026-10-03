import AppKit

/// Running-app list (most recently used first), app activation, and Show Desktop
/// for the client's app switcher.
@MainActor
final class AppSwitcher {
    private var iconCache: [String: String] = [:]
    private var mruOrder: [String] = []
    private var appsHiddenForDesktop: [String] = []

    func trackActivation(_ bundleId: String) {
        if let idx = mruOrder.firstIndex(of: bundleId) {
            mruOrder.remove(at: idx)
        }
        mruOrder.insert(bundleId, at: 0)
    }

    func runningApps() -> [RDRunningApp] {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.activationPolicy == .regular,
           let bid = frontmost.bundleIdentifier {
            trackActivation(bid)
        }

        let apps: [RDRunningApp] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { return nil }
                return RDRunningApp(
                    bundleId: bundleId,
                    name: app.localizedName ?? bundleId,
                    isActive: app.isActive,
                    isHidden: app.isHidden,
                    iconPNG: iconPNG(for: app)
                )
            }

        return apps.sorted { app1, app2 in
            if app1.isActive != app2.isActive {
                return app1.isActive
            }
            let idx1 = mruOrder.firstIndex(of: app1.bundleId) ?? Int.max
            let idx2 = mruOrder.firstIndex(of: app2.bundleId) ?? Int.max
            if idx1 != idx2 {
                return idx1 < idx2
            }
            return app1.name.localizedCaseInsensitiveCompare(app2.name) == .orderedAscending
        }
    }

    func activate(bundleId: String) {
        if let idx = appsHiddenForDesktop.firstIndex(of: bundleId) {
            appsHiddenForDesktop.remove(at: idx)
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return }
        if app.isHidden {
            app.unhide()
        }
        app.activate(options: [.activateAllWindows])
        // Cooperative activation can refuse a request from a background app;
        // asking LaunchServices to open the running app always brings it forward.
        if let bundleURL = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config, completionHandler: nil)
        }
    }

    func toggleShowDesktop() {
        if !appsHiddenForDesktop.isEmpty {
            // Restore previously hidden apps
            for bundleId in appsHiddenForDesktop {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.unhide()
            }
            if let lastFocused = appsHiddenForDesktop.first {
                NSRunningApplication.runningApplications(withBundleIdentifier: lastFocused).first?.activate()
            }
            appsHiddenForDesktop.removeAll()
        } else {
            // Hide all visible apps to reveal desktop
            var toHide: [String] = []
            if let activeApp = NSWorkspace.shared.frontmostApplication,
               let bid = activeApp.bundleIdentifier, bid != "com.apple.finder" {
                toHide.append(bid)
            }
            for app in NSWorkspace.shared.runningApplications {
                guard app.activationPolicy == .regular,
                      !app.isHidden,
                      let bid = app.bundleIdentifier,
                      bid != "com.apple.finder" else { continue }
                if !toHide.contains(bid) {
                    toHide.append(bid)
                }
                app.hide()
            }
            appsHiddenForDesktop = toHide
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        }
    }

    private func iconPNG(for app: NSRunningApplication) -> String? {
        guard let bundleId = app.bundleIdentifier else { return nil }
        if let cached = iconCache[bundleId] {
            return cached
        }
        guard let icon = app.icon else { return nil }
        let size = NSSize(width: 64, height: 64)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        let base64 = pngData.base64EncodedString()
        iconCache[bundleId] = base64
        return base64
    }
}
