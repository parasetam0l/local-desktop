import SwiftUI

/// 4-digit PIN entry with dot indicators and auto-submit on the fourth digit.
/// The `refreshToken` parameter lets the parent force a clean state after a
/// failed attempt.
struct PinSheet: View {
    let serverName: String
    var errorText: String?
    var refreshToken: Int
    var onCancel: (() -> Void)?
    var onSubmit: (_ pin: String, _ trust: Bool) -> Void

    @State private var pin = ""
    @State private var trust = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Enter the PIN set on \(serverName.isEmpty ? "your Mac" : serverName)")
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: 16, height: 16)
                }
            }

            TextField("", text: $pin)
                .keyboardType(.numberPad)
                .focused($focused)
                .frame(width: 2, height: 2)
                .opacity(0.01)
                .onChange(of: pin) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(4))
                    if filtered != newValue {
                        pin = filtered
                        return
                    }
                    if filtered.count == 4 {
                        onSubmit(filtered, trust)
                    }
                }

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Toggle("Trust this device (skip the PIN next time)", isOn: $trust)
                .font(.footnote)

            if let onCancel {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(24)
        .onAppear {
            focused = true
        }
        .id(refreshToken)
    }
}
