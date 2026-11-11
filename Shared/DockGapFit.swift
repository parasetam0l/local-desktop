import CoreGraphics

/// Where a window goes when the Dock leaves or comes back or the desktop is turned, in
/// coordinates that grow rightwards and downwards. The left, right and bottom limits of
/// a screen's usable area are the ones that move.
enum DockGapFit {
    /// How near counts as against the Dock (tiled windows can keep a small margin); a
    /// smaller change of the usable area is not the Dock.
    static let tolerance: CGFloat = 8

    /// The frame for `window` after the usable area of `screen` went from `old` to `new`,
    /// or nil when it stays as it is. An edge against the Dock follows it into the room
    /// it left; an edge reaching into the room it takes is pulled back out.
    static func fitted(_ window: CGRect, from old: CGRect, to new: CGRect, screen: CGRect) -> CGRect? {
        let left = edge(window.minX, old.minX, new.minX, screen.minX, outward: -1)
        let right = edge(window.maxX, old.maxX, new.maxX, screen.maxX, outward: 1)
        let bottom = edge(window.maxY, old.maxY, new.maxY, screen.maxY, outward: 1)
        guard left < right, window.minY < bottom else { return nil }
        let frame = CGRect(x: left, y: window.minY, width: right - left, height: bottom - window.minY)
        return frame == window ? nil : frame
    }

    /// Whether the usable area changed by as much as a Dock takes.
    static func differs(_ old: CGRect, _ new: CGRect) -> Bool {
        abs(old.minX - new.minX) > tolerance || abs(old.maxX - new.maxX) > tolerance
            || abs(old.maxY - new.maxY) > tolerance
    }

    private static func edge(_ window: CGFloat, _ old: CGFloat, _ new: CGFloat, _ screen: CGFloat,
                             outward: CGFloat) -> CGFloat {
        let gained = (new - old) * outward
        guard abs(gained) > tolerance else { return window }
        if gained > 0 {
            return abs(window - old) <= tolerance ? new : window
        }
        guard (window - new) * outward > 0, (window - screen) * outward <= tolerance else { return window }
        return new
    }
}
