import UIKit

/// Holds the app in one orientation while the lock is on. UIKit asks the app delegate
/// which orientations are allowed, so that is what this is.
final class OrientationLock: NSObject, UIApplicationDelegate {
    private static var allowed: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowed
    }

    private static var scenes: [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    }

    /// The orientation the app is in now.
    static var current: UIInterfaceOrientation? {
        guard let scene = scenes.first else { return nil }
        if #available(iOS 26.0, *) { return scene.effectiveGeometry.interfaceOrientation }
        return scene.interfaceOrientation
    }

    /// Allows only the orientation with this `UIInterfaceOrientation` raw value, or all
    /// of them with nil.
    static func apply(_ locked: Int?) {
        allowed = locked.map { UIInterfaceOrientationMask(rawValue: 1 << UInt($0)) } ?? .allButUpsideDown
        for scene in scenes {
            var controller = scene.keyWindow?.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: allowed))
        }
    }
}
