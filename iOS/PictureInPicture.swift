import AVKit

/// Live-stream playback delegate: the desktop is always "playing" and can't be scrubbed.
final class PiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        completion()
    }
}

/// Picture-in-Picture for the canvas's display layer.
///
/// Sample-buffer PiP requires an active `.playback` audio session, which is why the
/// app declares the `audio` background mode (no audio is ever played).
@MainActor
final class PictureInPictureCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    weak var controller: CanvasController?
    private let layer: AVSampleBufferDisplayLayer
    private var pipController: AVPictureInPictureController?
    private var playbackDelegate: PiPPlaybackDelegate?

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    private static func activateAudioSession(_ active: Bool) {
        let session = AVAudioSession.sharedInstance()
        if active {
            try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        }
        try? session.setActive(active, options: active ? [] : [.notifyOthersOnDeactivation])
    }

    private func setUp() {
        guard AVPictureInPictureController.isPictureInPictureSupported(), pipController == nil else { return }
        Self.activateAudioSession(true)
        let delegate = PiPPlaybackDelegate()
        playbackDelegate = delegate
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: delegate)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        pipController = pip
    }

    private func tearDown() {
        guard pipController != nil else { return }
        pipController = nil
        playbackDelegate = nil
        Self.activateAudioSession(false)
    }

    func setAutoPiP(_ enabled: Bool) {
        if enabled {
            setUp()
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        } else {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = false
            if !(pipController?.isPictureInPictureActive ?? false) {
                tearDown()
            }
        }
    }

    func start() {
        setUp()
        guard let pip = pipController else { return }
        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pip.startPictureInPicture()
            }
        }
    }

    func stop() {
        pipController?.stopPictureInPicture()
    }

    private func pipDidEnd() {
        controller?.isPiPActive = false
        if !(controller?.isAutoPiPEnabled ?? false) {
            tearDown()
        }
    }

    // MARK: AVPictureInPictureControllerDelegate
    // The protocol isn't main-actor annotated, so these hop explicitly.

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.controller?.isPiPActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.pipDidEnd()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.pipDidEnd()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
