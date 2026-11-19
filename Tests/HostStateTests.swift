import XCTest

/// `hostState` travels between Macs and phones of different versions: older Macs omit
/// the lid fields and older clients ignore them. These pin that compatibility down.
final class HostStateTests: XCTestCase {
    func testDecodesStateFromAnOlderMac() throws {
        let legacy = Data(#"{"isLocked":false,"isDisplaySleeping":true}"#.utf8)
        let state = try XCTUnwrap(RDJSON.decode(HostStateMsg.self, from: legacy))
        XCTAssertFalse(state.isLocked)
        XCTAssertTrue(state.isDisplaySleeping)
        XCTAssertNil(state.blocksLocalInput)
        XCTAssertNil(state.isLidClosed)
        XCTAssertNil(state.hasExternalDisplay)
    }

    func testRoundTripsLidFields() throws {
        let state = HostStateMsg(isLocked: true,
                                 isDisplaySleeping: false,
                                 blocksLocalInput: false,
                                 isLidClosed: true,
                                 hasExternalDisplay: false)
        let decoded = try XCTUnwrap(RDJSON.decode(HostStateMsg.self, from: RDJSON.encode(state)))
        XCTAssertEqual(decoded, state)
    }

    func testCapsLockIsOptionalAndRoundTrips() throws {
        let legacy = Data(#"{"isLocked":false,"isDisplaySleeping":false}"#.utf8)
        XCTAssertNil(try XCTUnwrap(RDJSON.decode(HostStateMsg.self, from: legacy)).capsLock)
        let state = HostStateMsg(isLocked: false, isDisplaySleeping: false, capsLock: true)
        let decoded = try XCTUnwrap(RDJSON.decode(HostStateMsg.self, from: RDJSON.encode(state)))
        XCTAssertEqual(decoded.capsLock, true)
        XCTAssertNotEqual(decoded, HostStateMsg(isLocked: false, isDisplaySleeping: false, capsLock: false))
    }

    func testLidFieldsAreOptionalOnTheWire() throws {
        let state = HostStateMsg(isLocked: false, isDisplaySleeping: false)
        let json = String(decoding: RDJSON.encode(state), as: UTF8.self)
        XCTAssertFalse(json.contains("isLidClosed"))
        XCTAssertFalse(json.contains("hasExternalDisplay"))
        XCTAssertFalse(json.contains("secureInputActive"))
    }

    func testSecureInputActiveIsOptionalAndRoundTrips() throws {
        let legacy = Data(#"{"isLocked":false,"isDisplaySleeping":false}"#.utf8)
        XCTAssertNil(try XCTUnwrap(RDJSON.decode(HostStateMsg.self, from: legacy)).secureInputActive)
        let state = HostStateMsg(isLocked: false, isDisplaySleeping: false, blocksLocalInput: true, secureInputActive: true)
        let decoded = try XCTUnwrap(RDJSON.decode(HostStateMsg.self, from: RDJSON.encode(state)))
        XCTAssertEqual(decoded.secureInputActive, true)
        XCTAssertNotEqual(decoded, HostStateMsg(isLocked: false, isDisplaySleeping: false, blocksLocalInput: true))
    }

    func testALockOnlyCountsOnceTheDisplayIsAwake() {
        XCTAssertTrue(HostStateMsg.reportsLocked(isLocked: true, isDisplaySleeping: false))
        XCTAssertFalse(HostStateMsg.reportsLocked(isLocked: true, isDisplaySleeping: true))
        XCTAssertFalse(HostStateMsg.reportsLocked(isLocked: false, isDisplaySleeping: false))
        XCTAssertFalse(HostStateMsg.reportsLocked(isLocked: false, isDisplaySleeping: true))
    }

    func testUnlockScreenIsOptionalAndRoundTrips() throws {
        let legacy = Data(#"{"isLocked":true,"isDisplaySleeping":false}"#.utf8)
        XCTAssertNil(try XCTUnwrap(RDJSON.decode(HostStateMsg.self, from: legacy)).unlockScreen)
        let state = HostStateMsg(isLocked: true, isDisplaySleeping: false, unlockScreen: true)
        XCTAssertEqual(try XCTUnwrap(RDJSON.decode(HostStateMsg.self, from: RDJSON.encode(state))).unlockScreen, true)

        let unlock = try XCTUnwrap(RDJSON.decode(RDUnlockScreenMsg.self,
                                                 from: RDJSON.encode(RDUnlockScreenMsg(password: "p@ss wörd\"1"))))
        XCTAssertEqual(unlock.password, "p@ss wörd\"1")
        XCTAssertEqual(RDWire(rawValue: 0x5E), .unlockScreen)
    }
}
