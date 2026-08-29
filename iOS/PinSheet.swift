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
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.18))
                    .frame(width: 64, height: 64)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
            }

            VStack(spacing: 6) {
                Text("Enter PIN")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("Set on \(serverName.isEmpty ? "your Mac" : serverName)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { index in
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
                            .frame(width: 18, height: 18)

                        if index < pin.count {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pin.count)

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
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Toggle("Trust this device (skip PIN next time)", isOn: $trust)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .tint(.blue)
                .padding(.horizontal, 4)

            if let onCancel {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .glassButton(variant: .secondary, size: .regular, isFullWidth: true)
                .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: 320)
        .glassCard(cornerRadius: 24, opacity: 0.16, shadowRadius: 24)
        .padding(24)
        .onAppear {
            focused = true
        }
        .id(refreshToken)
    }
}
