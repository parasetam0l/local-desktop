import XCTest

final class ClosedLidWakeTests: XCTestCase {
    func testHostWakeOverrideTogglesHeadlessState() {
        var state = HostClosedLidWakeState()
        XCTAssertTrue(state.isHeadlessClosedLid(lidClosed: true, hasExternalDisplay: false))
        XCTAssertFalse(state.isHeadlessClosedLid(lidClosed: false, hasExternalDisplay: false))
        XCTAssertFalse(state.isHeadlessClosedLid(lidClosed: true, hasExternalDisplay: true))

        state.beginWakeRequest(lidClosed: true, hasExternalDisplay: false, now: 100)
        XCTAssertTrue(state.wakeRequestedWithClosedLid)
        XCTAssertFalse(state.isHeadlessClosedLid(lidClosed: true, hasExternalDisplay: false))

        state.reset()
        XCTAssertFalse(state.wakeRequestedWithClosedLid)
        XCTAssertTrue(state.isHeadlessClosedLid(lidClosed: true, hasExternalDisplay: false))
    }

    func testHostSleepNotificationIgnoresStaleSleepInsideSettleWindow() {
        var state = HostClosedLidWakeState()
        state.beginWakeRequest(lidClosed: true, hasExternalDisplay: false, now: 100)

        // Inside 2s settle window or while SizedMirror is starting, stay in wake attempt.
        XCTAssertFalse(state.handleScreensDidSleep(lidClosed: true, hasExternalDisplay: false,
                                                   isStartingSizedMirror: false, now: 101.5))
        XCTAssertTrue(state.wakeRequestedWithClosedLid)

        XCTAssertFalse(state.handleScreensDidSleep(lidClosed: true, hasExternalDisplay: false,
                                                   isStartingSizedMirror: true, now: 105))
        XCTAssertTrue(state.wakeRequestedWithClosedLid)

        // Once settled, genuine closed-lid sleep clears the wake override.
        XCTAssertTrue(state.handleScreensDidSleep(lidClosed: true, hasExternalDisplay: false,
                                                  isStartingSizedMirror: false, now: 102.5))
        XCTAssertFalse(state.wakeRequestedWithClosedLid)
    }

    func testLidOrExternalDisplayChangeResetsWakeOverride() {
        var state = HostClosedLidWakeState()
        state.beginWakeRequest(lidClosed: true, hasExternalDisplay: false, now: 50)
        XCTAssertTrue(state.wakeRequestedWithClosedLid)

        state.lidOrExternalChanged(lidClosed: true, prevLidClosed: true,
                                   hasExternalDisplay: false, prevHasExternalDisplay: false)
        XCTAssertTrue(state.wakeRequestedWithClosedLid)

        state.lidOrExternalChanged(lidClosed: false, prevLidClosed: true,
                                   hasExternalDisplay: false, prevHasExternalDisplay: false)
        XCTAssertFalse(state.wakeRequestedWithClosedLid)

        state.beginWakeRequest(lidClosed: true, hasExternalDisplay: false, now: 60)
        state.lidOrExternalChanged(lidClosed: true, prevLidClosed: true,
                                   hasExternalDisplay: true, prevHasExternalDisplay: false)
        XCTAssertFalse(state.wakeRequestedWithClosedLid)
    }

    func testClientAutoWakesOnlyOnInitialConnectWithClosedLid() {
        XCTAssertTrue(ClientWakePolicy.shouldAutoWakeClosedLid(isInitialConnect: true,
                                                               isHeadlessClosedLid: true,
                                                               isDisplaySleeping: true))
        XCTAssertFalse(ClientWakePolicy.shouldAutoWakeClosedLid(isInitialConnect: false,
                                                                isHeadlessClosedLid: true,
                                                                isDisplaySleeping: true))
        XCTAssertFalse(ClientWakePolicy.shouldAutoWakeClosedLid(isInitialConnect: true,
                                                                isHeadlessClosedLid: false,
                                                                isDisplaySleeping: true))
        XCTAssertFalse(ClientWakePolicy.shouldAutoWakeClosedLid(isInitialConnect: true,
                                                                isHeadlessClosedLid: true,
                                                                isDisplaySleeping: false))
    }

    func testScrollHelpersHiddenUntilFrameAvailableAndAwake() {
        XCTAssertFalse(ClientWakePolicy.shouldShowScrollHelpers(showSetting: true,
                                                                hasVideoFrame: false,
                                                                isDisplaySleeping: true))
        XCTAssertFalse(ClientWakePolicy.shouldShowScrollHelpers(showSetting: true,
                                                                hasVideoFrame: true,
                                                                isDisplaySleeping: true))
        XCTAssertFalse(ClientWakePolicy.shouldShowScrollHelpers(showSetting: true,
                                                                hasVideoFrame: false,
                                                                isDisplaySleeping: false))
        XCTAssertFalse(ClientWakePolicy.shouldShowScrollHelpers(showSetting: false,
                                                                hasVideoFrame: true,
                                                                isDisplaySleeping: false))
        XCTAssertTrue(ClientWakePolicy.shouldShowScrollHelpers(showSetting: true,
                                                               hasVideoFrame: true,
                                                               isDisplaySleeping: false))
    }

    func testConnectedOverlaySelection() {
        XCTAssertEqual(ClientWakePolicy.connectedOverlay(isHeadlessClosedLid: true,
                                                         isDisplaySleeping: true,
                                                         showsDisplaySleeping: false,
                                                         hasVideoFrame: false),
                       .lidClosed)
        XCTAssertEqual(ClientWakePolicy.connectedOverlay(isHeadlessClosedLid: false,
                                                         isDisplaySleeping: true,
                                                         showsDisplaySleeping: true,
                                                         hasVideoFrame: false),
                       .sleeping)
        XCTAssertEqual(ClientWakePolicy.connectedOverlay(isHeadlessClosedLid: false,
                                                         isDisplaySleeping: false,
                                                         showsDisplaySleeping: false,
                                                         hasVideoFrame: false),
                       .loading)
        XCTAssertEqual(ClientWakePolicy.connectedOverlay(isHeadlessClosedLid: false,
                                                         isDisplaySleeping: false,
                                                         showsDisplaySleeping: false,
                                                         hasVideoFrame: true),
                       .none)
    }
}
