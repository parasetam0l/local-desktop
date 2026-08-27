import SwiftUI
import UIKit

/// UITextField subclass that reports backspace presses, which the normal
/// delegate API does not surface.
final class KeyboardCaptureField: UITextField {
    var onDeleteBackward: (() -> Void)?
    var onReturn: (() -> Void)?

    override func deleteBackward() {
        onDeleteBackward?()
        super.deleteBackward()
    }
}

/// Invisible text field that brings up the system keyboard and forwards every
/// typed character, delete, and return to the remote session.
struct KeyboardCapture: UIViewRepresentable {
    var isActive: Bool
    var onText: (String) -> Void
    var onDelete: () -> Void
    var onReturnKey: () -> Void

    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: KeyboardCapture

        init(_ parent: KeyboardCapture) {
            self.parent = parent
        }

        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            if string.isEmpty {
                return false // backspace handled via deleteBackward override
            }
            parent.onText(string)
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturnKey()
            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> KeyboardCaptureField {
        let field = KeyboardCaptureField(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardType = .default
        field.returnKeyType = .default
        field.textColor = .clear
        field.backgroundColor = .clear
        field.tintColor = .clear
        return field
    }

    func updateUIView(_ field: KeyboardCaptureField, context: Context) {
        field.onDeleteBackward = onDelete
        field.onReturn = onReturnKey
        DispatchQueue.main.async {
            if isActive && !field.isFirstResponder {
                field.becomeFirstResponder()
            } else if !isActive && field.isFirstResponder {
                field.resignFirstResponder()
            }
        }
    }
}
