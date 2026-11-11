import XCTest

final class DockGapFitTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let withDock = CGRect(x: 0, y: 33, width: 1728, height: 1019)
    private let withoutDock = CGRect(x: 0, y: 33, width: 1728, height: 1084)

    func testWindowAgainstTheDockFillsTheGap() {
        let window = CGRect(x: 100, y: 33, width: 800, height: 1019)
        XCTAssertEqual(DockGapFit.fitted(window, from: withDock, to: withoutDock, screen: screen),
                       CGRect(x: 100, y: 33, width: 800, height: 1084))
    }

    func testWindowAwayFromTheDockStays() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 400)
        XCTAssertNil(DockGapFit.fitted(window, from: withDock, to: withoutDock, screen: screen))
        XCTAssertNil(DockGapFit.fitted(window, from: withoutDock, to: withDock, screen: screen))
    }

    func testWindowIsPushedOutWhenTheDockComesBack() {
        let window = CGRect(x: 100, y: 33, width: 800, height: 1084)
        XCTAssertEqual(DockGapFit.fitted(window, from: withoutDock, to: withDock, screen: screen),
                       CGRect(x: 100, y: 33, width: 800, height: 1019))
    }

    func testDockOnTheLeft() {
        let shown = CGRect(x: 70, y: 33, width: 1658, height: 1084)
        let hidden = CGRect(x: 0, y: 33, width: 1728, height: 1084)
        let window = CGRect(x: 70, y: 200, width: 600, height: 400)
        let stretched = CGRect(x: 0, y: 200, width: 670, height: 400)
        XCTAssertEqual(DockGapFit.fitted(window, from: shown, to: hidden, screen: screen), stretched)
        XCTAssertEqual(DockGapFit.fitted(stretched, from: hidden, to: shown, screen: screen), window)
    }

    func testWindowEntirelyWhereTheDockGoesStays() {
        let window = CGRect(x: 100, y: 1060, width: 300, height: 50)
        XCTAssertNil(DockGapFit.fitted(window, from: withoutDock, to: withDock, screen: screen))
    }

    func testFullWindowFollowsATurnToPortrait() {
        let landscape = CGRect(x: 0, y: 33, width: 1112, height: 781)
        let portrait = CGRect(x: 0, y: 33, width: 834, height: 1059)
        let both = CGRect(x: 0, y: 0, width: 1112, height: 1092)
        XCTAssertEqual(DockGapFit.fitted(landscape, from: landscape, to: portrait, screen: both), portrait)
    }

    func testFullWindowFollowsATurnToLandscape() {
        let landscape = CGRect(x: 0, y: 33, width: 1112, height: 781)
        let portrait = CGRect(x: 0, y: 33, width: 834, height: 1059)
        let both = CGRect(x: 0, y: 0, width: 1112, height: 1092)
        XCTAssertEqual(DockGapFit.fitted(portrait, from: portrait, to: landscape, screen: both), landscape)
    }

    func testSmallChangeIsNotTheDock() {
        let slightly = CGRect(x: 0, y: 33, width: 1728, height: 1023)
        XCTAssertFalse(DockGapFit.differs(withDock, slightly))
        XCTAssertTrue(DockGapFit.differs(withDock, withoutDock))
    }
}
