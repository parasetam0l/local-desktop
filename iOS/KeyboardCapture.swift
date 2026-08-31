import SwiftUI
import UIKit

/// Invisible text field that maintains a live dummy text buffer.
/// Maintaining a non-empty buffer ensures the iOS software keyboard's native
/// auto-repeat timer fires continuously when holding down the Backspace key.
final class RepeatingKeyboardCaptureField: UITextField, UITextFieldDelegate {
    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onReturn: (() -> Void)?

    private static let dummyBuffer = "       "

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.delegate = self
        self.text = Self.dummyBuffer
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func deleteBackward() {
        onDeleteBackward?()
        resetBuffer()
    }

    func resetBuffer() {
        DispatchQueue.main.async {
            self.text = Self.dummyBuffer
            if let endPosition = self.position(from: self.beginningOfDocument, offset: Self.dummyBuffer.count) {
                self.selectedTextRange = self.textRange(from: endPosition, to: endPosition)
            }
        }
    }

    // MARK: - UITextFieldDelegate

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if string.isEmpty {
            onDeleteBackward?()
        } else if string == "\n" {
            onReturn?()
        } else {
            onText?(string)
        }
        resetBuffer()
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn?()
        resetBuffer()
        return false
    }
}

/// Invisible text field that brings up the system keyboard and forwards every
/// typed character, delete (with continuous repeat), and return to the remote session.
struct KeyboardCapture: UIViewRepresentable {
    var isActive: Bool
    var onText: (String) -> Void
    var onDelete: () -> Void
    var onReturnKey: () -> Void

    func makeUIView(context: Context) -> RepeatingKeyboardCaptureField {
        let field = RepeatingKeyboardCaptureField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        return field
    }

    func updateUIView(_ field: RepeatingKeyboardCaptureField, context: Context) {
        field.onText = onText
        field.onDeleteBackward = onDelete
        field.onReturn = onReturnKey

        DispatchQueue.main.async {
            if isActive && !field.isFirstResponder {
                field.becomeFirstResponder()
                field.resetBuffer()
            } else if !isActive && field.isFirstResponder {
                field.resignFirstResponder()
            }
        }
    }
}

