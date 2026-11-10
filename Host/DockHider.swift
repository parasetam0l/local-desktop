import Foundation

/// Turns the Dock's own auto-hide on for a remote session and puts it back afterwards,
/// so the desktop gets its full height on a small screen. A Dock that already hides
/// itself is left alone.
///
/// It uses the private CoreDock calls System Settings uses (no Dock restart, no
/// permission), looked up at run time: on a macOS without them `isAvailable` is false.
/// While the Dock is hidden for a session a flag is kept in the defaults, so a host that
/// crashed or was killed restores the Dock the next time it starts.
enum DockHider {
    private typealias Getter = @convention(c) () -> UInt8
    private typealias Setter = @convention(c) (UInt8) -> Void
    private static let hiddenBySessionKey = "rd.dockHiddenBySession"

    private static let functions: (get: Getter, set: Setter)? = {
        // RTLD_DEFAULT: ApplicationServices is already loaded by AppKit.
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let get = dlsym(handle, "CoreDockGetAutoHideEnabled"),
              let set = dlsym(handle, "CoreDockSetAutoHideEnabled") else { return nil }
        return (unsafeBitCast(get, to: Getter.self), unsafeBitCast(set, to: Setter.self))
    }()

    static var isAvailable: Bool { functions != nil }

    /// Whether the Dock is hidden because a session asked for it.
    static var isHiddenBySession: Bool { UserDefaults.standard.bool(forKey: hiddenBySessionKey) }

    static func hide() {
        guard let functions, !isHiddenBySession, functions.get() == 0 else { return }
        UserDefaults.standard.set(true, forKey: hiddenBySessionKey)
        functions.set(1)
    }

    /// Shows the Dock again if a session hid it; also undoes what a crashed host left.
    static func restore() {
        guard isHiddenBySession else { return }
        UserDefaults.standard.removeObject(forKey: hiddenBySessionKey)
        functions?.set(0)
    }
}
