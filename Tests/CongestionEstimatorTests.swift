import XCTest

/// The host sets the bitrate from frame delivery times (`frameAck`). These pin down
/// when it cuts and when it climbs back.
final class CongestionEstimatorTests: XCTestCase {
    /// Feeds one window (0.5 s at 60 fps) of the same delay; returns the window's verdict.
    private func window(_ estimator: inout CongestionEstimator, delay: TimeInterval,
                        factor: Double, start: TimeInterval) -> Double? {
        var result: Double?
        for frame in 0...30 {
            let now = start + Double(frame) / 60
            if let next = estimator.add(delay: delay, factor: factor, now: now) { result = next }
        }
        return result
    }

    func testSteadyDelayKeepsTheRateThenClimbsSlowly() {
        var estimator = CongestionEstimator()
        // A steady 6 ms path has no queue: the first clear window waits, the second climbs.
        XCTAssertNil(window(&estimator, delay: 0.006, factor: 1.0, start: 100))
        XCTAssertEqual(window(&estimator, delay: 0.006, factor: 1.0, start: 100.6)!, 1.1, accuracy: 0.001)
    }

    func testQueueingCutsTheRate() {
        var estimator = CongestionEstimator()
        _ = window(&estimator, delay: 0.006, factor: 1.0, start: 100)
        // 40 ms above the path's own delay: a moderate cut.
        XCTAssertEqual(window(&estimator, delay: 0.046, factor: 1.0, start: 100.6)!, 0.85, accuracy: 0.001)
        // A single 300 ms stall in a clear window doesn't cut the rate.
        var stall = CongestionEstimator()
        _ = window(&stall, delay: 0.006, factor: 1.0, start: 100)
        var verdict: Double?
        for frame in 0...30 {
            let delay = frame == 10 ? 0.3 : 0.006
            if let next = stall.add(delay: delay, factor: 1.0, now: 100.6 + Double(frame) / 60) { verdict = next }
        }
        XCTAssertGreaterThanOrEqual(verdict ?? 1.0, 1.0)
    }

    func testRateStaysWithinBounds() {
        var estimator = CongestionEstimator()
        _ = window(&estimator, delay: 0.006, factor: 0.3, start: 100)
        XCTAssertNil(window(&estimator, delay: 0.200, factor: 0.3, start: 100.6))
        var calm = CongestionEstimator()
        _ = window(&calm, delay: 0.006, factor: 1.25, start: 100)
        XCTAssertNil(window(&calm, delay: 0.006, factor: 1.25, start: 100.6))
    }
}
