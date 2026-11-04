import Foundation
import IOKit
import CoreGraphics

/// Tracks whether this MacBook's lid is shut and whether a non-built-in display is
/// active.
///
/// macOS separates idle sleep from forced sleep: closing the lid is a forced-sleep
/// path, and no power assertion (`PreventUserIdle*`, `caffeinate -d/-i/-s`) can keep
/// the Mac awake through it. So while the lid is shut with no external display the host
/// cannot deliver a usable screen; it uses this state to stop trying to wake/stream and
/// to tell the client why instead of flashing sleep/lock states.
///
/// IOPMrootDomain has no public notification for the lid, so the state is polled. Both
/// reads are cheap: one IORegistry property lookup plus one display-list query.
@MainActor
final class LidStateMonitor {
    private(set) var isLidClosed = false
    private(set) var hasExternalDisplay = false

    /// The lid is shut and no other display is attached: macOS is forcing (or about to
    /// force) clamshell sleep and there is no screen to capture.
    var isHeadlessClosedLid: Bool { isLidClosed && !hasExternalDisplay }

    /// Called on the main actor whenever either reading settles into a new value.
    var onChange: (() -> Void)?

    private struct Snapshot: Equatable {
        let lidClosed: Bool
        let externalDisplay: Bool
    }

    private var timer: Timer?
    private var lastPublished: Snapshot?

    private static let pollInterval: TimeInterval = 2

    func start() {
        guard timer == nil else { return }
        refresh(forceNotify: true)
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-reads both values now; the host also calls this from the sleep/wake and
    /// screen-change notifications so a stale reading doesn't outlive an event.
    func refresh(forceNotify: Bool = false) {
        let snapshot = Snapshot(lidClosed: Self.readLidClosed() ?? false,
                                externalDisplay: Self.readHasExternalDisplay())
        guard forceNotify || snapshot != lastPublished else { return }
        lastPublished = snapshot
        isLidClosed = snapshot.lidClosed
        hasExternalDisplay = snapshot.externalDisplay
        onChange?()
    }

    // MARK: Readings

    private static func readLidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service,
                                                             "AppleClamshellState" as CFString,
                                                             kCFAllocatorDefault,
                                                             0)?.takeRetainedValue() else {
            return nil
        }
        if let number = property as? NSNumber {
            return number.boolValue
        }
        if let string = property as? String {
            return string.caseInsensitiveCompare("yes") == .orderedSame || string == "1"
        }
        return nil
    }

    /// Whether a display other than the built-in one is online. A clamshell setup with
    /// an external display counts; a shut lid with only the built-in panel does not.
    private static func readHasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}
