import AppKit
import CoreGraphics

/// Lays the Mac's desktop out at a size chosen by the client (e.g. an iPad's 4:3 screen):
/// a virtual display of that size is created and the Mac's main display mirrors it, so
/// the whole desktop is drawn at that size and the virtual display is what gets streamed.
///
/// The virtual display comes from CoreGraphics' private `CGVirtualDisplay` classes. They
/// are looked up at run time, so the app still launches (and reports the mode as
/// unavailable) on a macOS that no longer has them. macOS removes the display and the
/// mirroring by itself when this process exits, so a crash can't leave the Mac mirrored.
final class SizedMirror {
    /// Limits for a requested size, in points.
    static let widthRange = 640...2732
    static let heightRange = 480...2048

    private(set) var size: RDMirrorSize?
    private(set) var displayID: CGDirectDisplayID?
    /// Kept alive for as long as the display should exist.
    private var virtualDisplay: NSObject?
    /// The display that mirrors the virtual one, to undo it on `stop()`.
    private var mirroredDisplay: CGDirectDisplayID?

    static var isAvailable: Bool {
        ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
            .allSatisfy { NSClassFromString($0) != nil }
    }

    static func clamped(_ size: RDMirrorSize) -> RDMirrorSize {
        RDMirrorSize(width: min(max(size.width, widthRange.lowerBound), widthRange.upperBound),
                     height: min(max(size.height, heightRange.lowerBound), heightRange.upperBound))
    }

    /// Creates the virtual display and makes the main display mirror it. Returns the
    /// virtual display's id, or nil (with nothing left behind) when that failed.
    func start(size requested: RDMirrorSize) -> CGDirectDisplayID? {
        stop()
        let size = Self.clamped(requested)
        let main = CGMainDisplayID()
        guard let (display, id) = Self.makeDisplay(size: size) else { return nil }

        // The display takes a moment to come online; configuring it before then fails.
        let deadline = Date().addingTimeInterval(2)
        while CGDisplayIsOnline(id) == 0, Date() < deadline {
            usleep(50_000)
        }

        // The virtual display is the one being mirrored, so its size is the desktop's size
        // (and, mirrored by the main display, it becomes the main display itself).
        // macOS can refuse the change right after the display appears, so try a few times.
        var mirrored = false
        for attempt in 0..<5 where !mirrored {
            if attempt > 0 { usleep(200_000) }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { continue }
            if CGConfigureDisplayMirrorOfDisplay(config, main, id) == .success {
                mirrored = CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
            } else {
                CGCancelDisplayConfiguration(config)
            }
        }
        guard mirrored else { return nil }

        virtualDisplay = display
        displayID = id
        mirroredDisplay = main
        self.size = size
        return id
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

    // MARK: - Private API

    private static func makeDisplay(size: RDMirrorSize) -> (NSObject, CGDirectDisplayID)? {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass: AnyClass = NSClassFromString("CGVirtualDisplayMode"),
              let displayClass: AnyClass = NSClassFromString("CGVirtualDisplay") else { return nil }

        let allocSel = NSSelectorFromString("alloc")
        let displayInitSel = NSSelectorFromString("initWithDescriptor:")
        let modeInitSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let applySel = NSSelectorFromString("applySettings:")
        guard displayClass.instancesRespond(to: displayInitSel), displayClass.instancesRespond(to: applySel),
              modeClass.instancesRespond(to: modeInitSel),
              let modeInitIMP = class_getMethodImplementation(modeClass, modeInitSel),
              let applyIMP = class_getMethodImplementation(displayClass, applySel) else { return nil }

        let descriptor = descriptorClass.init()
        descriptor.setValue("LocalDesktop Mirror", forKey: "name")
        // HiDPI: twice the points in each direction.
        descriptor.setValue(size.width * 2, forKey: "maxPixelsWide")
        descriptor.setValue(size.height * 2, forKey: "maxPixelsHigh")
        // About 264 points per inch at 2x, like an iPad; only the proportions matter.
        descriptor.setValue(NSValue(size: NSSize(width: Double(size.width) * 25.4 / 132,
                                                 height: Double(size.height) * 25.4 / 132)),
                            forKey: "sizeInMillimeters")
        descriptor.setValue(0x4C44, forKey: "vendorID")
        descriptor.setValue(0x0001, forKey: "productID")
        descriptor.setValue(1, forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        // `alloc` hands over a reference that `init…` consumes, hence unretained then retained.
        guard let displayAlloc = (displayClass as AnyObject).perform(allocSel)?.takeUnretainedValue(),
              let display = displayAlloc.perform(displayInitSel, with: descriptor)?.takeRetainedValue() as? NSObject,
              let modeAlloc = (modeClass as AnyObject).perform(allocSel)?.takeUnretainedValue() else { return nil }

        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>?
        let modeInit = unsafeBitCast(modeInitIMP, to: ModeInit.self)
        guard let mode = modeInit(modeAlloc, modeInitSel, UInt(size.width), UInt(size.height), 60)?
            .takeRetainedValue() else { return nil }

        let settings = settingsClass.init()
        settings.setValue(1, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard unsafeBitCast(applyIMP, to: Apply.self)(display, applySel, settings),
              let id = display.value(forKey: "displayID") as? UInt32, id != 0 else { return nil }
        return (display, id)
    }
}
