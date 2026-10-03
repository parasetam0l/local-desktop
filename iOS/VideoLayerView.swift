import UIKit
import AVFoundation

/// A view backed by an AVSampleBufferDisplayLayer. Frames are enqueued on it
/// directly from the decode queue through `VideoOutput`.
final class VideoLayerView: UIView {
    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resize
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        displayLayer.magnificationFilter = .nearest
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
}
