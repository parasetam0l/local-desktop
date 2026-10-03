import UIKit

/// Zoomable, scrollable view of the remote screen with direct-mode gestures
/// and the virtual cursor used in touchpad mode.
final class CanvasScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var directTap: ((CGPoint) -> Void)?
    var directRightTap: ((CGPoint) -> Void)?
    var dragEvent: ((DragEvent) -> Void)?

    weak var controller: CanvasController?

    let containerView = UIView()
    let videoView = VideoLayerView()
    private(set) lazy var pictureInPicture = PictureInPictureCoordinator(layer: videoView.displayLayer)
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
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        addSubview(containerView)
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

    /// Lays the canvas out for a stream of `newSize` pixels (first frame or a resolution change).
    func setContentSize(_ newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0, newSize != currentContentSize else { return }
        let isFirst = currentContentSize == .zero
        currentContentSize = newSize
        videoView.isHidden = false
        applySizeUpdate(newSize, isFirst: isFirst)
    }

    private func applySizeUpdate(_ newSize: CGSize, isFirst: Bool) {
        let oldScale = self.zoomScale
        let oldMin = self.minimumZoomScale
        let wasAtMin = oldScale <= oldMin + 0.001

        // Save relative scroll position (0..1) so we can restore it after resolution change.
        // contentSize already includes the zoom scale.
        let relativeX: CGFloat
        let relativeY: CGFloat
        if contentSize.width > 0 && contentSize.height > 0 && !isFirst {
            let scrollableWidth = max(1, contentSize.width - bounds.width)
            let scrollableHeight = max(1, contentSize.height - bounds.height)
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
            contentOffset = CGPoint(
                x: max(0, min(relativeX * newScrollableWidth, newSize.width * newScale - bounds.width)),
                y: max(0, min(relativeY * newScrollableHeight, newSize.height * newScale - bounds.height))
            )
        }

        centerImage()
        updateCursorPosition()
        videoView.setNeedsLayout()
        videoView.layoutIfNeeded()
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

    // MARK: Virtual cursor

    private let cursorIndicator: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        view.backgroundColor = .white.withAlphaComponent(0.85)
        view.layer.cornerRadius = 10
        view.layer.borderWidth = 1.5
        view.layer.borderColor = UIColor.black.withAlphaComponent(0.35).cgColor
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
        let pointInScroll = videoView.convert(currentCursorPosition, to: self)
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

    /// Scrolls just enough to keep `remotePoint` out of the outer edge band while zoomed.
    func centerOn(remotePoint: CGPoint) {
        guard zoomScale > minimumZoomScale + 0.05,
              currentContentSize.width > 0, currentContentSize.height > 0 else { return }

        let pointInScroll = videoView.convert(remotePoint, to: self)

        let viewWidth = bounds.width
        let viewHeight = bounds.height
        guard viewWidth > 0, viewHeight > 0 else { return }

        // Deadzone margin (outer 18% / at least 60pt)
        let marginX = max(60.0, viewWidth * 0.18)
        let marginY = max(60.0, viewHeight * 0.18)

        var newOffset = contentOffset

        let cursorVisibleX = pointInScroll.x - contentOffset.x
        let cursorVisibleY = pointInScroll.y - contentOffset.y

        if cursorVisibleX < marginX {
            newOffset.x = pointInScroll.x - marginX
        } else if cursorVisibleX > viewWidth - marginX {
            newOffset.x = pointInScroll.x - (viewWidth - marginX)
        }

        if cursorVisibleY < marginY {
            newOffset.y = pointInScroll.y - marginY
        } else if cursorVisibleY > viewHeight - marginY {
            newOffset.y = pointInScroll.y - (viewHeight - marginY)
        }

        let maxOffsetX = max(0, contentSize.width - viewWidth)
        let maxOffsetY = max(0, contentSize.height - viewHeight)
        newOffset.x = min(max(newOffset.x, 0), maxOffsetX)
        newOffset.y = min(max(newOffset.y, 0), maxOffsetY)

        if abs(newOffset.x - contentOffset.x) > 0.5 || abs(newOffset.y - contentOffset.y) > 0.5 {
            setContentOffset(newOffset, animated: false)
        }
    }

    /// Zoom driven from the touchpad overlay (which sits on top and owns the touches).
    func zoom(by factor: CGFloat) {
        let target = max(minimumZoomScale, min(zoomScale * factor, maximumZoomScale))
        setZoomScale(target, animated: false)
    }

    // MARK: Coordinate mapping

    func remotePoint(at screenPoint: CGPoint) -> CGPoint? {
        guard currentContentSize.width > 0, currentContentSize.height > 0 else { return nil }
        let local = convert(screenPoint, to: videoView)
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
