import Foundation

/// Turns frame delivery times (send to `frameAck`) into bitrate changes. The lowest
/// recent delay is the path itself; time above it is video queued somewhere on the way,
/// so a rising excess means the stream is more than the link carries.
struct CongestionEstimator {
    private var windowStart: TimeInterval = 0
    private var excessTotal: TimeInterval = 0
    private var samples = 0
    private var baseline: TimeInterval = .greatestFiniteMagnitude
    private var previousBaseline: TimeInterval = .greatestFiniteMagnitude
    private var baselineStart: TimeInterval = 0
    private var calmWindows = 0

    static let window: TimeInterval = 0.5
    static let baselineLifetime: TimeInterval = 10

    /// Adds one frame's delivery time; returns a new bitrate factor at the end of a window
    /// that calls for one.
    mutating func add(delay: TimeInterval, factor: Double,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        // The baseline is the lowest delay over the last 10 to 20 seconds, so it follows
        // a device that roams to a farther access point.
        if now - baselineStart > Self.baselineLifetime {
            previousBaseline = baseline
            baseline = .greatestFiniteMagnitude
            baselineStart = now
        }
        baseline = min(baseline, delay)
        let floor = min(baseline, previousBaseline)

        if samples == 0 { windowStart = now }
        // One frame caught in a Wi-Fi stall shouldn't cut the rate on its own: its excess
        // counts at most 60 ms, so only a run of late frames tips the window over.
        excessTotal += min(0.06, max(0, delay - floor))
        samples += 1
        guard now - windowStart >= Self.window else { return nil }

        let excessMs = excessTotal / Double(samples) * 1000
        excessTotal = 0
        samples = 0
        if excessMs > 25 {
            calmWindows = 0
            // The worse the queue, the harder the cut.
            let cut = excessMs > 45 ? 0.7 : 0.85
            let next = max(0.3, factor * cut)
            return next == factor ? nil : next
        }
        if excessMs < 8 {
            calmWindows += 1
            // Climb back one step per second of clear delivery: 10 %, so a cut from a
            // Wi-Fi hiccup is undone in seconds rather than half a minute.
            guard calmWindows >= 2 else { return nil }
            calmWindows = 0
            let next = min(1.25, factor + 0.1)
            return next == factor ? nil : next
        }
        calmWindows = 0
        return nil
    }
}
