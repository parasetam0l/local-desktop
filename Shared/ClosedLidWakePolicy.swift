import Foundation

/// Tracks explicit wake attempts while a MacBook's lid is shut with no external display,
/// separating user-initiated wakes from automatic background capture retries.
struct HostClosedLidWakeState: Equatable {
    /// Delay after an explicit wake request during which stale `screensDidSleep`
    /// notifications don't immediately cancel the wake attempt.
    static let sleepSettleWindow: TimeInterval = 2.0

    private(set) var wakeRequestedWithClosedLid = false
    private(set) var lastWakeRequestAt: TimeInterval = -.infinity

    func isHeadlessClosedLid(lidClosed: Bool, hasExternalDisplay: Bool) -> Bool {
        lidClosed && !hasExternalDisplay && !wakeRequestedWithClosedLid
    }

    mutating func beginWakeRequest(lidClosed: Bool, hasExternalDisplay: Bool, now: TimeInterval) {
        if lidClosed, !hasExternalDisplay {
            wakeRequestedWithClosedLid = true
        }
        lastWakeRequestAt = now
    }

    mutating func reset() {
        wakeRequestedWithClosedLid = false
    }

    mutating func lidOrExternalChanged(lidClosed: Bool, prevLidClosed: Bool,
                                       hasExternalDisplay: Bool, prevHasExternalDisplay: Bool) {
        if lidClosed != prevLidClosed || hasExternalDisplay != prevHasExternalDisplay {
            wakeRequestedWithClosedLid = false
        }
    }

    /// Returns `true` when a closed-lid sleep event ended an active wake override and power
    /// assertions should be updated.
    mutating func handleScreensDidSleep(lidClosed: Bool, hasExternalDisplay: Bool,
                                        isStartingSizedMirror: Bool, now: TimeInterval) -> Bool {
        guard lidClosed, !hasExternalDisplay, wakeRequestedWithClosedLid else { return false }
        guard !isStartingSizedMirror, now - lastWakeRequestAt >= Self.sleepSettleWindow else {
            return false
        }
        wakeRequestedWithClosedLid = false
        return true
    }
}

/// Pure UI/session rules for closed-lid wake behavior and overlay visibility on iOS.
enum ClientWakePolicy {
    enum ConnectedOverlayKind: Equatable {
        case none
        case lidClosed
        case sleeping
        case loading
    }

    static func shouldAutoWakeClosedLid(isInitialConnect: Bool,
                                        isHeadlessClosedLid: Bool,
                                        isDisplaySleeping: Bool) -> Bool {
        isInitialConnect && isHeadlessClosedLid && isDisplaySleeping
    }

    static func shouldShowScrollHelpers(showSetting: Bool,
                                        hasVideoFrame: Bool,
                                        isDisplaySleeping: Bool) -> Bool {
        showSetting && hasVideoFrame && !isDisplaySleeping
    }

    static func connectedOverlay(isHeadlessClosedLid: Bool,
                                 isDisplaySleeping: Bool,
                                 showsDisplaySleeping: Bool,
                                 hasVideoFrame: Bool) -> ConnectedOverlayKind {
        if isHeadlessClosedLid, isDisplaySleeping {
            return .lidClosed
        }
        if showsDisplaySleeping {
            return .sleeping
        }
        if !hasVideoFrame {
            return .loading
        }
        return .none
    }
}
