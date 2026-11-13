import AppKit
import CoreGraphics

/// Lays the Mac's desktop out at a size chosen by the client (e.g. an iPad's 4:3 screen,
/// or an iPhone held upright):
/// a virtual display of that size is created and the Mac's main display mirrors it, so
/// the whole desktop is drawn at that size and the virtual display is what gets streamed.
///
/// The virtual display comes from CoreGraphics' private `CGVirtualDisplay` classes. They
/// are looked up at run time, so the app still launches (and reports the mode as
/// unavailable) on a macOS that no longer has them. macOS removes the display and the
/// mirroring by itself when this process exits, so a crash can't leave the Mac mirrored.
@MainActor
final class SizedMirror {
    /// Limits for either side of a requested size, in points (a portrait desktop is
    /// taller than wide, so both sides share them).
    static let sideRange = RDMirrorSize.shortestSide...RDMirrorSize.longestSide
    /// macOS decides once, when a display first appears, whether it is Retina, and takes
    /// one narrower than about 960 points (so every portrait one) for a plain display of
    /// twice the size. A display that started Retina stays Retina when it is resized, so
    /// a narrow one starts at `startSize` and is resized right after.
    private static let retinaStartWidth = 1024
    private static let startSize = RDMirrorSize(width: 1024, height: 768)

    private(set) var size: RDMirrorSize?
    private(set) var displayID: CGDirectDisplayID?
    /// Kept alive for as long as the display should exist.
    private var virtualDisplay: NSObject?
    /// The display that mirrors the virtual one, to undo it on `stop()`.
    private var mirroredDisplay: CGDirectDisplayID?

    nonisolated static let isAvailable: Bool = ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
        .allSatisfy { NSClassFromString($0) != nil }

    static func clamped(_ size: RDMirrorSize) -> RDMirrorSize {
        RDMirrorSize(width: min(max(size.width, sideRange.lowerBound), sideRange.upperBound),
                     height: min(max(size.height, sideRange.lowerBound), sideRange.upperBound))
    }

