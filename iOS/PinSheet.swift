import SwiftUI

/// 4-digit PIN entry with dot indicators and auto-submit on the fourth digit.
/// The `refreshToken` parameter lets the parent force a clean state after a
/// failed attempt.
struct PinSheet: View {
    let serverName: String
    /// The Mac's identity fingerprint; the Mac shows the same value in its menu.
    var fingerprint: String = ""
    var errorText: String?
    var refreshToken: Int
    var onCancel: (() -> Void)?
    var onSubmit: (_ pin: String, _ trust: Bool) -> Void

    @State private var pin = ""
    @State private var trust = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 26))
                .foregroundStyle(SessionStyle.accent)
                .frame(width: 52, height: 52)
                .background(SessionStyle.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(spacing: 6) {
                Text("Enter PIN")
                    .font(.headline)
                Text("Set on \(serverName.isEmpty ? "your Mac" : serverName)")
                    .font(.subheadline)
                    .foregroundStyle(SessionStyle.secondaryText)
                    .multilineTextAlignment(.center)
                if !fingerprint.isEmpty {
                    Text("Fingerprint \(fingerprint)")
                        .font(.caption.monospaced())
                        .foregroundStyle(SessionStyle.secondaryText)
                        .accessibilityHint("Should match the fingerprint in the Mac's LocalDesktop menu")
                }
            }

            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { index in
                    ZStack {
                        Circle()
                            .stroke(SessionStyle.hairline, lineWidth: 1.5)
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
                    let filtered = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(4))
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
                    .foregroundStyle(SessionStyle.danger)
                    .multilineTextAlignment(.center)
            }

            Toggle("Trust this device and skip the PIN next time", isOn: $trust)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
                .background(SessionStyle.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let onCancel {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .buttonStyle(SessionButtonStyle(fullWidth: true))
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(SessionStyle.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SessionStyle.hairline, lineWidth: 0.5))
        .foregroundStyle(.white)
        .tint(SessionStyle.accent)
        .environment(\.colorScheme, .dark)
        .padding(24)
        .onAppear {
            focused = true
        }
        .id(refreshToken)
    }
}
