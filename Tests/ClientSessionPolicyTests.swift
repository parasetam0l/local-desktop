import XCTest

final class ClientSessionPolicyTests: XCTestCase {
    func testAutoKeyboardPolicyDirectAndTouchpadModes() {
        XCTAssertTrue(AutoKeyboardPolicy.shouldAutoShowKeyboard(autoKeyboard: true,
                                                                autoKeyboardInTouchpad: true,
                                                                touchpadMode: true))
        XCTAssertTrue(AutoKeyboardPolicy.shouldAutoShowKeyboard(autoKeyboard: true,
                                                                autoKeyboardInTouchpad: true,
                                                                touchpadMode: false))
        XCTAssertFalse(AutoKeyboardPolicy.shouldAutoShowKeyboard(autoKeyboard: true,
                                                                 autoKeyboardInTouchpad: false,
                                                                 touchpadMode: true))
        XCTAssertTrue(AutoKeyboardPolicy.shouldAutoShowKeyboard(autoKeyboard: true,
                                                                autoKeyboardInTouchpad: false,
                                                                touchpadMode: false))
        XCTAssertFalse(AutoKeyboardPolicy.shouldAutoShowKeyboard(autoKeyboard: false,
                                                                 autoKeyboardInTouchpad: true,
                                                                 touchpadMode: true))
        XCTAssertFalse(AutoKeyboardPolicy.shouldAutoShowKeyboard(autoKeyboard: false,
                                                                 autoKeyboardInTouchpad: true,
                                                                 touchpadMode: false))
    }

    func testInitialConnectBaselinesWithoutSyncing() {
        var state = ClientClipboardSyncState()
        state.setSharing(true, currentChangeCount: 10)

        // Even if the pasteboard ticked while connecting, initial auth baselines
        // without triggering a pre-session paste prompt.
        XCTAssertFalse(state.didAuthenticate(isInitialConnect: true,
                                             sharesClipboard: true,
                                             currentChangeCount: 11,
                                             now: 100))
        XCTAssertEqual(state.syncedChangeCount, 11)
        XCTAssertFalse(state.canStartSync(trigger: .pasteCommand,
                                          isConnected: true,
                                          sharesClipboard: true,
                                          currentChangeCount: 11,
                                          now: 100))
    }

    func testInPlaceReconnectDoesNotAutoSyncButBackgroundReturnReconnectDoes() {
        var state = ClientClipboardSyncState()
        state.setSharing(true, currentChangeCount: 5)
        XCTAssertFalse(state.didAuthenticate(isInitialConnect: true,
                                             sharesClipboard: true,
                                             currentChangeCount: 5,
                                             now: 10))

        // In-place network drop/reconnect (never left app) should not prompt even if
        // Universal Clipboard bumped changeCount while the connection dropped.
        XCTAssertFalse(state.didAuthenticate(isInitialConnect: false,
                                             sharesClipboard: true,
                                             currentChangeCount: 6,
                                             now: 20))

        // User switched to another app while disconnected, copied, and returned.
        XCTAssertFalse(state.foregroundReturnShouldSync(isConnected: false,
                                                        sharesClipboard: true,
                                                        currentChangeCount: 7,
                                                        now: 30))
        XCTAssertTrue(state.didAuthenticate(isInitialConnect: false,
                                            sharesClipboard: true,
                                            currentChangeCount: 7,
                                            now: 31))
        // Consumed after one sync opportunity.
        XCTAssertFalse(state.didAuthenticate(isInitialConnect: false,
                                             sharesClipboard: true,
                                             currentChangeCount: 7,
                                             now: 32))
    }

    func testPromptDismissCooldownAndReentryGuards() {
        var state = ClientClipboardSyncState()
        state.setSharing(true, currentChangeCount: 20)
        XCTAssertFalse(state.didAuthenticate(isInitialConnect: true,
                                             sharesClipboard: true,
                                             currentChangeCount: 20,
                                             now: 100))

        // Returned from Safari with a newly copied item.
        XCTAssertTrue(state.foregroundReturnShouldSync(isConnected: true,
                                                       sharesClipboard: true,
                                                       currentChangeCount: 21,
                                                       now: 105))
        state.beginSync(currentChangeCount: 21)

        // While the iOS "Allow Paste" sheet is visible, re-entry is blocked even if changeCount bumps.
        XCTAssertFalse(state.canStartSync(trigger: .foregroundReturn,
                                          isConnected: true,
                                          sharesClipboard: true,
                                          currentChangeCount: 22,
                                          now: 105.5))
        XCTAssertFalse(state.canStartSync(trigger: .pasteCommand,
                                          isConnected: true,
                                          sharesClipboard: true,
                                          currentChangeCount: 22,
                                          now: 105.5))

        state.endSync(currentChangeCount: 21, now: 107)

        // Alert dismissal `.active` within cooldown does not re-sync even if another source bumped count.
        XCTAssertFalse(state.foregroundReturnShouldSync(isConnected: true,
                                                        sharesClipboard: true,
                                                        currentChangeCount: 22,
                                                        now: 107 + 0.2))
        // After cooldown expires, a genuinely new change can sync on foreground return.
        XCTAssertTrue(state.foregroundReturnShouldSync(isConnected: true,
                                                       sharesClipboard: true,
                                                       currentChangeCount: 22,
                                                       now: 107 + ClientClipboardSyncState.promptDismissCooldown))
    }

    func testReceivingFromHostAndTogglingSharingUpdatesBaseline() {
        var state = ClientClipboardSyncState()
        state.setSharing(true, currentChangeCount: 1)

        state.didReceiveFromHost(currentChangeCount: 4)
        XCTAssertFalse(state.canStartSync(trigger: .foregroundReturn,
                                          isConnected: true,
                                          sharesClipboard: true,
                                          currentChangeCount: 4,
                                          now: 50))

        state.setSharing(false, currentChangeCount: 4)
        XCTAssertNil(state.syncedChangeCount)
        state.didReceiveFromHost(currentChangeCount: 9)
        XCTAssertNil(state.syncedChangeCount)
    }

    func testPreferredReadKindChoosesAtMostOneType() {
        XCTAssertEqual(ClientClipboardSyncState.preferredReadKind(hasImages: true,
                                                                  hasStrings: false,
                                                                  hasURLs: true), .image)
        XCTAssertEqual(ClientClipboardSyncState.preferredReadKind(hasImages: false,
                                                                  hasStrings: true,
                                                                  hasURLs: true), .string)
        XCTAssertEqual(ClientClipboardSyncState.preferredReadKind(hasImages: false,
                                                                  hasStrings: false,
                                                                  hasURLs: true), .url)
        XCTAssertEqual(ClientClipboardSyncState.preferredReadKind(hasImages: true,
                                                                  hasStrings: true,
                                                                  hasURLs: false), .string)
        XCTAssertNil(ClientClipboardSyncState.preferredReadKind(hasImages: false,
                                                                hasStrings: false,
                                                                hasURLs: false))
    }
}
