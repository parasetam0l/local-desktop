import Foundation

/// Pure rule for deciding when an editable Mac text field focus event should open
/// the on-screen keyboard on iOS.
enum AutoKeyboardPolicy {
    static func shouldAutoShowKeyboard(autoKeyboard: Bool,
                                       autoKeyboardInTouchpad: Bool,
                                       touchpadMode: Bool) -> Bool {
        autoKeyboard && (!touchpadMode || autoKeyboardInTouchpad)
    }
}

/// Tracks iOS clipboard sync state across app switches, reconnects, and prompt dismissals
/// so each remote pasteboard change triggers at most one iOS paste read and never loops.
struct ClientClipboardSyncState: Equatable {
    enum Trigger {
        case foregroundReturn
        case pasteCommand
        case reconnect
    }

    enum ReadKind: Equatable {
        case image
        case string
        case url
    }

    /// Suppresses redundant foreground-return syncs caused by `.inactive -> .active`
    /// bounces right after the iOS paste permission alert dismisses.
    static let promptDismissCooldown: TimeInterval = 1.5

    private(set) var syncedChangeCount: Int?
    private(set) var pendingForegroundSync = false
    private(set) var isSyncing = false
    private(set) var suppressForegroundSyncUntil: TimeInterval = -.infinity

    mutating func setSharing(_ enabled: Bool, currentChangeCount: Int) {
        syncedChangeCount = enabled ? currentChangeCount : nil
        pendingForegroundSync = false
    }

    /// Updates state after `.authOK` and returns whether `ClientSession` should sync
    /// the local clipboard right now.
    ///
    /// Initial connections baseline `changeCount` instead of reading the pasteboard,
    /// matching "What was already copied before a session isn't shared." Reconnects only
    /// sync if the user returned from background while the session was disconnected.
    mutating func didAuthenticate(isInitialConnect: Bool,
                                  sharesClipboard: Bool,
                                  currentChangeCount: Int,
                                  now: TimeInterval) -> Bool {
        guard sharesClipboard else {
            syncedChangeCount = nil
            pendingForegroundSync = false
            return false
        }
        if isInitialConnect {
            syncedChangeCount = currentChangeCount
            pendingForegroundSync = false
            return false
        }
        if syncedChangeCount == nil {
            syncedChangeCount = currentChangeCount
        }
        let shouldSync = pendingForegroundSync
        pendingForegroundSync = false
        return shouldSync
    }

    /// Handles returning to the app after being backgrounded.
    mutating func foregroundReturnShouldSync(isConnected: Bool,
                                             sharesClipboard: Bool,
                                             currentChangeCount: Int,
                                             now: TimeInterval) -> Bool {
        guard sharesClipboard else { return false }
        guard isConnected else {
            pendingForegroundSync = true
            return false
        }
        return canStartSync(trigger: .foregroundReturn,
                            isConnected: true,
                            sharesClipboard: true,
                            currentChangeCount: currentChangeCount,
                            now: now)
    }

    func canStartSync(trigger: Trigger,
                      isConnected: Bool,
                      sharesClipboard: Bool,
                      currentChangeCount: Int,
                      now: TimeInterval) -> Bool {
        guard isConnected, sharesClipboard, !isSyncing, let synced = syncedChangeCount else {
            return false
        }
        guard currentChangeCount != synced else { return false }
        if trigger == .foregroundReturn, now < suppressForegroundSyncUntil {
            return false
        }
        return true
    }

    mutating func beginSync(currentChangeCount: Int) {
        syncedChangeCount = currentChangeCount
        isSyncing = true
        pendingForegroundSync = false
    }

    mutating func endSync(currentChangeCount: Int, now: TimeInterval) {
        syncedChangeCount = currentChangeCount
        isSyncing = false
        suppressForegroundSyncUntil = now + Self.promptDismissCooldown
    }

    mutating func didReceiveFromHost(currentChangeCount: Int) {
        guard syncedChangeCount != nil else { return }
        syncedChangeCount = currentChangeCount
    }

    /// Chooses at most one typed pasteboard property to read without touching
    /// `pasteboard.types`, preferring images over plain URLs when an app puts both
    /// on the clipboard (for example Safari "Copy Image").
    static func preferredReadKind(hasImages: Bool,
                                  hasStrings: Bool,
                                  hasURLs: Bool) -> ReadKind? {
        if hasImages, !hasStrings { return .image }
        if hasStrings { return .string }
        if hasURLs { return .url }
        if hasImages { return .image }
        return nil
    }
}
