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
    /// Probing above 1.0× needs enough frames (~16 fps) to genuinely load the path,
    /// so near-idle desktop intervals don't silently climb to maximum overshoot bitrate.
    static let minProbeSamples = 8

    /// Caps probing for presets whose target rate (`Sharp`, 50 Mbps) already meets or
    /// exceeds typical Wi-Fi headroom, preventing 55–62.5 Mbps bursts from causing queues.
    static func maxFactor(forBaseBitrate bitrate: Int) -> Double {
        bitrate >= 45_000_000 ? 1.0 : 1.25
    }

    /// Adds one frame's delivery time; returns a new bitrate factor at the end of a window
    /// that calls for one. Pass `allowCut: false` during startup warmup so initial IDR/handshake
    /// bursts establish baseline RTT without triggering an immediate rate crash.
    mutating func add(delay: TimeInterval, factor: Double,
                      allowCut: Bool = true,
                      maxFactor: Double = 1.25,
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

        let count = samples
        let excessMs = excessTotal / Double(count) * 1000
        excessTotal = 0
        samples = 0
        if excessMs > 25 {
            calmWindows = 0
            guard allowCut else { return nil }
            // The worse the queue, the harder the cut.
            let cut = excessMs > 45 ? 0.7 : 0.85
            let next = max(0.3, factor * cut)
            return next == factor ? nil : next
        }
        let calmThresholdMs = factor < 1.0 ? 20.0 : 8.0
        let enoughTrafficToProbe = factor < 1.0 || count >= Self.minProbeSamples
        if excessMs < calmThresholdMs, enoughTrafficToProbe {
            calmWindows += 1
            // Recover back to 1.0x faster (+15% per calm second) than probing above it (+10%).
            guard calmWindows >= 2 else { return nil }
            calmWindows = 0
            let next = factor < 1.0 ? min(1.0, factor + 0.15) : min(maxFactor, factor + 0.1)
            return next == factor ? nil : next
        }
        calmWindows = 0
        return nil
    }
}

/// Evaluates 5-second datagram loss windows consistently across both `frameAck`-driven
/// delivery logging and the 1 Hz watchdog (which catches complete datagram blackouts).
struct DatagramLossMonitor {
    /// Lost datagram frames in a 5 s window that mark it as lossy.
    static let lossyWindowFrames = 3
    /// Consecutive lossy windows required before moving video back onto reliable stream delivery.
    static let requiredLossyWindows = 2
    /// Wait slightly past 5 s so normal `frameAck`-driven rollover runs without contention.
    static let idleWindowTimeout: TimeInterval = 5.5

    private(set) var consecutiveLossyWindows = 0

    mutating func reset() {
        consecutiveLossyWindows = 0
    }

    mutating func evaluateWindow(lost: Int) -> Bool {
        consecutiveLossyWindows = lost >= Self.lossyWindowFrames ? consecutiveLossyWindows + 1 : 0
        return consecutiveLossyWindows >= Self.requiredLossyWindows
    }

    mutating func pollIdleWindow(windowStart: TimeInterval, now: TimeInterval, lost: Int) -> Bool? {
        guard now - windowStart >= Self.idleWindowTimeout else { return nil }
        return evaluateWindow(lost: lost)
    }
}
