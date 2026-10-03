import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

/// Thread-safe handle to the renderer of the display layer the canvas is currently
/// showing. The canvas attaches its layer on the main thread; frames are enqueued
/// from the decode queue through the layer's `sampleBufferRenderer`, which (unlike
/// the layer itself) is documented as safe to feed from a background thread.
final class VideoOutput: @unchecked Sendable {
    private let lock = NSLock()
    private weak var layer: AVSampleBufferDisplayLayer?
    private var renderer: AVSampleBufferVideoRenderer?
    private var rendererContentSize: CGSize = .zero

    @MainActor
    func attach(_ layer: AVSampleBufferDisplayLayer) {
        let renderer = layer.sampleBufferRenderer
        lock.lock()
        self.layer = layer
        self.renderer = renderer
        rendererContentSize = .zero
        lock.unlock()
    }

    @MainActor
    func detach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        if self.layer === layer {
            self.layer = nil
            renderer = nil
        }
        lock.unlock()
    }

    /// Returns true when the renderer had failed or was interrupted (e.g. while the
    /// app was in the background) and needs a keyframe to recover.
    func enqueue(_ sample: CMSampleBuffer, size: CGSize) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let renderer else { return false }
        var needsKeyframe = false
        if rendererContentSize != size {
            rendererContentSize = size
            renderer.flush()
        }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            needsKeyframe = true
        }
        renderer.enqueue(sample)
        return needsKeyframe
    }
}

/// Decodes video payloads on its own queue and feeds the attached display layer.
/// Main-actor state is only touched through the two callbacks, which hop to main.
final class VideoPipeline: @unchecked Sendable {
    let output = VideoOutput()

    private let queue = DispatchQueue(label: "rd.client.decode", qos: .userInteractive)
    private let onSize: @MainActor @Sendable (CGSize) -> Void
    private let onNeedsKeyframe: @MainActor @Sendable () -> Void

    // Confined to `queue`.
    private let decoder = VideoDecoder()
    private var reportedSize: CGSize = .zero

    private let statsLock = NSLock()
    private var decodedFrames = 0
    private var lastDecodeMs: Double = 0

    /// - Parameters:
    ///   - onSize: the first frame arrived or the stream size changed.
    ///   - onNeedsKeyframe: the decoder or display layer can't continue without an IDR.
    init(onSize: @escaping @MainActor @Sendable (CGSize) -> Void,
         onNeedsKeyframe: @escaping @MainActor @Sendable () -> Void) {
        self.onSize = onSize
        self.onNeedsKeyframe = onNeedsKeyframe
    }

    func submit(_ payload: Data) {
        queue.async { self.decode(payload) }
    }

    /// Forgets stream state (parameter sets, size) before a new connection.
    func reset() {
        queue.async {
            self.decoder.reset()
            self.reportedSize = .zero
        }
    }

    func drainStats() -> (frames: Int, decodeMs: Double) {
        statsLock.lock()
        defer { statsLock.unlock() }
        let result = (decodedFrames, lastDecodeMs)
        decodedFrames = 0
        return result
    }

    private func decode(_ payload: Data) {
        guard let (width, height, codec, data) = RDFrameCodec.unpack(payload), width > 0, height > 0 else { return }
        let start = CACurrentMediaTime()
        let size = CGSize(width: width, height: height)
        decoder.decode(annexB: data, codec: codec) { sample in
            let elapsedMs = (CACurrentMediaTime() - start) * 1000.0
            statsLock.lock()
            decodedFrames += 1
            lastDecodeMs = elapsedMs
            statsLock.unlock()

            if size != reportedSize {
                reportedSize = size
                let onSize = self.onSize
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onSize(size) }
                }
            }
            if output.enqueue(sample, size: size) {
                requestKeyframe()
            }
        } onError: {
            self.requestKeyframe()
        }
    }

    private func requestKeyframe() {
        let onNeedsKeyframe = self.onNeedsKeyframe
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onNeedsKeyframe() }
        }
    }
}