    /// Lays the desktop out at `size`: creates the virtual display and makes the Mac's
    /// display mirror it, or resizes the one already there (no display is removed for
    /// that, which matters with the lid shut, where it is the only one). Returns the
    /// virtual display's id, or nil (with nothing left behind) when that failed.
    ///
    /// A new display takes a moment, and this waits for it without holding the main
    /// thread: macOS tells this process about display changes there, so until the main
    /// thread is free `CGDisplayBounds` keeps the old answer.
    func start(size requested: RDMirrorSize) async -> CGDirectDisplayID? {
        let size = Self.clamped(requested)
        if let display = virtualDisplay, let id = displayID, CGDisplayIsOnline(id) != 0 {
            guard Self.apply(size, to: display),
                  await Self.waitUntil({ Self.hasSize(size, id) }) else { return nil }
            self.size = size
            mirrorReturnedDisplays()
            return id
        }
        stop()
        guard let (display, id) = await Self.makeRetinaDisplay(size: size) else { return nil }

        // The virtual display is the one being mirrored, so its size is the desktop's size
        // (and, mirrored by the main display, it becomes the main display itself).
        // macOS can refuse the change right after the display appears, so try a few times.
        var mirrored: CGDirectDisplayID?
        for attempt in 0..<6 where mirrored == nil {
            guard let target = Self.displayToMirror(excluding: id) else { break }
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(80)) }
            if Self.mirror(target, to: id) { mirrored = target }
        }
        // With the lid shut there is no panel to mirror: the virtual display is the whole
        // desktop by itself. With the panel in use, an unmirrored display would only be a
        // second, empty desktop.
        if mirrored == nil, Self.builtinDisplay().map(Self.isUsable) == true { return nil }

        virtualDisplay = display
        displayID = id
        mirroredDisplay = mirrored
        self.size = size
        return id
    }

    /// The display that should show the same picture: the Mac's own panel, or else
    /// whatever is the main display.
    private static func displayToMirror(excluding id: CGDirectDisplayID) -> CGDirectDisplayID? {
        if let builtin = builtinDisplay(), isUsable(builtin) { return builtin }
        let main = CGMainDisplayID()
        return main != id && isUsable(main) ? main : nil
    }

    /// Ends mirroring and removes the virtual display. Safe to call when not active.
    func stop() {
        if let mirrored = mirroredDisplay {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success {
                CGConfigureDisplayMirrorOfDisplay(config, mirrored, kCGNullDirectDisplay)
                CGCompleteDisplayConfiguration(config, .forAppOnly)
            }
        }
        mirroredDisplay = nil
        virtualDisplay = nil
        displayID = nil
        size = nil
    }

    /// Makes a built-in display that came back (the lid was opened) mirror the virtual
    /// display too, instead of sitting beside it as a second desktop.
    func mirrorReturnedDisplays() {
        guard let id = displayID, mirroredDisplay.map({ CGDisplayMirrorsDisplay($0) != id }) ?? true,
              let builtin = Self.builtinDisplay(), Self.isUsable(builtin),
              CGDisplayMirrorsDisplay(builtin) != id else { return }
        if Self.mirror(builtin, to: id) { mirroredDisplay = builtin }
    }

    private static func isUsable(_ display: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(display) != 0 && CGDisplayIsActive(display) != 0
    }

    private static func mirror(_ display: CGDirectDisplayID, to master: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayMirrorOfDisplay(config, display, master) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }

    /// The Mac's own panel, if it has one that is connected.
    static func builtinDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: - Private API

    nonisolated(unsafe) private static var serial = 0

    /// Gives the display one HiDPI mode of `size`, which it then switches to.
    private static func apply(_ size: RDMirrorSize, to display: NSObject) -> Bool {
        guard let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass: AnyClass = NSClassFromString("CGVirtualDisplayMode") else { return false }
        let allocSel = NSSelectorFromString("alloc")
        let modeInitSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let applySel = NSSelectorFromString("applySettings:")
        guard modeClass.instancesRespond(to: modeInitSel), display.responds(to: applySel),
              let modeInitIMP = class_getMethodImplementation(modeClass, modeInitSel),
              let applyIMP = class_getMethodImplementation(type(of: display), applySel),
              let modeAlloc = (modeClass as AnyObject).perform(allocSel)?.takeUnretainedValue() else { return false }

        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>?
        let modeInit = unsafeBitCast(modeInitIMP, to: ModeInit.self)
        guard let mode = modeInit(modeAlloc, modeInitSel, UInt(size.width), UInt(size.height), 60)?
            .takeRetainedValue() else { return false }

        let settings = settingsClass.init()
        settings.setValue(1, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(applyIMP, to: Apply.self)(display, applySel, settings)
    }

    /// A new virtual display of `size` points that is online and Retina, or nil (the
    /// display is gone again by then).
    static func makeRetinaDisplay(size: RDMirrorSize) async -> (NSObject, CGDirectDisplayID)? {
        let first = size.width >= retinaStartWidth ? size : startSize
        guard let (display, id) = makeDisplay(size: first) else { return nil }
        // The display takes a moment to come online; configuring it before then fails.
        guard await waitUntil({ CGDisplayIsOnline(id) != 0 }) else { return nil }
        if first != size {
            guard await waitUntil({ hasSize(first, id) }), apply(size, to: display) else { return nil }
        }
        // Twice the size here means macOS took it for a plain display after all.
        guard await waitUntil({ hasSize(size, id) }) else { return nil }
        return (display, id)
    }

    private static func hasSize(_ size: RDMirrorSize, _ id: CGDirectDisplayID) -> Bool {
        let bounds = CGDisplayBounds(id)
        return Int(bounds.width) == size.width && Int(bounds.height) == size.height
    }

    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return true
    }

    private static func makeDisplay(size: RDMirrorSize) -> (NSObject, CGDirectDisplayID)? {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass: AnyClass = NSClassFromString("CGVirtualDisplay") else { return nil }
        let allocSel = NSSelectorFromString("alloc")
        let displayInitSel = NSSelectorFromString("initWithDescriptor:")
        guard displayClass.instancesRespond(to: displayInitSel) else { return nil }

        let descriptor = descriptorClass.init()
        descriptor.setValue("LocalDesktop Mirror", forKey: "name")
        // HiDPI: twice the points in each direction. Room for the largest size, so a later change only needs new settings.
        descriptor.setValue(sideRange.upperBound * 2, forKey: "maxPixelsWide")
        descriptor.setValue(sideRange.upperBound * 2, forKey: "maxPixelsHigh")
        // About 264 points per inch at 2x, like an iPad; only the proportions matter.
        descriptor.setValue(NSValue(size: NSSize(width: Double(size.width) * 25.4 / 132,
                                                 height: Double(size.height) * 25.4 / 132)),
                            forKey: "sizeInMillimeters")
        descriptor.setValue(0x4C44, forKey: "vendorID")
        descriptor.setValue(0x0001, forKey: "productID")
        // A new serial each time: one that is still being removed must not be taken for it.
        serial += 1
        descriptor.setValue(serial, forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        // `alloc` hands over a reference that `init…` consumes, hence unretained then retained.
        guard let displayAlloc = (displayClass as AnyObject).perform(allocSel)?.takeUnretainedValue(),
              let display = displayAlloc.perform(displayInitSel, with: descriptor)?.takeRetainedValue() as? NSObject,
              apply(size, to: display),
              let id = display.value(forKey: "displayID") as? UInt32, id != 0 else { return nil }
        return (display, id)
    }
}
