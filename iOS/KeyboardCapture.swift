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
    /// The keyboard went away on its own (e.g. the iPad's dismiss-keyboard key).
    var onDismissed: (() -> Void)?

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

    // MARK: - Attached keyboard

    /// A key of an attached keyboard went down or up: the Mac's key code, and whether
    /// this is the press (true, also for each repeat) or the release.
    var onHardwareKey: ((UInt16, Bool) -> Void)?
    /// The modifiers held on the attached keyboard changed.
    var onHardwareModifiers: ((RDModifiers) -> Void)?

    private var hardwareModifiers: RDModifiers = []
    private var hardwareKeysDown: Set<UInt16> = []
    private var repeatTimer: Timer?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var others = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { others.insert(press); continue }
            if let modifier = HardwareKeyMap.modifier(for: key.keyCode) {
                hardwareModifiers.insert(modifier)
                onHardwareModifiers?(hardwareModifiers)
            } else if let code = HardwareKeyMap.macKeyCode(for: key.keyCode) {
                hardwareKeysDown.insert(code)
                onHardwareKey?(code, true)
                startRepeating(code)
            } else {
                others.insert(press)
            }
        }
        // Keys sent to the Mac must not also type into this (invisible) text view.
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = releaseHardwareKeys(in: presses)
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = releaseHardwareKeys(in: presses)
        if !others.isEmpty { super.pressesCancelled(others, with: event) }
    }

    private func releaseHardwareKeys(in presses: Set<UIPress>) -> Set<UIPress> {
        var others = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { others.insert(press); continue }
            if let modifier = HardwareKeyMap.modifier(for: key.keyCode) {
                hardwareModifiers.remove(modifier)
                onHardwareModifiers?(hardwareModifiers)
            } else if let code = HardwareKeyMap.macKeyCode(for: key.keyCode) {
                if hardwareKeysDown.remove(code) != nil { onHardwareKey?(code, false) }
                if hardwareKeysDown.isEmpty { stopRepeating() }
            } else {
                others.insert(press)
            }
        }
        return others
    }

    /// Lets go of everything, so nothing stays down on the Mac when the keyboard goes away.
    func releaseAllHardwareKeys() {
        stopRepeating()
        for code in hardwareKeysDown { onHardwareKey?(code, false) }
        hardwareKeysDown.removeAll()
        if !hardwareModifiers.isEmpty {
            hardwareModifiers = []
            onHardwareModifiers?([])
        }
    }

    /// Key presses made for the Mac don't repeat by themselves, so a held key is sent
    /// again like a keyboard would: after a pause, then quickly.
    private func startRepeating(_ code: UInt16) {
        stopRepeating()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.hardwareKeysDown.contains(code) else { return }
                        self.onHardwareKey?(code, true)
                    }
                }
            }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        releaseAllHardwareKeys()
        return super.resignFirstResponder()
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

    func textViewDidEndEditing(_ textView: UITextView) {
        onDismissed?()
    }

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
    var onHardwareKey: (UInt16, Bool) -> Void
    var onHardwareModifiers: (RDModifiers) -> Void
    var onDismissed: () -> Void

    final class Coordinator {
        var appliedIsActive = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> TrackpadTextView {
        let view = TrackpadTextView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        return view
    }

    func updateUIView(_ view: TrackpadTextView, context: Context) {
        view.onText = onText
        view.onDeleteBackward = onDelete
        view.onReturn = onReturnKey
        view.onArrowKey = onArrowKey
        view.onDismissed = onDismissed
        view.onHardwareKey = onHardwareKey
        view.onHardwareModifiers = onHardwareModifiers

        // Only act when the requested state changes; re-asserting it on every update
        // would bring back a keyboard the user just dismissed.
        guard context.coordinator.appliedIsActive != isActive else { return }
        context.coordinator.appliedIsActive = isActive
        let isActive = self.isActive
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


/// Reports where the system keyboard is, in this view's own coordinates, including a
/// floating or undocked iPad keyboard (which the keyboard notifications don't describe).
/// With no keyboard up the frame is an empty strip at the bottom edge.
struct KeyboardFrameTracker: UIViewRepresentable {
    var onChange: (CGRect) -> Void

    final class TrackerView: UIView {
        var onChange: ((CGRect) -> Void)?
        private let probe = ProbeView()
        private var lastFrame = CGRect.null

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            keyboardLayoutGuide.followsUndockedKeyboard = true
            probe.isHidden = true
            probe.translatesAutoresizingMaskIntoConstraints = false
            probe.onMove = { [weak self] in self?.report() }
            addSubview(probe)
            observeKeyboard()
            NSLayoutConstraint.activate([
                probe.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                probe.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.bottomAnchor),
                probe.leadingAnchor.constraint(equalTo: keyboardLayoutGuide.leadingAnchor),
                probe.trailingAnchor.constraint(equalTo: keyboardLayoutGuide.trailingAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        /// The guide can settle a little after the keyboard appears without the probe
        /// being moved again, so the keyboard's own notifications trigger more readings.
        private func observeKeyboard() {
            let names = [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
                         UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
                         UIResponder.keyboardDidHideNotification]
            for name in names {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                                       name: name, object: nil)
            }
        }

        private func readNow() {
            window?.setNeedsLayout()
            window?.layoutIfNeeded()
            setNeedsLayout()
            layoutIfNeeded()
            report()
        }

        @objc private func keyboardChanged(_ note: Notification) {
            noteFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            for delay in [0.0, 0.1, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.readNow()
                }
            }
        }

        /// The frame the keyboard's last notification announced (screen coordinates,
        /// which are this full-screen view's own).
        private var noteFrame = CGRect.zero

        private func report() {
            var frame = keyboardLayoutGuide.layoutFrame
            // When a floating keyboard appears the guide is some points too narrow until
            // the keyboard is next touched (measured: 320 instead of 334), while the
            // notification for the same keyboard already has the real width.
            if frame.width < bounds.width - 1, noteFrame.width > frame.width,
               abs(noteFrame.minX - frame.minX) < 1 {
                frame.size.width = noteFrame.width
            }
            guard frame != lastFrame else { return }
            lastFrame = frame
            // Layout can run inside a SwiftUI update; state must change after it.
            DispatchQueue.main.async { [weak self] in self?.onChange?(frame) }
        }
    }

    /// Follows the keyboard guide; dragging a floating keyboard only moves it, which
    /// doesn't lay the parent out again, hence the observers.
    final class ProbeView: UIView {
        var onMove: (() -> Void)?
        override var center: CGPoint { didSet { onMove?() } }
        override var bounds: CGRect { didSet { onMove?() } }
    }

    func makeUIView(context: Context) -> TrackerView {
        TrackerView()
    }

    func updateUIView(_ view: TrackerView, context: Context) {
        view.onChange = onChange
    }
}
