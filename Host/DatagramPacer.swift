import Foundation
import Network

/// Sends video datagrams spread out in time instead of in one burst. A keyframe is
/// hundreds of datagrams; handed to the network at once, older Wi-Fi (a 2017 iPad)
/// dropped some, and one lost piece costs the whole frame and a new, larger keyframe.
/// A frame up to `burstBytes` still leaves at once, so ordinary frames gain no delay;
/// the rest goes at `rate`, a few times the encoder's bitrate.
final class DatagramPacer: @unchecked Sendable {
    /// Sent without waiting: covers a typical inter frame at 20 Mbit/s.
    static let burstBytes = 24_000
    /// The pacing rate is the encoder's bitrate times this, at least `minRate`.
    static let rateMultiple = 4.0
    static let minRate = 40_000_000

    private let queue = DispatchQueue(label: "rd.datagram-pacer", qos: .userInteractive)
    private let send: (Data, Bool) -> Void
    private var pending: [(datagram: Data, done: (() -> Void)?)] = []
    private var head = 0
    private var bytesPerSecond = Double(minRate) / 8
    private var credit = Double(burstBytes)
    private var lastRefill: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private let now: () -> TimeInterval

    /// `send(datagram, isLast)` runs on the pacer's queue; `isLast` marks a frame's
    /// final datagram.
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         send: @escaping (Data, Bool) -> Void) {
        self.now = now
        self.send = send
    }

    convenience init(flow: NWConnection) {
        self.init { datagram, _ in flow.send(content: datagram, completion: .idempotent) }
    }

    static func rate(forEncoderBitrate bitrate: Int) -> Int {
        max(minRate, Int(Double(bitrate) * rateMultiple))
    }

    func setRate(bitsPerSecond: Int) {
        queue.async { self.bytesPerSecond = Double(max(bitsPerSecond, 1_000_000)) / 8 }
    }

    /// Queues one frame's datagrams; `done` runs on the pacer's queue once the last
    /// of them was handed to the network.
    func enqueue(_ datagrams: [Data], done: @escaping () -> Void) {
        guard !datagrams.isEmpty else { return queue.async(execute: done) }
        queue.async {
            for (index, datagram) in datagrams.enumerated() {
                self.pending.append((datagram, index == datagrams.count - 1 ? done : nil))
            }
            self.drain()
        }
    }

    func cancel() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.pending.removeAll()
            self.head = 0
        }
    }

    /// For tests: runs `drain` as the timer would. Call on any thread.
    func tickForTesting() { queue.sync { drain() } }
    var queuedForTesting: Int { queue.sync { pending.count - head } }

    private func drain() {
        let t = now()
        if lastRefill > 0 {
            credit = min(Double(Self.burstBytes), credit + (t - lastRefill) * bytesPerSecond)
        }
        lastRefill = t
        while head < pending.count, credit > 0 {
            let item = pending[head]
            head += 1
            credit -= Double(item.datagram.count)
            send(item.datagram, item.done != nil)
            item.done?()
        }
        if head == pending.count {
            pending.removeAll(keepingCapacity: true)
            head = 0
            timer?.cancel()
            timer = nil
        } else if timer == nil {
            let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            source.schedule(deadline: .now() + .milliseconds(1), repeating: .milliseconds(1),
                            leeway: .microseconds(200))
            source.setEventHandler { [weak self] in self?.drain() }
            source.resume()
            timer = source
        }
    }
}
