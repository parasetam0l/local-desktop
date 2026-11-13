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

    func testDatagramLossMonitorFallsBackOnlyAfterTwoLossyWindows() {
        var monitor = DatagramLossMonitor()
        XCTAssertFalse(monitor.evaluateWindow(lost: 3))
        XCTAssertEqual(monitor.consecutiveLossyWindows, 1)
        // A clean window clears the streak before falling back.
        XCTAssertFalse(monitor.evaluateWindow(lost: 2))
        XCTAssertEqual(monitor.consecutiveLossyWindows, 0)
        // Two consecutive lossy windows trigger stream fallback.
        XCTAssertFalse(monitor.evaluateWindow(lost: 3))
        XCTAssertTrue(monitor.evaluateWindow(lost: 4))
    }

    func testDatagramLossMonitorPollIdleCatchesCompleteBlackout() {
        var monitor = DatagramLossMonitor()
        // Before 5.5 s, the idle watchdog defers to live `frameAck` rollover.
        XCTAssertNil(monitor.pollIdleWindow(windowStart: 10, now: 15.0, lost: 8))
        // Window 1 with 0 acks and >= 3 expired frames advances to 1 lossy window.
        XCTAssertEqual(monitor.pollIdleWindow(windowStart: 10, now: 15.5, lost: 8), false)
        XCTAssertEqual(monitor.consecutiveLossyWindows, 1)
        // Window 2 with continued blackout triggers fallback back to reliable stream.
        XCTAssertEqual(monitor.pollIdleWindow(windowStart: 15.5, now: 21.0, lost: 8), true)
    }

    func testStartupWarmupSuppressesCutWhileLearningBaseline() {
        var estimator = CongestionEstimator()
        // Frame 1 establishes a 5 ms baseline, then a startup IDR queue spike hits 70 ms;
        // with allowCut: false, baseline stays clean and the bitrate isn't slashed.
        XCTAssertNil(estimator.add(delay: 0.005, factor: 1.0, allowCut: false, now: 100.0))
        for frame in 1...30 {
            let t = 100.0 + Double(frame) / 60
            XCTAssertNil(estimator.add(delay: 0.070, factor: 1.0, allowCut: false, now: t))
        }
        // Once warmup ends, genuine sustained queueing cuts using the learned 5 ms baseline.
        XCTAssertEqual(window(&estimator, delay: 0.045, factor: 1.0, start: 100.6)!, 0.85, accuracy: 0.001)
    }

    func testRecoveryBelowOneClimbsFaster() {
        var estimator = CongestionEstimator()
        XCTAssertNil(window(&estimator, delay: 0.006, factor: 0.60, start: 100))
        XCTAssertEqual(window(&estimator, delay: 0.006, factor: 0.60, start: 100.6)!, 0.75, accuracy: 0.001)
    }

    func testRecoveryBelowOneClimbsThroughModerateWifiJitter() {
        var estimator = CongestionEstimator()
        // Establish 4 ms path baseline while cut down to 0.30x (1st calm window).
        XCTAssertNil(window(&estimator, delay: 0.004, factor: 0.30, start: 100))
        // Typical 20 ms Wi-Fi average (16 ms excess) must still recover back toward 1.0x.
        XCTAssertEqual(window(&estimator, delay: 0.020, factor: 0.30, start: 100.6)!, 0.45, accuracy: 0.001)
    }

    func testProbingAboveOneRequiresTighterClearanceThanRecovery() {
        var estimator = CongestionEstimator()
        XCTAssertNil(window(&estimator, delay: 0.004, factor: 1.0, start: 100))
        // 16 ms excess stays steady at 1.0x instead of over-probing to 1.1x.
        XCTAssertNil(window(&estimator, delay: 0.020, factor: 1.0, start: 100.6))
    }

    func testMaxFactorCapsSharpProbingAtPresetTarget() {
        let sharpCap = CongestionEstimator.maxFactor(forBaseBitrate: RDQualityPreset.sharp.targetBitrate)
        XCTAssertEqual(sharpCap, 1.0)
        XCTAssertEqual(CongestionEstimator.maxFactor(forBaseBitrate: RDQualityPreset.high.targetBitrate), 1.25)

        var estimator = CongestionEstimator()
        XCTAssertNil(window(&estimator, delay: 0.004, factor: 1.0, start: 100))
        // With Sharp cap = 1.0, a clear window never over-probes to 1.1x.
        var verdict: Double?
        for frame in 0...30 {
            if let next = estimator.add(delay: 0.004, factor: 1.0, maxFactor: sharpCap, now: 100.6 + Double(frame) / 60) {
                verdict = next
            }
        }
        XCTAssertNil(verdict)
    }

    func testProbingAboveOneSkipsSparseLowFpsWindows() {
        var estimator = CongestionEstimator()
        // Two 0.5 s calm windows with only 2 frames each (~4 fps) must not advance above 1.0x.
        for windowIndex in 0..<2 {
            let t0 = 100.0 + Double(windowIndex) * 0.6
            XCTAssertNil(estimator.add(delay: 0.005, factor: 1.0, now: t0))
            XCTAssertNil(estimator.add(delay: 0.005, factor: 1.0, now: t0 + 0.52))
        }
        // Recovery below 1.0x still progresses even when FPS is sparse.
        var recovering = CongestionEstimator()
        XCTAssertNil(recovering.add(delay: 0.005, factor: 0.50, now: 200.0))
        XCTAssertNil(recovering.add(delay: 0.005, factor: 0.50, now: 200.52))
        XCTAssertNil(recovering.add(delay: 0.005, factor: 0.50, now: 200.6))
        XCTAssertEqual(recovering.add(delay: 0.005, factor: 0.50, now: 201.12)!, 0.65, accuracy: 0.001)
    }
}
