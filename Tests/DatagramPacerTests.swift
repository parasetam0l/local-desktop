import XCTest

final class DatagramPacerTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t: TimeInterval = 100 }
    private final class Sent: @unchecked Sendable {
        var sizes: [Int] = []
        let lock = NSLock()
        func add(_ n: Int) { lock.lock(); sizes.append(n); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return sizes.count }
    }

    func testSmallFrameLeavesAtOnceAndLargeOneIsPaced() {
        let clock = Clock(), sent = Sent()
        let pacer = DatagramPacer(now: { clock.t }) { d, _ in sent.add(d.count) }
        pacer.setRate(bitsPerSecond: 96_000_000)   // 12,000 bytes per ms
        let small = Array(repeating: Data(count: 1200), count: 10)   // 12 KB
        let done = expectation(description: "small done")
        pacer.enqueue(small) { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(sent.count, 10)

        // 120 KB: the remaining burst credit (12 KB) goes at once, the rest waits for time.
        clock.t += 1   // credit refills to the 24 KB cap
        pacer.enqueue(Array(repeating: Data(count: 1200), count: 100)) {}
        pacer.tickForTesting()
        let afterBurst = sent.count - 10
        XCTAssertGreaterThanOrEqual(afterBurst, 20)
        XCTAssertLessThanOrEqual(afterBurst, 21)
        clock.t += 0.001   // 1 ms: 12,000 bytes more
        pacer.tickForTesting()
        // A datagram may overshoot the credit by one.
        XCTAssertTrue((10...11).contains(sent.count - 10 - afterBurst))
        // Catch-up after a late tick is capped at the burst size, so it takes a few ticks.
        for _ in 0..<10 where pacer.queuedForTesting > 0 {
            clock.t += 0.002
            pacer.tickForTesting()
        }
        XCTAssertEqual(pacer.queuedForTesting, 0)
        XCTAssertEqual(sent.count, 110)
    }

    func testRateFollowsEncoderWithFloor() {
        XCTAssertEqual(DatagramPacer.rate(forEncoderBitrate: 20_000_000), 80_000_000)
        XCTAssertEqual(DatagramPacer.rate(forEncoderBitrate: 2_000_000), DatagramPacer.minRate)
    }
}
