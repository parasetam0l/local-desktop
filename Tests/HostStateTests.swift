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

    func testLidFieldsAreOptionalOnTheWire() throws {
        let state = HostStateMsg(isLocked: false, isDisplaySleeping: false)
        let json = String(decoding: RDJSON.encode(state), as: UTF8.self)
        XCTAssertFalse(json.contains("isLidClosed"))
        XCTAssertFalse(json.contains("hasExternalDisplay"))
    }

    func testALockOnlyCountsOnceTheDisplayIsAwake() {
        XCTAssertTrue(HostStateMsg.reportsLocked(isLocked: true, isDisplaySleeping: false))
        XCTAssertFalse(HostStateMsg.reportsLocked(isLocked: true, isDisplaySleeping: true))
        XCTAssertFalse(HostStateMsg.reportsLocked(isLocked: false, isDisplaySleeping: false))
        XCTAssertFalse(HostStateMsg.reportsLocked(isLocked: false, isDisplaySleeping: true))
    }
}
