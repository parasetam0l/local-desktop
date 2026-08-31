import SwiftUI
import UIKit

/// Custom invisible UITextView with a 2D virtual coordinate grid.
/// - Supports continuous Backspace auto-repeat.
/// - Supports Spacebar Trackpad 2D cursor navigation (dispatches Left, Right, Up, Down arrow keys to macOS).
final class TrackpadTextView: UITextView, UITextViewDelegate {
    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onReturn: (() -> Void)?
    var onArrowKey: ((RDKey) -> Void)?

    private static let lineLength = 60
    private static let numLines = 60
    private static let initialLine = 30
    private static let initialCol = 30
    private static let initialOffset = initialLine * (lineLength + 1) + initialCol

    private var lastTrackedOffset: Int = TrackpadTextView.initialOffset
    private var isResettingRange = false

    private var colAccumulator: Int = 0
    private var lineAccumulator: Int = 0
    private let colThreshold: Int = 3
    private let lineThreshold: Int = 2
    private let hapticFeedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        self.delegate = self
        self.text = Array(repeating: String(repeating: " ", count: Self.lineLength), count: Self.numLines).joined(separator: "\n")
        self.selectedRange = NSRange(location: Self.initialOffset, length: 0)
        self.lastTrackedOffset = Self.initialOffset

        self.autocorrectionType = .no
        self.autocapitalizationType = .none
        self.spellCheckingType = .no
        self.smartQuotesType = .no
        self.smartDashesType = .no
        self.smartInsertDeleteType = .no
        self.keyboardType = .default
        self.returnKeyType = .default
        self.textColor = .clear
        self.backgroundColor = .clear
        self.tintColor = .clear
        self.isScrollEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func deleteBackward() {
        onDeleteBackward?()
        resetToCenter()
    }

    func resetToCenter() {
        guard !isResettingRange else { return }
        isResettingRange = true
        self.selectedRange = NSRange(location: Self.initialOffset, length: 0)
        self.lastTrackedOffset = Self.initialOffset
        self.colAccumulator = 0
        self.lineAccumulator = 0
        isResettingRange = false
    }

    // MARK: - UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text.isEmpty {
            onDeleteBackward?()
        } else if text == "\n" {
            onReturn?()
        } else {
            onText?(text)
        }
        resetToCenter()
        return false
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isResettingRange else { return }

        let newOffset = textView.selectedRange.location
        guard newOffset != lastTrackedOffset else { return }

        let lineStride = Self.lineLength + 1
        let newLine = newOffset / lineStride
        let newCol = newOffset % lineStride
        let lastLine = lastTrackedOffset / lineStride
        let lastCol = lastTrackedOffset % lineStride

        let deltaCol = newCol - lastCol
        let deltaLine = newLine - lastLine

        lastTrackedOffset = newOffset

        colAccumulator += deltaCol
        lineAccumulator += deltaLine

        if abs(colAccumulator) >= colThreshold {
            let steps = colAccumulator / colThreshold
            colAccumulator -= steps * colThreshold
            let key: RDKey = steps > 0 ? .right : .left
            for _ in 0..<abs(steps) {
                onArrowKey?(key)
            }
            hapticFeedback.selectionChanged()
        }

        if abs(lineAccumulator) >= lineThreshold {
            let steps = lineAccumulator / lineThreshold
            lineAccumulator -= steps * lineThreshold
            let key: RDKey = steps > 0 ? .down : .up
            for _ in 0..<abs(steps) {
                onArrowKey?(key)
            }
            hapticFeedback.selectionChanged()
        }

        if newLine < 5 || newLine > Self.numLines - 5 || newCol < 5 || newCol > Self.lineLength - 5 {
            DispatchQueue.main.async { [weak self] in
                self?.resetToCenter()
            }
        }
    }
}

/// Invisible text view that brings up the system keyboard and forwards every
/// typed character, continuous repeating delete, return, and Spacebar trackpad arrow navigation.
struct KeyboardCapture: UIViewRepresentable {
    var isActive: Bool
    var onText: (String) -> Void
    var onDelete: () -> Void
    var onReturnKey: () -> Void
    var onArrowKey: (RDKey) -> Void

    func makeUIView(context: Context) -> TrackpadTextView {
        let view = TrackpadTextView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        return view
    }

    func updateUIView(_ view: TrackpadTextView, context: Context) {
        view.onText = onText
        view.onDeleteBackward = onDelete
        view.onReturn = onReturnKey
        view.onArrowKey = onArrowKey

        DispatchQueue.main.async {
            if isActive && !view.isFirstResponder {
                view.becomeFirstResponder()
                view.resetToCenter()
            } else if !isActive && view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }
}

