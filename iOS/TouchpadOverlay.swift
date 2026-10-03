import SwiftUI
import UIKit

/// Full-screen relative touchpad shown in touchpad mode:
/// - 1-finger drag moves the real Mac pointer smoothly
/// - 1-finger tap = left click at current pointer position
/// - 2-finger tap = right click at current pointer position
/// - 2-finger drag = smooth scroll (content follows the fingers)
/// - 2-finger pinch = zoom remote canvas
/// - long-press then drag = click-and-drag (mouse down → move → up)
final class TouchpadUIView: UIView, UIGestureRecognizerDelegate {
    var onMove: ((CGFloat, CGFloat) -> Void)?
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    /// Scroll deltas in points, in the direction the fingers moved.
    var onScroll: ((CGFloat, CGFloat) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    /// Incremental zoom factor.
    var onZoom: ((CGFloat) -> Void)?

    private var dragActive = false

    /// A two-finger gesture is either a scroll or a pinch; it is decided by whichever
    /// passes its threshold first, so scrolling doesn't zoom and vice versa.
    private enum TwoFingerMode {
        case undecided
        case scroll
        case zoom
    }
    private var twoFingerMode = TwoFingerMode.undecided
    private var pendingScroll = CGPoint.zero
    private var pendingZoom: CGFloat = 1
    private static let scrollDecisionDistance: CGFloat = 10
    private static let zoomDecisionScale: CGFloat = 0.08

    private let scrollPan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1

        scrollPan.addTarget(self, action: #selector(handleScrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2

        pinch.addTarget(self, action: #selector(handlePinch(_:)))

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.require(toFail: pinch)
        twoFingerTap.require(toFail: scrollPan)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3

        let tapAndDrag = UILongPressGestureRecognizer(target: self, action: #selector(handleTapAndDrag(_:)))
        tapAndDrag.numberOfTapsRequired = 1
        tapAndDrag.minimumPressDuration = 0.1

        for gesture in [pan, scrollPan, pinch, tap, twoFingerTap, longPress, tapAndDrag] {
            addGestureRecognizer(gesture)
            gesture.delegate = self
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer {
            return true
        }
        // Allow tapAndDrag to work with pan so that movement updates position.
        // We will identify tapAndDrag by its numberOfTapsRequired == 1
        if let longPress = gestureRecognizer as? UILongPressGestureRecognizer, longPress.numberOfTapsRequired == 1, otherGestureRecognizer is UIPanGestureRecognizer {
            return true
        }
        if let longPress = otherGestureRecognizer as? UILongPressGestureRecognizer, longPress.numberOfTapsRequired == 1, gestureRecognizer is UIPanGestureRecognizer {
            return true
        }
        return false
    }

    // MARK: Gestures

    private func applyBallistics(dx: CGFloat, dy: CGFloat) -> (CGFloat, CGFloat) {
        let speed = hypot(dx, dy)
        guard speed > 0 else { return (0, 0) }

        // Non-linear acceleration curve:
        // - Micro-movements (< 3.0 pt): 0.65x sub-pixel precision for accurate targeting
        // - Medium speeds (3.0 - 12.0 pt): 1.0x - 1.45x natural 1:1 motion
        // - Fast flicks (> 12.0 pt): power curve up to 3.0x to cover multi-monitor/retina displays
        let factor: CGFloat
        if speed < 3.0 {
            factor = 0.65 + (speed / 3.0) * 0.35
        } else if speed < 12.0 {
            factor = 1.0 + ((speed - 3.0) / 9.0) * 0.45
        } else {
            let extra = min(speed - 12.0, 30.0)
            factor = 1.45 + (extra / 30.0) * 1.55
        }

        return (dx * factor, dy * factor)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard gesture.state == .began || gesture.state == .changed else { return }
        let (dx, dy) = applyBallistics(dx: translation.x, dy: translation.y)
        onMove?(dx, dy)
    }

    private func isActive(_ gesture: UIGestureRecognizer) -> Bool {
        gesture.state == .began || gesture.state == .changed
    }

    private func beginTwoFingerGestureIfNeeded(other: UIGestureRecognizer) {
        guard !isActive(other) else { return }
        twoFingerMode = .undecided
        pendingScroll = .zero
        pendingZoom = 1
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            beginTwoFingerGestureIfNeeded(other: pinch)
        }
        guard isActive(gesture) else { return }
        var translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        if twoFingerMode == .undecided {
            pendingScroll.x += translation.x
            pendingScroll.y += translation.y
            guard hypot(pendingScroll.x, pendingScroll.y) > Self.scrollDecisionDistance else { return }
            twoFingerMode = .scroll
            translation = pendingScroll
        }
        guard twoFingerMode == .scroll else { return }
        onScroll?(translation.x, translation.y)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            beginTwoFingerGestureIfNeeded(other: scrollPan)
        }
        guard isActive(gesture) else { return }
        var step = gesture.scale
        gesture.scale = 1

        if twoFingerMode == .undecided {
            pendingZoom *= step
            guard abs(pendingZoom - 1) > Self.zoomDecisionScale else { return }
            twoFingerMode = .zoom
            step = pendingZoom
        }
        guard twoFingerMode == .zoom else { return }
        onZoom?(step)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !dragActive, gesture.state == .ended else { return }
        onLeftClick?()
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard !dragActive, gesture.state == .ended else { return }
        onRightClick?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onRightClick?()
    }

    @objc private func handleTapAndDrag(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            dragActive = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onDragStateChange?(true)
        case .ended, .cancelled, .failed:
            dragActive = false
            onDragStateChange?(false)
        default:
            break
        }
    }
}

struct TouchpadOverlay: UIViewRepresentable {
    let controller: CanvasController
    let onMove: (CGFloat, CGFloat) -> Void
    let onLeftClick: () -> Void
    let onRightClick: () -> Void
    let onScroll: (CGFloat, CGFloat) -> Void
    let onDragStateChange: (Bool) -> Void

    func makeUIView(context: Context) -> TouchpadUIView {
        let view = TouchpadUIView()
        bind(view)
        return view
    }

    func updateUIView(_ view: TouchpadUIView, context: Context) {
        bind(view)
    }

    private func bind(_ view: TouchpadUIView) {
        view.onMove = onMove
        view.onLeftClick = onLeftClick
        view.onRightClick = onRightClick
        view.onScroll = onScroll
        view.onDragStateChange = onDragStateChange
        view.onZoom = { [weak controller] factor in
            controller?.canvas?.zoom(by: factor)
        }
    }
}
