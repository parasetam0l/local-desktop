import SwiftUI
import UIKit

/// Full-screen relative touchpad shown in touchpad mode:
/// - 1-finger drag moves the real Mac pointer smoothly
/// - 1-finger tap = left click at current pointer position
/// - 2-finger tap = right click at current pointer position
/// - 2-finger drag = smooth scroll
/// - 2-finger pinch = zoom remote canvas
/// - long-press then drag = click-and-drag (mouse down → move → up)
final class TouchpadUIView: UIView, UIGestureRecognizerDelegate {
    var onMove: ((CGFloat, CGFloat) -> Void)?
    var onLeftClick: ((CGPoint?) -> Void)?
    var onRightClick: ((CGPoint?) -> Void)?
    var onScroll: ((CGFloat, CGFloat) -> Void)?
    var onDragEvent: ((DragEvent) -> Void)?
    var onPinch: ((UIPinchGestureRecognizer) -> Void)?

    private var dragActive = false
    private var scrollAccumulation = CGPoint.zero
    private let scrollPointsPerLine: CGFloat = 10
    private let mouseSpeed: CGFloat = 1.3

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.require(toFail: pinch)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3

        for gesture in [pan, pinch, tap, twoFingerTap, longPress] {
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
        return false
    }

    // MARK: Gestures

    private func applyBallistics(dx: CGFloat, dy: CGFloat) -> (CGFloat, CGFloat) {
        let speed = hypot(dx, dy)
        guard speed > 0 else { return (0, 0) }
        let factor = max(1.2, min(2.4, 1.2 + speed * 0.04))
        return (dx * factor, dy * factor)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard gesture.state == .began || gesture.state == .changed else { return }
        let (dx, dy) = applyBallistics(dx: translation.x, dy: translation.y)
        onMove?(dx, dy)
    }



    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        onPinch?(gesture)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !dragActive, gesture.state == .ended else { return }
        onLeftClick?(nil)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard !dragActive, gesture.state == .ended else { return }
        onRightClick?(nil)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onRightClick?(nil)
    }
}

struct TouchpadOverlay: UIViewRepresentable {
    let controller: CanvasController
    let onMove: (CGFloat, CGFloat) -> Void
    let onLeftClick: (CGPoint?) -> Void
    let onRightClick: (CGPoint?) -> Void
    let onScroll: (CGFloat, CGFloat) -> Void
    let onDrag: (DragEvent) -> Void

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
        view.onDragEvent = onDrag
        view.onPinch = { [weak controller] gesture in
            controller?.canvas?.handleExternalPinch(gesture)
        }
    }
}
