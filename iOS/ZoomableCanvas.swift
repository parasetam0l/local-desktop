import SwiftUI
import UIKit
import AVFoundation

enum DragEvent {
    case began(CGPoint) // remote coordinates
    case changed(CGPoint)
    case ended
}

/// Shared handle so the touchpad overlay and session can map screen points into remote
/// coordinates and push hardware video sample buffers.
final class CanvasController: ObservableObject {
    weak var canvas: CanvasScrollView?
}

// MARK: - Video Layer View (AVSampleBufferDisplayLayer)

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

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }
}

// MARK: - Canvas Scroll View

final class CanvasScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var directTap: ((CGPoint) -> Void)?
    var directRightTap: ((CGPoint) -> Void)?
    var dragEvent: ((DragEvent) -> Void)?

    let containerView = UIView()
    let videoView = VideoLayerView()
    let imageView = UIImageView()
    private(set) var currentContentSize: CGSize = .zero
    private var lastBoundsSize: CGSize = .zero
    private var hasSetInitialZoom = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false

        videoView.isHidden = true
        imageView.isHidden = true
        imageView.contentMode = .scaleAspectFit
        imageView.isOpaque = true
        imageView.layer.magnificationFilter = .nearest

        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        addSubview(containerView)
        containerView.addSubview(imageView)
        containerView.addSubview(videoView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35

        let tapAndDrag = UILongPressGestureRecognizer(target: self, action: #selector(handleTapAndDrag(_:)))
        tapAndDrag.numberOfTapsRequired = 1
        tapAndDrag.minimumPressDuration = 0.1

        for gesture in [tap, twoFingerTap, longPress, tapAndDrag] {
            addGestureRecognizer(gesture)
            gesture.delegate = self
        }

        if let pinch = pinchGestureRecognizer {
            twoFingerTap.require(toFail: pinch)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func displaySampleBuffer(_ sampleBuffer: CMSampleBuffer, width: Int, height: Int) {
        let newSize = CGSize(width: width, height: height)
        guard width > 0, height > 0 else { return }

        let isFirst = currentContentSize == .zero
        let sizeChanged = currentContentSize != newSize

        if isFirst || sizeChanged {
            currentContentSize = newSize
            if Thread.isMainThread {
                self.applySizeUpdate(newSize, isFirst: isFirst)
            } else {
                DispatchQueue.main.sync {
                    self.applySizeUpdate(newSize, isFirst: isFirst)
                }
            }
            if sizeChanged {
                videoView.displayLayer.flush()
            }
        }

        if Thread.isMainThread {
            videoView.isHidden = false
            imageView.isHidden = true
        } else {
            DispatchQueue.main.async {
                self.videoView.isHidden = false
                self.imageView.isHidden = true
            }
        }
        
        videoView.enqueue(sampleBuffer)
    }

    private func applySizeUpdate(_ newSize: CGSize, isFirst: Bool) {
        let oldScale = self.zoomScale
        let oldMin = self.minimumZoomScale
        let wasAtMin = oldScale <= oldMin + 0.001

        // Save relative scroll position (0..1) so we can restore it after resolution change
        let oldContentSize = self.contentSize
        let relativeX: CGFloat
        let relativeY: CGFloat
        if oldContentSize.width > 0 && oldContentSize.height > 0 && !isFirst {
            let scrollableWidth = max(1, self.contentSize.width * oldScale - bounds.width)
            let scrollableHeight = max(1, self.contentSize.height * oldScale - bounds.height)
            relativeX = contentOffset.x / scrollableWidth
            relativeY = contentOffset.y / scrollableHeight
        } else {
            relativeX = 0.5
            relativeY = 0.5
        }

        self.minimumZoomScale = 1.0
        self.maximumZoomScale = 1.0
        self.zoomScale = 1.0
        
        containerView.transform = .identity
        containerView.frame = CGRect(origin: .zero, size: newSize)
        imageView.frame = CGRect(origin: .zero, size: newSize)
        videoView.frame = CGRect(origin: .zero, size: newSize)
        videoView.displayLayer.frame = CGRect(origin: .zero, size: newSize)
        contentSize = newSize
        
        updateZoomScales(resetZoom: isFirst || wasAtMin)
        
        if !isFirst && !wasAtMin {
            let relativeScale = oldScale / oldMin
            let newScale = min(max(self.minimumZoomScale * relativeScale, self.minimumZoomScale), self.maximumZoomScale)
            self.zoomScale = newScale

            // Restore scroll position relative to new content size
            let newScrollableWidth = max(1, newSize.width * newScale - bounds.width)
            let newScrollableHeight = max(1, newSize.height * newScale - bounds.height)
            let newOffsetX = relativeX * newScrollableWidth
            let newOffsetY = relativeY * newScrollableHeight
            contentOffset = CGPoint(
                x: max(0, min(newOffsetX, newSize.width * newScale - bounds.width)),
                y: max(0, min(newOffsetY, newSize.height * newScale - bounds.height))
            )
        }
        
        centerImage()
        updateCursorPosition()
        videoView.setNeedsLayout()
        videoView.layoutIfNeeded()
    }

    func setNewImage(_ newImage: UIImage) {
        let newSize = newImage.size
        guard newSize.width > 0, newSize.height > 0 else { return }

        let isFirst = currentContentSize == .zero
        let sizeChanged = currentContentSize != newSize
        currentContentSize = newSize
        imageView.image = newImage
        imageView.isHidden = false
        videoView.isHidden = true

        if isFirst || sizeChanged {
            self.minimumZoomScale = 1.0
            self.maximumZoomScale = 1.0
            self.zoomScale = 1.0

            containerView.transform = .identity
            containerView.frame = CGRect(origin: .zero, size: newSize)
            imageView.frame = CGRect(origin: .zero, size: newSize)
            videoView.frame = CGRect(origin: .zero, size: newSize)
            videoView.displayLayer.frame = CGRect(origin: .zero, size: newSize)

            contentSize = newSize
            updateZoomScales(resetZoom: isFirst)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            let oldHeight = lastBoundsSize.height
            let newHeight = bounds.size.height
            lastBoundsSize = bounds.size
            
            let oldZoom = zoomScale
            updateZoomScales(resetZoom: false)
            
            if oldHeight > 0, newHeight > 0, abs(oldZoom - zoomScale) < 0.001 {
                let heightDiff = oldHeight - newHeight
                var newOffset = contentOffset
                newOffset.y += heightDiff
                
                let maxOffsetY = max(0, contentSize.height - bounds.height)
                newOffset.y = max(0, min(newOffset.y, maxOffsetY))
                self.contentOffset = newOffset
            }
        }
        centerImage()
    }

    func updateZoomScales(resetZoom: Bool = false) {
        guard bounds.width > 0, bounds.height > 0,
              currentContentSize.width > 0, currentContentSize.height > 0 else { return }

        let fitScale = min(bounds.width / currentContentSize.width, bounds.height / currentContentSize.height)
        guard fitScale > 0 else { return }

        let prevMin = minimumZoomScale
        minimumZoomScale = fitScale
        maximumZoomScale = max(fitScale * 8.0, 4.0)

        let forceReset = !hasSetInitialZoom || resetZoom
        if forceReset || zoomScale <= prevMin + 0.001 {
            setZoomScale(fitScale, animated: false)
            if forceReset {
                hasSetInitialZoom = true
                DispatchQueue.main.async {
                    self.setZoomScale(fitScale, animated: false)
                    self.centerImage()
                }
            }
        } else if zoomScale < minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: false)
        } else if zoomScale > maximumZoomScale {
            setZoomScale(maximumZoomScale, animated: false)
        }
        centerImage()
    }

    private let cursorIndicator: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        view.backgroundColor = .white.withAlphaComponent(0.8)
        view.layer.cornerRadius = 10
        view.layer.borderWidth = 1.5
        view.layer.borderColor = UIColor.black.withAlphaComponent(0.3).cgColor
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.5
        view.layer.shadowRadius = 4
        view.layer.shadowOffset = .zero
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }()

    private(set) var currentCursorPosition: CGPoint = .zero

    func showCursor(at point: CGPoint) {
        currentCursorPosition = point
        cursorIndicator.isHidden = false
        if cursorIndicator.superview != self {
            addSubview(cursorIndicator)
        }
        bringSubviewToFront(cursorIndicator)
        updateCursorPosition()
    }

    func hideCursor() {
        cursorIndicator.isHidden = true
    }

    func updateCursorPosition() {
        guard !cursorIndicator.isHidden, currentContentSize.width > 0, currentContentSize.height > 0 else { return }
        let targetView: UIView = videoView.isHidden ? imageView : videoView
        let pointInScroll = targetView.convert(currentCursorPosition, to: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorIndicator.frame.origin = CGPoint(x: pointInScroll.x - 10, y: pointInScroll.y - 10)
        CATransaction.commit()
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        containerView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        updateCursorPosition()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCursorPosition()
    }

    private func centerImage() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let boundsSize = bounds.size
        let frame = containerView.frame

        var center = CGPoint(x: frame.width * 0.5, y: frame.height * 0.5)

        if frame.width < boundsSize.width {
            center.x += (boundsSize.width - frame.width) * 0.5
        }
        if frame.height < boundsSize.height {
            center.y += (boundsSize.height - frame.height) * 0.5
        }

        containerView.center = center
    }

    func centerOn(remotePoint: CGPoint) {
        guard zoomScale > minimumZoomScale + 0.05,
              currentContentSize.width > 0, currentContentSize.height > 0 else { return }

        let targetView: UIView = videoView.isHidden ? imageView : videoView
        let pointInView = targetView.convert(remotePoint, to: self)

        var newOffset = CGPoint(
            x: pointInView.x - bounds.width * 0.5,
            y: pointInView.y - bounds.height * 0.5
        )

        let maxOffsetX = max(0, contentSize.width - bounds.width)
        let maxOffsetY = max(0, contentSize.height - bounds.height)
        newOffset.x = min(max(newOffset.x, 0), maxOffsetX)
        newOffset.y = min(max(newOffset.y, 0), maxOffsetY)

        if abs(newOffset.x - contentOffset.x) > 1.0 || abs(newOffset.y - contentOffset.y) > 1.0 {
            setContentOffset(newOffset, animated: false)
        }
    }

    func handleExternalPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let scale = gesture.scale
            let current = zoomScale
            let target = max(minimumZoomScale, min(current * scale, maximumZoomScale))
            setZoomScale(target, animated: false)
            gesture.scale = 1.0
        default:
            break
        }
    }

    // MARK: Coordinate mapping

    func remotePoint(at screenPoint: CGPoint) -> CGPoint? {
        guard currentContentSize.width > 0, currentContentSize.height > 0 else { return nil }
        let targetView: UIView = videoView.isHidden ? imageView : videoView
        let local = convert(screenPoint, to: targetView)
        guard local.x >= -40, local.y >= -40,
              local.x <= currentContentSize.width + 40, local.y <= currentContentSize.height + 40 else { return nil }
        return CGPoint(x: min(max(local.x, 0), currentContentSize.width),
                       y: min(max(local.y, 0), currentContentSize.height))
    }

    // MARK: Gestures

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if otherGestureRecognizer is UIPinchGestureRecognizer || gestureRecognizer is UIPinchGestureRecognizer {
            return false
        }
        return true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let point = remotePoint(at: gesture.location(in: self)) else { return }
        directTap?(point)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let point = remotePoint(at: gesture.location(in: self)) else { return }
        directRightTap?(point)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let point = remotePoint(at: gesture.location(in: self)) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        directRightTap?(point)
    }

    @objc private func handleTapAndDrag(_ gesture: UILongPressGestureRecognizer) {
        guard let point = remotePoint(at: gesture.location(in: self)) else {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                isScrollEnabled = true
                dragEvent?(.ended)
            }
            return
        }

        switch gesture.state {
        case .began:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            isScrollEnabled = false
            dragEvent?(.began(point))
        case .changed:
            dragEvent?(.changed(point))
        case .ended, .cancelled, .failed:
            isScrollEnabled = true
            dragEvent?(.ended)
        default:
            break
        }
    }
}

struct ZoomableCanvas: UIViewRepresentable {
    let image: UIImage?
    let controller: CanvasController
    var onTap: ((CGPoint) -> Void)?
    var onRightTap: ((CGPoint) -> Void)?
    var onDrag: ((DragEvent) -> Void)?

    final class Coordinator {
        var lastImage: UIImage?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> CanvasScrollView {
        let view = CanvasScrollView()
        controller.canvas = view
        if let image {
            view.setNewImage(image)
            context.coordinator.lastImage = image
        }
        return view
    }

    func updateUIView(_ view: CanvasScrollView, context: Context) {
        controller.canvas = view
        view.directTap = onTap
        view.directRightTap = onRightTap
        view.dragEvent = onDrag
        if let image, image !== context.coordinator.lastImage {
            context.coordinator.lastImage = image
            view.setNewImage(image)
        }
    }
}
